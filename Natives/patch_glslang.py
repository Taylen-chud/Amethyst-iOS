#!/usr/bin/env python3
"""
patch_glslang.py

TGlslangToSpvTraverser::convertSwizzle() (SPIRV/GlslangToSpv.cpp) converts a
glslang AST swizzle node (e.g. ".xyz") into a list of component indices for
SPIR-V. It does this via an unchecked downcast-and-dereference:

    swizzle.push_back(swizzleSequence[i]->getAsConstantUnion()->getConstArray()[0].getIConst());

getAsConstantUnion() returns nullptr for any AST node that isn't a
TIntermConstantUnion (that's the base-class default in intermediate.h; only
TIntermConstantUnion overrides it to return `this`). Ordinary swizzles always
have constant-union index nodes, so this works in the common case - but for
some shaders (e.g. certain chained-swizzle or optimizer-folded patterns) a
sequence element isn't a constant union, getAsConstantUnion() returns null,
and ->getConstArray() dereferences it immediately: SIGSEGV, taking the whole
JVM down with it (observed as `libMobileGL.dylib ... convertSwizzle+0x1c`).

This patches convertSwizzle to null-check each element. On a null (the
"can't happen in valid shaders, but here we are" case), it falls back to
component index 0 and logs once via fprintf(stderr) instead of crashing the
process - a wrong swizzle component in a single shader is a far better
failure mode than taking down the whole game.

Idempotent: safe to re-run.

Usage:
    python3 patch_glslang.py /path/to/glslang/checkout
"""
import sys
import pathlib

TARGET_REL_PATH = "SPIRV/GlslangToSpv.cpp"

OLD = """// Convert a glslang AST swizzle node to a swizzle vector for building SPIR-V.
void TGlslangToSpvTraverser::convertSwizzle(const glslang::TIntermAggregate& node, std::vector<unsigned>& swizzle)
{
    const glslang::TIntermSequence& swizzleSequence = node.getSequence();
    for (int i = 0; i < (int)swizzleSequence.size(); ++i)
        swizzle.push_back(swizzleSequence[i]->getAsConstantUnion()->getConstArray()[0].getIConst());
}"""

NEW = """// Convert a glslang AST swizzle node to a swizzle vector for building SPIR-V.
void TGlslangToSpvTraverser::convertSwizzle(const glslang::TIntermAggregate& node, std::vector<unsigned>& swizzle)
{
    const glslang::TIntermSequence& swizzleSequence = node.getSequence();
    for (int i = 0; i < (int)swizzleSequence.size(); ++i) {
        // getAsConstantUnion() returns nullptr for any node that isn't a
        // TIntermConstantUnion (base-class default in intermediate.h). That
        // should never happen for a well-formed swizzle, but when it does
        // (some shaders hit this via chained-swizzle/optimizer-folded AST
        // shapes), dereferencing the null pointer here used to take the
        // whole process down with a SIGSEGV. Fall back to component 0 and
        // report it instead of crashing - a wrong swizzle component in one
        // shader beats losing the whole session.
        const glslang::TIntermConstantUnion* constUnion = swizzleSequence[i]->getAsConstantUnion();
        if (constUnion == nullptr) {
            fprintf(stderr, "[glslang] convertSwizzle: non-constant swizzle index element %d, "
                             "falling back to component 0 instead of crashing\\n", i);
            swizzle.push_back(0);
            continue;
        }
        swizzle.push_back(constUnion->getConstArray()[0].getIConst());
    }
}"""

STEPS = [
    ("convertSwizzle null-check guard", OLD, NEW),
]


def apply_patch(root: pathlib.Path) -> int:
    target = root / TARGET_REL_PATH
    if not target.is_file():
        print(f"ERROR: {target} not found. Pass the path to your glslang checkout root.", file=sys.stderr)
        return 1

    text = target.read_text()
    changed = False

    for name, old, new in STEPS:
        if new in text:
            print(f"[patch_glslang] '{name}' already applied, skipping.")
            continue
        if old not in text:
            print(f"ERROR: expected pattern for '{name}' not found in {target}.\n"
                  f"glslang's source has likely changed upstream since this script was written; "
                  f"the patch needs updating rather than blindly applied.", file=sys.stderr)
            return 1
        count = text.count(old)
        if count != 1:
            print(f"ERROR: pattern for '{name}' matched {count} times (expected exactly 1) in {target}; "
                  f"refusing to guess which to patch.", file=sys.stderr)
            return 1
        text = text.replace(old, new)
        changed = True
        print(f"[patch_glslang] Applied '{name}'.")

    if changed:
        target.write_text(text)
        print(f"[patch_glslang] Wrote {target}")
    else:
        print("[patch_glslang] Nothing to do, all patches already present.")

    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} /path/to/glslang/checkout", file=sys.stderr)
        sys.exit(1)
    sys.exit(apply_patch(pathlib.Path(sys.argv[1])))
