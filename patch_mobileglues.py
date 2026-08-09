#!/usr/bin/env python3
"""
Patch MobileGlues-cpp for Darwin/iOS builds.
Patches:
  1. gl/framebuffer.cpp:
     Replaces the three ARB alias entry points with forwarding wrappers
     on Apple platforms, because Darwin does not support the GCC-style
     __attribute__((alias(...))) used by the upstream source.
  2. egl/trace.h:
     Prevents the Linux/Android __NR_gettid syscall implementation from
     being compiled on Apple platforms. MobileGlues currently uses
     __NR_gettid for EGL tracing, but that identifier is not available
     when compiling the iOS target with Apple Clang.
The script is safe to run repeatedly:
  - Already-patched files are skipped.
  - If upstream source changes and an expected block cannot be found,
    the script prints a warning and continues instead of hard-failing.
Usage:
    patch_mobileglues.py <MobileGlues-root>
or, for the existing framebuffer-only behavior:
    patch_mobileglues.py <path/to/framebuffer.cpp>
"""
import os
import sys
def patch_framebuffer(path):
    try:
        with open(path, "r") as f:
            src = f.read()
    except OSError as e:
        print(f"Warning: could not read {path}: {e}", file=sys.stderr)
        return False
    # Already patched.
    if (
        "#ifndef __APPLE__" in src
        and "glDeleteFramebuffersARB" in src
        and "__attribute__((alias(\"glDeleteFramebuffers\")))" in src
    ):
        print("MobileGlues Darwin alias patch already applied; skipping")
        return True
    old_block = (
        'extern "C" {\n'
        'GLAPI GLAPIENTRY void glDeleteFramebuffersARB(GLsizei n, const GLuint* names) '
        '__attribute__((alias("glDeleteFramebuffers")));\n'
        'GLAPI GLAPIENTRY void glFramebufferRenderbufferARB(GLenum target, GLenum attachment, '
        'GLenum renderbuffertarget,\n'
        '                                                   GLuint renderbuffer) '
        '__attribute__((alias("glFramebufferRenderbuffer")));\n'
        'GLAPI GLAPIENTRY void glFramebufferTextureLayerARB(GLenum target, GLenum attachment, '
        'GLuint texture, GLint level,\n'
        '                                                   GLint layer) '
        '__attribute__((alias("glFramebufferTextureLayer")));\n'
        '}'
    )
    if old_block not in src:
        print(
            "Warning: MobileGlues Darwin alias block not found in "
            + path
            + " (upstream source may have changed) - skipping patch; "
              "verify the ARB entry points still build on Darwin.",
            file=sys.stderr,
        )
        return False
    new_block = (
        'extern "C" {\n'
        '#ifndef __APPLE__\n'
        'GLAPI GLAPIENTRY void glDeleteFramebuffersARB(GLsizei n, const GLuint* names) '
        '__attribute__((alias("glDeleteFramebuffers")));\n'
        'GLAPI GLAPIENTRY void glFramebufferRenderbufferARB(GLenum target, GLenum attachment, '
        'GLenum renderbuffertarget,\n'
        '                                                   GLuint renderbuffer) '
        '__attribute__((alias("glFramebufferRenderbuffer")));\n'
        'GLAPI GLAPIENTRY void glFramebufferTextureLayerARB(GLenum target, GLenum attachment, '
        'GLuint texture, GLint level,\n'
        '                                                   GLint layer) '
        '__attribute__((alias("glFramebufferTextureLayer")));\n'
        '#else\n'
        'GLAPI GLAPIENTRY void glDeleteFramebuffersARB(GLsizei n, const GLuint* names) '
        '{ glDeleteFramebuffers(n, names); }\n'
        'GLAPI GLAPIENTRY void glFramebufferRenderbufferARB(GLenum target, GLenum attachment, '
        'GLenum renderbuffertarget, GLuint renderbuffer) '
        '{ glFramebufferRenderbuffer(target, attachment, renderbuffertarget, renderbuffer); }\n'
        'GLAPI GLAPIENTRY void glFramebufferTextureLayerARB(GLenum target, GLenum attachment, '
        'GLuint texture, GLint level, GLint layer) '
        '{ glFramebufferTextureLayer(target, attachment, texture, level, layer); }\n'
        '#endif\n'
        '}'
    )
    src = src.replace(old_block, new_block, 1)
    try:
        with open(path, "w") as f:
            f.write(src)
    except OSError as e:
        print(f"Warning: could not write {path}: {e}", file=sys.stderr)
        return False
    print("Patched MobileGlues Darwin ARB aliases in " + path)
    return True
def patch_trace(path):
    try:
        with open(path, "r") as f:
            src = f.read()
    except OSError as e:
        print(f"Warning: could not read {path}: {e}", file=sys.stderr)
        return False
    # Already patched.
    if "MOBILEGLUES_DARWIN_TRACE_PATCH" in src:
        print("MobileGlues Darwin trace patch already applied; skipping")
        return True
    # The upstream implementation uses Linux/Android's __NR_gettid.
    # We only need to change the Apple path. Keep Linux/Android untouched.
    old_include_block = (
        "#include <sys/syscall.h>\n"
        "#include <unistd.h>"
    )
    new_include_block = (
        "/* MOBILEGLUES_DARWIN_TRACE_PATCH */\n"
        "#if defined(__APPLE__)\n"
        "#include <stdint.h>\n"
        "#include <pthread.h>\n"
        "#else\n"
        "#include <sys/syscall.h>\n"
        "#include <unistd.h>\n"
        "#endif"
    )
    if old_include_block in src:
        src = src.replace(old_include_block, new_include_block, 1)
    else:
        print(
            "Warning: MobileGlues trace include block not found in "
            + path
            + " (upstream source may have changed) - skipping trace patch.",
            file=sys.stderr,
        )
        return False
    old_tid = "return (int)syscall(__NR_gettid);"
    new_tid = (
        "#if defined(__APPLE__)\n"
        "    /*\n"
        "     * Darwin does not provide Linux's __NR_gettid.\n"
        "     * EGL tracing is disabled in the iOS build, but keep this\n"
        "     * function valid if tracing is enabled in the future.\n"
        "     */\n"
        "    return (int)(uintptr_t)pthread_self();\n"
        "#else\n"
        "    return (int)syscall(__NR_gettid);\n"
        "#endif"
    )
    if old_tid not in src:
        print(
            "Warning: MobileGlues __NR_gettid implementation not found in "
            + path
            + " (upstream source may have changed) - skipping trace patch.",
            file=sys.stderr,
        )
        return False
    src = src.replace(old_tid, new_tid, 1)
    try:
        with open(path, "w") as f:
            f.write(src)
    except OSError as e:
        print(f"Warning: could not write {path}: {e}", file=sys.stderr)
        return False
    print("Patched MobileGlues Darwin __NR_gettid handling in " + path)
    return True
def patch_root(root):
    framebuffer = os.path.join(
        root,
        "MobileGlues-cpp",
        "gl",
        "framebuffer.cpp",
    )
    trace = os.path.join(
        root,
        "MobileGlues-cpp",
        "egl",
        "trace.h",
    )
    print("Patching MobileGlues for Darwin/iOS...")
    print("  framebuffer: " + framebuffer)
    print("  trace:      " + trace)
    patch_framebuffer(framebuffer)
    patch_trace(trace)
    print("MobileGlues Darwin patching complete")
    return 0
def main():
    if len(sys.argv) != 2:
        print(
            "usage: patch_mobileglues.py "
            "<MobileGlues-root|path/to/framebuffer.cpp>",
            file=sys.stderr,
        )
        return 1
    path = os.path.abspath(sys.argv[1])
    if os.path.isdir(path):
        return patch_root(path)
    if os.path.isfile(path):
        # Preserve the original script's single-file usage.
        return 0 if patch_framebuffer(path) else 0
    print(f"Warning: path does not exist: {path}", file=sys.stderr)
    return 0
if __name__ == "__main__":
    sys.exit(main())
