#pragma once

#include <stdbool.h>
#include <string.h>

#define RENDERER_NAME_GL4ES "libgl4es_114.dylib"
#define RENDERER_NAME_MTL_ANGLE "libtinygl4angle.dylib"
#define RENDERER_NAME_MOBILEGLUES "libmobileglues.dylib"
#define RENDERER_NAME_MOBILEGL "libMobileGL.dylib"
#define RENDERER_NAME_VK_ZINK "libOSMesa.8.dylib"
#define RENDERER_NAME_MOLTENVK "libMoltenVK.dylib"
#define RENDERER_NAME_KOSMICKRISP "libvulkan.dylib"
#define RENDERER_FILE_KOSMICKRISP "libame_vulkan.dylib"

typedef enum {
    AME_RENDERER_UNKNOWN,
    AME_RENDERER_AUTO,
    AME_RENDERER_GL4ES,
    AME_RENDERER_ANGLE,
    AME_RENDERER_MOBILEGLUES,
    AME_RENDERER_MOBILEGL,
    AME_RENDERER_ZINK,
    AME_RENDERER_MOLTENVK,
    AME_RENDERER_KOSMICKRISP
} ame_renderer_t;

static inline ame_renderer_t ame_renderer_from_name(const char *name)
{
    if (!name) return AME_RENDERER_UNKNOWN;
    if (!strcmp(name, "auto")) return AME_RENDERER_AUTO;
    if (!strcmp(name, RENDERER_NAME_GL4ES)) return AME_RENDERER_GL4ES;
    if (!strcmp(name, RENDERER_NAME_MTL_ANGLE)) return AME_RENDERER_ANGLE;
    if (!strcmp(name, RENDERER_NAME_MOBILEGLUES)) return AME_RENDERER_MOBILEGLUES;
    if (!strcmp(name, RENDERER_NAME_MOBILEGL)) return AME_RENDERER_MOBILEGL;
    if (!strcmp(name, RENDERER_NAME_MOLTENVK)) return AME_RENDERER_MOLTENVK;
    if (!strcmp(name, RENDERER_NAME_KOSMICKRISP)) return AME_RENDERER_KOSMICKRISP;
    if (!strncmp(name, "libOSMesa", 9)) return AME_RENDERER_ZINK;
    return AME_RENDERER_UNKNOWN;
}

// renderers that expose a desktop GL context, gl4es is the only one that asks for GLES
static inline bool ame_renderer_is_desktop_gl(ame_renderer_t r)
{
    return r == AME_RENDERER_ANGLE || r == AME_RENDERER_MOBILEGLUES || r == AME_RENDERER_MOBILEGL;
}

// these ship their own EGL entry points, everything else goes through ANGLE's
static inline bool ame_renderer_owns_egl(ame_renderer_t r)
{
    return r == AME_RENDERER_MOBILEGLUES || r == AME_RENDERER_MOBILEGL;
}

// everything that presents through ANGLE sizes its drawable from bounds * contentsScale
static inline bool ame_renderer_uses_angle(ame_renderer_t r)
{
    return r == AME_RENDERER_AUTO || r == AME_RENDERER_GL4ES || r == AME_RENDERER_ANGLE || r == AME_RENDERER_MOBILEGLUES;
}

// games talk to a Vulkan driver directly, there is no GL context behind these
static inline bool ame_renderer_is_vulkan_native(ame_renderer_t r)
{
    return r == AME_RENDERER_MOLTENVK || r == AME_RENDERER_KOSMICKRISP;
}

// Kosmic Krisp's WSI sizes the layer's drawableSize itself when it creates a swapchain,
// MoltenVK expects the app to set it, so writing it from outside fights the driver
static inline bool ame_vulkan_driver_sizes_layer(ame_renderer_t r)
{
    return r == AME_RENDERER_KOSMICKRISP;
}

// bundled file name of the Vulkan driver a renderer loads, MoltenVK for anything else
static inline const char *ame_vulkan_library_file(ame_renderer_t r)
{
    return r == AME_RENDERER_KOSMICKRISP ? RENDERER_FILE_KOSMICKRISP : RENDERER_NAME_MOLTENVK;
}

static inline bool isMobileGLRenderer(const char *renderer)
{
    return ame_renderer_from_name(renderer) == AME_RENDERER_MOBILEGL;
}
