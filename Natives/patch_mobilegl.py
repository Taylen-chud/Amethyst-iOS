#!/usr/bin/env python3

from pathlib import Path
import sys

if len(sys.argv) != 2:
    print("Usage: patch_mobilegl.py <MobileGL directory>")
    sys.exit(1)

root = Path(sys.argv[1])

# MobileGL's repository layout may differ between revisions.
# Find the actual FramebufferBlitter.cpp without assuming an extra
# "MobileGL/" directory under the repository root.
matches = list(root.rglob("FramebufferBlitter.cpp"))

target = None
for candidate in matches:
    if (
        candidate.parent.name == "Pipeline"
        and candidate.parent.parent.name == "DirectVulkan"
    ):
        target = candidate
        break

if target is None:
    print(f"[Amethyst] MobileGL FramebufferBlitter.cpp not found under: {root}")
    sys.exit(1)

marker = "// AMETHYST_RESOLUTION_SCALE_FIX"

old = """        if (drawFbo.IsDefaultFramebuffer()) {
            Uint32 defaultWidth = 0;
            Uint32 defaultHeight = 0;
            drawFbo.GetDimensions(defaultWidth, defaultHeight);

            if (dstX1 == 0 && dstY1 == 0) {
                outRects.dstX1 = static_cast<Int>(defaultWidth);
                outRects.dstY1 = static_cast<Int>(defaultHeight);
            }
        }
"""

new = """        if (drawFbo.IsDefaultFramebuffer()) {
            Uint32 defaultWidth = 0;
            Uint32 defaultHeight = 0;
            drawFbo.GetDimensions(defaultWidth, defaultHeight);

            const Int sourceWidth = std::abs(srcX1 - srcX0);
            const Int sourceHeight = std::abs(srcY1 - srcY0);
            const Int destWidth = std::abs(dstX1 - dstX0);
            const Int destHeight = std::abs(dstY1 - dstY0);

            // Scale reduced render resolution to the screen.
            if (defaultWidth > 0 && defaultHeight > 0 &&
                sourceWidth > 0 && sourceHeight > 0 &&
                sourceWidth == destWidth && sourceHeight == destHeight &&
                (destWidth != static_cast<Int>(defaultWidth) ||
                 destHeight != static_cast<Int>(defaultHeight))) {

                outRects.dstX1 = dstX0 +
                    (dstX0 <= dstX1
                        ? static_cast<Int>(defaultWidth)
                        : -static_cast<Int>(defaultWidth));

                outRects.dstY1 = dstY0 +
                    (dstY0 <= dstY1
                        ? static_cast<Int>(defaultHeight)
                        : -static_cast<Int>(defaultHeight));

            } else if (dstX1 == 0 && dstY1 == 0) {
                outRects.dstX1 = static_cast<Int>(defaultWidth);
                outRects.dstY1 = static_cast<Int>(defaultHeight);
            }
        }
"""

if not target.exists():
    print(f"[Amethyst] MobileGL file not found: {target}")
    sys.exit(1)

print(f"[Amethyst] Patching MobileGL: {target}")

source = target.read_text(encoding="utf-8")

if marker in source:
    print("[Amethyst] MobileGL already patched.")
    sys.exit(0)

if old not in source:
    print("[Amethyst] Could not find MobileGL code to patch.")
    sys.exit(1)

target.write_text(
    source.replace(old, marker + "\n" + new, 1),
    encoding="utf-8"
)

print("[Amethyst] MobileGL resolution scaling patch applied.")
