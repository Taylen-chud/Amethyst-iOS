#!/usr/bin/env python3

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
TARGET = (
    ROOT / "Natives" / "external" / "MobileGL" / "MobileGL"
    / "MG_Backend" / "DirectVulkan" / "Pipeline"
    / "FramebufferBlitter.cpp"
)

MARKER = "// AMETHYST_RESOLUTION_SCALE_FIX"

OLD = """        if (drawFbo.IsDefaultFramebuffer()) {
            Uint32 defaultWidth = 0;
            Uint32 defaultHeight = 0;
            drawFbo.GetDimensions(defaultWidth, defaultHeight);

            if (dstX1 == 0 && dstY1 == 0) {
                outRects.dstX1 = static_cast<Int>(defaultWidth);
                outRects.dstY1 = static_cast<Int>(defaultHeight);
            }
        }
"""

NEW = """        if (drawFbo.IsDefaultFramebuffer()) {
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


def main():
    print("[Amethyst] Patching MobileGL...")

    if not TARGET.exists():
        print(f"[Amethyst] MobileGL file not found: {TARGET}", file=sys.stderr)
        sys.exit(1)

    source = TARGET.read_text(encoding="utf-8")

    if MARKER in source:
        print("[Amethyst] MobileGL already patched.")
        return

    if OLD not in source:
        print("[Amethyst] Could not find MobileGL code to patch.", file=sys.stderr)
        sys.exit(1)

    TARGET.write_text(
        source.replace(OLD, MARKER + "\n" + NEW, 1),
        encoding="utf-8"
    )

    print("[Amethyst] MobileGL patched.")


if __name__ == "__main__":
    main()
