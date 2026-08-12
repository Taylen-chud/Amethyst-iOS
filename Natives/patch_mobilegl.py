#!/usr/bin/env python3
"""
patch_mobilegl.py

MobileGL's DirectGLES::ProbeTexture() calls glTexStorage2DMultisample /
glTexStorage3DMultisample as soon as the corresponding function pointer is
non-null - but a non-null pointer only means the symbol resolved via
dlsym/GetProcAddress, not that the *current* GLES context actually supports
multisample texture storage:

    - GL_TEXTURE_2D_MULTISAMPLE            requires GLES 3.1+
    - GL_TEXTURE_2D_MULTISAMPLE_ARRAY       requires GLES 3.2+
                                             (or OES_texture_storage_multisample_2d_array)

ANGLE's Metal backend exports these entry points even on contexts where the
underlying capability isn't actually wired up, so calling them unconditionally
segfaults deep inside ANGLE (gl::State::getTargetTexture) instead of failing
gracefully - this is the crash seen via MobileGL-gles.dylib on iOS.

This script:
  1. Adds a `const MG_External::GLESCapabilities& capabilities` parameter to
     ProbeTexture().
  2. Gates the two multisample-storage calls on capabilities.GLESVersion
     actually meeting the GLES version each one requires, falling back to
     the existing "unsupported" path (unbind/delete/return false) instead of
     calling into the crashing entry point.
  3. Updates both call sites in PopulateFormatCapabilitiesImpl to pass
     `capabilities` through.

Idempotent: safe to re-run - if the guarded version is already present, each
step is skipped instead of re-applying (or corrupting) the patch.

Usage:
    python3 patch_mobilegl.py /path/to/MobileGL/checkout
"""
import sys
import pathlib

TARGET_REL_PATH = "MobileGL/MG_Backend/DirectGLES/BackendObject_DirectGLES.cpp"

# --- Patch 1: ProbeTexture signature -----------------------------------

SIG_OLD = """        Bool ProbeTexture(const MG_External::GLESFunctionsTable& gl, TextureTarget target, GLenum internalFormat,
                          GLenum imageFormat, GLenum imageType, TextureInternalFormat logicalFormat,
                          Bool* outRenderable) {"""

SIG_NEW = """        Bool ProbeTexture(const MG_External::GLESFunctionsTable& gl,
                          const MG_External::GLESCapabilities& capabilities, TextureTarget target,
                          GLenum internalFormat, GLenum imageFormat, GLenum imageType,
                          TextureInternalFormat logicalFormat, Bool* outRenderable) {"""

# --- Patch 2: gate the multisample-storage calls on actual GLES version --

MS_OLD = """            const Bool isMultisample = IsGLESProbeMultisampleTarget(target);
            if (isMultisample) {
                if (target == TextureTarget::Texture2DMultisample && gl.glTexStorage2DMultisample) {
                    gl.glTexStorage2DMultisample(glTarget, 1, internalFormat, 1, 1, GL_TRUE);
                } else if (target == TextureTarget::Texture2DMultisampleArray && gl.glTexStorage3DMultisample) {
                    gl.glTexStorage3DMultisample(glTarget, 1, internalFormat, 1, 1, 1, GL_TRUE);
                } else {
                    gl.glBindTexture(glTarget, static_cast<GLuint>(previousBinding));
                    gl.glDeleteTextures(1, &texture);
                    return false;
                }
            } else {"""

MS_NEW = """            const Bool isMultisample = IsGLESProbeMultisampleTarget(target);
            if (isMultisample) {
                // A non-null function pointer only means the symbol resolved; it does not
                // mean the current context actually supports multisample texture storage.
                // ANGLE's Metal backend has been observed to export these entry points on
                // contexts that can't actually back them, which segfaults inside ANGLE
                // (gl::State::getTargetTexture) instead of failing the call cleanly. Gate
                // on the real negotiated GLES version so we take the existing "unsupported"
                // fallback path below instead of calling into a broken stub.
                const Bool have31 = capabilities.GLESVersion.Major > 3 ||
                    (capabilities.GLESVersion.Major == 3 && capabilities.GLESVersion.Minor >= 1);
                const Bool have32 = capabilities.GLESVersion.Major > 3 ||
                    (capabilities.GLESVersion.Major == 3 && capabilities.GLESVersion.Minor >= 2);
                if (target == TextureTarget::Texture2DMultisample && gl.glTexStorage2DMultisample && have31) {
                    gl.glTexStorage2DMultisample(glTarget, 1, internalFormat, 1, 1, GL_TRUE);
                } else if (target == TextureTarget::Texture2DMultisampleArray && gl.glTexStorage3DMultisample && have32) {
                    gl.glTexStorage3DMultisample(glTarget, 1, internalFormat, 1, 1, 1, GL_TRUE);
                } else {
                    gl.glBindTexture(glTarget, static_cast<GLuint>(previousBinding));
                    gl.glDeleteTextures(1, &texture);
                    return false;
                }
            } else {"""

# --- Patch 3 & 4: pass `capabilities` through both call sites ------------

CALL1_OLD = """                        const Bool nativeCreated =
                            ProbeTexture(gl, probeTarget, nativeInfo.InternalFormat, nativeInfo.ImageFormat,
                                         nativeInfo.ImageType, logicalFormat, &nativeRenderable);"""

CALL1_NEW = """                        const Bool nativeCreated =
                            ProbeTexture(gl, capabilities, probeTarget, nativeInfo.InternalFormat,
                                         nativeInfo.ImageFormat, nativeInfo.ImageType, logicalFormat,
                                         &nativeRenderable);"""

CALL2_OLD = """                        const Bool fallbackCreated =
                            ProbeTexture(gl, probeTarget, fallbackInfo.InternalFormat, fallbackInfo.ImageFormat,
                                         fallbackInfo.ImageType, logicalFormat, &fallbackRenderable);"""

CALL2_NEW = """                        const Bool fallbackCreated =
                            ProbeTexture(gl, capabilities, probeTarget, fallbackInfo.InternalFormat,
                                         fallbackInfo.ImageFormat, fallbackInfo.ImageType, logicalFormat,
                                         &fallbackRenderable);"""

STEPS = [
    ("ProbeTexture signature", SIG_OLD, SIG_NEW),
    ("multisample storage guard", MS_OLD, MS_NEW),
    ("native probe call site", CALL1_OLD, CALL1_NEW),
    ("fallback probe call site", CALL2_OLD, CALL2_NEW),
]


def apply_patch(root: pathlib.Path) -> int:
    target = root / TARGET_REL_PATH
    if not target.is_file():
        print(f"ERROR: {target} not found. Pass the path to your MobileGL checkout root.", file=sys.stderr)
        return 1

    text = target.read_text()
    changed = False

    for name, old, new in STEPS:
        if new in text:
            print(f"[patch_mobilegl] '{name}' already applied, skipping.")
            continue
        if old not in text:
            print(f"ERROR: expected pattern for '{name}' not found in {target}.\n"
                  f"MobileGL's source has likely changed upstream since this script was written; "
                  f"the patch needs updating rather than blindly applied.", file=sys.stderr)
            return 1
        count = text.count(old)
        if count != 1:
            print(f"ERROR: pattern for '{name}' matched {count} times (expected exactly 1) in {target}; "
                  f"refusing to guess which to patch.", file=sys.stderr)
            return 1
        text = text.replace(old, new)
        changed = True
        print(f"[patch_mobilegl] Applied '{name}'.")

    if changed:
        target.write_text(text)
        print(f"[patch_mobilegl] Wrote {target}")
    else:
        print("[patch_mobilegl] Nothing to do, all patches already present.")

    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} /path/to/MobileGL/checkout", file=sys.stderr)
        sys.exit(1)
    sys.exit(apply_patch(pathlib.Path(sys.argv[1])))
