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
