#ifndef LODMESH_H
#define LODMESH_H

#include <stdint.h>

#define LM_TILE 64
#define LM_GROUPS 16
#define LM_HDR 32 // header words per block: the 16 groups' words, the lowest solid tops of its 4 x 4 parts, its groups' tops
#define LM_DEEP (-512)

enum
{
	LM_G_TOP = 0,
	LM_G_BOTTOM = 1,
	LM_G_XP = 2,
	LM_G_XN = 3,
	LM_G_ZP = 4,
	LM_G_ZN = 5,
	LM_G_BXP = 6,
	LM_G_BXN = 7,
	LM_G_BZP = 8,
	LM_G_BZN = 9,
	LM_G_SXP = 10,
	LM_G_SXN = 11,
	LM_G_SZP = 12,
	LM_G_SZN = 13,
	LM_G_PLANT = 14,
	LM_G_INFO = 15
};

// Faces as columns.metal numbers them.
enum
{
	LM_F_TOP = 0,
	LM_F_XP = 1,
	LM_F_XN = 2,
	LM_F_ZP = 3,
	LM_F_ZN = 4,
	LM_F_BOTTOM = 5,
	LM_F_PLANT = 6
};
// What a face is of: the ground (or the whole column), a crown's leaves, the ground under a crown.
enum
{
	LM_K_GROUND = 0,
	LM_K_CROWN = 1,
	LM_K_UNDER = 2
};

// A quad, two words:
//   w0: x (7 bits, cells from the tile's corner) | z (7) << 7 | (e1 - 1) (6) << 14 | (e2 - 1) (6) << 20 | face (3) << 26 | kind (2) << 29
//       | skirt (1) << 31 (a skirt's ground piece, one cell: the vertex stage lowers its foot to the surface across the seam)
//   w1: (y0 + 512) (12 bits) | (y1 + 512) (12) << 12 | extra (8) << 24
// Tops and undersides: cells [x, x + e1) x [z, z + e2) at height y0. Walls facing +-x: the plane x, cells [z, z + e1), from y0 to
// y1; facing +-z: the plane z, cells [x, x + e1). Plants: cell (x, z); e1 - 1 = quad (bit 0: 0 along x = z, 1 along x + z = 1)
// | (blocks - 1) << 1; e2 - 1 = the offset's x nibble; extra = the offset's z nibble | y nibble << 4 (columns.metal's plant word
// B nibbles); y0 the ground's top.

typedef struct
{
	const uint32_t *geom;	// the level's N x N geometry words (toroidal: cell (x, z) at (z mod N) * N + x mod N)
	const uint32_t *crown;	// the level's crown words (NULL: the level has none)
	const uint32_t *runs;	// the level's crown run words (NULL: none)
	const uint32_t *plantA; // level 0's plant words A and B (NULL: none)
	const uint32_t *plantB;
	int logN;
	int level;
	int tx, tz;	   // the tile (absolute, in tiles of its level)
	int neighbors; // which edge neighbors are resident (their cells are this level's): 1 +x, 2 -x, 4 +z, 8 -z
	int block;	   // cells per block side: 8 or 16
} LmIn;

// Meshes one tile. header: (64 / block)^2 blocks x LM_HDR words, block-major in rows of z: per group start (quads from the
// tile's first, 20 bits) | count << 20 (12 bits); word 15: (lowest y + 512) | (highest y + 512) << 16 of the block's faces
// (tops, walls down to the neighbors' surfaces, plants); words 16-23: the lowest solid top (+ 512, 12 bits each: the
// column's top, a crown cell's ground) of the block's 4 x 4 parts, two a word (part k = pz * 4 + px in word 16 + k / 2, bits
// (k & 1) * 12): occluders the GPU's horizon cull can trust (everything under them is solid). quads: two words each.
// Words 24-31: the highest point of each group's faces (+ 512, 12 bits, two a word: group g in word 24 + g / 2, bits (g & 1)
// * 12), so the horizon cull can drop a block's groups that sit lower than its highest. Returns the quad count, or -1 when
// `cap` quads are not enough.
int lm_mesh(const LmIn *in, uint32_t *header, uint32_t *quads, int cap);

#endif
