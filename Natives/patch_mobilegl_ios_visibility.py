#!/usr/bin/env python3
import sys
from pathlib import Path

TARGET_FILE = "CMakeLists.txt"

OLD_BLOCK = """if (APPLE AND MOBILEGL_IOS)
    target_compile_definitions(${CMAKE_PROJECT_NAME} PUBLIC MOBILEGL_IOS=1 _LIBCPP_DISABLE_AVAILABILITY)"""

NEW_BLOCK = """if (APPLE AND MOBILEGL_IOS)
    target_compile_definitions(${CMAKE_PROJECT_NAME} PUBLIC MOBILEGL_IOS=1 _LIBCPP_DISABLE_AVAILABILITY)

    # Restrict exported symbols on iOS to avoid symbol collisions with libshaderc
    set(MOBILEGL_IOS_EXPORTED_SYMBOLS
        "${CMAKE_CURRENT_SOURCE_DIR}/MobileGL/MG_Impl/DyldInterpose/ExportedSymbols.txt")
    target_link_options(${CMAKE_PROJECT_NAME} PRIVATE
        "LINKER:-exported_symbols_list,${MOBILEGL_IOS_EXPORTED_SYMBOLS}")
    set_property(TARGET ${CMAKE_PROJECT_NAME} APPEND PROPERTY
        LINK_DEPENDS "${MOBILEGL_IOS_EXPORTED_SYMBOLS}")"""

def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <path-to-mobilegl-repo>", file=sys.stderr)
        return 1

    root = Path(sys.argv[1]).resolve()
    target = root / TARGET_FILE

    if not target.is_file():
        print(f"Error: Couldn't find {target}", file=sys.stderr)
        return 1

    content = target.read_text()

    if "MOBILEGL_IOS_EXPORTED_SYMBOLS" in content:
        print("iOS visibility patch already applied, skipping.")
        return 0

    if OLD_BLOCK not in content:
        print("Error: Target iOS block not found in CMakeLists.txt.", file=sys.stderr)
        return 1

    patched_content = content.replace(OLD_BLOCK, NEW_BLOCK, 1)
    target.write_text(patched_content)
    print("Successfully patched iOS symbol visibility in CMakeLists.txt")

    return 0

if __name__ == "__main__":
    sys.exit(main())