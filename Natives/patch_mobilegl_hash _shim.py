#!/usr/bin/env python3
import sys
from pathlib import Path

TARGET_FILE = "CMakeLists.txt"
SHIM_PATH = "MobileGL/MG_Util/Compat/libcxx_hash_shim.cpp"

ANCHOR = "MobileGL/MG_Util/Debug/Log.cpp"
ENTRY = f"    {SHIM_PATH}\n"

def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <path-to-mobilegl-repo>", file=sys.stderr)
        return 1

    root = Path(sys.argv[1]).resolve()
    target = root / TARGET_FILE

    if not target.is_file():
        print(f"Error: Couldn't find {target}", file=sys.stderr)
        return 1

    shim = root / SHIM_PATH
    if not shim.is_file():
        print(f"Warning: {SHIM_PATH} doesn't exist yet. Make sure to copy it over before building.", file=sys.stderr)

    content = target.read_text()

    if SHIM_PATH in content:
        print("Shim entry already in CMakeLists.txt, skipping.")
        return 0

    if ANCHOR not in content:
        print(f"Error: Couldn't find anchor string ('{ANCHOR}') in CMakeLists.txt. Check upstream changes.", file=sys.stderr)
        return 1

    # Insert shim right after the anchor file entry
    lines = content.splitlines(keepends=True)
    new_lines = []
    applied = False

    for line in lines:
        new_lines.append(line)
        if ANCHOR in line and not applied:
            new_lines.append("\n" + ENTRY)
            applied = True

    if applied:
        target.write_text("".join(new_lines))
        print("Successfully added hash shim to CMakeLists.txt")
    else:
        print("Error: Failed to apply patch.", file=sys.stderr)
        return 1

    return 0

if __name__ == "__main__":
    sys.exit(main())