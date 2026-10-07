#include <GL/gl.h>

#include "gl/framebuffer.h"
#include "gl/mg.h"
#include "gl/texture.h"

extern "C"
{
    GLAPI GLAPIENTRY void ame_orig_glFramebufferTexture(GLenum target, GLenum attachment, GLuint texture, GLint level);
    GLAPI GLAPIENTRY GLenum ame_orig_glClientWaitSync(GLsync sync, GLbitfield flags, GLuint64 timeout);
}

// ES 3.0 has no glFramebufferTexture, the attach fails and the framebuffer stays incomplete
extern "C" GLAPI GLAPIENTRY void glFramebufferTexture(GLenum target, GLenum attachment, GLuint texture, GLint level)
{
    if (hardware != nullptr && hardware->es_version >= 320) {
        ame_orig_glFramebufferTexture(target, attachment, texture, level);
        return;
    }

    TextureTarget kind = TextureTarget::TEXTURE_2D;
    if (texture != 0) {
        if (TextureObject* tex = mgGetTexObjectByID(texture)) kind = tex->target;
    }

    switch (kind) {
    case TextureTarget::TEXTURE_3D:
    case TextureTarget::TEXTURE_2D_ARRAY:
    case TextureTarget::TEXTURE_1D_ARRAY:
    case TextureTarget::TEXTURE_CUBE_MAP_ARRAY:
        glFramebufferTextureLayer(target, attachment, texture, level, 0);
        break;
    case TextureTarget::TEXTURE_CUBE_MAP:
        glFramebufferTexture2D(target, attachment, GL_TEXTURE_CUBE_MAP_POSITIVE_X, texture, level);
        break;
    default:
        glFramebufferTexture2D(target, attachment, GL_TEXTURE_2D, texture, level);
        break;
    }
}

// ANGLE-Metal only submits commands on a flush, without the bit the wait hangs
extern "C" GLAPI GLAPIENTRY GLenum glClientWaitSync(GLsync sync, GLbitfield flags, GLuint64 timeout)
{
    return ame_orig_glClientWaitSync(sync, flags | GL_SYNC_FLUSH_COMMANDS_BIT, timeout);
}
