#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import "SurfaceViewController.h"

#include <dlfcn.h>
#include <string.h>
#include "bridge_tbl.h"
#include "environ.h"
#include "gl_bridge.h"
#include "utils.h"

static EGLDisplay g_EglDisplay = EGL_NO_DISPLAY;
static egl_library handle;

static BOOL gl_is_mobilegl_renderer() {
    return isMobileGLRenderer(getenv("POJAV_RENDERER"));
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
    
    if (!eglLibrary || strlen(eglLibrary) == 0) {
        eglLibrary = RENDERER_NAME_MTL_ANGLE;
    }

    NSString *eglPath = [NSString stringWithFormat:@"@rpath/%s", eglLibrary];
    void* dl_handle = dlopen(eglPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    
    if (!dl_handle) {
        // Fallback check without path prefix if RTLD search path handles it
        dl_handle = dlopen(eglLibrary, RTLD_NOW | RTLD_GLOBAL);
    }

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
        NSLog(@"EGLBridge: dlsym_EGL failed to resolve required EGL symbols.");
        return false;
    }

    if (!handle.eglGetDisplay) return false;
    g_EglDisplay = handle.eglGetDisplay(EGL_DEFAULT_DISPLAY);
    
    if (g_EglDisplay == EGL_NO_DISPLAY) {
        NSLog(@"EGLBridge: eglGetDisplay(EGL_DEFAULT_DISPLAY) returned EGL_NO_DISPLAY");
        return false;
    }
    
    if (!handle.eglInitialize(g_EglDisplay, NULL, NULL)) {
        NSLog(@"EGLBridge: Error eglInitialize() failed: 0x%x", handle.eglGetError ? handle.eglGetError() : 0);
        return false;
    }
    return true;
}

gl_render_window_t* gl_init_context(gl_render_window_t *share) {
    if (g_EglDisplay == EGL_NO_DISPLAY || !handle.eglChooseConfig) {
        NSLog(@"EGLBridge: Cannot create context, EGL display or bindings uninitialized.");
        return NULL;
    }

    gl_render_window_t* bundle = calloc(1, sizeof(gl_render_window_t));

    NSString *renderer = NSProcessInfo.processInfo.environment[@"POJAV_RENDERER"];
    BOOL angleDesktopGL = [renderer isEqualToString:@ RENDERER_NAME_MTL_ANGLE];
    // isMobileGLRenderer()/mobileGL covers BOTH libMobileGL.dylib and
    // libMobileGL-gles.dylib, since they're the same binary under two names.
    // That's fine for things like surface sizing attribs below, but the EGL
    // client API MUST NOT be collapsed the same way: libMobileGL-gles.dylib
    // is backed by ANGLE's libGLESv2 and has to be driven via the real
    // EGL_OPENGL_ES_API path (like MobileGlues), while only the plain,
    // non-gles libMobileGL.dylib build wants the desktop EGL_OPENGL_API path
    // alongside tinygl4angle. Binding the gles variant through the desktop
    // path mismatches ANGLE's internal ES-typed state and segfaults inside
    // libGLESv2 (gl::State::getTargetTexture) as soon as it's touched.
    BOOL mobileGL = gl_is_mobilegl_renderer();
    BOOL mobileGLDesktop = [renderer isEqualToString:@ RENDERER_NAME_MOBILEGL];
    BOOL useDesktopGL = angleDesktopGL || mobileGLDesktop;

    const EGLint attribs[] = {
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 24,
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT|EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, useDesktopGL ? EGL_OPENGL_BIT : EGL_OPENGL_ES3_BIT,
        EGL_NONE
    };

    EGLint num_configs;
    EGLint vid;
    if (!handle.eglChooseConfig(g_EglDisplay, attribs, &bundle->config, 1, &num_configs)) {
        NSLog(@"EGLBridge: Error couldn't get an EGL visual config: 0x%x", handle.eglGetError());
        free(bundle);
        return NULL;
    }
    assert(bundle->config);
    assert(num_configs > 0);

    if (!handle.eglGetConfigAttrib(g_EglDisplay, bundle->config, EGL_NATIVE_VISUAL_ID, &vid)) {
        NSLog(@"EGLBridge: Error eglGetConfigAttrib() failed: 0x%x", handle.eglGetError());
        free(bundle);
        return NULL;
    }

    EGLBoolean bindResult;
    if (useDesktopGL) {
        NSLog(@"EGLBridge: Binding to desktop OpenGL");
        bindResult = handle.eglBindAPI(EGL_OPENGL_API);
    } else {
        NSLog(@"EGLBridge: Binding to OpenGL ES");
        bindResult = handle.eglBindAPI(EGL_OPENGL_ES_API);
    }
    if (!bindResult) NSLog(@"EGLBridge: bind failed: %x\n", handle.eglGetError());

    CALayer *layer = SurfaceViewController.surface.layer;
    const EGLint mobileGLSurfaceAttribs[] = {
        EGL_WIDTH, (EGLint)MAX(1.0, round(layer.bounds.size.width * layer.contentsScale)),
        EGL_HEIGHT, (EGLint)MAX(1.0, round(layer.bounds.size.height * layer.contentsScale)),
        EGL_NONE
    };
    bundle->surface = handle.eglCreateWindowSurface(g_EglDisplay, bundle->config, (__bridge EGLNativeWindowType)layer,
        mobileGL ? mobileGLSurfaceAttribs : NULL);
    if (!bundle->surface) {
        NSLog(@"EGLBridge: eglCreateWindowSurface finished with error: 0x%x", handle.eglGetError());
        free(bundle);
        return NULL;
    }

    const EGLint gles_ctx_attribs[] = {
        EGL_CONTEXT_CLIENT_VERSION, 3,
        EGL_NONE
    };
    const EGLint desktop_ctx_attribs[] = {
        EGL_CONTEXT_MAJOR_VERSION, 3,
        EGL_CONTEXT_MINOR_VERSION, 3,
        EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
        EGL_NONE
    };
    bundle->context = handle.eglCreateContext(g_EglDisplay, bundle->config, share ? share->context : EGL_NO_CONTEXT,
        useDesktopGL ? desktop_ctx_attribs : gles_ctx_attribs);
    if (!bundle->context) {
        NSLog(@"EGLBridge: Error eglCreateContext finished with error: 0x%x", handle.eglGetError());
        free(bundle);
        return NULL;
    }

    return bundle;
}

void gl_make_current(gl_render_window_t* bundle) {
    if (!handle.eglMakeCurrent) return;

    if (!bundle) {
        if (handle.eglMakeCurrent(g_EglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT)) {
            currentBundle = NULL;
        }
        return;
    }

    if (handle.eglMakeCurrent(g_EglDisplay, bundle->surface, bundle->surface, bundle->context)) {
        currentBundle = (basic_render_window_t *)bundle;
    } else {
        NSLog(@"EGLBridge: eglMakeCurrent returned with error: 0x%x", handle.eglGetError());
    }
}

void gl_swap_buffers() {
    if (!handle.eglSwapBuffers || !currentBundle) return;
    if (!handle.eglSwapBuffers(g_EglDisplay, currentBundle->gl.surface) && handle.eglGetError() == EGL_BAD_SURFACE) {
        NSLog(@"eglSwapBuffers error 0x%x", handle.eglGetError());
    }
}

void gl_swap_interval(int swapInterval) {
    if (!handle.eglSwapInterval) return;
    handle.eglSwapInterval(g_EglDisplay, swapInterval);
}

void gl_terminate() {
    if (!handle.eglMakeCurrent) return;
    handle.eglMakeCurrent(g_EglDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (currentBundle) {
        if (handle.eglDestroySurface) handle.eglDestroySurface(g_EglDisplay, currentBundle->gl.surface);
        if (handle.eglDestroyContext) handle.eglDestroyContext(g_EglDisplay, currentBundle->gl.context);
        free(currentBundle);
        currentBundle = NULL;
    }
    if (handle.eglTerminate) handle.eglTerminate(g_EglDisplay);
    if (handle.eglReleaseThread) handle.eglReleaseThread();
}

void set_gl_bridge_tbl() {
    br_init = gl_init;
    br_init_context = (br_init_context_t) gl_init_context;
    br_make_current = (br_make_current_t) gl_make_current;
    br_swap_buffers = gl_swap_buffers;
    br_swap_interval = gl_swap_interval;
    br_terminate = gl_terminate;
}
