// libcxx_hash_shim.cpp
//
// Provides a definition for __ZNSt3__113__hash_memoryEPKvm
// (std::__1::__hash_memory(void const*, unsigned long)) which some builds of
// libMobileGL.dylib expect to find exported from the system libc++.1.dylib.
// On this device's libc++, the symbol either isn't exported or is inlined,
// so dyld fails to bind it and the dylib refuses to load at all.
//
// This shim supplies the symbol under its exact mangled name via inline asm,
// and is dlopen()'d with RTLD_GLOBAL before libMobileGL is ever touched, with
// DYLD_FORCE_FLAT_NAMESPACE=1 set so dyld will resolve the unresolved
// two-level-namespace reference against this already-loaded image instead of
// insisting on libc++.1.dylib specifically.
//
// NOTE: this does not need to reproduce libc++'s exact hash algorithm -
// __hash_memory is only ever consumed by std::hash internals as an opaque
// mixing function, never compared against a fixed/serialized value. Any
// deterministic function of the input bytes is safe here.

#include <cstddef>

extern "C" size_t __amethyst_hash_memory(const void *ptr, size_t size)
    __asm__("__ZNSt3__113__hash_memoryEPKvm");

extern "C" size_t __amethyst_hash_memory(const void *ptr, size_t size) {
    const unsigned char *data = static_cast<const unsigned char *>(ptr);
    size_t hash = 14695981039346656037ULL; // FNV-1a offset basis
    for (size_t i = 0; i < size; i++) {
        hash ^= data[i];
        hash *= 1099511628211ULL; // FNV-1a prime
    }
    return hash;
}
