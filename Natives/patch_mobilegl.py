#!/usr/bin/env python3

from pathlib import Path
import sys

if len(sys.argv) != 2:
    print("Usage: patch_mobilegl.py <MobileGL directory>")
    sys.exit(1)

root = Path(sys.argv[1])

print(f"[Amethyst] Searching MobileGL source: {root}")

marker = "// AMETHYST_RESOLUTION_SCALE_FIX"

target = None
source = None

# Find the source containing the Vulkan image copy/blit decision.
for candidate in root.rglob("*.cpp"):
    try:
        text = candidate.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        continue

    if (
        "vkCmdCopyImage(" in text
        and "vkCmdBlitImage(" in text
        and "sameSize" in text
    ):
        target = candidate
        source = text
        break

if target is None:
    print("[Amethyst] Could not find the MobileGL Vulkan blit/copy implementation.")
    print("[Amethyst] No resolution-scaling patch was applied.")
    sys.exit(1)

print(f"[Amethyst] Found Vulkan blit/copy implementation: {target}")

if marker in source:
    print("[Amethyst] MobileGL resolution patch already applied.")
    sys.exit(0)

old = """        const Bool sameSize = (srcWidth == dstWidth) && (srcHeight == dstHeight);
        const Bool sameFormat = (srcBinding.format == dstBinding.format);

        if (sameSize && sameFormat && (srcBinding.sampleCount == VK_SAMPLE_COUNT_1_BIT) &&
            (dstBinding.sampleCount == VK_SAMPLE_COUNT_1_BIT)) {
"""

if old not in source:
    print("[Amethyst] Found the Vulkan blit/copy implementation,")
    print("[Amethyst] but its expected copy/blit decision code does not match.")
    print("[Amethyst] MobileGL revision uses different code.")
    sys.exit(1)

new = """        // AMETHYST_RESOLUTION_SCALE_FIX
        //
        // Minecraft's resolution slider changes the size of its internal
        // framebuffer, while the default framebuffer remains the physical
        // display/swapchain size.
        //
        // If the reduced framebuffer is copied directly into the swapchain,
        // only the smaller region is updated. Force a scaled Vulkan blit
        // whenever the destination is the default framebuffer and the
        // source size differs from the swapchain extent.
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

target.write_text(
    source.replace(old, marker + "\n" + new, 1),
    encoding="utf-8"
)

print("[Amethyst] MobileGL resolution-scaling patch applied.")
print("[Amethyst] Reduced render resolutions will be scaled to the swapchain.")
