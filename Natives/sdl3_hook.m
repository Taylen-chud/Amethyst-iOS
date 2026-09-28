#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "GameSurfaceView.h"
#import "SurfaceViewController.h"
#import "sdl3_hook.h"

#include <stdint.h>
#include <stdlib.h>
#include "jni.h"

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

static void AMAttachSDLWindowOnMain(long long sdlWindow, long long uiWindowPointer) {
    GameSurfaceView *host = [SurfaceViewController surface];
    if (host == nil) {
        NSLog(@"[SDL3] host GameSurfaceView is unavailable");
        return;
    }

    UIWindow *sdlWindowObject = (__bridge UIWindow *)(void *)uiWindowPointer;
    UIView *sdlView = nil;

    if (sdlWindowObject != nil) {
        UIViewController *rootController = sdlWindowObject.rootViewController;
        sdlView = AMFindSDLView(rootController.view);
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

    // SDL owns this auxiliary UIWindow. Amethyst owns the visible host view.
    // Keeping SDL's window hidden prevents it from appearing above the launcher.
    if (sdlWindowObject != nil) {
        sdlWindowObject.hidden = YES;
        sdlWindowObject.userInteractionEnabled = NO;
    }

    NSLog(@"[SDL3] attached %@ to Amethyst GameSurfaceView (SDL window=%p)",
          NSStringFromClass(sdlView.class), (void *)(uintptr_t)sdlWindow);
}

void AmethystSDL3Prepare(void) {
    // Keep SDL's UIKit backend from trying to become the visible app window.
    // Minecraft's SDL window is embedded into Amethyst after SDL creates it.
    setenv("SDL_IOS_HIDE_HOME_INDICATOR", "2", 0);

    // Make SDL and LWJGL resolve Vulkan through the same MoltenVK image.
    // This is important when SDL creates a Vulkan surface for a Vulkan-backed
    // Minecraft renderer: two independent Vulkan loader images cannot share
    // instance/function pointers safely.
    NSString *moltenVK = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/libMoltenVK.dylib"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:moltenVK]) {
        setenv("SDL_VULKAN_LIBRARY", moltenVK.UTF8String, 0);
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
Java_org_lwjgl_sdl_SDL3Bridge_nativeAttachWindow(JNIEnv *env, jclass clazz, jlong sdlWindow, jlong uiWindow) {
    (void)env;
    (void)clazz;

    dispatch_async(dispatch_get_main_queue(), ^{
        AMAttachSDLWindowOnMain((long long)sdlWindow, (long long)uiWindow);
    });
}
