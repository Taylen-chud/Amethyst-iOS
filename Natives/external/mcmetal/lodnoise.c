#include <arm_neon.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#pragma clang fp contract(off)

typedef struct
{
	uint8_t perm[256];
	uint8_t perm2[512]; // perm twice: indices up to 511 need no wrap
	double ox, oy, oz;
	double fudge; // SmearedPerlinNoise.fudgeYScale (unused for plain Perlin)
	double freq;  // the layer's frequency in its stack
	float amp;	  // the layer's amplitude in its stack
	float pad;
} Layer;

typedef struct
{
	int n;
	int smeared;
	Layer *layers;
} Stack;

// GradientNoise.GRADIENT (x, y, z)
static const float GX[16] = {1, -1, 1, -1, 1, -1, 1, -1, 0, 0, 0, 0, 1, 0, -1, 0};
static const float GY[16] = {1, 1, -1, -1, 0, 0, 0, 0, 1, -1, 1, -1, 1, -1, 1, -1};
static const float GZ[16] = {0, 0, 0, 0, 1, 1, -1, -1, 1, 1, -1, -1, 0, 1, 0, -1};

#define HALF_ROUND_OFF 16777215.999999998 // Math.nextDown(16777216.0)

static inline double wrapd(double v)
{
	if (v >= -HALF_ROUND_OFF && v < HALF_ROUND_OFF)
		return v;
	return v - floor(v / 33554432.0 + 0.5) * 33554432.0;
}

// Mth.floor(double): (int) Math.floor; the coordinates here are within +-2^25 + 256 after wrap
static inline int floori(double v)
{
	return (int)floor(v);
}

static inline float smooth(float t)
{
	return t * t * t * (t * (t * 6.0f - 15.0f) + 10.0f);
}

static inline float lerpf(float t, float a, float b)
{
	return a + t * (b - a);
}

static inline float lerp3f(float tx, float ty, float tz, float a000, float a100, float a010, float a110, float a001, float a101, float a011,
						   float a111)
{
	return lerpf(tz, lerpf(ty, lerpf(tx, a000, a100), lerpf(tx, a010, a110)), lerpf(ty, lerpf(tx, a001, a101), lerpf(tx, a011, a111)));
}

// SmearedPerlinNoise.computeFudgeY
static inline double fudgey(double fudge, double y, double fyd)
{
	double v = y >= 0.0 && y < fyd ? y : fyd;
	return (double)floori(v / fudge + (double)1.0E-7f) * fudge;
}

static inline int perm(const Layer *L, int i)
{
	return L->perm[i & 255];
}

// ---- stacks ----

// perms: n x 256 bytes; params: n x 5 doubles (offsetX, offsetY, offsetZ, fudgeYScale, frequency); amps: n floats
int64_t mcn_stack_new(int n, int smeared, const uint8_t *perms, const double *params, const float *amps)
{
	Stack *s = calloc(1, sizeof(Stack));
	if (!s)
		return 0;
	s->n = n;
	s->smeared = smeared;
	s->layers = calloc((size_t)(n > 0 ? n : 1), sizeof(Layer));
	if (!s->layers)
	{
		free(s);
		return 0;
	}
	for (int i = 0; i < n; i++)
	{
		Layer *L = &s->layers[i];
		memcpy(L->perm, perms + 256 * i, 256);
		memcpy(L->perm2, perms + 256 * i, 256);
		memcpy(L->perm2 + 256, perms + 256 * i, 256);
		L->ox = params[5 * i];
		L->oy = params[5 * i + 1];
		L->oz = params[5 * i + 2];
		L->fudge = params[5 * i + 3];
		L->freq = params[5 * i + 4];
		L->amp = amps[i];
	}
	return (int64_t)(intptr_t)s;
}

void mcn_stack_free(int64_t h)
{
	Stack *s = (Stack *)(intptr_t)h;
	if (!s)
		return;
	free(s->layers);
	free(s);
}

// ---- points: NoiseStack.get(x, y, z) over PerlinNoise.get / SmearedPerlinNoise.get ----

static float sample_and_lerp(const Layer *L, int x, int y, int z, float fx, float fy, float fz, float fys)
{
	int a = perm(L, x), b = perm(L, x + 1);
	int aa = perm(L, a + y), ab = perm(L, a + y + 1), ba = perm(L, b + y), bb = perm(L, b + y + 1);
	int h;
	// GradientNoise.gradDot: x * gx + y * gy + z * gz, in that order
#define GD(hh, X, Y, Z) (h = (hh) & 15, GX[h] * (X) + GY[h] * (Y) + GZ[h] * (Z))
	float v000 = GD(perm(L, aa + z), fx, fy, fz);
	float v100 = GD(perm(L, ba + z), fx - 1.0f, fy, fz);
	float v010 = GD(perm(L, ab + z), fx, fy - 1.0f, fz);
	float v110 = GD(perm(L, bb + z), fx - 1.0f, fy - 1.0f, fz);
	float v001 = GD(perm(L, aa + z + 1), fx, fy, fz - 1.0f);
	float v101 = GD(perm(L, ba + z + 1), fx - 1.0f, fy, fz - 1.0f);
	float v011 = GD(perm(L, ab + z + 1), fx, fy - 1.0f, fz - 1.0f);
	float v111 = GD(perm(L, bb + z + 1), fx - 1.0f, fy - 1.0f, fz - 1.0f);
#undef GD
	return lerp3f(smooth(fx), smooth(fys), smooth(fz), v000, v100, v010, v110, v001, v101, v011, v111);
}

static float layer_get(const Layer *L, int smeared, double x, double y, double z)
{
	double X = wrapd(x) + L->ox, Y = wrapd(y) + L->oy, Z = wrapd(z) + L->oz;
	int xi = floori(X), yi = floori(Y), zi = floori(Z);
	float fx = (float)(X - (double)xi), fz = (float)(Z - (double)zi);
	if (!smeared)
	{
		float fy = (float)(Y - (double)yi);
		return sample_and_lerp(L, xi, yi, zi, fx, fy, fz, fy);
	}
	double fyd = Y - (double)yi;
	float fy = (float)(fyd - fudgey(L->fudge, y, fyd));
	return sample_and_lerp(L, xi, yi, zi, fx, fy, fz, (float)fyd);
}

float mcn_stack_point(int64_t h, double x, double y, double z)
{
	const Stack *s = (const Stack *)(intptr_t)h;
	float sum = 0.0f;
	for (int i = 0; i < s->n; i++)
	{
		const Layer *L = &s->layers[i];
		double f = L->freq;
		sum = sum + L->amp * layer_get(L, s->smeared, x * f, y * f, z * f);
	}
	return sum;
}

// n points (x, y, z interleaved doubles) -> out
void mcn_stack_points(int64_t h, const double *xyz, int n, float *out)
{
	for (int i = 0; i < n; i++)
		out[i] = mcn_stack_point(h, xyz[3 * i], xyz[3 * i + 1], xyz[3 * i + 2]);
}

// ---- volumes ----

typedef struct
{
	int sx, sy, sz, x0, y0, z0, dx, dy, dz;
} Vol;

// One layer over the volume, added into buf: PerlinNoise.addToVolume / SmearedPerlinNoise.addToVolume (plain C port).
static void layer_volume_c(const Layer *L, int smeared, float *buf, const Vol *v, double xs, double ys, float amp)
{
	int i = 0;
	for (int z = 0; z < v->sz; z++)
	{
		double Zd = wrapd((double)(v->z0 + z * v->dz) * xs) + L->oz;
		int zf = floori(Zd);
		float fz = (float)(Zd - (double)zf), fz1 = fz - 1.0f;
		float sz = smooth(fz);
		for (int x = 0; x < v->sx; x++)
		{
			double Xd = wrapd((double)(v->x0 + x * v->dx) * xs) + L->ox;
			int xf = floori(Xd);
			float fx = (float)(Xd - (double)xf), fx1 = fx - 1.0f;
			int a = perm(L, xf), b = perm(L, xf + 1);
			float sx = smooth(fx);
			for (int y = 0; y < v->sy; y++, i++)
			{
				double yv = (double)(v->y0 + y * v->dy) * ys;
				double Yd = wrapd(yv) + L->oy;
				int yf = floori(Yd);
				double fyd = Yd - (double)yf;
				float sy = smooth((float)fyd);
				float fy = smeared ? (float)(fyd - fudgey(L->fudge, yv, fyd)) : (float)fyd;
				float fy1 = fy - 1.0f;
				int aa = perm(L, a + yf), ab = perm(L, a + yf + 1), ba = perm(L, b + yf), bb = perm(L, b + yf + 1);
				int h000 = perm(L, aa + zf) & 15, h100 = perm(L, ba + zf) & 15, h010 = perm(L, ab + zf) & 15, h110 = perm(L, bb + zf) & 15;
				int h001 = perm(L, aa + zf + 1) & 15, h101 = perm(L, ba + zf + 1) & 15, h011 = perm(L, ab + zf + 1) & 15, h111 = perm(L, bb + zf + 1) & 15;
				// Gradient.dotXz (x * gx + z * gz), then + gy * y
				float d000 = GX[h000] * fx + GZ[h000] * fz, d100 = GX[h100] * fx1 + GZ[h100] * fz;
				float d010 = GX[h010] * fx + GZ[h010] * fz, d110 = GX[h110] * fx1 + GZ[h110] * fz;
				float d001 = GX[h001] * fx + GZ[h001] * fz1, d101 = GX[h101] * fx1 + GZ[h101] * fz1;
				float d011 = GX[h011] * fx + GZ[h011] * fz1, d111 = GX[h111] * fx1 + GZ[h111] * fz1;
				float val = lerp3f(sx, sy, sz, d000 + GY[h000] * fy, d100 + GY[h100] * fy, d010 + GY[h010] * fy1, d110 + GY[h110] * fy1,
								   d001 + GY[h001] * fy, d101 + GY[h101] * fy, d011 + GY[h011] * fy1, d111 + GY[h111] * fy1);
				buf[i] = buf[i] + amp * val;
			}
		}
	}
}

// ---- NEON ----

#define MAXY 64 // y lanes per column chunk
#define MAXL 64 // layers per stack

typedef struct
{
	// per layer, over the volume's y (padded to a multiple of 16 lanes)
	uint8_t yf8[MAXY];
	float fy[MAXY], fy1[MAXY], sy[MAXY];
} YTab;

typedef struct
{
	int xf;
	float fx, fx1, sx;
	uint8_t a, b;
} XTab;

typedef struct
{
	int zf;
	float fz, fz1, sz;
} ZTab;

typedef struct
{
	YTab *y;
	XTab *x;
	ZTab *z;
	size_t ycap, xcap, zcap;
} Scratch;

static _Thread_local Scratch scratch;

static void *grow(void *p, size_t *cap, size_t need, size_t elem)
{
	if (need <= *cap)
		return p;
	size_t n = need + need / 2 + 16;
	void *q = realloc(p, n * elem);
	if (!q)
		return NULL;
	*cap = n;
	return q;
}

// The y-, x- and z-dependent parts of each layer: per layer and volume, not per point.
static int prepare(const Stack *s, int first, int count, const Vol *v, int ys0, int ycount, double xzScale, double yScale, int tab)
{
	Scratch *sc = &scratch;
	size_t need = (size_t)(tab + count);
	sc->y = grow(sc->y, &sc->ycap, need, sizeof(YTab));
	sc->x = grow(sc->x, &sc->xcap, need * (size_t)v->sx, sizeof(XTab));
	sc->z = grow(sc->z, &sc->zcap, need * (size_t)v->sz, sizeof(ZTab));
	if (!sc->y || !sc->x || !sc->z)
		return 0;
	for (int k = 0; k < count; k++)
	{
		const Layer *L = &s->layers[first + k];
		double xs = xzScale * L->freq, ys = yScale * L->freq;
		YTab *Y = &sc->y[tab + k];
		int padded = (ycount + 15) & ~15;
		for (int j = 0; j < padded; j++)
		{
			int y = ys0 + (j < ycount ? j : ycount - 1);
			double yv = (double)(v->y0 + y * v->dy) * ys;
			double Yd = wrapd(yv) + L->oy;
			int yf = floori(Yd);
			double fyd = Yd - (double)yf;
			float fy = s->smeared ? (float)(fyd - fudgey(L->fudge, yv, fyd)) : (float)fyd;
			Y->yf8[j] = (uint8_t)yf;
			Y->fy[j] = fy;
			Y->fy1[j] = fy - 1.0f;
			Y->sy[j] = smooth((float)fyd);
		}
		XTab *X = &sc->x[(size_t)(tab + k) * (size_t)v->sx];
		for (int x = 0; x < v->sx; x++)
		{
			double Xd = wrapd((double)(v->x0 + x * v->dx) * xs) + L->ox;
			int xf = floori(Xd);
			X[x].xf = xf;
			X[x].fx = (float)(Xd - (double)xf);
			X[x].fx1 = X[x].fx - 1.0f;
			X[x].sx = smooth(X[x].fx);
			X[x].a = (uint8_t)perm(L, xf);
			X[x].b = (uint8_t)perm(L, xf + 1);
		}
		ZTab *Z = &sc->z[(size_t)(tab + k) * (size_t)v->sz];
		for (int z = 0; z < v->sz; z++)
		{
			double Zd = wrapd((double)(v->z0 + z * v->dz) * xs) + L->oz;
			int zf = floori(Zd);
			Z[z].zf = zf;
			Z[z].fz = (float)(Zd - (double)zf);
			Z[z].fz1 = Z[z].fz - 1.0f;
			Z[z].sz = smooth(Z[z].fz);
		}
	}
	return 1;
}

// Gradient components as floats for 4-lane TBL2 lookups: +-1.0f and 0 differ only in their two high bytes, so a 32-byte
// table holds a component's byte 2 (entries 0-15, by h) and byte 3 (entries 16-31); index bytes (ff, ff, h, h + 16) per
// lane give the float (out-of-range bytes read 0).
static const uint8_t GT[3][32] = {
	{0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00, 0x00, 0x00, 0x00, 0x80, 0x00, 0x80, 0x00, 0x3f, 0xbf, 0x3f, 0xbf, 0x3f, 0xbf, 0x3f, 0xbf, 0x00, 0x00, 0x00, 0x00, 0x3f, 0x00, 0xbf, 0x00},
	{0x80, 0x80, 0x80, 0x80, 0x00, 0x00, 0x00, 0x00, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x3f, 0x3f, 0xbf, 0xbf, 0x00, 0x00, 0x00, 0x00, 0x3f, 0xbf, 0x3f, 0xbf, 0x3f, 0xbf, 0x3f, 0xbf},
	{0x00, 0x00, 0x00, 0x00, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x00, 0x80, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x3f, 0x3f, 0xbf, 0xbf, 0x3f, 0x3f, 0xbf, 0xbf, 0x00, 0x3f, 0x00, 0xbf},
};

static inline uint8x16x2_t load32(const uint8_t *p)
{
	uint8x16x2_t t;
	t.val[0] = vld1q_u8(p);
	t.val[1] = vld1q_u8(p + 16);
	return t;
}

// 4 lanes' h bytes (packed, lane 0 in the low byte) -> TBL2 index bytes (ff, ff, h, h + 16) per lane
static inline uint8x16_t gindex(uint32_t packed, uint8x16_t ffs)
{
	static const uint8_t spread[16] = {4, 4, 0, 0, 4, 4, 1, 1, 4, 4, 2, 2, 4, 4, 3, 3};
	static const uint8_t plus[16] = {0, 0, 0, 16, 0, 0, 0, 16, 0, 0, 0, 16, 0, 0, 0, 16};
	uint8x16_t h = vreinterpretq_u8_u32(vsetq_lane_u32(packed, vreinterpretq_u32_u8(ffs), 0));
	return vaddq_u8(vqtbl1q_u8(h, vld1q_u8(spread)), vld1q_u8(plus));
}

static inline float32x4_t gfetch(uint8x16x2_t t, uint8x16_t idx)
{
	return vreinterpretq_f32_u8(vqtbl2q_u8(t, idx));
}

static inline float32x4_t lerpv(float32x4_t t, float32x4_t a, float32x4_t b)
{
	return vaddq_f32(a, vmulq_f32(t, vsubq_f32(b, a)));
}

// The 8 corners of one cell (a column's x and z, one y floor) as the game's volume loop caches them: the corner's
// Gradient.dotXz (x * gx + z * gz) and its gy.
static inline void cell(const Layer *L, int a, int b, int zf, int yf, float fx, float fx1, float fz, float fz1, float *d, float *g)
{
	int aa = perm(L, a + yf), ab = perm(L, a + yf + 1), ba = perm(L, b + yf), bb = perm(L, b + yf + 1);
	int h[8] = {perm(L, aa + zf) & 15, perm(L, ba + zf) & 15, perm(L, ab + zf) & 15, perm(L, bb + zf) & 15, perm(L, aa + zf + 1) & 15,
				perm(L, ba + zf + 1) & 15, perm(L, ab + zf + 1) & 15, perm(L, bb + zf + 1) & 15};
	for (int c = 0; c < 8; c++)
	{
		float X = (c & 1) ? fx1 : fx, Z = (c & 4) ? fz1 : fz;
		d[c] = GX[h[c]] * X + GZ[h[c]] * Z;
		g[c] = GY[h[c]];
	}
}

// One layer over one column chunk (ycount lanes from the y table at offset 0), added into acc[0..ycount).
// need: per group of 4 lanes, whether it is needed (NULL: all); groups not needed are left as they are.
// A group of 4 lanes in one cell (one y floor: low frequencies, most layers of the cave noises) takes the cell's corners
// from a scalar cache, as the game's loop does. Other groups hash their 4 lanes with scalar loads (the integer units are
// otherwise idle; faster than TBL lookups into a 256-byte table, measured) and fetch their gradients with TBL2.
static void layer_column_neon(const Layer *L, const YTab *Y, const XTab *X, const ZTab *Z, int ycount, float amp, float *acc,
							  const uint8x16x2_t gx, const uint8x16x2_t gy, const uint8x16x2_t gz, const uint8_t *need)
{
	float32x4_t fx = vdupq_n_f32(X->fx), fx1 = vdupq_n_f32(X->fx1), fz = vdupq_n_f32(Z->fz), fz1 = vdupq_n_f32(Z->fz1);
	float32x4_t sx = vdupq_n_f32(X->sx), sz = vdupq_n_f32(Z->sz), va = vdupq_n_f32(amp);
	uint8x16_t ffs = vdupq_n_u8(0xFF);
	int cached = -1;
	float cd[8], cg[8];
	float32x4_t D[8], G[8];
	for (int j = 0; j < ycount; j += 4)
	{
		if (need && !need[j / 4])
			continue;
		float32x4_t fy = vld1q_f32(Y->fy + j), fy1 = vld1q_f32(Y->fy1 + j), sy = vld1q_f32(Y->sy + j);
		float32x4_t v[8];
		uint32_t yw;
		memcpy(&yw, Y->yf8 + j, 4);
		if (yw == (yw & 0xFFu) * 0x01010101u)
		{
			int y8 = (int)(yw & 0xFFu);
			if (y8 != cached)
			{
				cached = y8;
				cell(L, X->a, X->b, Z->zf, y8, X->fx, X->fx1, Z->fz, Z->fz1, cd, cg);
				for (int c = 0; c < 8; c++)
				{
					D[c] = vdupq_n_f32(cd[c]);
					G[c] = vdupq_n_f32(cg[c]);
				}
			}
			for (int c = 0; c < 8; c++)
				v[c] = vaddq_f32(D[c], vmulq_f32(G[c], (c & 2) ? fy1 : fy));
		}
		else
		{
			uint32_t pk[8] = {0};
			const uint8_t *P = L->perm2;
			int a = X->a, b = X->b, zf = Z->zf & 255;
			for (int k = 0; k < 4; k++)
			{
				int y8 = Y->yf8[j + k];
				int aa = P[a + y8] + zf, ab = P[a + y8 + 1] + zf, ba = P[b + y8] + zf, bb = P[b + y8 + 1] + zf;
				int sh = 8 * k;
				pk[0] |= (uint32_t)(P[aa] & 15) << sh;
				pk[1] |= (uint32_t)(P[ba] & 15) << sh;
				pk[2] |= (uint32_t)(P[ab] & 15) << sh;
				pk[3] |= (uint32_t)(P[bb] & 15) << sh;
				pk[4] |= (uint32_t)(P[aa + 1] & 15) << sh;
				pk[5] |= (uint32_t)(P[ba + 1] & 15) << sh;
				pk[6] |= (uint32_t)(P[ab + 1] & 15) << sh;
				pk[7] |= (uint32_t)(P[bb + 1] & 15) << sh;
			}
			for (int c = 0; c < 8; c++)
			{
				uint32_t packed = pk[c];
				uint8x16_t idx = gindex(packed, ffs);
				float32x4_t X1 = (c & 1) ? fx1 : fx; // corners 1, 3, 5, 7 are x1
				float32x4_t Zc = (c & 4) ? fz1 : fz; // corners 4..7 are z1
				float32x4_t Yc = (c & 2) ? fy1 : fy; // corners 2, 3, 6, 7 are y1
				float32x4_t d = vaddq_f32(vmulq_f32(gfetch(gx, idx), X1), vmulq_f32(gfetch(gz, idx), Zc));
				v[c] = vaddq_f32(d, vmulq_f32(gfetch(gy, idx), Yc));
			}
		}
		// lerp3(sx, sy, sz, v000, v100, v010, v110, v001, v101, v011, v111)
		float32x4_t l0 = lerpv(sy, lerpv(sx, v[0], v[1]), lerpv(sx, v[2], v[3]));
		float32x4_t l1 = lerpv(sy, lerpv(sx, v[4], v[5]), lerpv(sx, v[6], v[7]));
		float32x4_t val = lerpv(sz, l0, l1);
		float32x4_t r = vaddq_f32(vld1q_f32(acc + j), vmulq_f32(va, val));
		vst1q_f32(acc + j, r);
	}
}

// Layers [first, first + count) of a stack over the volume into out (acc mode: out += sum; set mode: out = 0 + sum).
static int stack_volume_neon(const Stack *s, float *out, const Vol *v, double xzScale, double yScale, float amp, int set)
{
	uint8x16x2_t gx = load32(GT[0]), gy = load32(GT[1]), gz = load32(GT[2]);
	int n = s->n;
	if (n > MAXL)
		return 0;
	float acc[MAXY + 16] __attribute__((aligned(16)));
	for (int y0 = 0; y0 < v->sy; y0 += MAXY)
	{
		int yc = v->sy - y0 < MAXY ? v->sy - y0 : MAXY;
		if (!prepare(s, 0, n, v, y0, yc, xzScale, yScale, 0))
			return 0;
		Scratch *sc = &scratch;
		for (int z = 0; z < v->sz; z++)
		{
			for (int x = 0; x < v->sx; x++)
			{
				float *col = out + ((size_t)z * (size_t)v->sx + (size_t)x) * (size_t)v->sy + (size_t)y0;
				int padded4 = (yc + 3) & ~3;
				for (int j = 0; j < padded4; j++)
					acc[j] = j < yc ? (set ? 0.0f : col[j]) : 0.0f;
				for (int k = 0; k < n; k++)
				{
					const Layer *L = &s->layers[k];
					layer_column_neon(L, &sc->y[k], &sc->x[(size_t)k * (size_t)v->sx + (size_t)x], &sc->z[(size_t)k * (size_t)v->sz + (size_t)z], yc,
									  amp * L->amp, acc, gx, gy, gz, NULL);
				}
				memcpy(col, acc, (size_t)yc * sizeof(float));
			}
		}
	}
	return 1;
}

static void stack_volume_c(const Stack *s, float *out, const Vol *v, double xzScale, double yScale, float amp, int set)
{
	size_t size = (size_t)v->sx * (size_t)v->sy * (size_t)v->sz;
	if (set)
		for (size_t i = 0; i < size; i++)
			out[i] = 0.0f;
	for (int k = 0; k < s->n; k++)
	{
		const Layer *L = &s->layers[k];
		layer_volume_c(L, s->smeared, out, v, xzScale * L->freq, yScale * L->freq, amp * L->amp);
	}
}

// NoiseStack.addToVolume(buffer, volume, xzScale, yScale, amp); set: the buffer filled with 0 first (NoiseFunction$Sampler).
void mcn_stack_volume(int64_t h, float *out, int sx, int sy, int sz, int x0, int y0, int z0, int dx, int dy, int dz, double xzScale, double yScale,
					  float amp, int set, int impl)
{
	const Stack *s = (const Stack *)(intptr_t)h;
	Vol v = {sx, sy, sz, x0, y0, z0, dx, dy, dz};
	// (columns of a few points, e.g. a 2D noise's slice: the 16-lane hashing would mostly compute padding)
	if (impl == 1 && sy >= 8 && stack_volume_neon(s, out, &v, xzScale, yScale, amp, set))
		return;
	stack_volume_c(s, out, &v, xzScale, yScale, amp, set);
}

// ---- BlendedNoise: lerp(clamp(main + 0.5, 0, 1), minLimit, maxLimit) with the game's LerpFunction rule (alpha 0: the
// first exactly, 1: the second exactly), so only the limit stacks a point needs are evaluated. ----

static inline float blend_alpha(float main)
{
	float a = main + 0.5f;
	// Mth.clamp(a, 0, 1): a < 0 ? 0 : Math.min(a, 1)
	return a < 0.0f ? 0.0f : (a <= 1.0f ? a : 1.0f);
}

static void blended_c(const Stack *m, const Stack *lo, const Stack *hi, float *out, const Vol *v, double mxz, double my, double lxz, double ly)
{
	size_t size = (size_t)v->sx * (size_t)v->sy * (size_t)v->sz;
	float *a = malloc(size * sizeof(float)), *b = malloc(size * sizeof(float));
	if (!a || !b)
	{
		free(a);
		free(b);
		return;
	}
	stack_volume_c(m, out, v, mxz, my, 1.0f, 1);
	stack_volume_c(lo, a, v, lxz, ly, 1.0f, 1);
	stack_volume_c(hi, b, v, lxz, ly, 1.0f, 1);
	for (size_t i = 0; i < size; i++)
	{
		float t = blend_alpha(out[i]);
		out[i] = t == 0.0f ? a[i] : t == 1.0f ? b[i]
											  : lerpf(t, a[i], b[i]);
	}
	free(a);
	free(b);
}

static int blended_neon(const Stack *m, const Stack *lo, const Stack *hi, float *out, const Vol *v, double mxz, double my, double lxz, double ly)
{
	uint8x16x2_t gx = load32(GT[0]), gy = load32(GT[1]), gz = load32(GT[2]);
	if (m->n > MAXL || lo->n > MAXL || hi->n > MAXL)
		return 0;
	float am[MAXY + 16] __attribute__((aligned(16))), alo[MAXY + 16] __attribute__((aligned(16))), ahi[MAXY + 16] __attribute__((aligned(16)));
	uint8_t needLo[MAXY / 4 + 4] = {0}, needHi[MAXY / 4 + 4] = {0};
	int tm = 0, tlo = m->n, thi = m->n + lo->n;
	for (int y0 = 0; y0 < v->sy; y0 += MAXY)
	{
		int yc = v->sy - y0 < MAXY ? v->sy - y0 : MAXY;
		if (!prepare(m, 0, m->n, v, y0, yc, mxz, my, tm) || !prepare(lo, 0, lo->n, v, y0, yc, lxz, ly, tlo) || !prepare(hi, 0, hi->n, v, y0, yc, lxz, ly, thi))
			return 0;
		Scratch *sc = &scratch;
		int padded4 = (yc + 3) & ~3;
		for (int z = 0; z < v->sz; z++)
		{
			for (int x = 0; x < v->sx; x++)
			{
				for (int j = 0; j < padded4; j++)
					am[j] = alo[j] = ahi[j] = 0.0f;
				for (int k = 0; k < m->n; k++)
				{
					int t = tm + k;
					layer_column_neon(&m->layers[k], &sc->y[t], &sc->x[(size_t)t * (size_t)v->sx + (size_t)x], &sc->z[(size_t)t * (size_t)v->sz + (size_t)z], yc,
									  m->layers[k].amp, am, gx, gy, gz, NULL);
				}
				int anyLo = 0, anyHi = 0;
				for (int g = 0; g < padded4 / 4; g++)
				{
					int nl = 0, nh = 0;
					for (int j = 4 * g; j < 4 * g + 4 && j < yc; j++)
					{
						float t = blend_alpha(am[j]);
						if (t != 1.0f)
							nl = 1; // t == 0 or between: the first is needed
						if (t != 0.0f)
							nh = 1;
					}
					needLo[g] = (uint8_t)nl;
					needHi[g] = (uint8_t)nh;
					anyLo |= nl;
					anyHi |= nh;
				}
				// groups of 4 lanes a limit stack isn't needed for are skipped (the lanes of a needed group are all computed)
				if (anyLo)
				{
					for (int k = 0; k < lo->n; k++)
					{
						int t = tlo + k;
						const Layer *L = &lo->layers[k];
						layer_column_neon(L, &sc->y[t], &sc->x[(size_t)t * (size_t)v->sx + (size_t)x], &sc->z[(size_t)t * (size_t)v->sz + (size_t)z], yc, L->amp, alo,
										  gx, gy, gz, needLo);
					}
				}
				if (anyHi)
				{
					for (int k = 0; k < hi->n; k++)
					{
						int t = thi + k;
						const Layer *L = &hi->layers[k];
						layer_column_neon(L, &sc->y[t], &sc->x[(size_t)t * (size_t)v->sx + (size_t)x], &sc->z[(size_t)t * (size_t)v->sz + (size_t)z], yc, L->amp, ahi,
										  gx, gy, gz, needHi);
					}
				}
				float *col = out + ((size_t)z * (size_t)v->sx + (size_t)x) * (size_t)v->sy + (size_t)y0;
				for (int j = 0; j < yc; j++)
				{
					float t = blend_alpha(am[j]);
					col[j] = t == 0.0f ? alo[j] : t == 1.0f ? ahi[j]
															: lerpf(t, alo[j], ahi[j]);
				}
			}
		}
	}
	return 1;
}

void mcn_blended_volume(int64_t hm, int64_t hlo, int64_t hhi, float *out, int sx, int sy, int sz, int x0, int y0, int z0, int dx, int dy, int dz,
						double mainXz, double mainY, double limitXz, double limitY, int impl)
{
	const Stack *m = (const Stack *)(intptr_t)hm, *lo = (const Stack *)(intptr_t)hlo, *hi = (const Stack *)(intptr_t)hhi;
	Vol v = {sx, sy, sz, x0, y0, z0, dx, dy, dz};
	if (impl == 1 && sy >= 8 && blended_neon(m, lo, hi, out, &v, mainXz, mainY, limitXz, limitY))
		return;
	blended_c(m, lo, hi, out, &v, mainXz, mainY, limitXz, limitY);
}

// BlendedNoise at one point (LerpFunction.sampleValue: alpha first, then only the side(s) it needs)
float mcn_blended_point(int64_t hm, int64_t hlo, int64_t hhi, int x, int y, int z, double mainXz, double mainY, double limitXz, double limitY)
{
	float t = blend_alpha(mcn_stack_point(hm, (double)x * mainXz, (double)y * mainY, (double)z * mainXz));
	if (t == 0.0f)
		return mcn_stack_point(hlo, (double)x * limitXz, (double)y * limitY, (double)z * limitXz);
	if (t == 1.0f)
		return mcn_stack_point(hhi, (double)x * limitXz, (double)y * limitY, (double)z * limitXz);
	float a = mcn_stack_point(hlo, (double)x * limitXz, (double)y * limitY, (double)z * limitXz);
	float b = mcn_stack_point(hhi, (double)x * limitXz, (double)y * limitY, (double)z * limitXz);
	return lerpf(t, a, b);
}
