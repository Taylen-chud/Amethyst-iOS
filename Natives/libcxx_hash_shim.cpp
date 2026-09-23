#include <cstddef>

// Fallback implementation of std::__1::__hash_memory for older iOS/macOS runtimes 
// that lack the symbol in system libc++.1.dylib.
extern "C" size_t __amethyst_hash_memory(const void *ptr, size_t size)
    __asm__("__ZNSt3__113__hash_memoryEPKvm");

extern "C" size_t __amethyst_hash_memory(const void *ptr, size_t size) {
    const auto *bytes = static_cast<const unsigned char *>(ptr);
    
    // Standard 64-bit FNV-1a hash
    size_t hash = 14695981039346656037ULL;
    for (size_t i = 0; i < size; ++i) {
        hash ^= bytes[i];
        hash *= 1099511628211ULL;
    }
    
    return hash;
}