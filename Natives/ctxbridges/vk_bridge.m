#import "vk_bridge.h"

#import <QuartzCore/CAMetalLayer.h>
#import <stdatomic.h>

#import "SurfaceViewController.h"
#import "ios_uikit_bridge.h"
#import "renderer_info.h"
#import "utils.h"

static _Atomic bool vulkanNative;

bool AMVulkanNativeActive(void) {
    return atomic_load_explicit(&vulkanNative, memory_order_acquire);
}

// resolution handling differs once the game renders through Vulkan, redo it on the main thread
static void syncGeometry(void) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = UIWindow.mainWindow.rootViewController;
        if ([vc isKindOfClass:SurfaceViewController.class]) {
            [(SurfaceViewController *)vc updateSavedResolution];
        }
        dispatch_semaphore_signal(done);
    });
    // never wedge the render thread if the main thread is busy
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
}

void *AMVulkanSurfaceLayer(void) {
    CALayer *layer = SurfaceViewController.surface.layer;
    if (![layer isKindOfClass:CAMetalLayer.class]) {
        NSLog(@"[VulkanBridge] surface layer is %@, vkCreateMetalSurfaceEXT needs a CAMetalLayer", layer.class);
    }
    if (!atomic_exchange_explicit(&vulkanNative, true, memory_order_acq_rel)) {
        NSLog(@"[VulkanBridge] game renders through Vulkan, syncing drawable size");
        syncGeometry();
    }
    return (__bridge void *)layer;
}

void AMVulkanNoteGLFallback(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSLog(@"[VulkanBridge] game asked for an OpenGL context, falling back to ANGLE");
    });
}
