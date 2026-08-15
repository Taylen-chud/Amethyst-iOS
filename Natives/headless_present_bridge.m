// headless_present_bridge.m
//
// EXPERIMENTAL / testing-branch only. Implements MobileGL_HeadlessPresent()
// (declared in MobileGL's MobileGL_HeadlessPresent.h), the interop entry
// point MobileGL's DirectVulkan backend calls once per frame when
// MOBILEGL_NO_SWAPCHAIN is set, instead of vkQueuePresentKHR.
//
// WHY THIS EXISTS: CAMetalLayer.displaySyncEnabled (the real API for
// disabling vsync on Metal) is explicitly documented as unavailable on iOS -
// Metal always waits for v-blank there, with no supported opt-out. That
// applies just as much to MoltenVK's CAMetalLayer-backed VkSwapchainKHR as it
// does to raw Metal. A PLAIN CALayer showing manually-updated IOSurface
// content is a different code path that isn't subject to that rule, so we
// use one instead: MobileGL renders to its own offscreen VkImages (see
// SwapchainObject::IsHeadless), copies the finished frame to a CPU-mapped
// buffer, and this file's job is just "get those pixels on screen without
// going through CAMetalLayer's drawable/present pipeline."
//
// KNOWN LIMITATIONS (this is a rough prototype, not production code):
//   - Synchronous CPU readback + memcpy every frame. Correctness over
//     performance; a real implementation would want a zero-copy Vulkan/Metal
//     interop path (VK_EXT_metal_objects or similar) instead.
//   - The measured/displayed refresh rate is still capped by the display's
//     own hardware refresh (CoreAnimation's compositor is still real) - what
//     this actually removes is the CPU-side render loop being BLOCKED
//     waiting for vsync, which is usually what "unlimited FPS" reports are
//     actually measuring, and does reduce input latency even where it can't
//     increase the physical number of distinct images shown per second.
//   - IOSurface pixel-format handling only covers the four VkFormats
//     ChooseSwapchainSurfaceFormat can actually pick (see below); anything
//     else falls back to BGRA8 and logs a warning rather than crashing.

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurface.h>

#import "SurfaceViewController.h"

// Mirrors the handful of VkFormat integer values ChooseSwapchainSurfaceFormat
// in SwapchainObject.cpp can actually pick, without needing to pull in
// Vulkan's headers here. If MobileGL's format selection ever changes, this
// mapping needs updating alongside it.
typedef NS_ENUM(int32_t, MobileGLHeadlessVkFormat) {
    MobileGLHeadlessVkFormat_R8G8B8A8_UNORM = 37,
    MobileGLHeadlessVkFormat_B8G8R8A8_UNORM = 44,
    MobileGLHeadlessVkFormat_R8G8B8A8_SRGB  = 43,
    MobileGLHeadlessVkFormat_B8G8R8A8_SRGB  = 50,
};

static CALayer *g_headlessPresentLayer = nil;
static IOSurfaceRef g_headlessSurface = NULL;
static uint32_t g_headlessSurfaceWidth = 0;
static uint32_t g_headlessSurfaceHeight = 0;
static dispatch_once_t g_headlessWarnedUnknownFormatOnce;

static OSType MobileGLHeadless_PixelFormatFor(int32_t vkFormat) {
    switch ((MobileGLHeadlessVkFormat)vkFormat) {
        case MobileGLHeadlessVkFormat_R8G8B8A8_UNORM:
        case MobileGLHeadlessVkFormat_R8G8B8A8_SRGB:
            return kCVPixelFormatType_32RGBA;
        case MobileGLHeadlessVkFormat_B8G8R8A8_UNORM:
        case MobileGLHeadlessVkFormat_B8G8R8A8_SRGB:
            return kCVPixelFormatType_32BGRA;
    }
    dispatch_once(&g_headlessWarnedUnknownFormatOnce, ^{
        NSLog(@"[HeadlessPresent] Unrecognized VkFormat %d from MobileGL, assuming BGRA8. "
               "If colors look swapped (red/blue reversed), this mapping needs a new case - "
               "see ChooseSwapchainSurfaceFormat in MobileGL's SwapchainObject.cpp for what it can pick.",
              vkFormat);
    });
    return kCVPixelFormatType_32BGRA;
}

// Ensures g_headlessPresentLayer exists as a sublayer of the current game
// surface's layer, sized to match. Must run on the main thread - CALayer
// hierarchy mutation (adding/removing/resizing sublayers) is not safe from
// background threads, only .contents assignment on an already-attached layer
// arguably is, and we're not relying on that distinction here.
static void MobileGLHeadless_EnsureLayer(uint32_t width, uint32_t height) {
    CALayer *parent = SurfaceViewController.surface.layer;
    if (!parent) {
        return;
    }
    if (!g_headlessPresentLayer) {
        g_headlessPresentLayer = [CALayer layer];
        // Match GameSurfaceView's own layer setup (opaque, async draw) rather
        // than leaving CALayer's slower defaults in place.
        g_headlessPresentLayer.opaque = YES;
        g_headlessPresentLayer.drawsAsynchronously = YES;
        // Sits ABOVE the CAMetalLayer underneath, which stays alive (MobileGL
        // still needs it for surface capability queries at swapchain-creation
        // time - see SwapchainObject::Create) but stops actively presenting
        // real drawables once headless mode takes over per-frame updates.
        [parent addSublayer:g_headlessPresentLayer];
    }
    if (!CGRectEqualToRect(g_headlessPresentLayer.frame, parent.bounds)) {
        g_headlessPresentLayer.frame = parent.bounds;
    }
}

void MobileGL_HeadlessPresent(const void *pixels, uint32_t width, uint32_t height, uint32_t bytesPerRow,
                               int32_t format) {
    if (!pixels || width == 0 || height == 0) {
        return;
    }

    // (Re)create the IOSurface if this is the first frame or the size changed
    // (rotation/resize). IOSurface creation/destruction is thread-safe on its
    // own, unlike the CALayer hierarchy touched below.
    if (!g_headlessSurface || g_headlessSurfaceWidth != width || g_headlessSurfaceHeight != height) {
        if (g_headlessSurface) {
            CFRelease(g_headlessSurface);
            g_headlessSurface = NULL;
        }
        OSType pixelFormat = MobileGLHeadless_PixelFormatFor(format);
        NSDictionary *properties = @{
            (id)kIOSurfaceWidth: @(width),
            (id)kIOSurfaceHeight: @(height),
            (id)kIOSurfaceBytesPerElement: @(4),
            (id)kIOSurfacePixelFormat: @(pixelFormat),
        };
        g_headlessSurface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
        if (!g_headlessSurface) {
            NSLog(@"[HeadlessPresent] IOSurfaceCreate failed for %ux%u", width, height);
            return;
        }
        g_headlessSurfaceWidth = width;
        g_headlessSurfaceHeight = height;
    }

    IOSurfaceRef surface = g_headlessSurface;
    IOSurfaceLock(surface, 0, NULL);
    uint8_t *dst = (uint8_t *)IOSurfaceGetBaseAddress(surface);
    size_t dstStride = IOSurfaceGetBytesPerRow(surface);
    const uint8_t *src = (const uint8_t *)pixels;
    size_t copyBytesPerRow = MIN((size_t)bytesPerRow, dstStride);
    // MobileGL's staging buffer is tightly packed (bufferRowLength=0 in the
    // VkBufferImageCopy that produced it - see VulkanRenderer::Present),
    // while IOSurface enforces its own row alignment, so these strides can
    // legitimately differ even for the same width - row-by-row copy handles
    // both cases rather than assuming they match.
    for (uint32_t row = 0; row < height; ++row) {
        memcpy(dst + row * dstStride, src + row * bytesPerRow, copyBytesPerRow);
    }
    IOSurfaceUnlock(surface, 0, NULL);

    // Hand off to main thread for the actual on-screen update. Dispatching
    // async (not sync) is what actually decouples MobileGL's render/copy loop
    // above from anything display-cadence-related - this call returns to the
    // render thread immediately rather than waiting for the next runloop
    // tick, so the GPU work driving `pixels` can keep going without waiting
    // on Core Animation at all.
    dispatch_async(dispatch_get_main_queue(), ^{
        MobileGLHeadless_EnsureLayer(width, height);
        if (g_headlessPresentLayer) {
            g_headlessPresentLayer.contents = (__bridge id)surface;
        }
    });
}
