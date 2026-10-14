#import "SurfaceViewController.h"

#include "jni.h"
#include "renderer_info.h"
#include <assert.h>
#include <dlfcn.h>

#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>

#include "EGL/egl.h"
#include "EGL/eglext.h"
#include "GL/osmesa.h"

#include "glfw_keycodes.h"
#include "ctxbridges/bridge_tbl.h"
#include "ctxbridges/vk_bridge.h"
#include "ctxbridges/osmesa_internal.h"
#include "utils.h"

int clientAPI;

void JNI_LWJGL_changeRenderer(const char* value_c) {
    JNIEnv *env;
    (*runtimeJavaVMPtr)->GetEnv(runtimeJavaVMPtr, (void **)&env, JNI_VERSION_1_4);
    jstring key = (*env)->NewStringUTF(env, "org.lwjgl.opengl.libname");
    jstring value = (*env)->NewStringUTF(env, value_c);
    jclass clazz = (*env)->FindClass(env, "java/lang/System");
    jmethodID method = (*env)->GetStaticMethodID(env, clazz, "setProperty", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
    (*env)->CallStaticObjectMethod(env, clazz, method, key, value);
}

void pojavTerminate() {
    CallbackBridge_nativeSetInputReady(NO);
    if (!br_terminate) return;
    br_terminate();
}

void* pojavGetCurrentContext() {
    return br_get_current();
}

int pojavInit(BOOL useStackQueue) {
    clientAPI = GLFW_OPENGL_API;
    isInputReady = 1;
    isUseStackQueueCall = useStackQueue;
    return JNI_TRUE;
}

int pojavInitOpenGL() {
    const char *name = getenv("AME_RENDERER");
    ame_renderer_t kind = ame_renderer_from_name(name);
    // auto still unresolved here means the game never asked for a GL version, pick gl4es
    if (kind == AME_RENDERER_AUTO) {
        kind = AME_RENDERER_GL4ES;
        name = RENDERER_NAME_GL4ES;
        setenv("AME_RENDERER", name, 1);
    }

    // the Vulkan drivers have no GL of their own, a game that wants one runs on ANGLE
    if (ame_renderer_is_vulkan_native(kind)) {
        AMVulkanNoteGLFallback();
        kind = AME_RENDERER_ANGLE;
        name = RENDERER_NAME_MTL_ANGLE;
        setenv("AME_RENDERER", name, 1);
    }

    switch (kind) {
        case AME_RENDERER_GL4ES:
        case AME_RENDERER_ANGLE:
        case AME_RENDERER_MOBILEGLUES:
            set_gl_bridge_tbl();
            break;
        case AME_RENDERER_MOBILEGL:
            setenv("MOBILEGL_BACKEND_TYPE", "DirectVulkan", 1);
            set_gl_bridge_tbl();
            break;
        case AME_RENDERER_ZINK:
            setenv("GALLIUM_DRIVER","zink",1);
            set_osm_bridge_tbl();
            break;
        default:
            NSLog(@"pojavInitOpenGL: unknown renderer %s", name ?: "<unset>");
            return 1;
    }
    JNI_LWJGL_changeRenderer(name);
    // Preload renderer library
    dlopen([NSString stringWithFormat:@"@rpath/%s", name].UTF8String, RTLD_GLOBAL);

    return !br_init();
}

void pojavSetWindowHint(int hint, int value) {
    if (hint == GLFW_CLIENT_API) {
        clientAPI = value;
    } else if (hint == GLFW_CONTEXT_VERSION_MAJOR && ame_renderer_from_name(getenv("AME_RENDERER")) == AME_RENDERER_AUTO) {
        const char *picked = (value == 1 || value == 2) ? RENDERER_NAME_GL4ES : RENDERER_NAME_MOBILEGLUES;
        setenv("AME_RENDERER", picked, 1);
        JNI_LWJGL_changeRenderer(picked);
    }
}

void pojavSwapBuffers() {
    br_swap_buffers();
}

void pojavMakeCurrent(basic_render_window_t* window) {
    br_make_current(window);
}

void* pojavCreateContext(basic_render_window_t* contextSrc) {
    if (clientAPI == GLFW_NO_API) {
        // Game has selected Vulkan API to render
        return AMVulkanSurfaceLayer();
    }

    static BOOL inited = NO;
    if (!inited) {
        inited = YES;
        pojavInitOpenGL();
    }

    return br_init_context(contextSrc);
}

void pojavSwapInterval(int interval) {
    if (!br_swap_interval) return;
    br_swap_interval(interval);
}
