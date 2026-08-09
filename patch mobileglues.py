#!/usr/bin/env python3
"""
Patch MobileGlues-cpp's gl/framebuffer.cpp so the three ARB alias entry
points (glDeleteFramebuffersARB, glFramebufferRenderbufferARB,
glFramebufferTextureLayerARB) build on Darwin, where
__attribute__((alias(...))) is not supported.

On non-Apple platforms the original alias-based declarations are left
untouched. On Apple platforms each ARB function is instead defined as a
tiny forwarding wrapper that calls the already-existing non-ARB function
of the same name (glDeleteFramebuffers, glFramebufferRenderbuffer,
glFramebufferTextureLayer) defined earlier in the same file.

Usage: patch_mobileglues.py <path/to/framebuffer.cpp>
Exits 0 (with a warning on stderr) if the expected block isn't found,
so an upstream MobileGlues-cpp update doesn't hard-fail the build --
it just means this script needs updating to match the new source.
Exits 0 without writing if the file already contains the guard (patch
already applied), so the recipe is safe to re-run.
"""
import sys

def main():
    if len(sys.argv) != 2:
        print("usage: patch_mobileglues.py <framebuffer.cpp>", file=sys.stderr)
        return 1

    path = sys.argv[1]
    with open(path, "r") as f:
        src = f.read()

    if "#ifndef __APPLE__" in src and "glDeleteFramebuffersARB" in src:
        print("MobileGlues Darwin alias patch already applied; skipping")
        return 0

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
        return 0

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
    with open(path, "w") as f:
        f.write(src)

    print("Patched MobileGlues Darwin ARB aliases in " + path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
