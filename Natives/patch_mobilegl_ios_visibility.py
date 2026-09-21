#!/usr/bin/env python3
"""
patch_mobilegl_ios_visibility.py

MobileGL's top-level CMakeLists.txt already documents and fixes the exact bug
behind the intermittent shaderc SIGSEGV / black-screen crash:

    # MobileGL statically embeds glslang, SPIRV-Tools, and SPIRV-Cross. When
    # this dylib is injected with DYLD_INSERT_LIBRARIES, exporting those C++
    # symbols interposes incompatible copies embedded by host libraries such
    # as shaderc. Keep only the public GL/EGL/CGL loader surface globally
    # visible; GetProcAddress can still return pointers to hidden internals.

That fix - a linker `-exported_symbols_list` restricting libMobileGL's
exported symbol table to its public loader surface - is applied only inside
`if (APPLE AND NOT MOBILEGL_IOS)`. The `if (APPLE AND MOBILEGL_IOS)` branch,
which is what actually builds for this project, never got it. So on iOS,
MobileGL's vendored SPIRV-Tools/glslang/SPIRV-Cross symbols are still
exported globally (CXX_VISIBILITY_PRESET hidden alone isn't enough here -
if it were, the macOS branch wouldn't need the exported_symbols_list step
either) and free to collide with LWJGL's separately-loaded libshaderc.dylib,
which vendors the same libraries. Apple's dyld coalesces same-named weak C++
symbols across every loaded image, so a call that starts in MobileGL's copy
of e.g. spvtools::opt::analysis::DefUseManager can get silently rerouted
mid-call into libshaderc.dylib's (differently-laid-out) copy - which is
exactly the reported SIGSEGV in DefUseManager::AnalyzeInstDef /
Instruction::GetSingleWordOperand (build-dependent, hence "random").

This patches the iOS branch to apply the same -exported_symbols_list guard,
reusing the same ExportedSymbols.txt the macOS branch already uses (the
"public GL/EGL/CGL loader surface" list - CGL entries are harmless no-ops
for a dylib that never defines them). Only the shared-library target gets
the linker flag, matching the macOS branch: exported_symbols_list is a
dynamic-library linker option and doesn't apply the same way to the static
_s target.

If MobileGL also needs specific DirectVulkan-backend entry points exported on
iOS that aren't already in that list, add them to ExportedSymbols.txt
separately - this script only wires up the mechanism, it doesn't audit the
symbol list's contents.

Idempotent: safe to re-run.

Usage:
    python3 patch_mobilegl_ios_visibility.py /path/to/MobileGL/checkout
"""
import sys
import pathlib

TARGET_REL_PATH = "CMakeLists.txt"

OLD = """if (APPLE AND MOBILEGL_IOS)
    target_compile_definitions(${CMAKE_PROJECT_NAME} PUBLIC MOBILEGL_IOS=1 _LIBCPP_DISABLE_AVAILABILITY)
    target_link_libraries(${CMAKE_PROJECT_NAME} PUBLIC
        "-framework CoreGraphics"
        "-framework Foundation"
        "-framework QuartzCore"
        objc)
    if (MOBILEGL_VULKAN_LIBRARY)
        target_link_libraries(${CMAKE_PROJECT_NAME} PUBLIC "${MOBILEGL_VULKAN_LIBRARY}")
    endif()

    if(TARGET ${CMAKE_PROJECT_NAME}_s)
        target_compile_definitions(${CMAKE_PROJECT_NAME}_s PUBLIC MOBILEGL_IOS=1 _LIBCPP_DISABLE_AVAILABILITY)
        target_link_libraries(${CMAKE_PROJECT_NAME}_s PUBLIC
            "-framework CoreGraphics"
            "-framework Foundation"
            "-framework QuartzCore"
            objc)
        if (MOBILEGL_VULKAN_LIBRARY)
            target_link_libraries(${CMAKE_PROJECT_NAME}_s PUBLIC "${MOBILEGL_VULKAN_LIBRARY}")
        endif()
    endif()
endif()"""

NEW = """if (APPLE AND MOBILEGL_IOS)
    target_compile_definitions(${CMAKE_PROJECT_NAME} PUBLIC MOBILEGL_IOS=1 _LIBCPP_DISABLE_AVAILABILITY)

    # Same reasoning as the "APPLE AND NOT MOBILEGL_IOS" branch above:
    # MobileGL statically embeds glslang, SPIRV-Tools, and SPIRV-Cross, and
    # LWJGL's bundled libshaderc.dylib embeds its own separate copy of the
    # same libraries. Without this, both copies export the same weak C++
    # symbols, dyld coalesces them by name across every loaded image, and a
    # call that starts in one copy's object graph can get silently rerouted
    # into the other's differently-laid-out implementation mid-call -
    # intermittent SIGSEGV in SPIRV-Tools' optimizer, or a corrupted shader
    # that compiles "successfully" into a black screen. Restrict this
    # dylib's exports to its public GL/EGL loader surface the same way the
    # macOS branch already does.
    set(MOBILEGL_IOS_EXPORTED_SYMBOLS
        "${CMAKE_CURRENT_SOURCE_DIR}/MobileGL/MG_Impl/DyldInterpose/ExportedSymbols.txt")
    target_link_options(${CMAKE_PROJECT_NAME} PRIVATE
        "LINKER:-exported_symbols_list,${MOBILEGL_IOS_EXPORTED_SYMBOLS}")
    set_property(TARGET ${CMAKE_PROJECT_NAME} APPEND PROPERTY
        LINK_DEPENDS "${MOBILEGL_IOS_EXPORTED_SYMBOLS}")

    target_link_libraries(${CMAKE_PROJECT_NAME} PUBLIC
        "-framework CoreGraphics"
        "-framework Foundation"
        "-framework QuartzCore"
        objc)
    if (MOBILEGL_VULKAN_LIBRARY)
        target_link_libraries(${CMAKE_PROJECT_NAME} PUBLIC "${MOBILEGL_VULKAN_LIBRARY}")
    endif()

    if(TARGET ${CMAKE_PROJECT_NAME}_s)
        target_compile_definitions(${CMAKE_PROJECT_NAME}_s PUBLIC MOBILEGL_IOS=1 _LIBCPP_DISABLE_AVAILABILITY)
        target_link_libraries(${CMAKE_PROJECT_NAME}_s PUBLIC
            "-framework CoreGraphics"
            "-framework Foundation"
            "-framework QuartzCore"
            objc)
        if (MOBILEGL_VULKAN_LIBRARY)
            target_link_libraries(${CMAKE_PROJECT_NAME}_s PUBLIC "${MOBILEGL_VULKAN_LIBRARY}")
        endif()
    endif()
endif()"""

STEPS = [
    ("iOS branch exported_symbols_list guard", OLD, NEW),
]


def apply_patch(root: pathlib.Path) -> int:
    target = root / TARGET_REL_PATH
    if not target.is_file():
        print(f"ERROR: {target} not found. Pass the path to your MobileGL checkout root.", file=sys.stderr)
        return 1

    text = target.read_text()
    changed = False

    for name, old, new in STEPS:
        if new in text:
            print(f"[patch_mobilegl_ios_visibility] '{name}' already applied, skipping.")
            continue
        if old not in text:
            print(f"ERROR: expected pattern for '{name}' not found in {target}.\n"
                  f"MobileGL's CMakeLists.txt has likely changed upstream since this script was "
                  f"written; the patch needs updating rather than blindly applied.", file=sys.stderr)
            return 1
        count = text.count(old)
        if count != 1:
            print(f"ERROR: pattern for '{name}' matched {count} times (expected exactly 1) in {target}; "
                  f"refusing to guess which to patch.", file=sys.stderr)
            return 1
        text = text.replace(old, new)
        changed = True
        print(f"[patch_mobilegl_ios_visibility] Applied '{name}'.")

    if changed:
        target.write_text(text)
        print(f"[patch_mobilegl_ios_visibility] Wrote {target}")
    else:
        print("[patch_mobilegl_ios_visibility] Nothing to do, all patches already present.")

    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} /path/to/MobileGL/checkout", file=sys.stderr)
        sys.exit(1)
    sys.exit(apply_patch(pathlib.Path(sys.argv[1])))
