#!/usr/bin/env python3
"""Removes _LIBCPP_DISABLE_AVAILABILITY from MobileGL iOS build targets."""

import argparse
import pathlib
import re
import sys

def patch_cmakelists(root: pathlib.Path) -> int:
    target = root / "CMakeLists.txt"
    if not target.is_file():
        print(f"Error: {target} not found.", file=sys.stderr)
        return 1

    content = target.read_text()
    
    # Match target_compile_definitions for both shared and static targets
    pattern = re.compile(r'(target_compile_definitions\(\$\{CMAKE_PROJECT_NAME\}(?:_s)? PUBLIC MOBILEGL_IOS=1) _LIBCPP_DISABLE_AVAILABILITY(\))')
    
    if "_LIBCPP_DISABLE_AVAILABILITY" not in content:
        print("Patch already applied or flag not found. Skipping.")
        return 0

    content, count = pattern.subn(r'\1\2', content)
    
    if count == 0:
        print("Error: Expected patterns not found. CMakeLists.txt may have changed upstream.", file=sys.stderr)
        return 1

    target.write_text(content)
    print(f"Successfully patched {count} target(s) in {target}.")
    return 0

def main() -> int:
    parser = argparse.ArgumentParser(description="Enable libc++ availability checking in MobileGL.")
    parser.add_argument("checkout_dir", type=pathlib.Path, help="Path to MobileGL checkout root")
    args = parser.parse_args()

    return patch_cmakelists(args.checkout_dir)

if __name__ == "__main__":
    sys.exit(main())