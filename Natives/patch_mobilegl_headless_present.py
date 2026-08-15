#!/usr/bin/env python3
"""
patch_mobilegl_headless_present.py

EXPERIMENTAL / testing-branch only. Adds a "headless" present mode to
MobileGL's DirectVulkan backend that bypasses vkQueuePresentKHR (and the
vkAcquireNextImageKHR that follows it) entirely, replacing them with a manual
GPU->CPU->IOSurface copy handed to the app's own CALayer. This exists because
CAMetalLayer.displaySyncEnabled - the real API for disabling vsync on Metal -
is documented as unavailable on iOS; Metal always waits for v-blank there,
with no supported opt-out, and MoltenVK's swapchain is CAMetalLayer-backed.

Written against a specific point-in-time clone of
https://github.com/MobileGL-Dev/MobileGL - that repo is actively developed
upstream, so if any hunk below fails to match, the most likely explanation is
that the surrounding code has changed since this was written, not that
something is wrong with your checkout. Each hunk fails loudly with a clear
error rather than guessing, same as patch_mobilegl.py/patch_glslang.py - if
you hit that, the fix is to open the named file, find the area described in
the hunk's comment, and hand-adjust the patch to match current context.

Idempotent: safe to re-run.

Usage:
    python3 patch_mobilegl_headless_present.py /path/to/MobileGL/checkout
"""
import sys
import pathlib

SWAPCHAIN_H = "MobileGL/MG_Backend/DirectVulkan/Renderer/SwapchainObject.h"
SWAPCHAIN_CPP = "MobileGL/MG_Backend/DirectVulkan/Renderer/SwapchainObject.cpp"
FRAMECONTEXT_H = "MobileGL/MG_Backend/DirectVulkan/Renderer/FrameContext.h"
FRAMECONTEXT_CPP = "MobileGL/MG_Backend/DirectVulkan/Renderer/FrameContext.cpp"
VULKANRENDERER_CPP = "MobileGL/MG_Backend/DirectVulkan/Renderer/VulkanRenderer.cpp"
HEADLESS_HEADER = "MobileGL/MG_Backend/DirectVulkan/MobileGL_HeadlessPresent.h"

HEADLESS_HEADER_CONTENT = """// MobileGL_HeadlessPresent.h
//
// EXPERIMENTAL / testing-branch only. Declares the single interop entry point
// MobileGL's DirectVulkan backend calls, in headless-swapchain mode (see
// SwapchainObject::IsHeadless), instead of vkQueuePresentKHR. The actual
// implementation lives OUTSIDE MobileGL, in the embedding app (for Amethyst:
// Natives/ctxbridges/headless_present_bridge.m), since presenting to screen
// without going through a real Vulkan/EGL surface is inherently a
// platform-specific, UI-framework-level operation (CALayer/IOSurface on iOS),
// not something a portable Vulkan renderer should own.
//
// Called once per frame, synchronously, with a pointer to a HOST_VISIBLE
// mapped Vulkan buffer containing one tightly-packed frame of pixel data.
// The pointer is only valid for the duration of this call - the buffer is
// unmapped immediately after MobileGL_HeadlessPresent returns, so the
// implementation must finish copying out of `pixels` before returning
// (do not save the pointer, do not hand it to something async without
// copying first).
#pragma once

#include <cstdint>

#ifdef __cplusplus
extern "C" {
#endif

// format is the VkFormat of the source image (e.g. VK_FORMAT_B8G8R8A8_UNORM
// = 44, VK_FORMAT_R8G8B8A8_UNORM = 37) - the implementation needs this to
// pick a matching IOSurface/CVPixelBuffer pixel format, since MobileGL may
// pick either BGRA or RGBA ordering depending on what the device's surface
// capabilities reported at swapchain-creation time.
void MobileGL_HeadlessPresent(const void* pixels, uint32_t width, uint32_t height, uint32_t bytesPerRow,
                               int32_t format);

#ifdef __cplusplus
}
#endif
"""

# ============================================================================
# SwapchainObject.h
# ============================================================================

SWAPCHAIN_H_ACCESSORS_OLD = """        VkImage GetImage(Uint32 index) const;
        VkImageLayout GetImageLayout(Uint32 index) const;
        void SetImageLayout(Uint32 index, VkImageLayout layout);
        SizeT GetImageCount() const { return m_images.size(); }"""

SWAPCHAIN_H_ACCESSORS_NEW = """        VkImage GetImage(Uint32 index) const;
        VkImageLayout GetImageLayout(Uint32 index) const;
        void SetImageLayout(Uint32 index, VkImageLayout layout);
        SizeT GetImageCount() const { return m_images.size(); }

        // EXPERIMENTAL / testing-branch only: "headless" mode replaces the real
        // VkSwapchainKHR (which on iOS is backed by CAMetalLayer, and CAMetalLayer
        // presentation on iOS always waits for v-blank - there is no supported way
        // to disable that, unlike macOS's displaySyncEnabled) with a small ring of
        // plain, manually-allocated VkImages that MobileGL owns outright. There is
        // no real "acquire" or "present" operation on these images, so nothing here
        // is gated by the display's refresh rate - VulkanRenderer::Present() copies
        // the finished image out to a staging buffer and hands it to the app's own
        // manual CALayer/IOSurface presentation path instead of vkQueuePresentKHR.
        // Enabled by setting the MOBILEGL_NO_SWAPCHAIN environment variable before
        // Create() runs. Everything else in this class (image views, depth/stencil
        // resources, layout tracking, content-defined tracking) is unchanged and
        // works identically in both modes - only how m_images/m_swapchain get
        // populated differs.
        Bool IsHeadless() const { return m_headless; }
        VkBuffer GetHeadlessStagingBuffer(Uint32 index) const;
        VkDeviceMemory GetHeadlessStagingMemory(Uint32 index) const;
        SizeT GetHeadlessStagingBufferSize() const { return m_headlessStagingSize; }"""

SWAPCHAIN_H_PRIVATE_OLD = """    private:
        void CreateImageViews(VkDevice device);
        void CreateDepthStencilResources(VkDevice device, VkPhysicalDevice physicalDevice);
        void DestroyDepthStencilResources(VkDevice device);
        static constexpr VkPresentModeKHR s_desiredPresentModes[] {
            VK_PRESENT_MODE_MAILBOX_KHR,
            VK_PRESENT_MODE_IMMEDIATE_KHR,
            VK_PRESENT_MODE_FIFO_RELAXED_KHR,
            VK_PRESENT_MODE_FIFO_KHR
        };

        VkSwapchainKHR m_swapchain = VK_NULL_HANDLE;
        VkSurfaceFormatKHR m_surfaceFormat{};
        VkExtent2D m_extent{};
        VkExtent2D m_surfaceExtent{};
        VkSurfaceTransformFlagBitsKHR m_preTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
        Vector<VkImage> m_images;
        Vector<VkImageView> m_imageViews;
        Vector<VkImageLayout> m_imageLayouts;

        VkFormat m_depthStencilFormat = VK_FORMAT_UNDEFINED;
        Vector<VkImage> m_depthStencilImages;
        Vector<VkDeviceMemory> m_depthStencilImageMemories;
        Vector<VkImageView> m_depthStencilImageViews;
        Vector<VkImageLayout> m_depthStencilImageLayouts;
        Vector<Bool> m_imageContentDefined;
        Vector<Bool> m_depthStencilContentDefined;
    };
} // namespace MobileGL::MG_Backend::DirectVulkan"""

SWAPCHAIN_H_PRIVATE_NEW = """    private:
        void CreateImageViews(VkDevice device);
        void CreateDepthStencilResources(VkDevice device, VkPhysicalDevice physicalDevice);
        void DestroyDepthStencilResources(VkDevice device);
        void CreateHeadlessImages(VkDevice device, VkPhysicalDevice physicalDevice, VkFormat format,
                                   VkExtent2D extent, Uint32 imageCount);
        void DestroyHeadlessResources(VkDevice device);
        static constexpr VkPresentModeKHR s_desiredPresentModes[] {
            VK_PRESENT_MODE_MAILBOX_KHR,
            VK_PRESENT_MODE_IMMEDIATE_KHR,
            VK_PRESENT_MODE_FIFO_RELAXED_KHR,
            VK_PRESENT_MODE_FIFO_KHR
        };

        VkSwapchainKHR m_swapchain = VK_NULL_HANDLE;
        VkSurfaceFormatKHR m_surfaceFormat{};
        VkExtent2D m_extent{};
        VkExtent2D m_surfaceExtent{};
        VkSurfaceTransformFlagBitsKHR m_preTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
        Vector<VkImage> m_images;
        Vector<VkImageView> m_imageViews;
        Vector<VkImageLayout> m_imageLayouts;

        // EXPERIMENTAL headless-present state - see IsHeadless() above. Only
        // populated/used when m_headless is true; DestroyHeadlessResources()
        // tears these down alongside the manually-created m_images entries
        // (which Shutdown() must NOT pass to vkDestroySwapchainKHR when headless,
        // since there is no real swapchain to destroy).
        Bool m_headless = false;
        Vector<VkDeviceMemory> m_headlessImageMemories;
        Vector<VkBuffer> m_headlessStagingBuffers;
        Vector<VkDeviceMemory> m_headlessStagingMemories;
        SizeT m_headlessStagingSize = 0;

        VkFormat m_depthStencilFormat = VK_FORMAT_UNDEFINED;
        Vector<VkImage> m_depthStencilImages;
        Vector<VkDeviceMemory> m_depthStencilImageMemories;
        Vector<VkImageView> m_depthStencilImageViews;
        Vector<VkImageLayout> m_depthStencilImageLayouts;
        Vector<Bool> m_imageContentDefined;
        Vector<Bool> m_depthStencilContentDefined;
    };
} // namespace MobileGL::MG_Backend::DirectVulkan"""

# ============================================================================
# SwapchainObject.cpp
# ============================================================================

SWAPCHAIN_CPP_SHUTDOWN_OLD = """    void SwapchainObject::Shutdown(VkDevice device) {
        DestroyDepthStencilResources(device);

        for (auto imageView : m_imageViews) {
            vkDestroyImageView(device, imageView, nullptr);
        }
        m_imageViews.clear();

        if (m_swapchain != VK_NULL_HANDLE) {
            vkDestroySwapchainKHR(device, m_swapchain, nullptr);
            m_swapchain = VK_NULL_HANDLE;
        }

        m_images.clear();
        m_imageLayouts.clear();
        m_imageContentDefined.clear();
        m_depthStencilContentDefined.clear();
        m_preTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
    }"""

SWAPCHAIN_CPP_SHUTDOWN_NEW = """    void SwapchainObject::Shutdown(VkDevice device) {
        DestroyDepthStencilResources(device);
        DestroyHeadlessResources(device);

        for (auto imageView : m_imageViews) {
            vkDestroyImageView(device, imageView, nullptr);
        }
        m_imageViews.clear();

        if (m_swapchain != VK_NULL_HANDLE) {
            vkDestroySwapchainKHR(device, m_swapchain, nullptr);
            m_swapchain = VK_NULL_HANDLE;
        }

        m_images.clear();
        m_imageLayouts.clear();
        m_imageContentDefined.clear();
        m_depthStencilContentDefined.clear();
        m_preTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
    }"""

SWAPCHAIN_CPP_CREATE_OLD = """        m_surfaceFormat = {createInfo.imageFormat, createInfo.imageColorSpace};
        m_extent = createInfo.imageExtent;
        // The surface-space extent this swapchain was built from, i.e. before the
        // quarter-turn swap above. Out-of-date checks must compare in THIS space: comparing a
        // freshly queried currentExtent against the swapped m_extent flips axes every rotation
        // and makes the comparison alternate forever.
        m_surfaceExtent = defaultFramebufferExtent;
        m_preTransform = createInfo.preTransform;

        VK_VERIFY(vkCreateSwapchainKHR(device, &createInfo, nullptr, &m_swapchain));

        Uint32 imageCount = 0;
        VK_VERIFY(vkGetSwapchainImagesKHR(device, m_swapchain, &imageCount, nullptr));

        m_images.resize(imageCount, VK_NULL_HANDLE);
        VK_VERIFY(vkGetSwapchainImagesKHR(device, m_swapchain, &imageCount, m_images.data()));
        m_imageLayouts.assign(imageCount, VK_IMAGE_LAYOUT_UNDEFINED);
        // Fresh swapchain images hold garbage until a render pass stores into them.
        m_imageContentDefined.assign(imageCount, false);
        m_depthStencilContentDefined.assign(imageCount, false);"""

SWAPCHAIN_CPP_CREATE_NEW = """        m_surfaceFormat = {createInfo.imageFormat, createInfo.imageColorSpace};
        m_extent = createInfo.imageExtent;
        // The surface-space extent this swapchain was built from, i.e. before the
        // quarter-turn swap above. Out-of-date checks must compare in THIS space: comparing a
        // freshly queried currentExtent against the swapped m_extent flips axes every rotation
        // and makes the comparison alternate forever.
        m_surfaceExtent = defaultFramebufferExtent;
        m_preTransform = createInfo.preTransform;

        // EXPERIMENTAL: MOBILEGL_NO_SWAPCHAIN skips vkCreateSwapchainKHR/
        // vkGetSwapchainImagesKHR entirely and manually creates m_images ourselves
        // instead - see IsHeadless() in the header for why. Everything below this
        // (CreateImageViews, CreateDepthStencilResources, default FBO setup) is
        // unchanged and works identically either way, since it only reads m_images/
        // m_extent/m_depthStencilFormat, never m_swapchain directly.
        m_headless = getenv("MOBILEGL_NO_SWAPCHAIN") != nullptr;
        if (m_headless) {
            MGLOG_I("MOBILEGL_NO_SWAPCHAIN set - creating %d headless images instead of a real VkSwapchainKHR",
                    targetImageCount);
            CreateHeadlessImages(device, physicalDevice, createInfo.imageFormat, createInfo.imageExtent,
                                  targetImageCount);
        } else {
            VK_VERIFY(vkCreateSwapchainKHR(device, &createInfo, nullptr, &m_swapchain));

            Uint32 imageCount = 0;
            VK_VERIFY(vkGetSwapchainImagesKHR(device, m_swapchain, &imageCount, nullptr));

            m_images.resize(imageCount, VK_NULL_HANDLE);
            VK_VERIFY(vkGetSwapchainImagesKHR(device, m_swapchain, &imageCount, m_images.data()));
        }
        m_imageLayouts.assign(m_images.size(), VK_IMAGE_LAYOUT_UNDEFINED);
        // Fresh swapchain images hold garbage until a render pass stores into them.
        m_imageContentDefined.assign(m_images.size(), false);
        m_depthStencilContentDefined.assign(m_images.size(), false);"""

SWAPCHAIN_CPP_INSERT_ANCHOR_OLD = """        m_depthStencilImageMemories.clear();
        m_depthStencilImageLayouts.clear();
        m_depthStencilFormat = VK_FORMAT_UNDEFINED;
    }

"""

SWAPCHAIN_CPP_INSERT_ANCHOR_NEW = """        m_depthStencilImageMemories.clear();
        m_depthStencilImageLayouts.clear();
        m_depthStencilFormat = VK_FORMAT_UNDEFINED;
    }

    // EXPERIMENTAL: see IsHeadless() in the header. Manually creates imageCount
    // plain VkImages (mirroring CreateDepthStencilResources's pattern above,
    // since that's already a manual-image-array creation with no swapchain
    // involved) plus a per-image HOST_VISIBLE|HOST_COHERENT staging buffer sized
    // to hold a tightly-packed copy of one image, used later by
    // VulkanRenderer::Present() to read the finished frame back to the CPU for
    // manual presentation instead of vkQueuePresentKHR.
    void SwapchainObject::CreateHeadlessImages(VkDevice device, VkPhysicalDevice physicalDevice, VkFormat format,
                                                VkExtent2D extent, Uint32 imageCount) {
        m_images.assign(imageCount, VK_NULL_HANDLE);
        m_headlessImageMemories.assign(imageCount, VK_NULL_HANDLE);
        m_headlessStagingBuffers.assign(imageCount, VK_NULL_HANDLE);
        m_headlessStagingMemories.assign(imageCount, VK_NULL_HANDLE);

        // Assumes a 4-bytes-per-pixel format (true for every format
        // ChooseSwapchainSurfaceFormat picks - B8G8R8A8/R8G8B8A8 UNORM/SRGB).
        // If that ever changes this needs to compute the real per-format size
        // instead of hardcoding 4.
        m_headlessStagingSize = static_cast<SizeT>(extent.width) * static_cast<SizeT>(extent.height) * 4;

        for (Uint32 i = 0; i < imageCount; ++i) {
            VkImageCreateInfo imageInfo{};
            imageInfo.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
            imageInfo.imageType = VK_IMAGE_TYPE_2D;
            imageInfo.extent.width = extent.width;
            imageInfo.extent.height = extent.height;
            imageInfo.extent.depth = 1;
            imageInfo.mipLevels = 1;
            imageInfo.arrayLayers = 1;
            imageInfo.format = format;
            imageInfo.tiling = VK_IMAGE_TILING_OPTIMAL;
            imageInfo.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
            // COLOR_ATTACHMENT so the existing render-pass/framebuffer code path
            // (which expects to render INTO these like real swapchain images)
            // keeps working unmodified; TRANSFER_SRC so Present() can read the
            // finished frame back out via vkCmdCopyImageToBuffer.
            imageInfo.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
            imageInfo.samples = VK_SAMPLE_COUNT_1_BIT;
            imageInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
            VK_VERIFY(vkCreateImage(device, &imageInfo, nullptr, &m_images[i]), "vkCreateImage(headless)");

            VkMemoryRequirements memRequirements{};
            vkGetImageMemoryRequirements(device, m_images[i], &memRequirements);

            VkMemoryAllocateInfo allocInfo{};
            allocInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
            allocInfo.allocationSize = memRequirements.size;
            allocInfo.memoryTypeIndex =
                FindMemoryType(physicalDevice, memRequirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
            VK_VERIFY(vkAllocateMemory(device, &allocInfo, nullptr, &m_headlessImageMemories[i]),
                      "vkAllocateMemory(headless image)");
            VK_VERIFY(vkBindImageMemory(device, m_images[i], m_headlessImageMemories[i], 0),
                      "vkBindImageMemory(headless image)");

            VkBufferCreateInfo bufferInfo{};
            bufferInfo.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
            bufferInfo.size = m_headlessStagingSize;
            bufferInfo.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
            bufferInfo.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
            VK_VERIFY(vkCreateBuffer(device, &bufferInfo, nullptr, &m_headlessStagingBuffers[i]),
                      "vkCreateBuffer(headless staging)");

            VkMemoryRequirements bufRequirements{};
            vkGetBufferMemoryRequirements(device, m_headlessStagingBuffers[i], &bufRequirements);

            VkMemoryAllocateInfo bufAllocInfo{};
            bufAllocInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
            bufAllocInfo.allocationSize = bufRequirements.size;
            bufAllocInfo.memoryTypeIndex = FindMemoryType(
                physicalDevice, bufRequirements.memoryTypeBits,
                VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
            VK_VERIFY(vkAllocateMemory(device, &bufAllocInfo, nullptr, &m_headlessStagingMemories[i]),
                      "vkAllocateMemory(headless staging)");
            VK_VERIFY(vkBindBufferMemory(device, m_headlessStagingBuffers[i], m_headlessStagingMemories[i], 0),
                      "vkBindBufferMemory(headless staging)");
        }
    }

    void SwapchainObject::DestroyHeadlessResources(VkDevice device) {
        for (auto buffer : m_headlessStagingBuffers) {
            if (buffer != VK_NULL_HANDLE) {
                vkDestroyBuffer(device, buffer, nullptr);
            }
        }
        m_headlessStagingBuffers.clear();

        for (auto memory : m_headlessStagingMemories) {
            if (memory != VK_NULL_HANDLE) {
                vkFreeMemory(device, memory, nullptr);
            }
        }
        m_headlessStagingMemories.clear();
        m_headlessStagingSize = 0;

        // NOTE: m_images itself is destroyed generically below in Shutdown() for
        // the real-swapchain case, but headless-created images are NOT owned by
        // any VkSwapchainKHR, so we must destroy them ourselves here rather than
        // relying on vkDestroySwapchainKHR (which never ran for these).
        if (m_headless) {
            for (auto image : m_images) {
                if (image != VK_NULL_HANDLE) {
                    vkDestroyImage(device, image, nullptr);
                }
            }
        }
        for (auto memory : m_headlessImageMemories) {
            if (memory != VK_NULL_HANDLE) {
                vkFreeMemory(device, memory, nullptr);
            }
        }
        m_headlessImageMemories.clear();
        m_headless = false;
    }

    VkBuffer SwapchainObject::GetHeadlessStagingBuffer(Uint32 index) const {
        MOBILEGL_ASSERT(index < m_headlessStagingBuffers.size(), "Headless staging buffer index out of range.");
        return m_headlessStagingBuffers[index];
    }

    VkDeviceMemory SwapchainObject::GetHeadlessStagingMemory(Uint32 index) const {
        MOBILEGL_ASSERT(index < m_headlessStagingMemories.size(), "Headless staging memory index out of range.");
        return m_headlessStagingMemories[index];
    }

"""

# ============================================================================
# FrameContext.h
# ============================================================================

FRAMECONTEXT_H_OLD = """        VkResult WaitAndAcquireNextImage(VkDevice device, VkSwapchainKHR swapchain, Uint32& outImageIndex,
                                         Uint64 timeout = UINT64_MAX, VkFence acquireFence = VK_NULL_HANDLE);"""

FRAMECONTEXT_H_NEW = """        VkResult WaitAndAcquireNextImage(VkDevice device, VkSwapchainKHR swapchain, Uint32& outImageIndex,
                                         Bool headless = false, Uint32 headlessImageCount = 0,
                                         Uint64 timeout = UINT64_MAX, VkFence acquireFence = VK_NULL_HANDLE);"""

# ============================================================================
# FrameContext.cpp
# ============================================================================

FRAMECONTEXT_CPP_OLD = """    VkResult FrameContext::WaitAndAcquireNextImage(VkDevice device, VkSwapchainKHR swapchain, Uint32& outImageIndex,
                                                   Uint64 timeout, VkFence acquireFence) {
        auto& frame = GetCurrent();
        VkResult result = vkWaitForFences(device, 1, &frame.imageInFlightFence, VK_TRUE, timeout);
        if (result != VK_SUCCESS) {
            return result;
        }
        // The slot's fence has been waited: every command buffer this slot
        // submitted (including mid-frame flushes) has finished executing.
        FreeRetiredCommandBuffers(frame);

        result = vkAcquireNextImageKHR(device, swapchain, timeout, frame.imageAvailableSemaphore, acquireFence,
                                       &outImageIndex);
        // VK_SUBOPTIMAL_KHR is a success code: an image *was* acquired and
        // imageAvailableSemaphore *will* be signaled. Bailing out on it skipped both
        // the consumed-flag reset (leaving a stale "already consumed", so the next
        // submit never waited on the pending signal) and the fence reset (leaving
        // the slot's fence signaled for the next submit to reuse). Only a genuine
        // failure - VK_ERROR_OUT_OF_DATE_KHR and friends, where nothing is acquired
        // and nothing is signaled - skips the bookkeeping.
        if (result != VK_SUCCESS && result != VK_SUBOPTIMAL_KHR) {
            return result;
        }

        frame.imageAvailableSemaphoreConsumed = false;
        const VkResult resetResult = vkResetFences(device, 1, &frame.imageInFlightFence);
        // Hand the acquire's own code back so the caller can schedule a rebuild.
        return resetResult == VK_SUCCESS ? result : resetResult;
    }"""

FRAMECONTEXT_CPP_NEW = """    VkResult FrameContext::WaitAndAcquireNextImage(VkDevice device, VkSwapchainKHR swapchain, Uint32& outImageIndex,
                                                   Bool headless, Uint32 headlessImageCount,
                                                   Uint64 timeout, VkFence acquireFence) {
        auto& frame = GetCurrent();
        VkResult result = vkWaitForFences(device, 1, &frame.imageInFlightFence, VK_TRUE, timeout);
        if (result != VK_SUCCESS) {
            return result;
        }
        // The slot's fence has been waited: every command buffer this slot
        // submitted (including mid-frame flushes) has finished executing.
        FreeRetiredCommandBuffers(frame);

        // EXPERIMENTAL headless mode (see SwapchainObject::IsHeadless): there is no
        // real VkSwapchainKHR to acquire from, and no display-linked "image
        // available" event to wait for - MobileGL owns all headlessImageCount
        // images all the time. Just round-robin to the next slot and mark the
        // (nonexistent) acquire semaphore as already consumed so GetSubmitInfo()
        // doesn't wait on a semaphore nothing will ever signal.
        if (headless) {
            MOBILEGL_ASSERT(headlessImageCount > 0, "WaitAndAcquireNextImage: headless requires headlessImageCount > 0");
            outImageIndex = (outImageIndex + 1) % headlessImageCount;
            frame.imageAvailableSemaphoreConsumed = true;
            const VkResult resetResult = vkResetFences(device, 1, &frame.imageInFlightFence);
            return resetResult;
        }

        result = vkAcquireNextImageKHR(device, swapchain, timeout, frame.imageAvailableSemaphore, acquireFence,
                                       &outImageIndex);
        // VK_SUBOPTIMAL_KHR is a success code: an image *was* acquired and
        // imageAvailableSemaphore *will* be signaled. Bailing out on it skipped both
        // the consumed-flag reset (leaving a stale "already consumed", so the next
        // submit never waited on the pending signal) and the fence reset (leaving
        // the slot's fence signaled for the next submit to reuse). Only a genuine
        // failure - VK_ERROR_OUT_OF_DATE_KHR and friends, where nothing is acquired
        // and nothing is signaled - skips the bookkeeping.
        if (result != VK_SUCCESS && result != VK_SUBOPTIMAL_KHR) {
            return result;
        }

        frame.imageAvailableSemaphoreConsumed = false;
        const VkResult resetResult = vkResetFences(device, 1, &frame.imageInFlightFence);
        // Hand the acquire's own code back so the caller can schedule a rebuild.
        return resetResult == VK_SUCCESS ? result : resetResult;
    }"""

# ============================================================================
# VulkanRenderer.cpp
# ============================================================================

VULKANRENDERER_INCLUDE_OLD = '#include "VulkanRenderer.h"'
VULKANRENDERER_INCLUDE_NEW = ('#include "VulkanRenderer.h"\n\n'
    '#include "../MobileGL_HeadlessPresent.h" '
    '// EXPERIMENTAL headless-present interop, see header for details')

VULKANRENDERER_CALLSITE_OLD = (
    "WaitAndAcquireNextImage(m_device, m_swapchainObject.GetHandle(), m_imageIndexAcquired);"
)
VULKANRENDERER_CALLSITE_NEW = (
    "WaitAndAcquireNextImage(m_device, m_swapchainObject.GetHandle(), m_imageIndexAcquired,\n"
    "                    m_swapchainObject.IsHeadless(), static_cast<Uint32>(m_swapchainObject.GetImageCount()));"
)
VULKANRENDERER_CALLSITE_EXPECTED_COUNT = 5

VULKANRENDERER_PRESENT_OLD = """        const auto acquiredImageLayout = m_swapchainObject.GetImageLayout(m_imageIndexAcquired);
        m_frameContext.TransitionToPresent(m_swapchainObject.GetImage(m_imageIndexAcquired), acquiredImageLayout);

        if (frame.isCommandRecording) {
            m_frameContext.EndCommandRecording();
            frame.hasCommandBufferRecorded = true;
            InvalidatePipelineMemo(); // command-buffer boundary: drop the pipeline memo
        }
        m_frameContext.EndPreCommandRecordingIfOpen();

        const Bool shouldSubmitCommandBuffer = frame.hasCommandBufferRecorded;

        // 1) Submit current frame work (the pre-pass stream, when recorded,
        //    rides the same submission strictly ahead of the frame commands).
        //    Batched texture uploads go first: the frame's commands may sample
        //    images whose texels only exist in the open upload batch, and
        //    flushing here also bounds upload latency to one frame.
        if (m_textureManager) {
            m_textureManager->FlushPendingUploads();
        }
        auto submitPacket = m_frameContext.GetSubmitInfo(shouldSubmitCommandBuffer, m_imageIndexAcquired);
        VK_VERIFY(vkQueueSubmit(m_graphicsQueue, 1, &submitPacket.submitInfo, frame.imageInFlightFence));
        RegisterSubmit(frame.imageInFlightFence, /*pooledFence=*/false);
        frame.lastSubmitIndex = m_submitCounter;
        frame.isCommandRecording = false;
        frame.hasCommandBufferRecorded = false;
        frame.hasPreCommandBufferRecorded = false;
        m_swapchainObject.SetImageLayout(m_imageIndexAcquired, VK_IMAGE_LAYOUT_PRESENT_SRC_KHR);

        // 2) Present current frame.
        auto presentPacket = m_frameContext.GetPresentInfo(m_swapchainObject.GetHandle(), m_imageIndexAcquired);
        auto result = vkQueuePresentKHR(m_presentQueue, &presentPacket.presentInfo);
        if (result == VK_SUBOPTIMAL_KHR) {
            // Suboptimal is not a reason to rebuild on its own: a driver may report it for a
            // surface whose size and orientation still match what we built from (Android does
            // this routinely), and rebuilding on it alone destroys every pipeline and
            // reallocates the default framebuffer once per frame - flicker, then garbage.
            // Defer to the surface-capabilities comparison below.
            result = VK_SUCCESS;
        }
        if (result == VK_ERROR_OUT_OF_DATE_KHR) {
            MGLOG_D("Present, vkQueuePresentKHR got %d, recreating swapchain", result);
            if (!RecreateSwapchain()) {
                // Window went zero-area (minimize) with the swapchain out of date:
                // stop submitting/acquiring until it has a size again.
                m_presentSuspended = true;
                m_swapchainResizeRequested = false;
                MGLOG_D("Present, zero-area window with out-of-date swapchain; suspending presentation");
                return;
            }
            m_swapchainResizeRequested = false;
            result = VK_SUCCESS;
        }
        VK_VERIFY(result, "Present, vkQueuePresentKHR");"""

VULKANRENDERER_PRESENT_NEW = """        const auto acquiredImageLayout = m_swapchainObject.GetImageLayout(m_imageIndexAcquired);
        const Bool headlessPresent = m_swapchainObject.IsHeadless();
        // EXPERIMENTAL: headless mode transitions to TRANSFER_SRC (for the
        // manual copy-out below) instead of PRESENT_SRC_KHR (which only means
        // something to a real swapchain image). TransitionToPresent is reused
        // unchanged - it just takes whatever target layout it's given.
        m_frameContext.TransitionToPresent(m_swapchainObject.GetImage(m_imageIndexAcquired), acquiredImageLayout,
            headlessPresent ? VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL : VK_IMAGE_LAYOUT_PRESENT_SRC_KHR);

        if (headlessPresent && frame.isCommandRecording) {
            // Record the readback copy into the SAME command buffer, still before
            // EndCommandRecording() below, so it rides the same vkQueueSubmit as
            // the rest of this frame's work instead of needing a second submit.
            VkBufferImageCopy region{};
            region.bufferOffset = 0;
            region.bufferRowLength = 0;   // tightly packed
            region.bufferImageHeight = 0; // tightly packed
            region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
            region.imageSubresource.mipLevel = 0;
            region.imageSubresource.baseArrayLayer = 0;
            region.imageSubresource.layerCount = 1;
            region.imageOffset = {0, 0, 0};
            region.imageExtent = {m_swapchainObject.GetExtent().width, m_swapchainObject.GetExtent().height, 1};
            vkCmdCopyImageToBuffer(frame.commandBuffer, m_swapchainObject.GetImage(m_imageIndexAcquired),
                                    VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                                    m_swapchainObject.GetHeadlessStagingBuffer(m_imageIndexAcquired), 1, &region);
        }

        if (frame.isCommandRecording) {
            m_frameContext.EndCommandRecording();
            frame.hasCommandBufferRecorded = true;
            InvalidatePipelineMemo(); // command-buffer boundary: drop the pipeline memo
        }
        m_frameContext.EndPreCommandRecordingIfOpen();

        const Bool shouldSubmitCommandBuffer = frame.hasCommandBufferRecorded;

        // 1) Submit current frame work (the pre-pass stream, when recorded,
        //    rides the same submission strictly ahead of the frame commands).
        //    Batched texture uploads go first: the frame's commands may sample
        //    images whose texels only exist in the open upload batch, and
        //    flushing here also bounds upload latency to one frame.
        if (m_textureManager) {
            m_textureManager->FlushPendingUploads();
        }
        auto submitPacket = m_frameContext.GetSubmitInfo(shouldSubmitCommandBuffer, m_imageIndexAcquired);
        VK_VERIFY(vkQueueSubmit(m_graphicsQueue, 1, &submitPacket.submitInfo, frame.imageInFlightFence));
        RegisterSubmit(frame.imageInFlightFence, /*pooledFence=*/false);
        frame.lastSubmitIndex = m_submitCounter;
        frame.isCommandRecording = false;
        frame.hasCommandBufferRecorded = false;
        frame.hasPreCommandBufferRecorded = false;
        m_swapchainObject.SetImageLayout(m_imageIndexAcquired,
            headlessPresent ? VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL : VK_IMAGE_LAYOUT_PRESENT_SRC_KHR);

        if (headlessPresent) {
            // 2) EXPERIMENTAL headless present: no vkQueuePresentKHR at all - that
            // call (and the vkAcquireNextImageKHR that follows it) is exactly what's
            // vsync-gated on iOS via CAMetalLayer, and there is no supported way to
            // disable that (unlike macOS's displaySyncEnabled). Instead: block until
            // THIS frame's GPU work (including the copy-to-buffer above) is done,
            // then hand the raw pixels to the app's own manual presentation path.
            // This is a synchronous wait - simple and correct, but not pipelined,
            // so it does not hide GPU latency the way the real swapchain path does.
            // Good enough for a testing branch; a production version would want to
            // present the PREVIOUS frame's copy while this one is still in flight.
            VK_VERIFY(vkWaitForFences(m_device, 1, &frame.imageInFlightFence, VK_TRUE, UINT64_MAX),
                      "Present, headless vkWaitForFences");
            void* mapped = nullptr;
            VkDeviceMemory stagingMemory = m_swapchainObject.GetHeadlessStagingMemory(m_imageIndexAcquired);
            VK_VERIFY(vkMapMemory(m_device, stagingMemory, 0, m_swapchainObject.GetHeadlessStagingBufferSize(), 0,
                                   &mapped),
                      "Present, headless vkMapMemory");
            MobileGL_HeadlessPresent(mapped, m_swapchainObject.GetExtent().width,
                                      m_swapchainObject.GetExtent().height,
                                      m_swapchainObject.GetExtent().width * 4,
                                      m_swapchainObject.GetSurfaceFormat().format);
            vkUnmapMemory(m_device, stagingMemory);
        } else {
        // 2) Present current frame.
        auto presentPacket = m_frameContext.GetPresentInfo(m_swapchainObject.GetHandle(), m_imageIndexAcquired);
        auto result = vkQueuePresentKHR(m_presentQueue, &presentPacket.presentInfo);
        if (result == VK_SUBOPTIMAL_KHR) {
            // Suboptimal is not a reason to rebuild on its own: a driver may report it for a
            // surface whose size and orientation still match what we built from (Android does
            // this routinely), and rebuilding on it alone destroys every pipeline and
            // reallocates the default framebuffer once per frame - flicker, then garbage.
            // Defer to the surface-capabilities comparison below.
            result = VK_SUCCESS;
        }
        if (result == VK_ERROR_OUT_OF_DATE_KHR) {
            MGLOG_D("Present, vkQueuePresentKHR got %d, recreating swapchain", result);
            if (!RecreateSwapchain()) {
                // Window went zero-area (minimize) with the swapchain out of date:
                // stop submitting/acquiring until it has a size again.
                m_presentSuspended = true;
                m_swapchainResizeRequested = false;
                MGLOG_D("Present, zero-area window with out-of-date swapchain; suspending presentation");
                return;
            }
            m_swapchainResizeRequested = false;
            result = VK_SUCCESS;
        }
        VK_VERIFY(result, "Present, vkQueuePresentKHR");
        }"""

# Each entry: (description, relative_file_path, old, new, expected_count)
STEPS = [
    ("SwapchainObject.h: headless accessors", SWAPCHAIN_H, SWAPCHAIN_H_ACCESSORS_OLD, SWAPCHAIN_H_ACCESSORS_NEW, 1),
    ("SwapchainObject.h: private members/methods", SWAPCHAIN_H, SWAPCHAIN_H_PRIVATE_OLD, SWAPCHAIN_H_PRIVATE_NEW, 1),
    ("SwapchainObject.cpp: Shutdown()", SWAPCHAIN_CPP, SWAPCHAIN_CPP_SHUTDOWN_OLD, SWAPCHAIN_CPP_SHUTDOWN_NEW, 1),
    ("SwapchainObject.cpp: Create() headless branch", SWAPCHAIN_CPP, SWAPCHAIN_CPP_CREATE_OLD, SWAPCHAIN_CPP_CREATE_NEW, 1),
    ("SwapchainObject.cpp: insert headless methods", SWAPCHAIN_CPP, SWAPCHAIN_CPP_INSERT_ANCHOR_OLD, SWAPCHAIN_CPP_INSERT_ANCHOR_NEW, 1),
    ("FrameContext.h: WaitAndAcquireNextImage signature", FRAMECONTEXT_H, FRAMECONTEXT_H_OLD, FRAMECONTEXT_H_NEW, 1),
    ("FrameContext.cpp: WaitAndAcquireNextImage body", FRAMECONTEXT_CPP, FRAMECONTEXT_CPP_OLD, FRAMECONTEXT_CPP_NEW, 1),
    ("VulkanRenderer.cpp: include headless header", VULKANRENDERER_CPP, VULKANRENDERER_INCLUDE_OLD, VULKANRENDERER_INCLUDE_NEW, 1),
    ("VulkanRenderer.cpp: WaitAndAcquireNextImage call sites", VULKANRENDERER_CPP, VULKANRENDERER_CALLSITE_OLD, VULKANRENDERER_CALLSITE_NEW, VULKANRENDERER_CALLSITE_EXPECTED_COUNT),
    ("VulkanRenderer.cpp: Present() headless branch", VULKANRENDERER_CPP, VULKANRENDERER_PRESENT_OLD, VULKANRENDERER_PRESENT_NEW, 1),
]


def apply_patch(root: pathlib.Path) -> int:
    header_path = root / HEADLESS_HEADER
    if header_path.is_file() and header_path.read_text() == HEADLESS_HEADER_CONTENT:
        print(f"[patch_mobilegl_headless_present] {HEADLESS_HEADER} already present, skipping.")
    else:
        header_path.parent.mkdir(parents=True, exist_ok=True)
        header_path.write_text(HEADLESS_HEADER_CONTENT)
        print(f"[patch_mobilegl_headless_present] Wrote {HEADLESS_HEADER}")

    files_touched = {}
    for name, rel_path, old, new, expected_count in STEPS:
        full_path = root / rel_path
        if not full_path.is_file():
            print(f"ERROR: {full_path} not found.", file=sys.stderr)
            return 1

        text = files_touched.get(rel_path)
        if text is None:
            text = full_path.read_text()

        if new in text:
            print(f"[patch_mobilegl_headless_present] '{name}' already applied, skipping.")
            files_touched[rel_path] = text
            continue

        count = text.count(old)
        if count != expected_count:
            print(f"ERROR: pattern for '{name}' matched {count} times (expected {expected_count}) in {full_path}.\n"
                  f"MobileGL's source has likely changed upstream since this script was written; "
                  f"open the file, find the area described in the hunk's comment, and adjust by hand.",
                  file=sys.stderr)
            return 1

        text = text.replace(old, new)
        files_touched[rel_path] = text
        print(f"[patch_mobilegl_headless_present] Applied '{name}'.")

    for rel_path, text in files_touched.items():
        (root / rel_path).write_text(text)
        print(f"[patch_mobilegl_headless_present] Wrote {rel_path}")

    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} /path/to/MobileGL/checkout", file=sys.stderr)
        sys.exit(1)
    sys.exit(apply_patch(pathlib.Path(sys.argv[1])))
