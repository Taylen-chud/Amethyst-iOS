#!/usr/bin/env python3

import re
import sys
from pathlib import Path


def patch_framebuffer(path: Path) -> None:
    source = path.read_text(encoding="utf-8")

    if "MOBILEGLUES_DARWIN_FBO_PATCH" in source:
        print(f"Already patched: {path}")
        return

    pattern = re.compile(
        r'''extern\s+"C"\s*\{.*?
__attribute__\\(\\(alias\\("glFramebufferTextureLayer"\\)\)\);\s*\}''',
        re.DOTALL,
    )

    replacement = """extern "C" {
#ifndef __APPLE__
GLAPI GLAPIENTRY void glDeleteFramebuffersARB(
    GLsizei n, const GLuint* names)
    __attribute__((alias("glDeleteFramebuffers")));

GLAPI GLAPIENTRY void glFramebufferRenderbufferARB(
    GLenum target,
    GLenum attachment,
    GLenum renderbuffertarget,
    GLuint renderbuffer)
    __attribute__((alias("glFramebufferRenderbuffer")));

GLAPI GLAPIENTRY void glFramebufferTextureLayerARB(
    GLenum target,
    GLenum attachment,
    GLuint texture,
    GLint level,
    GLint layer)
    __attribute__((alias("glFramebufferTextureLayer")));
#else
/* MOBILEGLUES_DARWIN_FBO_PATCH */
GLAPI GLAPIENTRY void glDeleteFramebuffersARB(
    GLsizei n, const GLuint* names)
{
    glDeleteFramebuffers(n, names);
}

GLAPI GLAPIENTRY void glFramebufferRenderbufferARB(
    GLenum target,
    GLenum attachment,
    GLenum renderbuffertarget,
    GLuint renderbuffer)
{
    glFramebufferRenderbuffer(
        target,
        attachment,
        renderbuffertarget,
        renderbuffer);
}

GLAPI GLAPIENTRY void glFramebufferTextureLayerARB(
    GLenum target,
    GLenum attachment,
    GLuint texture,
    GLint level,
    GLint layer)
{
    glFramebufferTextureLayer(
        target,
        attachment,
        texture,
        level,
        layer);
}
#endif
}"""

    patched, count = pattern.subn(replacement, source, count=1)

    if count != 1:
        raise RuntimeError(
            f"Could not find the framebuffer alias block in {path}"
        )

    path.write_text(patched, encoding="utf-8")
    print(f"Patched framebuffer aliases: {path}")


def patch_trace(path: Path) -> None:
    source = path.read_text(encoding="utf-8")

    if "MOBILEGLUES_DARWIN_TRACE_PATCH" in source:
        print(f"Already patched: {path}")
        return

    old_code = "return (int)syscall(__NR_gettid);"

    if old_code not in source:
        raise RuntimeError(
            f"Could not find __NR_gettid implementation in {path}"
        )

    if "#include <pthread.h>" not in source:
        source = (
            "#include <pthread.h>\n"
            "#include <stdint.h>\n"
            + source
        )

    new_code = """#if defined(__APPLE__)
    /* MOBILEGLUES_DARWIN_TRACE_PATCH */
    return (int)(uintptr_t)pthread_self();
#else
    return (int)syscall(__NR_gettid);
#endif"""

    source = source.replace(old_code, new_code, 1)

    path.write_text(source, encoding="utf-8")
    print(f"Patched Darwin thread ID handling: {path}")


def main() -> int:
    if len(sys.argv) != 2:
        print(
            f"Usage: {Path(sys.argv[0]).name} "
            "<MobileGlues-source-directory>",
            file=sys.stderr,
        )
        return 2

    root = Path(sys.argv[1]).expanduser().resolve()
    cpp_root = root / "MobileGlues-cpp"

    framebuffer = cpp_root / "gl" / "framebuffer.cpp"
    trace = cpp_root / "egl" / "trace.h"

    missing = [
        str(path)
        for path in (framebuffer, trace)
        if not path.is_file()
    ]

    if missing:
        print(
            "Required MobileGlues files were not found:",
            file=sys.stderr,
        )

        for path in missing:
            print(f"  {path}", file=sys.stderr)

        return 1

    try:
        patch_framebuffer(framebuffer)
        patch_trace(trace)
    except (OSError, RuntimeError) as error:
        print(f"MobileGlues patch failed: {error}", file=sys.stderr)
        return 1

    print("MobileGlues Darwin/iOS patching complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
