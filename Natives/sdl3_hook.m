#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>
#include "jni.h"

#import "GameSurfaceView.h"
#import "SurfaceViewController.h"

static UIView *AMFindSDLView(UIView *root) {
    if (root == nil) return nil;

    NSString *name = NSStringFromClass(root.class);
    if ([name containsString:@"SDL_uikitmetalview"] ||
        [name containsString:@"SDL_uikitopenglview"]) {
        return root;
    }

    for (UIView *view in root.subviews) {
        UIView *found = AMFindSDLView(view);
        if (found != nil) return found;
    }
    return nil;
}

static void AMRunSyncOnMain(void (^block)(void)) {
    if ([NSThread isMainThread]) {
        block();
        return;
    }
    dispatch_sync(dispatch_get_main_queue(), block);
}

static void AMAttachSDLWindowOnMain(long long sdlWindow, long long uiWindowPointer) {
    GameSurfaceView *host = [SurfaceViewController surface];
    if (host == nil) {
        NSLog(@"[SDL3] host GameSurfaceView is unavailable");
        return;
    }

    UIWindow *window = (__bridge UIWindow *)(void *)uiWindowPointer;
    UIView *sdlView = nil;
    if (window != nil && window.rootViewController != nil) {
        sdlView = AMFindSDLView(window.rootViewController.view);
    }

    if (sdlView == nil) {
        NSLog(@"[SDL3] could not locate SDL UIKit render view");
        return;
    }

    if (sdlView.superview != host) {
        [sdlView removeFromSuperview];
        sdlView.translatesAutoresizingMaskIntoConstraints = NO;
        [host addSubview:sdlView];
        [NSLayoutConstraint activateConstraints:@[
            [sdlView.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
            [sdlView.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
            [sdlView.topAnchor constraintEqualToAnchor:host.topAnchor],
            [sdlView.bottomAnchor constraintEqualToAnchor:host.bottomAnchor]
        ]];
    }

    sdlView.hidden = NO;
    sdlView.userInteractionEnabled = YES;

    if (window != nil) {
        window.hidden = YES;
        window.userInteractionEnabled = NO;
    }

    NSLog(@"[SDL3] attached %@ to GameSurfaceView (SDL window=%p)",
          NSStringFromClass(sdlView.class), (void *)(uintptr_t)sdlWindow);
}

static void AMSDL3SetMainReady(void) {
    AMRunSyncOnMain(^{
        const char *paths[] = {
            "@executable_path/Frameworks/lwjgl34/libSDL3.dylib",
            "@loader_path/Frameworks/lwjgl34/libSDL3.dylib",
            NULL
        };

        for (int i = 0; paths[i] != NULL; i++) {
            void *handle = dlopen(paths[i], RTLD_NOW | RTLD_LOCAL);
            if (handle == NULL) continue;

            void (*setMainReady)(void) = (void (*)(void))dlsym(handle, "SDL_SetMainReady");
            if (setMainReady != NULL) {
                setMainReady();
                NSLog(@"[SDL3] SDL_SetMainReady called");
                dlclose(handle);
                return;
            }
            dlclose(handle);
        }

        void *handle = dlopen("@rpath/SDL3.framework/SDL3", RTLD_NOW | RTLD_LOCAL);
        if (handle != NULL) {
            void (*setMainReady)(void) = (void (*)(void))dlsym(handle, "SDL_SetMainReady");
            if (setMainReady != NULL) {
                setMainReady();
                NSLog(@"[SDL3] SDL_SetMainReady called");
            }
            dlclose(handle);
        }
    });
}

void AmethystSDL3Prepare(void) {
    NSLog(@"[SDL3 TRACE] nativePrepare BEGIN main=%d", [NSThread isMainThread]);
    AMSDL3SetMainReady();
    setenv("SDL_IOS_HIDE_HOME_INDICATOR", "2", 0);

    NSString *moltenVK = [NSBundle.mainBundle.bundlePath
        stringByAppendingPathComponent:@"Frameworks/libMoltenVK.dylib"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:moltenVK]) {
        setenv("SDL_VULKAN_LIBRARY", moltenVK.UTF8String, 1);
        NSLog(@"[SDL3] SDL_VULKAN_LIBRARY=%@", moltenVK);
    } else {
        NSLog(@"[SDL3] libMoltenVK.dylib not found");
    }
    NSLog(@"[SDL3 TRACE] nativePrepare END");
}

void AmethystSDL3Loaded(void) {
    NSLog(@"[SDL3 TRACE] nativeLoaded main=%d", [NSThread isMainThread]);
}

static BOOL AMInvokeBoolOnMain(long long functionAddress, int flags) {
    if (functionAddress == 0) return NO;

    __block BOOL result = NO;
    AMRunSyncOnMain(^{
        BOOL (*fn)(int) = (BOOL (*)(int))(uintptr_t)functionAddress;
        result = fn(flags);
    });
    return result;
}

JNIEXPORT void JNICALL
Java_org_lwjgl_sdl_SDL3Bridge_nativePrepare(JNIEnv *env, jclass clazz) {
    (void)env;
    (void)clazz;
    AmethystSDL3Prepare();
}

JNIEXPORT void JNICALL
Java_org_lwjgl_sdl_SDL3Bridge_nativeLoaded(JNIEnv *env, jclass clazz) {
    (void)env;
    (void)clazz;
    AmethystSDL3Loaded();
}

JNIEXPORT jboolean JNICALL
Java_org_lwjgl_sdl_SDL3Bridge_nativeInit(JNIEnv *env, jclass clazz,
                                         jlong functionAddress, jint flags) {
    (void)env;
    (void)clazz;
    NSLog(@"[SDL3 TRACE] nativeInit flags=%d main=%d", (int)flags, [NSThread isMainThread]);
    BOOL result = AMInvokeBoolOnMain((long long)functionAddress, (int)flags);
    NSLog(@"[SDL3 TRACE] nativeInit result=%d", result);
    return result ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jboolean JNICALL
Java_org_lwjgl_sdl_SDL3Bridge_nativeInitSubSystem(JNIEnv *env, jclass clazz,
                                                  jlong functionAddress, jint flags) {
    (void)env;
    (void)clazz;
    NSLog(@"[SDL3 TRACE] nativeInitSubSystem flags=%d main=%d", (int)flags, [NSThread isMainThread]);
    BOOL result = AMInvokeBoolOnMain((long long)functionAddress, (int)flags);
    NSLog(@"[SDL3 TRACE] nativeInitSubSystem result=%d", result);
    return result ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jlong JNICALL
Java_org_lwjgl_sdl_SDL3Bridge_nativeCreateWindow(JNIEnv *env, jclass clazz,
                                                  jlong functionAddress, jlong title,
                                                  jint w, jint h, jlong flags) {
    (void)env;
    (void)clazz;
    NSLog(@"[SDL3 TRACE] nativeCreateWindow main=%d", [NSThread isMainThread]);
    __block void *window = NULL;
    AMRunSyncOnMain(^{
        void *(*fn)(const char *, int, int, uint64_t) =
            (void *(*)(const char *, int, int, uint64_t))(uintptr_t)functionAddress;
        window = fn((const char *)(uintptr_t)title, (int)w, (int)h, (uint64_t)flags);
    });
    NSLog(@"[SDL3 TRACE] nativeCreateWindow result=%p", window);
    return (jlong)(uintptr_t)window;
}

JNIEXPORT jlong JNICALL
Java_org_lwjgl_sdl_SDL3Bridge_nativeCreateWindowWithProperties(JNIEnv *env, jclass clazz,
                                                               jlong functionAddress, jint props) {
    (void)env;
    (void)clazz;
    NSLog(@"[SDL3 TRACE] nativeCreateWindowWithProperties main=%d", [NSThread isMainThread]);
    __block void *window = NULL;
    AMRunSyncOnMain(^{
        void *(*fn)(uint32_t) = (void *(*)(uint32_t))(uintptr_t)functionAddress;
        window = fn((uint32_t)props);
    });
    NSLog(@"[SDL3 TRACE] nativeCreateWindowWithProperties result=%p", window);
    return (jlong)(uintptr_t)window;
}

JNIEXPORT void JNICALL
Java_org_lwjgl_sdl_SDL3Bridge_nativeAttachWindow(JNIEnv *env, jclass clazz,
                                                   jlong sdlWindow, jlong uiWindow) {
    (void)env;
    (void)clazz;

    dispatch_async(dispatch_get_main_queue(), ^{
        AMAttachSDLWindowOnMain((long long)sdlWindow, (long long)uiWindow);
    });
}
