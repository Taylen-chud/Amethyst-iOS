#!/usr/bin/env python3
"""Hard sed-style fixes for iOS JDK 25 build.

Runs after jdk25_ios_fixups.py and the fuzz-fallback pass. Handles cases
where the Python fixup's old text didn't match exactly due to whitespace
or version differences. All fixes are idempotent.

Usage: python3 ios_sed_fixes.py [/path/to/openjdk-25]
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else '.')


def show(path, pattern):
    for i, line in enumerate(path.read_text().splitlines(), 1):
        if re.search(pattern, line):
            print(f'  {i}: {line}')


# Fix 1: _load_reported bitfield
# mirror_w_set takes address of _load_reported which is still a :1 bitfield.
# C++ forbids taking the address of a bitfield so the build fails with
# "address of bit-field requested". Rewrite to go through mirror_w(this).
p = ROOT / 'src/hotspot/share/code/nmethod.hpp'
if p.exists():
    s = p.read_text()
    s2 = s.replace(
        'mirror_w_set(_load_reported) = true',
        'mirror_w(this)->_load_reported = true'
    )
    if s2 != s:
        p.write_text(s2)
        print('[ios_sed_fixes] fix1: patched nmethod.hpp _load_reported')
    else:
        print('[ios_sed_fixes] fix1: nmethod.hpp already patched or pattern not found')
else:
    print('[ios_sed_fixes] fix1: WARN nmethod.hpp not found')


# Fix 2: memMapPrinter_macosx.cpp includes mach_vm.h which is explicitly
# unsupported on the iOS SDK. Wrap the entire file in !TARGET_OS_IPHONE
# and provide an empty stub so the NMT linker symbol resolves.
p = ROOT / 'src/hotspot/os/bsd/memMapPrinter_macosx.cpp'
if p.exists():
    s = p.read_text()
    if 'TARGET_OS_IPHONE' not in s:
        patched = (
            '#include <TargetConditionals.h>\n'
            '#if !TARGET_OS_IPHONE\n'
            + s +
            '#endif\n'
            '#if TARGET_OS_IPHONE\n'
            '#include "nmt/memMapPrinter.hpp"\n'
            'void MemMapPrinter::pd_print_all_mappings(const MappingPrintSession&) {}\n'
            '#endif\n'
        )
        p.write_text(patched)
        print('[ios_sed_fixes] fix2: patched memMapPrinter_macosx.cpp')
    else:
        print('[ios_sed_fixes] fix2: memMapPrinter_macosx.cpp already patched')
else:
    print('[ios_sed_fixes] fix2: WARN memMapPrinter_macosx.cpp not found')


# Fix 3: flags-ldflags.m4 sets -mmacosx-version-min which conflicts with
# -miphoneos-version-min at link time. Comment it out.
p = ROOT / 'make/autoconf/flags-ldflags.m4'
if p.exists():
    s = p.read_text()
    s2 = re.sub(
        r'(\s+)(OS_LDFLAGS="-mmacosx-version-min=)',
        r'\1#OS_LDFLAGS="-mmacosx-version-min=',
        s
    )
    if s2 != s:
        p.write_text(s2)
        print('[ios_sed_fixes] fix3: patched flags-ldflags.m4')
    else:
        print('[ios_sed_fixes] fix3: flags-ldflags.m4 already patched or pattern not found')
else:
    print('[ios_sed_fixes] fix3: WARN flags-ldflags.m4 not found')


# Fix 4: CoreLibraries.gmk links ApplicationServices and Cocoa which don't
# exist on iOS SDK. Replace every pair with Foundation. Also strip any
# remaining standalone ApplicationServices or Cocoa lines.
p = ROOT / 'make/modules/java.base/lib/CoreLibraries.gmk'
if p.exists():
    s = p.read_text()
    original = s
    s = re.sub(
        r'[ \t]*-framework ApplicationServices[ \t]*\\\n[ \t]*-framework Cocoa[ \t]*\\',
        '        -framework Foundation \\\\',
        s
    )
    s = re.sub(r'[ \t]*-framework ApplicationServices[ \t]*\\\n', '', s)
    s = re.sub(r'[ \t]*-framework Cocoa[ \t]*\\\n', '', s)
    if s != original:
        p.write_text(s)
        print('[ios_sed_fixes] fix4: patched CoreLibraries.gmk')
        show(p, r'framework.*(Foundation|ApplicationServices|Cocoa)')
    else:
        print('[ios_sed_fixes] fix4: CoreLibraries.gmk already patched or pattern not found')
        show(p, r'ApplicationServices|Cocoa')
else:
    print('[ios_sed_fixes] fix4: WARN CoreLibraries.gmk not found')


# Fix 5: Lib.gmk libnet block is missing -framework CFNetwork. The symbols
# CFNetworkCopyProxiesForURL etc. live in CFNetwork, not CoreServices.
p = ROOT / 'make/modules/java.base/Lib.gmk'
if p.exists():
    s = p.read_text()
    if 'CFNetwork' not in s:
        original = s
        patterns = [
            ('        -framework CoreServices, \\\n',
             '        -framework CoreServices \\\n        -framework CFNetwork, \\\n'),
            ('    -framework CoreServices, \\\n',
             '    -framework CoreServices \\\n    -framework CFNetwork, \\\n'),
            ('-framework CoreServices, \\',
             '-framework CoreServices \\\n        -framework CFNetwork, \\'),
        ]
        for old, new in patterns:
            if old in s:
                s = s.replace(old, new)
                break
        if s != original:
            p.write_text(s)
            print('[ios_sed_fixes] fix5: patched Lib.gmk CFNetwork')
            show(p, r'CFNetwork|CoreServices')
        else:
            print('[ios_sed_fixes] fix5: WARN Lib.gmk CoreServices pattern not matched')
            print('[ios_sed_fixes] fix5: candidates:')
            for line in s.splitlines():
                if 'CoreServices' in line:
                    print(' ', repr(line))
    else:
        print('[ios_sed_fixes] fix5: Lib.gmk CFNetwork already present')
else:
    print('[ios_sed_fixes] fix5: WARN Lib.gmk not found')


# Fix 6: java.instrument/Lib.gmk - ApplicationServices + Cocoa don't exist
# on iOS. Replace with Foundation only.
p = ROOT / 'make/modules/java.instrument/Lib.gmk'
if p.exists():
    s = p.read_text()
    original = s
    s = re.sub(
        r'[ \t]*-framework ApplicationServices[ \t]*\\\n[ \t]*-framework Cocoa[ \t]*\\',
        '        -framework Foundation \\\\',
        s
    )
    s = re.sub(r'[ \t]*-framework ApplicationServices[ \t]*\\\n', '', s)
    s = re.sub(r'[ \t]*-framework Cocoa[ \t]*\\\n', '', s)
    if s != original:
        p.write_text(s)
        print('[ios_sed_fixes] fix6: patched java.instrument/Lib.gmk')
        show(p, r'framework')
    else:
        print('[ios_sed_fixes] fix6: java.instrument/Lib.gmk already patched or no match')
        show(p, r'ApplicationServices|Cocoa')
else:
    print('[ios_sed_fixes] fix6: WARN java.instrument/Lib.gmk not found')


# Fix 7: AwtLibraries.gmk - guard BUILD_LIBJAWT with macosx_NOTIOS so iOS
# skips it entirely. The sources live in src/java.desktop/macosx which gets
# moved out so the build errors with "No sources found for BUILD_LIBJAWT".
p = ROOT / 'make/modules/java.desktop/lib/AwtLibraries.gmk'
if p.exists():
    s = p.read_text()
    if 'libjawt disabled for iOS' not in s:
        original = s
        old = '$(eval $(call SetupJdkLibrary, BUILD_LIBJAWT,'
        if old in s:
            idx = s.index(old)
            targets_marker = 'TARGETS += $(BUILD_LIBJAWT)'
            targets_idx = s.index(targets_marker, idx)
            end_idx = targets_idx + len(targets_marker)
            block = s[idx:end_idx]
            new_block = (
                '# libjawt disabled for iOS - sources moved to macosx_NOTIOS\n'
                'ifeq ($(call isTargetOs, macosx_NOTIOS), true)\n'
                + block + '\n'
                'endif'
            )
            s = s[:idx] + new_block + s[end_idx:]
            p.write_text(s)
            print('[ios_sed_fixes] fix7: patched AwtLibraries.gmk BUILD_LIBJAWT guard')
        else:
            print('[ios_sed_fixes] fix7: WARN BUILD_LIBJAWT block not found')
    else:
        print('[ios_sed_fixes] fix7: AwtLibraries.gmk already patched')
else:
    print('[ios_sed_fixes] fix7: WARN AwtLibraries.gmk not found')


# Fix 8: ClientLibraries.gmk - guard BUILD_LIBOSXUI with macosx_NOTIOS.
# Sources live in src/java.desktop/macosx which gets moved out on iOS,
# causing "No sources found for BUILD_LIBOSXUI".
p = ROOT / 'make/modules/java.desktop/lib/ClientLibraries.gmk'
if p.exists():
    s = p.read_text()
    if 'libosxui disabled for iOS' not in s:
        original = s
        old = '$(eval $(call SetupJdkLibrary, BUILD_LIBOSXUI,'
        if old in s:
            idx = s.index(old)
            targets_marker = 'TARGETS += $(BUILD_LIBOSXUI)'
            targets_idx = s.index(targets_marker, idx)
            end_idx = targets_idx + len(targets_marker)
            block = s[idx:end_idx]
            new_block = (
                '# libosxui disabled for iOS - sources moved to macosx_NOTIOS\n'
                'ifeq ($(call isTargetOs, macosx_NOTIOS), true)\n'
                + block + '\n'
                'endif'
            )
            s = s[:idx] + new_block + s[end_idx:]
            p.write_text(s)
            print('[ios_sed_fixes] fix8: patched ClientLibraries.gmk BUILD_LIBOSXUI guard')
        else:
            print('[ios_sed_fixes] fix8: WARN BUILD_LIBOSXUI block not found in ClientLibraries.gmk')
    else:
        print('[ios_sed_fixes] fix8: ClientLibraries.gmk already patched')
else:
    print('[ios_sed_fixes] fix8: WARN ClientLibraries.gmk not found')


# Fix 9: AwtLibraries.gmk - guard BUILD_LIBOSXAPP with macosx_NOTIOS.
# libosxapp sources are in src/java.desktop/macosx which gets moved out.
# libawt_lwawt depends on libosxapp so both must be skipped together.
p = ROOT / 'make/modules/java.desktop/lib/AwtLibraries.gmk'
if p.exists():
    s = p.read_text()
    original = s
    # Guard libosxapp block
    if 'libosxapp disabled for iOS' not in s:
        old = 'ifeq ($(call isTargetOs, macosx), true)\n  ##############################################################################\n  # Build libosxapp'
        new = 'ifeq ($(call isTargetOs, macosx_NOTIOS), true)\n  ##############################################################################\n  # Build libosxapp'
        if old in s:
            s = s.replace(old, new)
            print('[ios_sed_fixes] fix9a: patched libosxapp guard')
        else:
            # Try alternate - just find and replace the isTargetOs macosx guard near libosxapp
            s = re.sub(
                r'(ifeq \(\$\(call isTargetOs, macosx\), true\)\s*\n\s*#{10,}\s*\n\s*# Build libosxapp)',
                lambda m: m.group(0).replace('isTargetOs, macosx)', 'isTargetOs, macosx_NOTIOS)'),
                s
            )
            if s != original:
                print('[ios_sed_fixes] fix9a: patched libosxapp guard (regex)')
            else:
                print('[ios_sed_fixes] fix9a: WARN libosxapp guard not found')

    # Guard libawt_lwawt block
    if 'libawt_lwawt disabled for iOS' not in s:
        old2 = 'ifeq ($(call isTargetOs, macosx), true)\n  ##############################################################################\n  ## Build libawt_lwawt'
        new2 = 'ifeq ($(call isTargetOs, macosx_NOTIOS), true)\n  ##############################################################################\n  ## Build libawt_lwawt'
        if old2 in s:
            s = s.replace(old2, new2)
            print('[ios_sed_fixes] fix9b: patched libawt_lwawt guard')
        else:
            s2 = re.sub(
                r'(ifeq \(\$\(call isTargetOs, macosx\), true\)\s*\n\s*#{10,}\s*\n\s*## Build libawt_lwawt)',
                lambda m: m.group(0).replace('isTargetOs, macosx)', 'isTargetOs, macosx_NOTIOS)'),
                s
            )
            if s2 != s:
                s = s2
                print('[ios_sed_fixes] fix9b: patched libawt_lwawt guard (regex)')
            else:
                print('[ios_sed_fixes] fix9b: WARN libawt_lwawt guard not found')

    if s != original:
        p.write_text(s)
else:
    print('[ios_sed_fixes] fix9: WARN AwtLibraries.gmk not found')


# Fix 10: jdk.hotspot.agent/Lib.gmk - libsaproc links JavaRuntimeSupport
# which doesn't exist on iOS. Comment out TARGETS += $(BUILD_LIBSAPROC).
p = ROOT / 'make/modules/jdk.hotspot.agent/Lib.gmk'
if p.exists():
    s = p.read_text()
    if 'BUILD_LIBSAPROC)  # disabled for iOS' not in s:
        s2 = s.replace(
            'TARGETS += $(BUILD_LIBSAPROC)',
            '#TARGETS += $(BUILD_LIBSAPROC)  # disabled for iOS'
        )
        if s2 != s:
            p.write_text(s2)
            print('[ios_sed_fixes] fix10: patched jdk.hotspot.agent/Lib.gmk libsaproc')
        else:
            print('[ios_sed_fixes] fix10: WARN BUILD_LIBSAPROC not found in Lib.gmk')
    else:
        print('[ios_sed_fixes] fix10: libsaproc already disabled')
else:
    print('[ios_sed_fixes] fix10: WARN jdk.hotspot.agent/Lib.gmk not found')


# Fix 11: jdk.jpackage/Lib.gmk - jpackageapplauncher links Cocoa which
# doesn't exist on iOS. Replace with Foundation.
p = ROOT / 'make/modules/jdk.jpackage/Lib.gmk'
if p.exists():
    s = p.read_text()
    original = s
    s = re.sub(r'-framework Cocoa(\s)', r'-framework Foundation\1', s)
    s = re.sub(r'-framework Cocoa,', r'-framework Foundation,', s)
    s = re.sub(r'-framework Cocoa\\', r'-framework Foundation\\', s)
    if s != original:
        p.write_text(s)
        print('[ios_sed_fixes] fix11: patched jdk.jpackage/Lib.gmk Cocoa -> Foundation')
        show(p, r'framework.*(Cocoa|Foundation)')
    else:
        print('[ios_sed_fixes] fix11: jdk.jpackage/Lib.gmk already patched or no Cocoa found')
        show(p, r'Cocoa|Foundation')
else:
    print('[ios_sed_fixes] fix11: WARN jdk.jpackage/Lib.gmk not found')


# Fix 12: ClientLibraries.gmk - libfontmanager depends on libawt_lwawt
# which is skipped on iOS. Switch all occurrences to libawt_headless.
# Run unconditionally since partial application leaves stale lwawt references.
p = ROOT / 'make/modules/java.desktop/lib/ClientLibraries.gmk'
if p.exists():
    s = p.read_text()
    original = s
    # Try all known spacing/trailing variants first.
    patterns = [
        ('JDK_LIBS_macosx := libawt_lwawt, \\',
         'JDK_LIBS_macosx := libawt_headless, \\'),
        ('JDK_LIBS_macosx := libawt_lwawt,',
         'JDK_LIBS_macosx := libawt_headless,'),
        ('JDK_LIBS_macosx := libawt_lwawt \\',
         'JDK_LIBS_macosx := libawt_headless \\'),
    ]
    for old, new in patterns:
        if old in s:
            s = s.replace(old, new)
    # Also catch any whitespace variation and bare references.
    s = re.sub(
        r'(JDK_LIBS_macosx\s*:=\s*)libawt_lwawt',
        r'\1libawt_headless',
        s
    )
    s = re.sub(
        r'\blibawt_lwawt\b',
        'libawt_headless',
        s
    )
    if s != original:
        p.write_text(s)
        print('[ios_sed_fixes] fix12: patched ClientLibraries.gmk libawt_lwawt -> libawt_headless')
        for line in s.splitlines():
            if 'libawt' in line:
                print(' ', repr(line))
    else:
        print('[ios_sed_fixes] fix12: no libawt_lwawt found in ClientLibraries.gmk')
        for line in s.splitlines():
            if 'libawt' in line:
                print(' ', repr(line))
else:
    print('[ios_sed_fixes] fix12: WARN ClientLibraries.gmk not found')


# Fix 13: AwtLibraries.gmk - libawt_headless is guarded with:
#   ifeq ($(call isTargetOs, windows macosx), false)
# which means it does NOT build on macOS. Since we're building with a macOS
# toolchain targeting iOS, libawt_headless never gets built, so libfontmanager
# can't depend on it. Change the guard to macosx_NOTIOS so iOS builds it.
p = ROOT / 'make/modules/java.desktop/lib/AwtLibraries.gmk'
if p.exists():
    s = p.read_text()
    original = s
    patterns = [
        ('ifeq ($(call isTargetOs, windows macosx), false)',
         'ifeq ($(call isTargetOs, windows macosx_NOTIOS), false)'),
        ('ifeq ($(call isTargetOs, windows macosx_NOTIOS), false)', None),  # already patched
    ]
    patched = False
    for old, new in patterns:
        if new is None:
            print('[ios_sed_fixes] fix13: libawt_headless guard already patched')
            patched = True
            break
        if old in s:
            s = s.replace(old, new)
            patched = True
            break
    if not patched:
        # Try regex for whitespace variations
        s2 = re.sub(
            r'ifeq \(\$\(call isTargetOs, windows macosx\), false\)',
            'ifeq ($(call isTargetOs, windows macosx_NOTIOS), false)',
            s
        )
        if s2 != s:
            s = s2
            patched = True
    if s != original:
        p.write_text(s)
        print('[ios_sed_fixes] fix13: patched AwtLibraries.gmk libawt_headless guard')
    elif not patched:
        print('[ios_sed_fixes] fix13: WARN libawt_headless guard not found')
        for line in s.splitlines():
            if 'libawt_headless' in line or ('windows' in line and 'macosx' in line):
                print(' ', repr(line))
else:
    print('[ios_sed_fixes] fix13: WARN AwtLibraries.gmk not found')
