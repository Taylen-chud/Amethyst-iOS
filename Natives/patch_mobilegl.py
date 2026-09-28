#!/usr/bin/env python3

import sys
from pathlib import Path

TARGET_FILE = "MobileGL/MG_Backend/DirectVulkan/Renderer/VulkanRenderer.cpp"

def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <path-to-mobilegl-repo>", file=sys.stderr)
        return 1

    root = Path(sys.argv[1]).resolve()
    target = root / TARGET_FILE

    print(f"[Amethyst] Inspecting MobileGL file: {target}")

    if not target.is_file():
        print(f"Error: Couldn't find {target}", file=sys.stderr)
        return 1

    content = target.read_text(encoding="utf-8")

    marker = "void VulkanRenderer::BlitFramebuffer("

    start = content.find(marker)

    if start == -1:
        print("[Amethyst] Could not find void VulkanRenderer::BlitFramebuffer().")
        print("[Amethyst] Printing matching renderer symbols instead:")

        for line in content.splitlines():
            if "VulkanRenderer::Blit" in line:
                print(line)

        return 1

    # Find the next VulkanRenderer function after BlitFramebuffer.
    next_function = content.find("\nvoid VulkanRenderer::", start + len(marker))

    if next_function == -1:
        next_function = content.find("\nBool VulkanRenderer::", start + len(marker))

    if next_function == -1:
        next_function = content.find("\nUint32 VulkanRenderer::", start + len(marker))

    if next_function == -1:
        next_function = content.find("\nVk", start + len(marker))

    if next_function == -1:
        section = content[start:]
    else:
        section = content[start:next_function]

    print("")
    print("========== AMETHYST MOBILEGL BLIT SOURCE ==========")
    print(section)
    print("========== END AMETHYST MOBILEGL BLIT SOURCE ==========")
    print("")

    return 1


if __name__ == "__main__":
    sys.exit(main())
