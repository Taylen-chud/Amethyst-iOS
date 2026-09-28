#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "GameSurfaceView.h"
#import "SurfaceViewController.h"
#import "sdl3_hook.h"

#include <stdint.h>
#include <stdlib.h>
#include <dlfcn.h>
#include "jni.h"

typedef void (*AMSDLSetMainReadyFunc)(void);

static UIView *AMFindSDLView(UIView *root) {
    if (root == nil) {
        return nil;
    }

    NSString *className = NSStringFromClass(root.class);

    if ([className containsString:@"SDL_uikitmetalview"] ||
        [className containsString:@"SDL_uikitopenglview"]) {
        return root;
    }

    for (UIView *subview in root.subviews) {
        UIView *found = AMFindSDLView(subview);

        if (found != nil) {
            return found;
        }
    }

    return nil;
}

static void AMAttachSDLWindowOnMain(long long sdlWindow,
                                    long long uiWindowPointer) {
    GameSurfaceView *host = [SurfaceViewController surface];

    if (host == nil) {
        NSLog(@"[SDL3] host GameSurfaceView is unavailable");
        return;
    }

    UIWindow *sdlWindowObject =
        (__bridge UIWindow *)(void *)uiWindowPointer;

    UIView *sdlView = nil;

    if (sdlWindowObject != nil) {
        UIViewController *rootController =
            sdlWindowObject.rootViewController;

        if (rootController != nil) {
            sdlView = AMFindSDLView(rootController.view);
        }
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

    if (sdlWindowObject != nil) {
        sdlWindowObject.hidden = YES;
        sdlWindowObject.userInteractionEnabled = NO;
    }

    NSLog(@"[SDL3] attached %@ to Amethyst GameSurfaceView (SDL window=%p)",
          NSStringFromClass(sdlView.class),
          (void *)(uintptr_t)sdlWindow);
}

static BOOL AMSDL3SetMainReady(void) {
    const char *libraryPaths[] = {
        "@executable_path/Frameworks/libSDL3.dylib",
        "@executable_path/Frameworks/SDL3.framework/SDL3",
        "@loader_path/Frameworks/libSDL3.dylib",
        "@loader_path/Frameworks/SDL3.framework/SDL3",
        NULL
    };

    void *handle = NULL;

    for (NSUInteger i = 0; libraryPaths[i] != NULL; i++) {
        handle = dlopen(libraryPaths[i], RTLD_NOW);

        if (handle != NULL) {
            NSLog(@"[SDL3] found SDL3 native library at %s",
                  libraryPaths[i]);
            break;
        }
    }

    if (handle == NULL) {
        handle = dlopen("@rpath/SDL3.framework/SDL3", RTLD_NOW);

        if (handle != NULL) {
            NSLog(@"[SDL3] found SDL3 through @rpath");
        }
    }

    if (handle == NULL) {
        const char *error = dlerror();

        NSLog(@"[SDL3] ERROR: could not load SDL3 before SDL_Init()");

        if (error != NULL) {
            NSLog(@"[SDL3] dlopen error: %s", error);
        }

        return NO;
    }

    dlerror();

    AMSDLSetMainReadyFunc setMainReady =
        (AMSDLSetMainReadyFunc)dlsym(handle, "SDL_SetMainReady");

    const char *symbolError = dlerror();

    if (symbolError != NULL || setMainReady == NULL) {
        NSLog(@"[SDL3] ERROR: SDL_SetMainReady was not found");

        if (symbolError != NULL) {
            NSLog(@"[SDL3] dlsym error: %s", symbolError);
        }

        return NO;
    }

    setMainReady();

    NSLog(@"[SDL3] SDL_SetMainReady() completed successfully");

    return YES;
}

void AmethystSDL3Prepare(void) {
    if (!AMSDL3SetMainReady()) {
        NSLog(@"[SDL3] WARNING: SDL main-entry initialization failed");
    }

    setenv("SDL_IOS_HIDE_HOME_INDICATOR", "2", 0);

    NSString *moltenVK =
        [NSBundle.mainBundle.bundlePath
            stringByAppendingPathComponent:
                @"Frameworks/libMoltenVK.dylib"];

    if ([[NSFileManager defaultManager] fileExistsAtPath:moltenVK]) {
        setenv("SDL_VULKAN_LIBRARY",
               moltenVK.UTF8String,
               0);

        NSLog(@"[SDL3] SDL_VULKAN_LIBRARY=%@",
              moltenVK);
    } else {
        NSLog(@"[SDL3] WARNING: libMoltenVK.dylib not found at %@",
              moltenVK);
    }
}

void AmethystSDL3Loaded(void) {
    NSLog(@"[SDL3] LWJGL SDL3 library loaded");
}

JNIEXPORT void JNICALL
Java_org_lwjgl_sdl_SDL3Bridge_nativePrepare(JNIEnv *env,
                                             jclass clazz) {
    (void)env;
    (void)clazz;

    AmethystSDL3Prepare();
}

JNIEXPORT void JNICALL
Java_org_lwjgl_sdl_SDL3Bridge_nativeLoaded(JNIEnv *env,
                                            jclass clazz) {
    (void)env;
    (void)clazz;

    AmethystSDL3Loaded();
}

JNIEXPORT void JNICALL
Java_org_lwjgl_sdl_SDL3Bridge_nativeAttachWindow(JNIEnv *env,
                                                  jclass clazz,
                                                  jlong sdlWindow,
                                                  jlong uiWindow) {
    (void)env;
    (void)clazz;

    dispatch_async(dispatch_get_main_queue(), ^{
        AMAttachSDLWindowOnMain((long long)sdlWindow,
                                (long long)uiWindow);
    });
}
