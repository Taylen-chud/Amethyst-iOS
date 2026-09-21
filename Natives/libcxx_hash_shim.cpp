#include <cstddef>

extern "C" {

// Custom/Internal hash memory implementation
size_t __amethyst_hash_memory(const void *ptr, size_t size) {
    const unsigned char *data = static_cast<const unsigned char *>(ptr);
    size_t hash = 14695981039346656037ULL; // FNV-1a offset basis
    for (size_t i = 0; i < size; i++) {
        hash ^= data[i];
        hash *= 1099511628211ULL; // FNV-1a prime
    }
    return hash;
}

// Single leading underscore in C code compiles to __ZNSt3... at Mach-O ABI level
__attribute__((visibility("default"), used))
size_t _ZNSt3__113__hash_memoryEPKvm(const void *ptr, size_t size) {
    return __amethyst_hash_memory(ptr, size);
}

} // extern "C"
