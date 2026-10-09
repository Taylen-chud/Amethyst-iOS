#import "mcmetal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MCC_PAGE 65536

// buffer: out[0] length, [1] storageMode, [2] hazardTrackingMode, [3] CPU-visible
void mcc_buffer_info(id<MTLBuffer> b, int64_t *out) {
	out[0] = (int64_t) b.length;
	out[1] = (int64_t) b.storageMode;
	out[2] = (int64_t) b.hazardTrackingMode;
	out[3] = b.storageMode == MTLStorageModeShared ? 1 : 0;
}

// texture: out[0] pixelFormat, [1] textureType, [2] width, [3] height, [4] mips, [5] arrayLength, [6] usage, [7] storageMode,
// [8] has a parent (a view), [9] parentRelativeLevel, [10] parent mips, [11] parent usage, [12] parent width, [13] parent height,
// [14] parent pixelFormat, [15] parent handle, [16-18] texture buffer: buffer, offset, bytes per row
void mcc_texture_info(id<MTLTexture> t, int64_t *out) {
	out[0] = (int64_t) t.pixelFormat;
	out[1] = (int64_t) t.textureType;
	out[2] = (int64_t) t.width;
	out[3] = (int64_t) t.height;
	out[4] = (int64_t) t.mipmapLevelCount;
	out[5] = (int64_t) t.arrayLength;
	out[6] = (int64_t) t.usage;
	out[7] = (int64_t) t.storageMode;
	id<MTLTexture> p = t.parentTexture;
	out[8] = p ? 1 : 0;
	out[9] = p ? (int64_t) t.parentRelativeLevel : 0;
	out[10] = p ? (int64_t) p.mipmapLevelCount : 0;
	out[11] = p ? (int64_t) p.usage : 0;
	out[12] = p ? (int64_t) p.width : 0;
	out[13] = p ? (int64_t) p.height : 0;
	out[14] = p ? (int64_t) p.pixelFormat : 0;
	out[15] = (int64_t) (intptr_t) p;
	// [16] a texture buffer's buffer handle, [17] its offset, [18] its bytes per row
	id<MTLBuffer> tb = t.buffer;
	out[16] = (int64_t) (intptr_t) tb;
	out[17] = tb ? (int64_t) t.bufferOffset : 0;
	out[18] = tb ? (int64_t) t.bufferBytesPerRow : 0;
}

// the encoder's level pass: out[0] render open, [1] renderSerial, [2] colorCount, [3] width, [4] height, [5] depth handle,
// [6] depth pixelFormat, then per color (8): handle, pixelFormat
void mcc_enc_state(Enc *enc, int64_t *out) {
	out[0] = enc->render ? 1 : 0;
	out[1] = (int64_t) enc->renderSerial;
	out[2] = enc->colorCount;
	out[3] = enc->width;
	out[4] = enc->height;
	out[5] = (int64_t) (intptr_t) enc->depth;
	out[6] = enc->depth ? (int64_t) enc->depth.pixelFormat : 0;
	for (int i = 0; i < MAX_COLORS; i++) {
		out[7 + 2 * i] = i < enc->colorCount ? (int64_t) (intptr_t) enc->colors[i] : 0;
		out[8 + 2 * i] = i < enc->colorCount && enc->colors[i] ? (int64_t) enc->colors[i].pixelFormat : 0;
	}
}

// Up to len bytes of b at offset (clamped to its length) into out; -1 if b isn't CPU-visible.
int mcc_bytes(id<MTLBuffer> b, int64_t offset, int len, void *out) {
	if (b.storageMode != MTLStorageModeShared) return -1;
	int64_t n = (int64_t) b.length - offset;
	if (n > len) n = len;
	if (n <= 0) return 0;
	memcpy(out, (const uint8_t *) b.contents + offset, (size_t) n);
	return (int) n;
}

// ---- the page store: pages.bin (unique pages, each MCC_PAGE bytes, zero-padded), a hash table in memory ----

typedef struct {
	FILE *pages;
	uint64_t *keys;   // hash (0 = empty)
	uint32_t *vals;   // page index
	uint32_t cap, used, count;
} Store;

static Store store;

static uint64_t pageHash(const uint8_t *p, size_t n) {
	// four multiply-xor lanes over 8-byte words; the tail word-padded with zeros (pages are zero-padded on disk too)
	uint64_t h[4] = {0x9E3779B97F4A7C15ull, 0xC2B2AE3D27D4EB4Full, 0x165667B19E3779F9ull, 0x27D4EB2F165667C5ull};
	size_t words = n / 8, i = 0;
	const uint64_t *w = (const uint64_t *) p;
	for (; i + 4 <= words; i += 4) {
		for (int k = 0; k < 4; k++) {
			h[k] ^= w[i + k];
			h[k] *= 0x100000001B3ull;
			h[k] ^= h[k] >> 29;
		}
	}
	for (; i < words; i++) {
		h[0] ^= w[i];
		h[0] *= 0x100000001B3ull;
		h[0] ^= h[0] >> 29;
	}
	uint64_t tail = 0;
	if (n % 8) memcpy(&tail, p + words * 8, n % 8);
	h[1] ^= tail;
	uint64_t r = h[0] ^ (h[1] * 31) ^ (h[2] * 131) ^ (h[3] * 1031) ^ (uint64_t) n;
	r ^= r >> 33;
	r *= 0xFF51AFD7ED558CCDull;
	r ^= r >> 33;
	return r ? r : 1;
}

// Opens (truncates) dir/pages.bin; resets the table. 0 ok.
int mcc_store_open(const char *path) {
	if (store.pages) fclose(store.pages);
	free(store.keys);
	free(store.vals);
	memset(&store, 0, sizeof store);
	store.pages = fopen(path, "wb");
	if (!store.pages) return -1;
	store.cap = 1 << 16;
	store.keys = calloc(store.cap, 8);
	store.vals = calloc(store.cap, 4);
	return 0;
}

void mcc_store_close(void) {
	if (store.pages) fclose(store.pages);
	store.pages = NULL;
}

static void storeGrow(void) {
	uint32_t oc = store.cap;
	uint64_t *ok = store.keys;
	uint32_t *ov = store.vals;
	store.cap = oc * 2;
	store.keys = calloc(store.cap, 8);
	store.vals = calloc(store.cap, 4);
	for (uint32_t i = 0; i < oc; i++) {
		if (!ok[i]) continue;
		uint32_t j = (uint32_t) ok[i] & (store.cap - 1);
		while (store.keys[j]) j = (j + 1) & (store.cap - 1);
		store.keys[j] = ok[i];
		store.vals[j] = ov[i];
	}
	free(ok);
	free(ov);
}

static uint8_t padPage[MCC_PAGE];

static uint32_t storePage(const uint8_t *p, size_t n) {
	uint64_t h = pageHash(p, n);
	uint32_t j = (uint32_t) h & (store.cap - 1);
	while (store.keys[j]) {
		if (store.keys[j] == h) return store.vals[j];  // (64-bit hash: a collision is taken as equal)
		j = (j + 1) & (store.cap - 1);
	}
	uint32_t idx = store.count++;
	if (n == MCC_PAGE) fwrite(p, 1, MCC_PAGE, store.pages);
	else {
		memset(padPage, 0, sizeof padPage);
		memcpy(padPage, p, n);
		fwrite(padPage, 1, MCC_PAGE, store.pages);
	}
	store.keys[j] = h;
	store.vals[j] = idx;
	if (++store.used * 2 > store.cap) storeGrow();
	return idx;
}

// The CPU-visible buffer b, page by page into the store: idx receives one page index a page (cap entries at most). The page count,
// or -1 (not CPU-visible, too many pages, no store).
int64_t mcc_snap(id<MTLBuffer> b, uint32_t *idx, int64_t cap) {
	if (!store.pages || b.storageMode != MTLStorageModeShared) return -1;
	uint64_t len = b.length;
	int64_t pages = (int64_t) ((len + MCC_PAGE - 1) / MCC_PAGE);
	if (pages > cap) return -1;
	const uint8_t *p = b.contents;
	for (int64_t i = 0; i < pages; i++) {
		uint64_t off = (uint64_t) i * MCC_PAGE, n = len - off < MCC_PAGE ? len - off : MCC_PAGE;
		idx[i] = storePage(p + off, (size_t) n);
	}
	fflush(store.pages);
	return pages;
}

// ---- texture copies out of the open level pass ----

static int texelBytes(MTLPixelFormat f) {
	switch ((int) f) {
		case 13: case 14: return 1;                                  // R8Uint, R8Sint
		case 20: case 22: case 23: case 24: case 32: case 33: case 34: return 2;  // R16Unorm/Snorm/Uint/Sint, RG8Snorm/Uint/Sint
		case 53: case 54: case 60: case 62: case 63: case 64: case 65: case 72: case 73: case 74: case 91: case 93: case 94: return 4;
		case 103: case 104: case 110: case 112: case 113: case 114: return 8;
		case 123: case 124: return 16;
		case 250: return 2;                                          // Depth16Unorm
		default: break;
	}
	switch (f) {
		case MTLPixelFormatR8Unorm: return 1;
		case MTLPixelFormatRG8Unorm: case MTLPixelFormatR16Float: return 2;
		case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB: case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatBGRA8Unorm_sRGB:
		case MTLPixelFormatR32Float: case MTLPixelFormatDepth32Float: case MTLPixelFormatRGB10A2Unorm: case MTLPixelFormatRG16Float:
		case MTLPixelFormatR32Uint: case MTLPixelFormatRG11B10Float:
			return 4;
		case MTLPixelFormatRGBA16Float: case MTLPixelFormatRG32Float: case MTLPixelFormatDepth32Float_Stencil8: return 8;
		case MTLPixelFormatRGBA32Float: return 16;
		default: return 0;
	}
}

// Every mip and slice of texture t into a new shared buffer (blit b); levels laid out one after another, rows tight. The bytes
// per texel go to *bpp (Depth32Float_Stencil8: its depth only, 4). nil if the format isn't handled.
static id<MTLBuffer> copyOut(id<MTLDevice> dev, id<MTLBlitCommandEncoder> b, id<MTLTexture> t, int *bpp) {
	int tb = texelBytes(t.pixelFormat);
	if (!tb || t.storageMode == MTLStorageModeMemoryless) return nil;
	MTLBlitOption opt = MTLBlitOptionNone;
	if (t.pixelFormat == MTLPixelFormatDepth32Float_Stencil8) {
		tb = 4;
		opt = MTLBlitOptionDepthFromDepthStencil;
	}
	*bpp = tb;
	NSUInteger slices = t.textureType == MTLTextureTypeCube ? 6 : t.arrayLength, total = 0;
	for (NSUInteger m = 0; m < t.mipmapLevelCount; m++) total += MAX(1, t.width >> m) * MAX(1, t.height >> m) * tb * slices;
	id<MTLBuffer> out = [dev newBufferWithLength:total options:MTLResourceStorageModeShared];
	NSUInteger at = 0;
	for (NSUInteger s = 0; s < slices; s++) {
		for (NSUInteger m = 0; m < t.mipmapLevelCount; m++) {
			NSUInteger w = MAX(1, t.width >> m), h = MAX(1, t.height >> m);
			[b copyFromTexture:t sourceSlice:s sourceLevel:m sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1) toBuffer:out
				destinationOffset:at destinationBytesPerRow:w * tb destinationBytesPerImage:w * h * tb options:opt];
			at += w * h * tb;
		}
	}
	return out;
}

// In the open level pass of enc: split it once, copy each of the n textures (all mips) out, reopen it (the caller rebinds the
// pass's state, MetalBridge.restorePass). When the frame completes each lands in paths[i]: header "MCTX" + {format, width,
// height, mips, slices, bytes per texel} as int32, then the levels. 1 done, 0 no pass open, -1 a format not handled.
int mcc_split_copy(Enc *enc, int n, id<MTLTexture> const *texs, const char *const *paths) {
	if (!enc->render) return 0;
	@autoreleasepool {
	id<MTLComputeCommandEncoder> c = mc_render_suspend(enc);
	[c endEncoding];
	[c release];
	id<MTLCommandBuffer> cmd = enc->cmd;
	id<MTLBlitCommandEncoder> b = [cmd blitCommandEncoder];
	int ok = 1;
	NSMutableArray *bufs = [NSMutableArray array], *heads = [NSMutableArray array], *names = [NSMutableArray array];
	for (int i = 0; i < n; i++) {
		id<MTLTexture> t = texs[i];
		if (!t) continue;
		int bpp = 0;
		id<MTLBuffer> out = copyOut(enc->ctx->device, b, t, &bpp);
		if (!out) {
			fprintf(stderr, "mcopt-own capture: texture format %d not handled (%s)\n", (int) t.pixelFormat, paths[i]);
			ok = -1;
			continue;
		}
		int32_t head[7] = {0x5854434D, (int32_t) t.pixelFormat, (int32_t) t.width, (int32_t) t.height, (int32_t) t.mipmapLevelCount,
			(int32_t) (t.textureType == MTLTextureTypeCube ? 6 : t.arrayLength), bpp};
		[bufs addObject:out];
		[out release];
		[heads addObject:[NSData dataWithBytes:head length:sizeof head]];
		[names addObject:[NSString stringWithUTF8String:paths[i]]];
	}
	[b endEncoding];
	[cmd addCompletedHandler:^(id<MTLCommandBuffer> done) {
		for (NSUInteger i = 0; i < bufs.count; i++) {
			FILE *f = fopen([names[i] UTF8String], "wb");
			if (!f) continue;
			fwrite([heads[i] bytes], 1, [heads[i] length], f);
			id<MTLBuffer> out = bufs[i];
			fwrite(out.contents, 1, out.length, f);
			fclose(f);
		}
	}];
	mc_render_resume(enc, mc_profiled_compute(enc, cmd, MTLDispatchTypeConcurrent));
	return ok;
	}
}

// Frame mode (FrameCapture.afterCommit): the contents of n objects (kinds[i] 0: texture, all mips and slices; 1: buffer) copied on a
// command buffer of their own, committed now: queued after everything committed so far, so it sees the state the next frame starts
// from. Each lands in paths[i] when done (textures as copyOut's .tex, buffers raw). 1 queued, -1 a texture format not handled.
int mcc_copy_out(Ctx *ctx, int n, id const *objs, const int *kinds, const char *const *paths) {
	@autoreleasepool {
		id<MTLCommandBuffer> cmd = [ctx->queue commandBuffer];
		id<MTLBlitCommandEncoder> b = [cmd blitCommandEncoder];
		int ok = 1;
		NSMutableArray *bufs = [NSMutableArray array], *heads = [NSMutableArray array], *names = [NSMutableArray array];
		for (int i = 0; i < n; i++) {
			if (!objs[i]) continue;
			id<MTLBuffer> out = nil;
			NSData *head = [NSData data];
			if (kinds[i] == 1) {
				id<MTLBuffer> src = objs[i];
				out = [ctx->device newBufferWithLength:src.length options:MTLResourceStorageModeShared];
				[b copyFromBuffer:src sourceOffset:0 toBuffer:out destinationOffset:0 size:src.length];
			} else {
				id<MTLTexture> t = objs[i];
				if (t.buffer) continue;  // (a texture over a buffer: its contents are the buffer's, captured as pages)
				int bpp = 0;
				out = copyOut(ctx->device, b, t, &bpp);
				if (!out) {
					fprintf(stderr, "mcopt-own capture: texture format %d not handled (%s)\n", (int) t.pixelFormat, paths[i]);
					ok = -1;
					continue;
				}
				int32_t h[7] = {0x5854434D, (int32_t) t.pixelFormat, (int32_t) t.width, (int32_t) t.height, (int32_t) t.mipmapLevelCount,
					(int32_t) (t.textureType == MTLTextureTypeCube ? 6 : t.arrayLength), bpp};
				head = [NSData dataWithBytes:h length:sizeof h];
			}
			[bufs addObject:out];
			[out release];
			[heads addObject:head];
			[names addObject:[NSString stringWithUTF8String:paths[i]]];
		}
		[b endEncoding];
		[cmd addCompletedHandler:^(id<MTLCommandBuffer> done) {
			for (NSUInteger i = 0; i < bufs.count; i++) {
				FILE *f = fopen([names[i] UTF8String], "wb");
				if (!f) continue;
				fwrite([heads[i] bytes], 1, [heads[i] length], f);
				id<MTLBuffer> out = bufs[i];
				fwrite(out.contents, 1, out.length, f);
				fclose(f);
			}
		}];
		[cmd commit];
		return ok;
	}
}

// CPU analysis opt-in: a completed, coherent producer-output bundle. This is
// deliberately separate from replay's async discovery/start-state copies.
// Called after main commit and before Java begins the next frame/cull/reset.
// Waiting is measurement-only; these frames are not performance evidence.
int mcc_copy_buffers_completed(Ctx *ctx, int n, id<MTLBuffer> const *src, const char *const *paths) {
	@autoreleasepool {
		if (n <= 0 || n > 64) return -1;
		id<MTLCommandBuffer> cmd = [ctx->queue commandBuffer];
		id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
		NSMutableArray *outputs = [NSMutableArray arrayWithCapacity:(NSUInteger) n];
		for (int i = 0; i < n; i++) {
			if (!src[i] || !paths[i] || !src[i].length) {
				[blit endEncoding];
				return -1;
			}
			id<MTLBuffer> out = [ctx->device newBufferWithLength:src[i].length options:MTLResourceStorageModeShared];
			if (!out) {
				[blit endEncoding];
				return -2;
			}
			[blit copyFromBuffer:src[i] sourceOffset:0 toBuffer:out destinationOffset:0 size:src[i].length];
			[outputs addObject:out];
			[out release];
		}
		[blit endEncoding];
		[cmd commit];
		[cmd waitUntilCompleted];
		if (cmd.status != MTLCommandBufferStatusCompleted) return -3;
		for (int i = 0; i < n; i++) {
			id<MTLBuffer> out = outputs[(NSUInteger) i];
			FILE *f = fopen(paths[i], "wb");
			if (!f) return -4;
			size_t wrote = fwrite(out.contents, 1, out.length, f);
			int closed = fclose(f);
			if (wrote != out.length || closed) return -5;
		}
		return 1;
	}
}
