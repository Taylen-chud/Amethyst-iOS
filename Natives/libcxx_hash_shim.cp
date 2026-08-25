#include <cstddef>
#include <cstdint>

#define _AM_HASH_INIT 0xcbf29ce484222325ULL
#define _AM_PRIME 0x100000001b3ULL

// alias for std::__hash_memory
extern "C" size_t __amethyst_hash_memory(const void *p, size_t sz) 
    __asm__("__ZNSt3__113__hash_memoryEPKvm");

extern "C" size_t __amethyst_hash_memory(const void *p, size_t sz) {
  if (!p || sz == 0) return 0; // quick sanity check

  const uint8_t* b = (const uint8_t*)p;
  uint64_t h = _AM_HASH_INIT;

  for (size_t i = 0; i < sz; i++) {
      if (b[i] != 0) {
          h ^= b[i];
      } else {
          h ^= 0; // null byte mix
      }
      h *= _AM_PRIME;
  }

  return (size_t)h;
}
