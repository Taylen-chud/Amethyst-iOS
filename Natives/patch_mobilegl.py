#!/usr/bin/env python3

from pathlib import Path
import sys

if len(sys.argv) != 2:
    print("Usage: patch_mobilegl.py <MobileGL directory>")
    sys.exit(1)

root = Path(sys.argv[1])

print(f"[Amethyst] Searching MobileGL source: {root}")

# Find the source file containing ResolveBlitRectangles.
target = None

for candidate in root.rglob("*.cpp"):
    try:
        source = candidate.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        continue

    if "ResolveBlitRectangles" in source:
        target = candidate
        break

if target is None:
    print("[Amethyst] Could not find ResolveBlitRectangles in MobileGL.")
    print("[Amethyst] No resolution-scaling patch was applied.")
    sys.exit(1)

print(f"[Amethyst] Found blit implementation: {target}")

marker = "// AMETHYST_RESOLUTION_SCALE_FIX"

source = target.read_text(encoding="utf-8")

if marker in source:
    print("[Amethyst] MobileGL resolution patch already applied.")
    sys.exit(0)

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

if old not in source:
    print("[Amethyst] Found ResolveBlitRectangles, but its expected code does not match.")
    print("[Amethyst] MobileGL revision uses different blit code.")
    sys.exit(1)

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

target.write_text(
    source.replace(old, marker + "\n" + new, 1),
    encoding="utf-8"
)

print("[Amethyst] MobileGL resolution-scaling patch applied.")
