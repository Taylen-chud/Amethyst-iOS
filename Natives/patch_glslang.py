#!/usr/bin/env python3
import sys
import os

# quick fix for glslang convertSwizzle null deref crash in GlslangToSpv.cpp
# prevents SIGSEGV in libMobileGL when processing folded swizzle nodes

old_str = """// Convert a glslang AST swizzle node to a swizzle vector for building SPIR-V.
void TGlslangToSpvTraverser::convertSwizzle(const glslang::TIntermAggregate& node, std::vector<unsigned>& swizzle)
{
    const glslang::TIntermSequence& swizzleSequence = node.getSequence();
    for (int i = 0; i < (int)swizzleSequence.size(); ++i)
        swizzle.push_back(swizzleSequence[i]->getAsConstantUnion()->getConstArray()[0].getIConst());
}"""

new_str = """// Convert a glslang AST swizzle node to a swizzle vector for building SPIR-V.
void TGlslangToSpvTraverser::convertSwizzle(const glslang::TIntermAggregate& node, std::vector<unsigned>& swizzle)
{
    const glslang::TIntermSequence& swizzleSequence = node.getSequence();
    for (int i = 0; i < (int)swizzleSequence.size(); ++i) {
        // getAsConstantUnion is null on non-constant nodes (optimizer folded)
        // fallback to 0 instead of crashing process
        const glslang::TIntermConstantUnion* constUnion = swizzleSequence[i]->getAsConstantUnion();
        if (!constUnion) {
            fprintf(stderr, "[glslang] convertSwizzle: bad swizzle idx %d, fallback to 0\\n", i);
            swizzle.push_back(0);
            continue;
        }
        swizzle.push_back(constUnion->getConstArray()[0].getIConst());
    }
}"""


def do_patch(path_in):
    rel = "SPIRV/GlslangToSpv.cpp"
    p = os.path.join(path_in, rel)

    # verify path
    if not os.path.exists(p):
        print("err: missing file %s" % p, file=sys.stderr)
        return 1

    # read source file
    f = open(p, "r")
    txt = f.read()
    f.close()

    # check status
    if new_str in txt:
        print("already patched.")
        return 0

    if old_str not in txt:
        print("err: target snippet missing from " + rel, file=sys.stderr)
        return 1

    # verify match count
    c = txt.count(old_str)
    if c != 1:
        print("err: expected 1 match, got %d" % c, file=sys.stderr)
        return 1

    # write back patch
    out = open(p, "w")
    out.write(txt.replace(old_str, new_str))
    out.close()

    print("patched " + rel + " ok.")
    return 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: patch.py <glslang_dir>", file=sys.stderr)
        sys.exit(1)

    dir_arg = sys.argv[1]
    res = do_patch(dir_arg)
    sys.exit(res)
