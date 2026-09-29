package net.kdt.patchjna;

import java.io.*;
import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.IllegalClassFormatException;
import java.lang.instrument.Instrumentation;
import java.lang.reflect.InvocationTargetException;
import java.nio.ByteBuffer;
import java.security.ProtectionDomain;
import java.util.ArrayList;
import java.util.List;

public class PatchJNAAgent implements ClassFileTransformer {
    
    private static final String MACOS_UTIL = "com/mojang/blaze3d/platform/MacosUtil";

    public byte[] transform(ClassLoader loader, String className, Class<?> classBeingRedefined,
    ProtectionDomain protectionDomain, byte[] classfileBuffer) throws IllegalClassFormatException {
        byte[] transformeredByteCode = classfileBuffer;
        if (className.equals("com/sun/jna/Platform")) {
            System.out.println("PatchJNAAgent: Replacing class");
            try {
                InputStream inputStream = PatchJNAAgent.class.getClassLoader().getResourceAsStream("com/sun/jna/Platform.class.patch");
                transformeredByteCode = new byte[inputStream.available()];
                DataInputStream dataInputStream = new DataInputStream(inputStream);
                dataInputStream.readFully(transformeredByteCode);
            } catch (Exception e) {
                e.printStackTrace();
            }
        } else if (MACOS_UTIL.equals(className)) {
            // Patch the original class instead of replacing it, so every field and
            // method signature Minecraft expects (which changes between versions) stays.
            try {
                byte[] patched = CocoaStubber.stubCocoaMethods(className, classfileBuffer);
                if (patched != null) {
                    transformeredByteCode = patched;
                }
            } catch (Throwable t) {
                System.out.println("PatchJNAAgent: failed to patch " + className + ", leaving it unmodified");
                t.printStackTrace();
            }
        }
        return transformeredByteCode;
    }

    public static void premain(String args, Instrumentation instrumentation) {
        System.out.println("PatchJNAAgent: premain called");
        instrumentation.addTransformer(new PatchJNAAgent());
    }

    helpers.
    
    static final class CocoaStubber {
        private static final String[] BLOCKED_PREFIXES = {"ca/weblite/objc/", "ca/weblite/nativeutils/"};

        private final byte[] cf;
        private int[] tag;
        private int[] off;

        private CocoaStubber(byte[] cf) {
            this.cf = cf;
        }

        /** @return the patched class bytes, or null if no method needed patching. */
        static byte[] stubCocoaMethods(String className, byte[] classBytes) throws IOException {
            return new CocoaStubber(classBytes).run(className);
        }

        private int u1(int p) {
            return cf[p] & 0xFF;
        }

        private int u2(int p) {
            return ((cf[p] & 0xFF) << 8) | (cf[p + 1] & 0xFF);
        }

        private int u4(int p) {
            return ByteBuffer.wrap(cf).getInt(p);
        }

        private String utf8(int idx) throws IOException {
            if (idx <= 0 || idx >= tag.length || tag[idx] != 1) {
                throw new IOException("Bad Utf8 constant index " + idx);
            }
            return new String(cf, off[idx] + 2, u2(off[idx]), "UTF-8");
        }

        private byte[] run(String className) throws IOException {
            if (cf.length < 10 || u4(0) != 0xCAFEBABE) {
                throw new IOException("Not a class file");
            }

            // Constant pool: only record where each entry is, it is never rewritten.
            int cpCount = u2(8);
            tag = new int[cpCount];
            off = new int[cpCount];
            int p = 10;
            for (int i = 1; i < cpCount; i++) {
                tag[i] = u1(p);
                off[i] = p + 1;
                switch (tag[i]) {
                    case 1: p += 3 + u2(p + 1); break;                       // Utf8
                    case 3: case 4: p += 5; break;                            // Integer, Float
                    case 5: case 6: p += 9; i++; break;                       // Long, Double (2 slots)
                    case 7: case 8: case 16: case 19: case 20: p += 3; break; // Class, String, MethodType, Module, Package
                    case 9: case 10: case 11: case 12: case 17: case 18: p += 5; break; // refs, NameAndType, (Invoke)Dynamic
                    case 15: p += 4; break;                                   // MethodHandle
                    default: throw new IOException("Unknown constant pool tag " + tag[i]);
                }
            }

            p += 6; // access_flags, this_class, super_class
            p += 2 + u2(p) * 2; // interfaces
            int fieldCount = u2(p);
            p += 2;
            for (int f = 0; f < fieldCount; f++) {
                p += 6;
                int attrCount = u2(p);
                p += 2;
                for (int a = 0; a < attrCount; a++) {
                    p += 6 + u4(p + 2);
                }
            }

            int methodCount = u2(p);
            p += 2;

            ByteArrayOutputStream bytes = new ByteArrayOutputStream(cf.length);
            DataOutputStream out = new DataOutputStream(bytes);
            out.write(cf, 0, p); // everything up to and including methods_count, unchanged

            List<String> stubbed = new ArrayList<String>();
            for (int m = 0; m < methodCount; m++) {
                int methodStart = p;
                String name = utf8(u2(p + 2));
                String desc = utf8(u2(p + 4));
                int attrCount = u2(p + 6);
                p += 8;
                int attrsStart = p;

                int codePos = -1;
                for (int a = 0; a < attrCount; a++) {
                    if ("Code".equals(utf8(u2(p)))) {
                        codePos = p;
                    }
                    p += 6 + u4(p + 2);
                }
                int methodEnd = p;

                // Constructors are left alone: stubbing them would skip super(), which
                // the verifier rejects. Everything else that touches Cocoa is stubbed.
                boolean stub = false;
                if (codePos >= 0 && !"<init>".equals(name)) {
                    int codeStart = codePos + 14;
                    stub = findBlockedReference(codeStart, codeStart + u4(codePos + 10)) != null;
                }

                if (!stub) {
                    out.write(cf, methodStart, methodEnd - methodStart);
                    continue;
                }

                out.write(cf, methodStart, 8); // access, name, descriptor, attributes_count
                int q = attrsStart;
                for (int a = 0; a < attrCount; a++) {
                    int attrLen = u4(q + 2);
                    if (q == codePos) {
                        byte[] body = defaultReturnBody(desc);
                        out.writeShort(u2(q));                 // attribute_name_index ("Code")
                        out.writeInt(2 + 2 + 4 + body.length + 2 + 2);
                        out.writeShort(2);                     // max_stack (enough for long/double)
                        out.writeShort(u2(q + 8));             // max_locals: unchanged, still covers the arguments
                        out.writeInt(body.length);
                        out.write(body);
                        out.writeShort(0);                     // exception_table_length
                        out.writeShort(0);                     // no LineNumberTable/StackMapTable/etc: body has no branches
                    } else {
                        out.write(cf, q, 6 + attrLen);
                    }
                    q += 6 + attrLen;
                }
                stubbed.add(name + desc);
            }
            out.write(cf, p, cf.length - p); // class attributes, unchanged
            out.flush();

            if (stubbed.isEmpty()) {
                System.out.println("PatchJNAAgent: " + className + " has no ca.weblite.objc references, left unmodified");
                return null;
            }
            System.out.println("PatchJNAAgent: " + className + " - stubbed " + stubbed.size()
                + " Cocoa-dependent method(s): " + stubbed);
            return bytes.toByteArray();
        }

        /** Bytecode that returns the default value ("nothing") for the given method descriptor. */
        private static byte[] defaultReturnBody(String desc) {
            switch (desc.charAt(desc.indexOf(')') + 1)) {
                case 'V': return new byte[] {(byte) 0xB1};                      // return
                case 'J': return new byte[] {0x09, (byte) 0xAD};                // lconst_0, lreturn
                case 'F': return new byte[] {0x0B, (byte) 0xAE};                // fconst_0, freturn
                case 'D': return new byte[] {0x0E, (byte) 0xAF};                // dconst_0, dreturn
                case 'L': case '[': return new byte[] {0x01, (byte) 0xB0};      // aconst_null, areturn
                default: return new byte[] {0x03, (byte) 0xAC};                 // iconst_0, ireturn (Z B C S I)
            }
        }

        /** Walks the method's instructions and returns the first blocked class it references, or null. */
        private String findBlockedReference(int pc, int end) throws IOException {
            int codeStart = pc;
            while (pc < end) {
                int op = u1(pc);
                String hit = null;
                int len;
                if (op == 0x12) {                                   // ldc
                    hit = blockedClass(u1(pc + 1));
                    len = 2;
                } else if (op == 0x13 || op == 0x14                 // ldc_w, ldc2_w
                    || (op >= 0xB2 && op <= 0xB9)                   // get/put field/static, invoke*
                    || op == 0xBB || op == 0xBD                     // new, anewarray
                    || op == 0xC0 || op == 0xC1                     // checkcast, instanceof
                    || op == 0xC5) {                                // multianewarray
                    hit = blockedClass(u2(pc + 1));
                    len = instructionLength(op, pc, codeStart);
                } else {
                    len = instructionLength(op, pc, codeStart);
                }
                if (hit != null) {
                    return hit;
                }
                pc += len;
            }
            return null;
        }

        private int instructionLength(int op, int pc, int codeStart) {
            if (op == 0xAA || op == 0xAB) {                         // tableswitch, lookupswitch
                int base = pc + 1 + ((4 - ((pc - codeStart + 1) % 4)) % 4);
                if (op == 0xAA) {
                    return base + 12 + 4 * (u4(base + 8) - u4(base + 4) + 1) - pc;
                }
                return base + 8 + 8 * u4(base + 4) - pc;
            }
            if (op == 0xC4) {                                       // wide
                return u1(pc + 1) == 0x84 ? 6 : 4;
            }
            if (op == 0x10 || op == 0x12 || (op >= 0x15 && op <= 0x19) || (op >= 0x36 && op <= 0x3A)
                || op == 0xA9 || op == 0xBC) return 2;              // bipush, ldc, xload, xstore, ret, newarray
            if (op == 0x11 || op == 0x13 || op == 0x14 || op == 0x84
                || (op >= 0x99 && op <= 0xA8) || (op >= 0xB2 && op <= 0xB8)
                || op == 0xBB || op == 0xBD || op == 0xC0 || op == 0xC1
                || op == 0xC6 || op == 0xC7) return 3;              // sipush, ldc_w, ldc2_w, iinc, branches, field/invoke, new, ...
            if (op == 0xC5) return 4;                               // multianewarray
            if (op == 0xB9 || op == 0xBA || op == 0xC8 || op == 0xC9) return 5; // invokeinterface, invokedynamic, goto_w, jsr_w
            return 1;
        }

        private String blockedClass(int idx) throws IOException {
            if (idx <= 0 || idx >= tag.length) {
                return null;
            }
            int classIdx;
            if (tag[idx] == 9 || tag[idx] == 10 || tag[idx] == 11) {    // Fieldref, Methodref, InterfaceMethodref
                classIdx = u2(off[idx]);
            } else if (tag[idx] == 7) {                                 // Class (new, checkcast, ldc Foo.class, ...)
                classIdx = idx;
            } else {
                return null;
            }
            String name = utf8(u2(off[classIdx]));
            String element = name;
            if (element.startsWith("[")) {                              // array class: [[Lca/weblite/objc/Foo;
                element = element.substring(element.lastIndexOf('[') + 1);
                if (element.startsWith("L")) {
                    element = element.substring(1);
                }
            }
            for (String prefix : BLOCKED_PREFIXES) {
                if (element.startsWith(prefix)) {
                    return name;
                }
            }
            return null;
        }
    }
}
