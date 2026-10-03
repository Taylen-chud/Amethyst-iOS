#!/usr/bin/env python3

import sys
from pathlib import Path


def main():
    if len(sys.argv) != 2:
        print("Usage: patch_disaggregated.py <MobileGL source directory>")
        sys.exit(1)

    root = Path(sys.argv[1])
    target = root / "MobileGL/MG_Impl/Pipe/TextureEmit.h"

    if not target.is_file():
        print(f"[MobileGL patch] WARNING: target not found: {target}")
        return

    text = target.read_text()

    old = """reinterpret_cast<Uint64>(reinterpret_cast<std::uintptr_t>(shadow)) +"""

    new = """static_cast<Uint64>(reinterpret_cast<std::uintptr_t>(shadow)) +"""

    if new in text:
        print("[MobileGL patch] TextureEmit.h disaggregated cast already fixed")
        return

    if old not in text:
        print("[MobileGL patch] WARNING: expected disaggregated cast not found")
        return

    text = text.replace(old, new, 1)
    target.write_text(text)

    print("[MobileGL patch] Fixed uintptr_t -> Uint64 cast in TextureEmit.h")


if __name__ == "__main__":
    main()