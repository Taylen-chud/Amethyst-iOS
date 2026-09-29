#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>
#include <objc/runtime.h>
#include "jni.h"

#import "GameSurfaceView.h"
#import "SurfaceViewController.h"

static UIWindow *gSDLWindow = nil;
static UIView *gSDLView = nil;
static BOOL gSDLInstalled = NO;
static BOOL gObserversInstalled = NO;

static BOOL AMIsSDLView(UIView *view) {
    if (view == nil) return NO;

    NSString *name = NSStringFromClass(view.class);
    return [name containsString:@"SDL_uikitmetalview"] ||
           [name containsString:@"SDL_uikitopenglview"];
}

static UIView *AMFindSDLView(UIView *root) {
    if (root == nil) return nil;

    if (AMIsSDLView(root)) {
        return root;
    }

    for (UIView *child in root.subviews) {
        UIView *found = AMFindSDLView(child);
        if (found != nil) return found;
    }

    return nil;
}

static UIWindow *AMFindSDLWindow(void) {
    NSSet<UIScene *> *scenes = UIApplication.sharedApplication.connectedScenes;

    for (UIScene *scene in scenes) {
        if (![scene isKindOfClass:UIWindowScene.class])
            continue;

        UIWindowScene *windowScene = (UIWindowScene *)scene;

        for (UIWindow *window in windowScene.windows) {
            UIView *sdlView = AMFindSDLView(window.rootViewController.view);

            if (sdlView != nil) {
                return window;
            }
        }
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

/*
 * SDL's UIKit backend creates an SDL_uikitview first and later replaces it
 * with SDL_uikitmetalview for Vulkan.
 *
 * Keep the SDL view inside Amethyst's real window hierarchy so UIKit input
 * continues to target the active application window.
 */
static void AMEmbedSDLViewOnMain(void) {
    GameSurfaceView *host = [SurfaceViewController surface];

    if (host == nil) {
        NSLog(@"[SDL3 EMBED] GameSurfaceView unavailable");
        return;
    }

    UIWindow *window = AMFindSDLWindow();

    if (window == nil) {
        NSLog(@"[SDL3 EMBED] SDL UIWindow not found yet");
        return;
    }

    UIView *sdlView = AMFindSDLView(window.rootViewController.view);

    if (sdlView == nil) {
        NSLog(@"[SDL3 EMBED] SDL UIKit view not found yet");
        return;
    }

    gSDLWindow = window;
    gSDLView = sdlView;

    NSLog(@"[SDL3 EMBED] Found SDL window=%p class=%@ key=%d hidden=%d interaction=%d",
          window,
          NSStringFromClass(window.class),
          window.isKeyWindow,
          window.hidden,
          window.userInteractionEnabled);

    NSLog(@"[SDL3 EMBED] SDL view=%p class=%@ superview=%@ interaction=%d",
          sdlView,
          NSStringFromClass(sdlView.class),
          NSStringFromClass(sdlView.superview.class),
          sdlView.userInteractionEnabled);

    /*
     * If SDL has already been embedded, do nothing.
     */
    if (sdlView.superview == host) {
        sdlView.hidden = NO;
        sdlView.userInteractionEnabled = YES;
        sdlView.multipleTouchEnabled = YES;
        gSDLInstalled = YES;

        NSLog(@"[SDL3 EMBED] SDL view already embedded");
        return;
    }

    /*
     * Preserve SDL's actual UIKit view. Do not create a fake renderer view.
     */
    [sdlView removeFromSuperview];

    sdlView.translatesAutoresizingMaskIntoConstraints = NO;
    sdlView.hidden = NO;
    sdlView.userInteractionEnabled = YES;
    sdlView.multipleTouchEnabled = YES;
    sdlView.exclusiveTouch = NO;

    /*
     * Put SDL behind Amethyst's existing controls.
     *
     * The previous implementation used addSubview:, which put SDL on top
     * of every existing child of GameSurfaceView.
     */
    [host insertSubview:sdlView atIndex:0];

    [NSLayoutConstraint activateConstraints:@[
        [sdlView.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [sdlView.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
        [sdlView.topAnchor constraintEqualToAnchor:host.topAnchor],
        [sdlView.bottomAnchor constraintEqualToAnchor:host.bottomAnchor]
    ]];

    /*
     * The SDL UIWindow no longer owns the render view. Hide only that
     * secondary window so it cannot cover the Amethyst window.
     */
    window.hidden = YES;
    window.userInteractionEnabled = NO;

    gSDLInstalled = YES;

    NSLog(@"[SDL3 EMBED] SUCCESS: %@ embedded into GameSurfaceView",
          NSStringFromClass(sdlView.class));
}

/*
 * SDL can create its UIKit window asynchronously relative to Java's class
 * initialization. Try immediately and again after UIKit window notifications.
 */
static void AMTryEmbed(void) {
    AMRunSyncOnMain(^{
        AMEmbedSDLViewOnMain();
    });
}

static void AMUIKitWindowDidBecomeVisible(NSNotification *note) {
    UIWindow *window = note.object;

    if (![window isKindOfClass:UIWindow.class])
        return;

    AMRunSyncOnMain(^{
        UIView *sdlView = AMFindSDLView(window.rootViewController.view);

        if (sdlView == nil)
            return;

        NSLog(@"[SDL3 EMBED] SDL window became visible: %p", window);

        /*
         * Delay one main-runloop turn because SDL may still be replacing its
         * generic SDL_uikitview with SDL_uikitmetalview.
         */
        dispatch_async(dispatch_get_main_queue(), ^{
            AMEmbedSDLViewOnMain();
        });
    });
}

static void AMUIKitWindowDidBecomeKey(NSNotification *note) {
    UIWindow *window = note.object;

    if (![window isKindOfClass:UIWindow.class])
        return;

    UIView *sdlView = AMFindSDLView(window.rootViewController.view);

    if (sdlView == nil)
        return;

    NSLog(@"[SDL3 EMBED] SDL window became key: %p", window);

    dispatch_async(dispatch_get_main_queue(), ^{
        AMEmbedSDLViewOnMain();
    });
}

static void AMInstallUIKitObservers(void) {
    if (gObserversInstalled)
        return;

    gObserversInstalled = YES;

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];

    [center addObserverForName:UIWindowDidBecomeVisibleNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
        AMUIKitWindowDidBecomeVisible(note);
    }];

    [center addObserverForName:UIWindowDidBecomeKeyNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
        AMUIKitWindowDidBecomeKey(note);
    }];

    NSLog(@"[SDL3 EMBED] UIKit window observers installed");
}

/*
 * SDL_SetMainReady must run before SDL initializes its application state.
 */
static void AMSDL3SetMainReady(void) {
    AMRunSyncOnMain(^{
        const char *paths[] = {
            "@executable_path/Frameworks/lwjgl34/libSDL3.dylib",
            "@loader_path/Frameworks/lwjgl34/libSDL3.dylib",
            NULL
        };

        for (int i = 0; paths[i] != NULL; i++) {
            void *handle = dlopen(paths[i], RTLD_NOW | RTLD_LOCAL);

            if (handle == NULL)
                continue;

            void (*setMainReady)(void) =
                (void (*)(void))dlsym(handle, "SDL_SetMainReady");

            if (setMainReady != NULL) {
                setMainReady();
                NSLog(@"[SDL3] SDL_SetMainReady called");
                dlclose(handle);
                return;
            }

            dlclose(handle);
        }

        void *handle =
            dlopen("@rpath/SDL3.framework/SDL3", RTLD_NOW | RTLD_LOCAL);

        if (handle != NULL) {
            void (*setMainReady)(void) =
                (void (*)(void))dlsym(handle, "SDL_SetMainReady");

            if (setMainReady != NULL) {
                setMainReady();
                NSLog(@"[SDL3] SDL_SetMainReady called");
            }

            dlclose(handle);
        }
    });
}

void AmethystSDL3Prepare(void) {
    NSLog(@"[SDL3 TRACE] nativePrepare BEGIN main=%d",
          [NSThread isMainThread]);

    AMInstallUIKitObservers();
    AMSDL3SetMainReady();

    /*
     * Keep SDL from installing its own home-indicator behavior over
     * Amethyst's presentation.
     */
    setenv("SDL_IOS_HIDE_HOME_INDICATOR", "2", 0);

    NSString *moltenVK =
        [NSBundle.mainBundle.bundlePath
            stringByAppendingPathComponent:@"Frameworks/libMoltenVK.dylib"];

    if ([[NSFileManager defaultManager] fileExistsAtPath:moltenVK]) {
        setenv("SDL_VULKAN_LIBRARY", moltenVK.UTF8String, 1);
        NSLog(@"[SDL3] SDL_VULKAN_LIBRARY=%@", moltenVK);
    } else {
        NSLog(@"[SDL3] libMoltenVK.dylib not found");
    }

    /*
     * SDL may not have created its UIWindow yet. This is intentionally
     * non-fatal; the UIKit notification handlers will catch it later.
     */
    dispatch_async(dispatch_get_main_queue(), ^{
        AMEmbedSDLViewOnMain();
    });

    NSLog(@"[SDL3 TRACE] nativePrepare END");
}

void AmethystSDL3Loaded(void) {
    NSLog(@"[SDL3 TRACE] nativeLoaded main=%d",
          [NSThread isMainThread]);

    /*
     * By nativeLoaded the SDL library is definitely resident. Give SDL one
     * more main-thread opportunity to create its UIKit window.
     */
    dispatch_async(dispatch_get_main_queue(), ^{
        AMEmbedSDLViewOnMain();
    });
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

/*
 * These functions are retained for compatibility with the existing
 * SDL3Bridge.java. Minecraft 26.3 does not appear to use them for its
 * actual window creation path, but keeping them prevents JNI symbol
 * mismatches if another LWJGL SDL path calls them.
 */
static BOOL AMInvokeBoolOnMain(long long functionAddress, int flags) {
    if (functionAddress == 0)
        return NO;

    __block BOOL result = NO;

    AMRunSyncOnMain(^{
        BOOL (*fn)(int) =
            (BOOL (*)(int))(uintptr_t)functionAddress;

        result = fn(flags);
    });

    return result;
}

JNIEXPORT jboolean JNICALL
Java_org_lwjgl_sdl_SDL3Bridge_nativeInit(JNIEnv *env, jclass clazz,
                                         jlong functionAddress, jint flags) {
    (void)env;
    (void)clazz;

    BOOL result =
        AMInvokeBoolOnMain((long long)functionAddress, (int)flags);

    return result ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jboolean JNICALL
Java_org_lwjgl_sdl_SDL3Bridge_nativeInitSubSystem(JNIEnv *env, jclass clazz,
                                                  jlong functionAddress,
                                                  jint flags) {
    (void)env;
    (void)clazz;

    BOOL result =
        AMInvokeBoolOnMain((long long)functionAddress, (int)flags);

    return result ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jlong JNICALL
Java_org_lwjgl_sdl_SDL3Bridge_nativeCreateWindow(JNIEnv *env, jclass clazz,
                                                 jlong functionAddress,
                                                 jlong title,
                                                 jint w, jint h,
                                                 jlong flags) {
    (void)env;
    (void)clazz;

    __block void *window = NULL;

    AMRunSyncOnMain(^{
        void *(*fn)(const char *, int, int, uint64_t) =
            (void *(*)(const char *, int, int, uint64_t))
                (uintptr_t)functionAddress;

        window = fn((const char *)(uintptr_t)title,
                    (int)w,
                    (int)h,
                    (uint64_t)flags);
    });

    dispatch_async(dispatch_get_main_queue(), ^{
        AMEmbedSDLViewOnMain();
    });

    return (jlong)(uintptr_t)window;
}

JNIEXPORT jlong JNICALL
Java_org_lwjgl_sdl_SDL3Bridge_nativeCreateWindowWithProperties(
    JNIEnv *env, jclass clazz,
    jlong functionAddress, jint props) {
    (void)env;
    (void)clazz;

    __block void *window = NULL;

    AMRunSyncOnMain(^{
        void *(*fn)(uint32_t) =
            (void *(*)(uint32_t))(uintptr_t)functionAddress;

        window = fn((uint32_t)props);
    });

    dispatch_async(dispatch_get_main_queue(), ^{
        AMEmbedSDLViewOnMain();
    });

    return (jlong)(uintptr_t)window;
}

JNIEXPORT jlong JNICALL
Java_org_lwjgl_sdl_SDL3Bridge_nativeInvokeOnMain(JNIEnv *env,
                                                 jclass clazz,
                                                 jlong functionAddress,
                                                 jlong a0,
                                                 jlong a1,
                                                 jlong a2,
                                                 jlong a3) {
    (void)env;
    (void)clazz;

    if (functionAddress == 0)
        return 0;

    __block uint64_t result = 0;

    AMRunSyncOnMain(^{
        uint64_t (*fn)(uint64_t, uint64_t, uint64_t, uint64_t) =
            (uint64_t (*)(uint64_t, uint64_t, uint64_t, uint64_t))
                (uintptr_t)functionAddress;

        result = fn((uint64_t)a0,
                    (uint64_t)a1,
                    (uint64_t)a2,
                    (uint64_t)a3);
    });

    return (jlong)result;
}

JNIEXPORT void JNICALL
Java_org_lwjgl_sdl_SDL3Bridge_nativeAttachWindow(JNIEnv *env,
                                                 jclass clazz,
                                                 jlong sdlWindow,
                                                 jlong uiWindow) {
    (void)env;
    (void)clazz;
    (void)sdlWindow;
    (void)uiWindow;

    /*
     * Do not trust the Java-side uiWindow pointer. The real MC 26.3 path
     * creates SDL's UIKit window internally. Rediscover it from UIKit.
     */
    dispatch_async(dispatch_get_main_queue(), ^{
        AMEmbedSDLViewOnMain();
    });
}
