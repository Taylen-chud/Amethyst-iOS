#!/usr/bin/env python3

import sys
from pathlib import Path

TARGET_FILE = "MobileGL/MG_Backend/DirectVulkan/Renderer/VulkanRenderer.cpp"

OLD_BLOCK = """        const Int srcWidth = std::abs(srcX1 - srcX0);
        const Int srcHeight = std::abs(srcY1 - srcY0);
        const Int dstWidth = std::abs(dstX1 - dstX0);
        const Int dstHeight = std::abs(dstY1 - dstY0);

        const Bool sameSize = (srcWidth == dstWidth) && (srcHeight == dstHeight);
        const Bool sameFormat = (srcBinding.format == dstBinding.format);

        if (sameSize && sameFormat && (srcBinding.sampleCount == VK_SAMPLE_COUNT_1_BIT) &&
            (dstBinding.sampleCount == VK_SAMPLE_COUNT_1_BIT)) {
"""

NEW_BLOCK = """        const Int srcWidth = std::abs(srcX1 - srcX0);
        const Int srcHeight = std::abs(srcY1 - srcY0);
        Int dstWidth = std::abs(dstX1 - dstX0);
        Int dstHeight = std::abs(dstY1 - dstY0);

        // AMETHYST_RESOLUTION_SCALE_FIX
        //
        // Minecraft's resolution slider changes the internal framebuffer
        // resolution while the default framebuffer remains the physical
        // display/swapchain size.
        //
        // When the render resolution is reduced, the source framebuffer can
        // be smaller than the swapchain. Make the destination rectangle use
        // the full swapchain extent so Vulkan performs a scaled blit instead
        // of copying the reduced framebuffer into a smaller region.
        if (drawFbo.IsDefaultFramebuffer()) {
            const auto swapchainExtent = m_swapchainObject.GetExtent();

            if (swapchainExtent.width > 0 &&
                swapchainExtent.height > 0 &&
                (srcWidth != static_cast<Int>(swapchainExtent.width) ||
                 srcHeight != static_cast<Int>(swapchainExtent.height))) {

                if (dstX0 <= dstX1) {
                    dstX1 = dstX0 + static_cast<Int>(swapchainExtent.width);
                } else {
                    dstX1 = dstX0 - static_cast<Int>(swapchainExtent.width);
                }

                if (dstY0 <= dstY1) {
                    dstY1 = dstY0 + static_cast<Int>(swapchainExtent.height);
                } else {
                    dstY1 = dstY0 - static_cast<Int>(swapchainExtent.height);
                }

                dstWidth = std::abs(dstX1 - dstX0);
                dstHeight = std::abs(dstY1 - dstY0);
            }
        }

        const Bool sameSize = (srcWidth == dstWidth) && (srcHeight == dstHeight);
        const Bool sameFormat = (srcBinding.format == dstBinding.format);

        if (sameSize && sameFormat && (srcBinding.sampleCount == VK_SAMPLE_COUNT_1_BIT) &&
            (dstBinding.sampleCount == VK_SAMPLE_COUNT_1_BIT)) {
"""

def main():
    if len(sys.argv) != 2:
        print(
            f"Usage: {sys.argv[0]} <path-to-mobilegl-repo>",
            file=sys.stderr
        )
        return 1

    root = Path(sys.argv[1]).resolve()
    target = root / TARGET_FILE

    print(f"[Amethyst] Patching MobileGL resolution scaling: {target}")

    if not target.is_file():
        print(
            f"Error: Couldn't find {target}",
            file=sys.stderr
        )
        return 1

    content = target.read_text(encoding="utf-8")

    if "AMETHYST_RESOLUTION_SCALE_FIX" in content:
        print("MobileGL resolution-scaling patch already applied, skipping.")
        return 0

    if OLD_BLOCK not in content:
        print(
            "Error: Expected VulkanRenderer blit block not found.",
            file=sys.stderr
        )
        print(
            "The MobileGL revision does not match the source this patch targets.",
            file=sys.stderr
        )
        return 1

    patched_content = content.replace(OLD_BLOCK, NEW_BLOCK, 1)

    target.write_text(patched_content, encoding="utf-8")

    print(
        "Successfully patched MobileGL resolution scaling in VulkanRenderer.cpp"
    )

    return 0


if __name__ == "__main__":
    sys.exit(main())
