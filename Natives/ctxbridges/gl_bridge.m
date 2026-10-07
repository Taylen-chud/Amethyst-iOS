#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import "SurfaceViewController.h"

#include <dlfcn.h>
#include <string.h>
#include <mach/mach.h>
#include "bridge_tbl.h"
#include "environ.h"
#include "gl_bridge.h"
#include "utils.h"

static EGLDisplay g_EglDisplay;
static egl_library handle;

static volatile int g_swapCount;
static volatile int g_inSwap;
static volatile mach_port_t g_renderThread;

// diagnostics for the black screen: lib the gl functions come from, set when egl is loaded
static void *g_glLib;

static void gl_diag_frame(int swaps) {
    if (!g_glLib || swaps < 5) return;
    typedef void (*fn_clearColor)(float, float, float, float);
    typedef void (*fn_clear)(unsigned);
    typedef void (*fn_scissor)(int, int, int, int);
    typedef void (*fn_toggle)(unsigned);
    typedef void (*fn_bindFb)(unsigned, unsigned);
    typedef void (*fn_colorMask)(unsigned char, unsigned char, unsigned char, unsigned char);
    typedef unsigned (*fn_getError)(void);
    static fn_clearColor clearColor; static fn_clear clear; static fn_scissor scissor;
    static fn_toggle enable, disable; static fn_bindFb bindFb; static fn_colorMask colorMask;
    static fn_getError getError;
    static BOOL resolved;
    if (!resolved) {
        resolved = YES;
        clearColor = (fn_clearColor)dlsym(g_glLib, "glClearColor");
        clear = (fn_clear)dlsym(g_glLib, "glClear");
        scissor = (fn_scissor)dlsym(g_glLib, "glScissor");
        enable = (fn_toggle)dlsym(g_glLib, "glEnable");
        disable = (fn_toggle)dlsym(g_glLib, "glDisable");
        bindFb = (fn_bindFb)dlsym(g_glLib, "glBindFramebuffer");
        colorMask = (fn_colorMask)dlsym(g_glLib, "glColorMask");
        getError = (fn_getError)dlsym(g_glLib, "glGetError");
        NSLog(@"EGLBridge: diag gl functions: clear=%p scissor=%p bindFb=%p getError=%p", clear, scissor, bindFb, getError);
    }
    if (getError && (swaps == 5 || swaps == 60 || swaps == 300)) {
        for (int i = 0; i < 16; i++) {
            unsigned err = getError();
            if (!err) break;
            NSLog(@"EGLBridge: gl error 0x%x (swap %d)", err, swaps);
        }
    }
    if (swaps == 120 || swaps == 600) gl_diag_readback(swaps);
    if (swaps >= 60 && clear && clearColor && scissor && enable && disable && bindFb && colorMask) {
        bindFb(0x8D40, 0);          // GL_FRAMEBUFFER, the window
        colorMask(1, 1, 1, 1);
        enable(0x0C11);             // GL_SCISSOR_TEST
        scissor(0, 0, 400, 400);
        clearColor(0.f, 1.f, 0.f, 1.f);
        clear(0x4000);              // GL_COLOR_BUFFER_BIT
        disable(0x0C11);
    }
}

static int g_surfW = 1, g_surfH = 1;

// reads a few pixels from whatever is bound for reading and logs them
static void gl_diag_probe(void *lib, const char *tag) {
    typedef void (*fn_readPixels)(int, int, int, int, unsigned, unsigned, void *);
    fn_readPixels readPixels = (fn_readPixels)dlsym(lib, "glReadPixels");
    if (!readPixels) return;
    int pts[5][2] = {{g_surfW / 2, g_surfH / 2}, {g_surfW / 4, g_surfH / 2}, {g_surfW * 3 / 4, g_surfH / 2},
                     {g_surfW / 2, g_surfH / 4}, {g_surfW / 2, g_surfH * 3 / 4}};
    char buf[160]; int n = 0;
    for (int i = 0; i < 5; i++) {
        unsigned char px[4] = {1, 2, 3, 4};
        readPixels(pts[i][0], pts[i][1], 1, 1, 0x1908, 0x1401, px);
        n += snprintf(buf + n, sizeof(buf) - n, " %02x%02x%02x%02x", px[0], px[1], px[2], px[3]);
    }
    NSLog(@"EGLBridge: pixels %s:%s", tag, buf);
}

// logs what the window and every framebuffer object minecraft made currently hold,
// so we can tell if its own render target has the picture and only the present is broken
static void gl_diag_readback(int swaps) {
    typedef void (*fn_getInteger)(unsigned, int *);
    typedef unsigned char (*fn_isFb)(unsigned);
    typedef unsigned (*fn_checkFb)(unsigned);
    typedef void (*fn_bindFb)(unsigned, unsigned);
    typedef void (*fn_readBuffer)(unsigned);
    typedef void (*fn_attachParam)(unsigned, unsigned, unsigned, int *);
    fn_getInteger getInteger = (fn_getInteger)dlsym(g_glLib, "glGetIntegerv");
    fn_isFb isFb = (fn_isFb)dlsym(g_glLib, "glIsFramebuffer");
    fn_checkFb checkFb = (fn_checkFb)dlsym(g_glLib, "glCheckFramebufferStatus");
    fn_bindFb bindFb = (fn_bindFb)dlsym(g_glLib, "glBindFramebuffer");
    fn_readBuffer readBuffer = (fn_readBuffer)dlsym(g_glLib, "glReadBuffer");
    fn_attachParam attachParam = (fn_attachParam)dlsym(g_glLib, "glGetFramebufferAttachmentParameteriv");
    if (!getInteger || !isFb || !checkFb || !bindFb || !readBuffer || !attachParam) {
        NSLog(@"EGLBridge: readback functions missing");
        return;
    }
    int drawFb = -1, readFb = -1, vp[4] = {0}, sc[4] = {0};
    getInteger(0x8CA6, &drawFb);
    getInteger(0x8CAA, &readFb);
    getInteger(0x0BA2, vp);        // GL_VIEWPORT
    getInteger(0x0C10, sc);        // GL_SCISSOR_BOX
    NSLog(@"EGLBridge: swap %d state: drawFb %d readFb %d viewport %d,%d %dx%d scissor %d,%d %dx%d",
        swaps, drawFb, readFb, vp[0], vp[1], vp[2], vp[3], sc[0], sc[1], sc[2], sc[3]);

    bindFb(0x8CA8, 0);
    gl_diag_probe(g_glLib, "window");
    for (unsigned id = 1; id <= 24; id++) {
        if (!isFb(id)) continue;
        bindFb(0x8CA8, id);
        unsigned status = checkFb(0x8CA8);
        int type = 0, name = 0;
        attachParam(0x8CA8, 0x8CE0, 0x8CD0, &type);
        attachParam(0x8CA8, 0x8CE0, 0x8CD1, &name);
        NSLog(@"EGLBridge: fbo %u status 0x%x color0 type 0x%x name %d", id, status, type, name);
        if (status == 0x8CD5 && type) {
            readBuffer(0x8CE0);
            char tag[24]; snprintf(tag, sizeof(tag), "fbo %u", id);
            gl_diag_probe(g_glLib, tag);
        }
    }
    bindFb(0x8CA8, readFb > 0 ? (unsigned)readFb : 0);
}

static BOOL gl_safe_read(uintptr_t addr, void *out, size_t len) {
    vm_size_t got = 0;
    return vm_read_overwrite(mach_task_self(), (vm_address_t)addr, len, (vm_address_t)out, &got) == KERN_SUCCESS && got == len;
}

static void gl_log_frame(int idx, uintptr_t addr) {
    addr &= 0x0000000FFFFFFFFFULL; // strip pointer auth bits
    Dl_info info;
    if (addr && dladdr((void *)addr, &info) && info.dli_fname) {
        const char *base = strrchr(info.dli_fname, '/');
        NSLog(@"EGLBridge:   #%d %s`%s +0x%lx", idx, base ? base + 1 : info.dli_fname,
            info.dli_sname ?: "?", (unsigned long)(addr - (uintptr_t)(info.dli_saddr ?: info.dli_fbase)));
    } else {
        NSLog(@"EGLBridge:   #%d 0x%lx", idx, (unsigned long)addr);
    }
}

static void gl_dump_render_thread(void) {
    mach_port_t thread = g_renderThread;
    if (!thread) return;
    if (thread_suspend(thread) != KERN_SUCCESS) return;
    arm_thread_state64_t st;
    mach_msg_type_number_t cnt = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&st, &cnt) == KERN_SUCCESS) {
        uintptr_t pc = (uintptr_t)__darwin_arm_thread_state64_get_pc(st);
        uintptr_t lr = (uintptr_t)__darwin_arm_thread_state64_get_lr(st);
        uintptr_t fp = (uintptr_t)__darwin_arm_thread_state64_get_fp(st);
        gl_log_frame(0, pc);
        gl_log_frame(1, lr);
        for (int i = 2; i < 12 && fp; i++) {
            uintptr_t frame[2];
            if ((fp & 7) || !gl_safe_read(fp, frame, sizeof(frame))) break;
            gl_log_frame(i, frame[1]);
            if (frame[0] <= fp) break;
            fp = frame[0];
        }
    }
    thread_resume(thread);
}

static void gl_start_watchdog(void) {
    static dispatch_source_t timer;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_queue_t q = dispatch_queue_create("ame.gl.watchdog", DISPATCH_QUEUE_SERIAL);
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC / 10);
        __block int last = -1, reports = 0;
        dispatch_source_set_event_handler(timer, ^{
            int now = g_swapCount;
            if (now == last && now > 0) {
                if (reports++ < 3) {
                    NSLog(@"EGLBridge: no swap for %ds (swaps=%d, inside eglSwapBuffers=%d)", reports * 5, now, g_inSwap);
                    gl_dump_render_thread();
                }
            } else {
                reports = 0;
            }
            last = now;
        });
        dispatch_resume(timer);
    });
}

static BOOL gl_is_mobilegl_renderer() {
    return isMobileGLRenderer(getenv("AME_RENDERER"));
}

// newer MobileGlues ships its own EGL layer (desktop GL contexts on top of its ES backend), so it
// gets used as the EGL library like MobileGL. AME_MG_EGL=0 goes back to plain ANGLE + ES context
static BOOL gl_use_mobileglues_egl() {
    const char *renderer = getenv("AME_RENDERER");
    if (!renderer || strcmp(renderer, RENDERER_NAME_MOBILEGLUES)) return NO;
    const char *opt = getenv("AME_MG_EGL");
    return !(opt && !strcmp(opt, "0"));
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
    const char *renderer = getenv("AME_RENDERER");
    BOOL ownEgl = gl_is_mobilegl_renderer() || gl_use_mobileglues_egl();
    const char *eglLibrary = ownEgl ? renderer : RENDERER_NAME_MTL_ANGLE;
    NSString *eglPath = [NSString stringWithFormat:@"@rpath/%s", eglLibrary ?: ""];
    void* dl_handle = dlopen(eglPath.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    if (!dl_handle) {
        NSLog(@"EGLBridge: failed to load %@ for renderer %s: %s",
            eglPath, renderer ?: "<unset>", dlerror() ?: "unknown dlopen error");
        return false;
    }

    g_glLib = dl_handle;
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
    NSLog(@"EGLBridge: display up (renderer %s, own egl: %d)", getenv("AME_RENDERER") ?: "<unset>",
        gl_is_mobilegl_renderer() || gl_use_mobileglues_egl());
    return true;
}

gl_render_window_t* gl_init_context(gl_render_window_t *share) {
    gl_render_window_t* bundle = calloc(1, sizeof(gl_render_window_t));

    NSString *renderer = NSProcessInfo.processInfo.environment[@"AME_RENDERER"];
    BOOL angleDesktopGL = [renderer isEqualToString:@ RENDERER_NAME_MTL_ANGLE];
    BOOL mobileGL = gl_is_mobilegl_renderer();
    BOOL mgEgl = gl_use_mobileglues_egl();
    BOOL desktopGL = angleDesktopGL || mobileGL || mgEgl;

    const EGLint attribs[] = {
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 24,
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT|EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, desktopGL ? EGL_OPENGL_BIT : EGL_OPENGL_ES3_BIT,
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
    if (desktopGL) {
        NSDebugLog(@"EGLBridge: Binding to desktop OpenGL");
        bindResult = handle.eglBindAPI(EGL_OPENGL_API);
    } else {
        NSDebugLog(@"EGLBridge: Binding to OpenGL ES");
        bindResult = handle.eglBindAPI(EGL_OPENGL_ES_API);
    }
    if (!bindResult) NSDebugLog(@"EGLBridge: bind failed: %p\n", handle.eglGetError());

    CALayer *layer = SurfaceViewController.surface.layer;
    CGSize drawableSize = layer.bounds.size;
    if ([layer isKindOfClass:CAMetalLayer.class]) {
        drawableSize = ((CAMetalLayer *)layer).drawableSize;
    } else {
        drawableSize = CGSizeMake(layer.bounds.size.width * layer.contentsScale,
                                  layer.bounds.size.height * layer.contentsScale);
    }
    g_surfW = (int)MAX(1.0, round(drawableSize.width));
    g_surfH = (int)MAX(1.0, round(drawableSize.height));
    const EGLint mobileGLSurfaceAttribs[] = {
        EGL_WIDTH, (EGLint)MAX(1.0, round(drawableSize.width)),
        EGL_HEIGHT, (EGLint)MAX(1.0, round(drawableSize.height)),
        EGL_NONE
    };
    bundle->surface = handle.eglCreateWindowSurface(g_EglDisplay, bundle->config, (__bridge EGLNativeWindowType)layer,
        mobileGL ? mobileGLSurfaceAttribs : NULL);
    if (!bundle->surface) {
        NSDebugLog(@"EGLBridge: eglCreateWindowSurface finished with error: 0x%x", handle.eglGetError());
        free(bundle);
        return NULL;
    }

    const EGLint gles_ctx_attribs[] = {
        EGL_CONTEXT_CLIENT_VERSION, 3,
        EGL_NONE
    };
    // MobileGlues turns down anything above its configured version (4.0 by default), 4.6 is MobileGL only
    const EGLint mg_ctx_attribs[] = {
        EGL_CONTEXT_MAJOR_VERSION, 4,
        EGL_CONTEXT_MINOR_VERSION, 0,
        EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
        EGL_NONE
    };
    const EGLint desktop_ctx_attribs[] = {
        EGL_CONTEXT_MAJOR_VERSION, 4,
        EGL_CONTEXT_MINOR_VERSION, 6,
        EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
        EGL_NONE
    };
    bundle->context = handle.eglCreateContext(g_EglDisplay, bundle->config, share ? share->context : EGL_NO_CONTEXT,
        mgEgl ? mg_ctx_attribs : (mobileGL ? desktop_ctx_attribs : gles_ctx_attribs));
    if (!bundle->context) {
        NSDebugLog(@"EGLBridge: Error eglCreateContext finished with error: 0x%x", handle.eglGetError());
        free(bundle);
        return NULL;
    }
    NSLog(@"EGLBridge: context %p surface %p (%.0fx%.0f, layer %@)", bundle->context, bundle->surface,
        drawableSize.width, drawableSize.height, NSStringFromClass(layer.class));
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
        static BOOL loggedCurrent;
        if (!loggedCurrent) {
            loggedCurrent = YES;
            NSLog(@"EGLBridge: context is current");
        }
    } else {
        NSLog(@"EGLBridge: eglMakeCurrent returned with error: 0x%x", handle.eglGetError());
    }
}

void gl_swap_buffers() {
    // Same rationale as osm_swap_buffers: block the render loop until the app
    // is active again so eglSwapBuffers (which can trigger Metal command buffer
    // submission) is never called from the background.
    pojavWaitForAppForeground();
    static int swaps, swapErrors;
    // a few markers so the log shows if frames keep coming
    ++swaps;
    if (swaps == 1) {
        g_renderThread = mach_thread_self();
        gl_start_watchdog();
    }
    g_swapCount = swaps;
    BOOL mark = swaps <= 3 || swaps == 60 || swaps == 600 || swaps == 6000;
    if (mark) NSLog(@"EGLBridge: swap #%d", swaps);
    gl_diag_frame(swaps);
    g_inSwap = 1;
    EGLBoolean swapped = handle.eglSwapBuffers(g_EglDisplay, currentBundle->gl.surface);
    g_inSwap = 0;
    if (!swapped) {
        EGLint err = handle.eglGetError();
        if (swapErrors++ < 5) NSLog(@"EGLBridge: eglSwapBuffers failed 0x%x", err);
    }
    if (swaps <= 3) NSLog(@"EGLBridge: swap #%d returned", swaps);
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
