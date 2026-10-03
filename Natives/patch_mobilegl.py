#!/usr/bin/env python3
import re
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

APPLIED = "applied"
SKIPPED = "skipped"
FAILED = "failed"
WARNED = "warned"


def read(path):
    return path.read_text(encoding="utf-8")


def write(path, text):
    path.write_text(text, encoding="utf-8")


def replace_once(path, old, new, marker, label, required=True):
    if not path.is_file():
        print(f"[{label}] {path} not found", file=sys.stderr)
        return FAILED if required else WARNED
    text = read(path)
    if marker in text:
        print(f"[{label}] already applied")
        return SKIPPED
    if text.count(old) != 1:
        print(f"[{label}] expected block found {text.count(old)} times in {path.name}, not touching it", file=sys.stderr)
        return FAILED if required else WARNED
    write(path, text.replace(old, new, 1))
    print(f"[{label}] applied")
    return APPLIED


def ios_visibility(root):
    old = """if (APPLE AND MOBILEGL_IOS)
    target_compile_definitions(${CMAKE_PROJECT_NAME} PUBLIC MOBILEGL_IOS=1 _LIBCPP_DISABLE_AVAILABILITY)"""
    new = """if (APPLE AND MOBILEGL_IOS)
    target_compile_definitions(${CMAKE_PROJECT_NAME} PUBLIC MOBILEGL_IOS=1 _LIBCPP_DISABLE_AVAILABILITY)

    set(MOBILEGL_IOS_EXPORTED_SYMBOLS
        "${CMAKE_CURRENT_SOURCE_DIR}/MobileGL/MG_Impl/DyldInterpose/ExportedSymbols.txt")
    target_link_options(${CMAKE_PROJECT_NAME} PRIVATE
        "LINKER:-exported_symbols_list,${MOBILEGL_IOS_EXPORTED_SYMBOLS}")
    set_property(TARGET ${CMAKE_PROJECT_NAME} APPEND PROPERTY
        LINK_DEPENDS "${MOBILEGL_IOS_EXPORTED_SYMBOLS}")"""
    return replace_once(root / "CMakeLists.txt", old, new, "MOBILEGL_IOS_EXPORTED_SYMBOLS", "ios_visibility")


def ios_resolution(root):
    old = """        VkImageBlit blitRegion{};
        blitRegion.srcSubresource.aspectMask = srcBinding.aspectMask;"""
    new = """        // resolution slider: the source fbo is smaller but the dst rect can end up the same size,
        // so stretch it over the whole swapchain and let the blit scale it
        if (drawIsDefaultFbo) {
            const Int requestedSrcWidth = std::abs(srcX1 - srcX0);
            const Int requestedSrcHeight = std::abs(srcY1 - srcY0);
            const Int requestedDstWidth = std::abs(dstX1 - dstX0);
            const Int requestedDstHeight = std::abs(dstY1 - dstY0);

            const Uint32 framebufferWidth = dstBinding.extent.x();
            const Uint32 framebufferHeight = dstBinding.extent.y();

            const Bool isFullscreenScaledBlit =
                requestedSrcWidth > 0 &&
                requestedSrcHeight > 0 &&
                requestedDstWidth == requestedSrcWidth &&
                requestedDstHeight == requestedSrcHeight &&
                (requestedDstWidth != static_cast<Int>(framebufferWidth) ||
                 requestedDstHeight != static_cast<Int>(framebufferHeight));

            if (isFullscreenScaledBlit) {
                dstX0 = 0;
                dstY0 = 0;
                dstX1 = static_cast<GLint>(framebufferWidth);
                dstY1 = static_cast<GLint>(framebufferHeight);
            }
        }

        VkImageBlit blitRegion{};
        blitRegion.srcSubresource.aspectMask = srcBinding.aspectMask;"""
    target = root / "MobileGL/MG_Backend/DirectVulkan/Renderer/VulkanRenderer.cpp"
    return replace_once(target, old, new, "isFullscreenScaledBlit", "ios_resolution")


def hash_shim(root):
    shim_rel = "MobileGL/MG_Util/Compat/libcxx_hash_shim.cpp"
    anchor = "MobileGL/MG_Util/Debug/Log.cpp"

    src = HERE / "libcxx_hash_shim.cpp"
    dst = root / shim_rel
    if src.is_file():
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dst)
        print("[hash_shim] copied libcxx_hash_shim.cpp")
    elif not dst.is_file():
        print(f"[hash_shim] {src} missing and {shim_rel} not in the checkout", file=sys.stderr)
        return FAILED

    target = root / "CMakeLists.txt"
    if not target.is_file():
        print(f"[hash_shim] {target} not found", file=sys.stderr)
        return FAILED
    text = read(target)
    if shim_rel in text:
        print("[hash_shim] cmake entry already there")
        return SKIPPED
    if anchor not in text:
        print(f"[hash_shim] anchor {anchor} not in CMakeLists.txt, upstream moved it", file=sys.stderr)
        return FAILED

    out = []
    done = False
    for line in text.splitlines(keepends=True):
        out.append(line)
        if not done and anchor in line:
            out.append(f"\n    {shim_rel}\n")
            done = True
    write(target, "".join(out))
    print("[hash_shim] applied")
    return APPLIED


def enable_availability(root):
    target = root / "CMakeLists.txt"
    if not target.is_file():
        print(f"[enable_availability] {target} not found", file=sys.stderr)
        return FAILED
    text = read(target)
    if "_LIBCPP_DISABLE_AVAILABILITY" not in text:
        print("[enable_availability] already applied")
        return SKIPPED
    pattern = re.compile(
        r"(target_compile_definitions\(\$\{CMAKE_PROJECT_NAME\}(?:_s)? PUBLIC MOBILEGL_IOS=1) _LIBCPP_DISABLE_AVAILABILITY(\))")
    text, count = pattern.subn(r"\1\2", text)
    if count == 0:
        print("[enable_availability] pattern not found, CMakeLists.txt changed upstream", file=sys.stderr)
        return FAILED
    write(target, text)
    print(f"[enable_availability] applied to {count} target(s)")
    return APPLIED


def glslang(root):
    target = root / "3rdparty/glslang/SPIRV/GlslangToSpv.cpp"
    old = """// Convert a glslang AST swizzle node to a swizzle vector for building SPIR-V.
void TGlslangToSpvTraverser::convertSwizzle(const glslang::TIntermAggregate& node, std::vector<unsigned>& swizzle)
{
    const glslang::TIntermSequence& swizzleSequence = node.getSequence();
    for (int i = 0; i < (int)swizzleSequence.size(); ++i)
        swizzle.push_back(swizzleSequence[i]->getAsConstantUnion()->getConstArray()[0].getIConst());
}"""
    new = """// Convert a glslang AST swizzle node to a swizzle vector for building SPIR-V.
void TGlslangToSpvTraverser::convertSwizzle(const glslang::TIntermAggregate& node, std::vector<unsigned>& swizzle)
{
    const glslang::TIntermSequence& swizzleSequence = node.getSequence();
    for (int i = 0; i < (int)swizzleSequence.size(); ++i) {
        // non-constant index node used to null deref and kill the whole jvm, fall back to .x instead
        const glslang::TIntermConstantUnion* constUnion = swizzleSequence[i]->getAsConstantUnion();
        if (constUnion == nullptr) {
            fprintf(stderr, "[glslang] convertSwizzle: non-constant swizzle index element %d, using component 0\\n", i);
            swizzle.push_back(0);
            continue;
        }
        swizzle.push_back(constUnion->getConstArray()[0].getIConst());
    }
}"""
    return replace_once(target, old, new, "using component 0", "glslang", required=False)


def adopt_t0_cloexec(root):
    target = root / "MobileGL/MG_Remote/Transport/AdoptT0.cpp"
    if not target.is_file():
        print("[adopt_t0] AdoptT0.cpp not in this checkout, nothing to do")
        return SKIPPED
    text = read(target)
    if "MGL_SOCK_CLOEXEC" in text:
        print("[adopt_t0] already applied")
        return SKIPPED
    if "SOCK_STREAM | SOCK_CLOEXEC" not in text:
        print("[adopt_t0] SOCK_CLOEXEC use not found, probably fixed upstream")
        return SKIPPED
    header = """#include "AdoptT0.h"
"""
    block = """#include "AdoptT0.h"

#if !defined(_WIN32)
#include <sys/socket.h>
#endif
#if defined(SOCK_CLOEXEC)
#define MGL_SOCK_CLOEXEC SOCK_CLOEXEC
#else
#define MGL_SOCK_CLOEXEC 0
#endif
"""
    if text.count(header) != 1:
        print("[adopt_t0] include anchor not found", file=sys.stderr)
        return FAILED
    text = text.replace(header, block, 1).replace("SOCK_STREAM | SOCK_CLOEXEC", "SOCK_STREAM | MGL_SOCK_CLOEXEC")
    write(target, text)
    print("[adopt_t0] applied")
    return APPLIED


def msg_nosignal(root):
    results = []
    for rel in ("MobileGL/MG_Remote/Transport/SocketTransport.cpp", "MobileGL/MG_Remote/Transport/StreamLink.cpp"):
        target = root / rel
        if not target.is_file():
            results.append(SKIPPED)
            continue
        text = read(target)
        if "MGL_MSG_NOSIGNAL_FIX" in text:
            print(f"[msg_nosignal] {target.name} already applied")
            results.append(SKIPPED)
            continue
        if "MSG_NOSIGNAL" not in text:
            results.append(SKIPPED)
            continue
        lines = text.splitlines(keepends=True)
        idx = next((i for i, l in enumerate(lines) if l.startswith("namespace MobileGL")), None)
        if idx is None:
            print(f"[msg_nosignal] no namespace anchor in {target.name}", file=sys.stderr)
            results.append(WARNED)
            continue
        fix = (
            "// MGL_MSG_NOSIGNAL_FIX: darwin has no MSG_NOSIGNAL, the jvm ignores SIGPIPE anyway\n"
            "#if !defined(_WIN32)\n"
            "#include <sys/socket.h>\n"
            "#if !defined(MSG_NOSIGNAL)\n"
            "#define MSG_NOSIGNAL 0\n"
            "#endif\n"
            "#endif\n\n"
        )
        lines.insert(idx, fix)
        write(target, "".join(lines))
        print(f"[msg_nosignal] {target.name} applied")
        results.append(APPLIED)
    if WARNED in results:
        return WARNED
    return APPLIED if APPLIED in results else SKIPPED


def shared_image_memfd(root):
    target = root / "MobileGL/MG_Remote/Server/SharedImageRegistry.cpp"
    if not target.is_file():
        return SKIPPED
    text = read(target)
    old = "#elif !defined(_WIN32)\n        // A host has no AHardwareBuffer."
    new = "#elif defined(__linux__)\n        // A host has no AHardwareBuffer."
    if new in text:
        print("[shared_image] already applied")
        return SKIPPED
    if text.count(old) != 1:
        print("[shared_image] memfd branch not found, probably changed upstream")
        return WARNED
    write(target, text.replace(old, new, 1))
    print("[shared_image] applied")
    return APPLIED


def persistent_map_darwin(root):
    target = root / "MobileGL/MG_Remote/Client/PersistentMapTracker.cpp"
    if not target.is_file():
        return SKIPPED
    text = read(target)
    if "MGL_DARWIN_FAULT_PC" in text:
        print("[persistent_map] already applied")
        return SKIPPED

    inc_old = "#include <ucontext.h>\n"
    inc_new = ("// MGL_DARWIN_FAULT_PC\n"
               "#if defined(__APPLE__)\n"
               "#include <sys/ucontext.h>\n"
               "#include <pthread.h>\n"
               "#else\n"
               "#include <ucontext.h>\n"
               "#endif\n")
    pc_old = """#if defined(__aarch64__)
            return static_cast<uintptr_t>(
                reinterpret_cast<ucontext_t*>(ucontext)->uc_mcontext.pc);"""
    pc_new = """#if defined(__APPLE__) && defined(__aarch64__)
            return static_cast<uintptr_t>(
                __darwin_arm_thread_state64_get_pc(reinterpret_cast<ucontext_t*>(ucontext)->uc_mcontext->__ss));
#elif defined(__aarch64__)
            return static_cast<uintptr_t>(
                reinterpret_cast<ucontext_t*>(ucontext)->uc_mcontext.pc);"""
    tid_old = "const pid_t tid = static_cast<pid_t>(syscall(SYS_gettid));"
    tid_new = ("#if defined(__APPLE__)\n"
               "            const pid_t tid = static_cast<pid_t>(pthread_mach_thread_np(pthread_self()));\n"
               "#else\n"
               "            const pid_t tid = static_cast<pid_t>(syscall(SYS_gettid));\n"
               "#endif")
    for old in (inc_old, pc_old, tid_old):
        if text.count(old) != 1:
            print("[persistent_map] expected code not found, probably changed upstream")
            return WARNED
    text = text.replace(inc_old, inc_new, 1).replace(pc_old, pc_new, 1).replace(tid_old, tid_new, 1)
    write(target, text)
    print("[persistent_map] applied")
    return APPLIED


def texture_emit_cast(root):
    target = root / "MobileGL/MG_Impl/Pipe/TextureEmit.h"
    old = "reinterpret_cast<Uint64>(reinterpret_cast<std::uintptr_t>(shadow)) +"
    new = "static_cast<Uint64>(reinterpret_cast<std::uintptr_t>(shadow)) +"
    return replace_once(target, old, new, new, "texture_emit", required=False)


STEPS = [
    ("ios_visibility", ios_visibility, True),
    ("ios_resolution", ios_resolution, True),
    ("hash_shim", hash_shim, True),
    ("enable_availability", enable_availability, True),
    ("glslang", glslang, False),
    ("adopt_t0_cloexec", adopt_t0_cloexec, True),
    ("msg_nosignal", msg_nosignal, False),
    ("shared_image_memfd", shared_image_memfd, False),
    ("persistent_map_darwin", persistent_map_darwin, False),
    ("texture_emit", texture_emit_cast, False),
]


def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <path-to-mobilegl-checkout>", file=sys.stderr)
        return 1

    root = Path(sys.argv[1]).resolve()
    if not (root / "CMakeLists.txt").is_file():
        print(f"{root} doesn't look like a MobileGL checkout", file=sys.stderr)
        return 1

    failed = []
    for name, step, required in STEPS:
        try:
            result = step(root)
        except Exception as e:
            print(f"[{name}] crashed: {e}", file=sys.stderr)
            result = FAILED if required else WARNED
        if result == FAILED:
            failed.append(name)

    if failed:
        print("patch_mobilegl: failed steps: " + ", ".join(failed), file=sys.stderr)
        return 1
    print("patch_mobilegl: done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
