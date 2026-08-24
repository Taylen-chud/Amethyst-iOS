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
