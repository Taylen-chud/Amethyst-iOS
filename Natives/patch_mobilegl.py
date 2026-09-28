#!/usr/bin/env python3

from pathlib import Path
import sys

if len(sys.argv) != 2:
    print("Usage: patch_mobilegl.py <MobileGL directory>")
    sys.exit(1)

root = Path(sys.argv[1])

print(f"[Amethyst] Searching MobileGL source: {root}")

# Find the VulkanRenderer implementation used by this MobileGL revision.
target = None

for candidate in root.rglob("*.cpp"):
    try:
        source = candidate.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        continue

    if "Bool VulkanRenderer::BlitFramebuffer(" in source:
        target = candidate
        break

if target is None:
    print("[Amethyst] Could not find VulkanRenderer::BlitFramebuffer.")
    print("[Amethyst] No resolution-scaling patch was applied.")
    sys.exit(1)

print(f"[Amethyst] Found Vulkan blit implementation: {target}")

marker = "// AMETHYST_RESOLUTION_SCALE_FIX"

source = target.read_text(encoding="utf-8")

if marker in source:
    print("[Amethyst] MobileGL resolution patch already applied.")
    sys.exit(0)

old = """        const Int srcWidth = std::abs(srcX1 - srcX0);
        const Int srcHeight = std::abs(srcY1 - srcY0);
        const Int dstWidth = std::abs(dstX1 - dstX0);
        const Int dstHeight = std::abs(dstY1 - dstY0);

        const Bool sameSize = (srcWidth == dstWidth) && (srcHeight == dstHeight);
"""

if old not in source:
    print("[Amethyst] Found VulkanRenderer::BlitFramebuffer,")
    print("[Amethyst] but its expected size-calculation code does not match.")
    print("[Amethyst] MobileGL revision uses different blit code.")
    sys.exit(1)

new = """        const Int srcWidth = std::abs(srcX1 - srcX0);
        const Int srcHeight = std::abs(srcY1 - srcY0);
        Int dstWidth = std::abs(dstX1 - dstX0);
        Int dstHeight = std::abs(dstY1 - dstY0);

        if (drawFbo.IsDefaultFramebuffer() &&
            srcWidth > 0 && srcHeight > 0) {

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
"""

target.write_text(
    source.replace(old, marker + "\n" + new, 1),
    encoding="utf-8"
)

print("[Amethyst] MobileGL resolution-scaling patch applied.")
print("[Amethyst] Reduced render resolutions will be scaled to the swapchain.")
