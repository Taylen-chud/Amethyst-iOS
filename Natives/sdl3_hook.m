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
}

void AmethystSDL3Prepare(void) {
    AMSDL3SetMainReady();
    setenv("SDL_IOS_HIDE_HOME_INDICATOR", "2", 0);

    NSString *moltenVK = [NSBundle.mainBundle.bundlePath
        stringByAppendingPathComponent:@"Frameworks/libMoltenVK.dylib"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:moltenVK]) {
        setenv("SDL_VULKAN_LIBRARY", moltenVK.UTF8String, 1);
    }
}

void AmethystSDL3Loaded(void) {
    NSLog(@"[SDL3] LWJGL SDL3 library loaded");
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

JNIEXPORT void JNICALL
Java_org_lwjgl_sdl_SDL3Bridge_nativeAttachWindow(JNIEnv *env, jclass clazz,
                                                   jlong sdlWindow, jlong uiWindow) {
    (void)env;
    (void)clazz;

    dispatch_async(dispatch_get_main_queue(), ^{
        AMAttachSDLWindowOnMain((long long)sdlWindow, (long long)uiWindow);
    });
}
