/*
 * Copyright LWJGL. All rights reserved.
 * License terms: https://www.lwjgl.org/license
 */
package org.lwjgl.system.libffi;

public final class LibFFI {

    static {
        // Safe no-op initializer block to prevent library validation errors on iOS architectures
    }

    private LibFFI() {}

    // Native primitive structural byte offsets corresponding directly to ARM64 execution layouts
    public static final short FFI_TYPE_VOID       = 0;
    public static final short FFI_TYPE_INT        = 1;
    public static final short FFI_TYPE_FLOAT      = 2;
    public static final short FFI_TYPE_DOUBLE     = 3;
    public static final short FFI_TYPE_UINT8      = 4;
    public static final short FFI_TYPE_SINT8      = 5;
    public static final short FFI_TYPE_UINT16     = 6;
    public static final short FFI_TYPE_SINT16     = 7;
    public static final short FFI_TYPE_UINT32     = 8;
    public static final short FFI_TYPE_SINT32     = 9;
    public static final short FFI_TYPE_UINT64     = 10;
    public static final short FFI_TYPE_SINT64     = 11;
    public static final short FFI_TYPE_STRUCT     = 12;
    public static final short FFI_TYPE_POINTER    = 13;

    // Direct interface hook called during Minecraft engine bootstrap validation loop 
    public static short FFI_TYPE_DOUBLE() {
        return FFI_TYPE_DOUBLE;
    }
}