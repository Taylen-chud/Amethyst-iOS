#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import "SurfaceViewController.h"

#include <dlfcn.h>
#include <string.h>
#include <stdatomic.h>
#include "bridge_tbl.h"
#include "environ.h"
#include "gl_bridge.h"
#include "utils.h"

static EGLDisplay g_EglDisplay;
static egl_library handle;

// Resolution changes arrive from the UIKit thread, while EGL/Vulkan calls must stay on
// the render thread. Queue the new drawable size atomically and apply it immediately
// before the next eglSwapBuffers().
static atomic_int pending_surface_width = 0;
static atomic_int pending_surface_height = 0;

static BOOL gl_is_mobilegl_renderer() {
    return isMobileGLRenderer(getenv("POJAV_RENDERER"));
}

void gl_notify_screen_size(int width, int height) {
    if (!gl_is_mobilegl_renderer()) return;

    width = MAX(width, 1);
    height = MAX(height, 1);
    atomic_store_explicit(&pending_surface_width, width, memory_order_release);
    atomic_store_explicit(&pending_surface_height, height, memory_order_release);
}

static void* load_egl_symbol(void *dl_handle, const char *symbol) {
    dlerror();
    void *addr = dlsym(dl_handle, symbol);
    const char *error = dlerror();
    if (!addr || error) {
        NSLog(@"EGLBridge: failed to resolve %s: %s", symbol, error ?: "symbol not found");
    }
    return addr;
}

static bool dlsym_EGL() {
    const char *renderer = getenv("POJAV_RENDERER");
    const char *eglLibrary = gl_is_mobilegl_renderer() ? renderer : RENDERER_NAME_MTL_ANGLE;
    NSString *eglPath = [NSString stringWithFormat:@"@rpath/%s", eglLibrary ?: ""];
    void* dl_handle = dlopen(eglPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    if (!dl_handle) {
        NSLog(@"EGLBridge: failed to load %@ for renderer %s: %s",
            eglPath, renderer ?: "<unset>", dlerror() ?: "unknown dlopen error");
        return false;
    }

    memset(&handle, 0, sizeof(handle));
    handle.eglBindAPI = load_egl_symbol(dl_handle, "eglBindAPI");
    handle.eglChooseConfig = load_egl_symbol(dl_handle, "eglChooseConfig");
    handle.eglCreateContext = load_egl_symbol(dl_handle, "eglCreateContext");
    handle.eglCreateWindowSurface = load_egl_symbol(dl_handle, "eglCreateWindowSurface");
    handle.eglDestroyContext = load_egl_symbol(dl_handle, "eglDestroyContext");
    handle.eglDestroySurface = load_egl_symbol(dl_handle, "eglDestroySurface");
    handle.eglGetConfigAttrib = load_egl_symbol(dl_handle, "eglGetConfigAttrib");
    handle.eglGetCurrentContext = load_egl_symbol(dl_handle, "eglGetCurrentContext");
    handle.eglGetDisplay = load_egl_symbol(dl_handle, "eglGetDisplay");
    handle.eglGetError = load_egl_symbol(dl_handle, "eglGetError");
    handle.eglGetPlatformDisplay = load_egl_symbol(dl_handle, "eglGetPlatformDisplay");
    handle.eglInitialize = load_egl_symbol(dl_handle, "eglInitialize");
    handle.eglMakeCurrent = load_egl_symbol(dl_handle, "eglMakeCurrent");
    handle.eglSwapBuffers = load_egl_symbol(dl_handle, "eglSwapBuffers");
    handle.eglReleaseThread = load_egl_symbol(dl_handle, "eglReleaseThread");
    handle.eglSwapInterval = load_egl_symbol(dl_handle, "eglSwapInterval");
    handle.eglTerminate = load_egl_symbol(dl_handle, "eglTerminate");
    handle.eglGetCurrentSurface = load_egl_symbol(dl_handle, "eglGetCurrentSurface");

    return handle.eglBindAPI && handle.eglChooseConfig && handle.eglCreateContext &&
        handle.eglCreateWindowSurface && handle.eglDestroyContext && handle.eglDestroySurface &&
        handle.eglGetConfigAttrib && handle.eglGetDisplay && handle.eglGetError &&
        handle.eglInitialize && handle.eglMakeCurrent && handle.eglSwapBuffers &&
        handle.eglReleaseThread && handle.eglSwapInterval && handle.eglTerminate;
}

static bool gl_init() {
    if (!dlsym_EGL()) {
        return false;
    }

    g_EglDisplay = handle.eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (g_EglDisplay == EGL_NO_DISPLAY) {
        NSDebugLog(@"EGLBridge: eglGetDisplay(EGL_DEFAULT_DISPLAY) returned EGL_NO_DISPLAY");
        return false;
    }
    if (!handle.eglInitialize(g_EglDisplay, NULL, NULL)) {
        NSDebugLog(@"EGLBridge: Error eglInitialize() failed: 0x%x", handle.eglGetError());
        return false;
    }
    return true;
}

gl_render_window_t* gl_init_context(gl_render_window_t *share) {
    gl_render_window_t* bundle = calloc(1, sizeof(gl_render_window_t));

    NSString *renderer = NSProcessInfo.processInfo.environment[@"POJAV_RENDERER"];
    BOOL angleDesktopGL = [renderer isEqualToString:@ RENDERER_NAME_MTL_ANGLE];
    BOOL mobileGL = gl_is_mobilegl_renderer();

    const EGLint attribs[] = {
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 24,
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT|EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, (angleDesktopGL || mobileGL) ? EGL_OPENGL_BIT : EGL_OPENGL_ES3_BIT,
        EGL_NONE
    };

    EGLint num_configs;
    EGLint vid;
    if (!handle.eglChooseConfig(g_EglDisplay, attribs, &bundle->config, 1, &num_configs)) {
        NSDebugLog(@"EGLBridge: Error couldn't get an EGL visual config: 0x%x", handle.eglGetError());
        free(bundle);
        return NULL;
    }
    assert(bundle->config);
    assert(num_configs > 0);

    if (!handle.eglGetConfigAttrib(g_EglDisplay, bundle->config, EGL_NATIVE_VISUAL_ID, &vid)) {
        NSDebugLog(@"EGLBridge: Error eglGetConfigAttrib() failed: 0x%x", handle.eglGetError());
        free(bundle);
        return NULL;
    }

    EGLBoolean bindResult;
    if (angleDesktopGL || mobileGL) {
        NSDebugLog(@"EGLBridge: Binding to desktop OpenGL");
        bindResult = handle.eglBindAPI(EGL_OPENGL_API);
    } else {
        NSDebugLog(@"EGLBridge: Binding to OpenGL ES");
        bindResult = handle.eglBindAPI(EGL_OPENGL_ES_API);
    }
    if (!bindResult) NSDebugLog(@"EGLBridge: bind failed: %p\n", handle.eglGetError());

    CALayer *layer = SurfaceViewController.surface.layer;
    const EGLint mobileGLSurfaceAttribs[] = {
        EGL_WIDTH, (EGLint)MAX(1.0, round(layer.bounds.size.width * layer.contentsScale)),
        EGL_HEIGHT, (EGLint)MAX(1.0, round(layer.bounds.size.height * layer.contentsScale)),
        EGL_NONE
    };
    bundle->surface = handle.eglCreateWindowSurface(g_EglDisplay, bundle->config, (__bridge EGLNativeWindowType)layer,
        mobileGL ? mobileGLSurfaceAttribs : NULL);
    bundle->surfaceWidth = mobileGL ? mobileGLSurfaceAttribs[1] : 0;
    bundle->surfaceHeight = mobileGL ? mobileGLSurfaceAttribs[3] : 0;
    if (!bundle->surface) {
        NSDebugLog(@"EGLBridge: eglCreateWindowSurface finished with error: 0x%x", handle.eglGetError());
        free(bundle);
        return NULL;
    }

    const EGLint gles_ctx_attribs[] = {
        EGL_CONTEXT_CLIENT_VERSION, 3,
        EGL_NONE
    };
    const EGLint desktop_ctx_attribs[] = {
        EGL_CONTEXT_MAJOR_VERSION, 4,
        EGL_CONTEXT_MINOR_VERSION, 6,
        EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
        EGL_NONE
    };
    bundle->context = handle.eglCreateContext(g_EglDisplay, bundle->config, share ? share->context : EGL_NO_CONTEXT,
        mobileGL ? desktop_ctx_attribs : gles_ctx_attribs);
    if (!bundle->context) {
        NSDebugLog(@"EGLBridge: Error eglCreateContext finished with error: 0x%x", handle.eglGetError());
        free(bundle);
        return NULL;
    }
    //NSDebugLog(@"EGLBridge: Created CTX pointer = %p (source = %p)", bundle->context, share?share->context:0);

    return bundle;
}

void gl_make_current(gl_render_window_t* bundle) {
    if(!bundle) {
        if(handle.eglMakeCurrent(g_EglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT)) {
            currentBundle = NULL;
        }
        return;
    }

    if(handle.eglMakeCurrent(g_EglDisplay, bundle->surface, bundle->surface, bundle->context)) {
        currentBundle = (basic_render_window_t *)bundle;
    } else {
        NSLog(@"EGLBridge: eglMakeCurrent returned with error: 0x%x", handle.eglGetError());
    }
}

static void gl_apply_pending_surface_resize(gl_render_window_t *bundle) {
    if (!bundle || !gl_is_mobilegl_renderer()) return;

    const int width = atomic_load_explicit(&pending_surface_width, memory_order_acquire);
    const int height = atomic_load_explicit(&pending_surface_height, memory_order_acquire);
    if (width <= 0 || height <= 0 || (width == bundle->surfaceWidth && height == bundle->surfaceHeight)) {
        return;
    }

    const EGLint attrs[] = {
        EGL_WIDTH, width,
        EGL_HEIGHT, height,
        EGL_NONE
    };
    EGLSurface oldSurface = bundle->surface;

    // Keep the EGL/Vulkan resize on the render thread. MobileGL receives the new
    // WindowHandle dimensions when the replacement EGL surface is created, which
    // causes its DirectVulkan backend to request a matching swapchain resize.
    if (!handle.eglMakeCurrent(g_EglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT)) {
        NSDebugLog(@"EGLBridge: couldn't release current surface before resize: 0x%x", handle.eglGetError());
        return;
    }

    EGLSurface newSurface = handle.eglCreateWindowSurface(
        g_EglDisplay, bundle->config, (__bridge EGLNativeWindowType)SurfaceViewController.surface.layer, attrs);
    if (newSurface == EGL_NO_SURFACE) {
        NSDebugLog(@"EGLBridge: couldn't recreate MobileGL surface at %dx%d: 0x%x", width, height, handle.eglGetError());
        handle.eglMakeCurrent(g_EglDisplay, oldSurface, oldSurface, bundle->context);
        return;
    }

    if (!handle.eglMakeCurrent(g_EglDisplay, newSurface, newSurface, bundle->context)) {
        NSDebugLog(@"EGLBridge: couldn't bind resized MobileGL surface: 0x%x", handle.eglGetError());
        handle.eglDestroySurface(g_EglDisplay, newSurface);
        handle.eglMakeCurrent(g_EglDisplay, oldSurface, oldSurface, bundle->context);
        return;
    }

    bundle->surface = newSurface;
    bundle->surfaceWidth = width;
    bundle->surfaceHeight = height;
    handle.eglDestroySurface(g_EglDisplay, oldSurface);

    // Consume exactly the size we applied. If UIKit posts another size while this
    // operation was in progress, it remains pending for the next frame.
    int expectedWidth = width;
    int expectedHeight = height;
    atomic_compare_exchange_strong_explicit(&pending_surface_width, &expectedWidth, 0,
                                            memory_order_acq_rel, memory_order_acquire);
    expectedWidth = width;
    atomic_compare_exchange_strong_explicit(&pending_surface_height, &expectedHeight, 0,
                                            memory_order_acq_rel, memory_order_acquire);
}

void gl_swap_buffers() {
    // Same rationale as osm_swap_buffers: block the render loop until the app
    // is active again so eglSwapBuffers (which can trigger Metal command buffer
    // submission) is never called from the background.
    pojavWaitForAppForeground();
    gl_apply_pending_surface_resize(&currentBundle->gl);
    if (!handle.eglSwapBuffers(g_EglDisplay, currentBundle->gl.surface) && handle.eglGetError() == EGL_BAD_SURFACE) {
        NSLog(@"eglSwapBuffers error 0x%x", handle.eglGetError());
        //stopSwapBuffers = true;
        //closeGLFWWindow();
    }
}

void gl_swap_interval(int swapInterval) {
    handle.eglSwapInterval(g_EglDisplay, swapInterval);
}

void gl_terminate() {
    handle.eglMakeCurrent(g_EglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    handle.eglDestroySurface(g_EglDisplay, currentBundle->gl.surface);
    handle.eglDestroyContext(g_EglDisplay, currentBundle->gl.context);
    handle.eglTerminate(g_EglDisplay);
    handle.eglReleaseThread();
    free(currentBundle);
    currentBundle = nil;
}

void set_gl_bridge_tbl() {
    br_init = gl_init;
    br_init_context = (br_init_context_t) gl_init_context;
    br_make_current = (br_make_current_t) gl_make_current;
    br_swap_buffers = gl_swap_buffers;
    br_swap_interval = gl_swap_interval;
    br_terminate = gl_terminate;
}
