// The far terrain's transition probe (-Dmcopt.lod.seam, LodSeam.java, mcopt/lod/seam.metal): one compute dispatch at the
// end of the level over the main target's color and depth. Only called with the probe on.
#import "mcmetal.h"
#include <string.h>

typedef struct {
	Ctx *ctx;
	id<MTLComputePipelineState> probe, blob, publish, taa;
	id<MTLTexture> colorCopy, depthCopy;   // readable copies when the game's textures aren't shader-readable
	id<MTLTexture> taaTex[2];              // -Dmcopt.lod.taa: the filter's output and history, ping-ponged
	int taaCur;
	id<MTLFunction> tileFn;                // -Dmcopt.lod.taaTile: the tile function and its pipeline (for one colour format)
	id<MTLRenderPipelineState> tilePso;
	MTLPixelFormat tileFormat;
	id<MTLTexture> tileTex[2];
	int tileCur;
} LodSeam;

LodSeam *mcl_seam_new(Ctx *ctx, const char *source, char *err, int errCap) {
	@autoreleasepool {
		MTLCompileOptions *o = [[MTLCompileOptions new] autorelease];
		o.languageVersion = MTLLanguageVersion3_1;
		o.mathMode = MTLMathModeSafe;
		NSError *e = nil;
		id<MTLLibrary> lib = [[ctx->device newLibraryWithSource:[NSString stringWithUTF8String:source] options:o error:&e] autorelease];
		if (!lib) {
			snprintf(err, errCap, "seam.metal: %s", e ? e.description.UTF8String : "?");
			return NULL;
		}
		id<MTLFunction> fn = [[lib newFunctionWithName:@"seam_probe"] autorelease];
		id<MTLComputePipelineState> pso = fn ? [ctx->device newComputePipelineStateWithFunction:fn error:&e] : nil;
		if (!pso) {
			snprintf(err, errCap, "seam_probe: %s", e ? e.description.UTF8String : "no function");
			return NULL;
		}
		id<MTLFunction> fb = [[lib newFunctionWithName:@"seam_blob"] autorelease];
		id<MTLComputePipelineState> blob = fb ? [ctx->device newComputePipelineStateWithFunction:fb error:&e] : nil;
		if (!blob) {
			snprintf(err, errCap, "seam_blob: %s", e ? e.description.UTF8String : "no function");
			return NULL;
		}
		id<MTLFunction> fp = [[lib newFunctionWithName:@"seam_publish"] autorelease];
		id<MTLComputePipelineState> publish = fp ? [ctx->device newComputePipelineStateWithFunction:fp error:&e] : nil;
		if (!publish) {
			snprintf(err, errCap, "seam_publish: %s", e ? e.description.UTF8String : "no function");
			return NULL;
		}
		id<MTLFunction> ft = [[lib newFunctionWithName:@"seam_taa"] autorelease];
		id<MTLComputePipelineState> taa = ft ? [ctx->device newComputePipelineStateWithFunction:ft error:&e] : nil;
		if (!taa) {
			snprintf(err, errCap, "seam_taa: %s", e ? e.description.UTF8String : "no function");
			return NULL;
		}
		LodSeam *s = calloc(1, sizeof(LodSeam));
		s->tileFn = [lib newFunctionWithName:@"seam_tile"];
		s->taa = taa;
		s->publish = publish;
		s->ctx = ctx;
		s->probe = pso;
		s->blob = blob;
		return s;
	}
}

// A shared, hazard-tracked buffer (frames read what earlier frames wrote).
id<MTLBuffer> mcl_seam_buffer(Ctx *ctx, uint64_t size) {
	id<MTLBuffer> b = [ctx->device newBufferWithLength:size options:MTLResourceStorageModeShared];
	memset(b.contents, 0, size);
	return b;
}

static id<MTLTexture> readable(LodSeam *s, Enc *enc, id<MTLTexture> t, id<MTLTexture> *copy) {
	if (t.usage & MTLTextureUsageShaderRead) return t;
	if (!*copy || (*copy).width != t.width || (*copy).height != t.height || (*copy).pixelFormat != t.pixelFormat) {
		if (*copy) [*copy release];
		MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:t.pixelFormat width:t.width height:t.height mipmapped:NO];
		d.usage = MTLTextureUsageShaderRead;
		d.storageMode = MTLStorageModePrivate;
		*copy = [s->ctx->device newTextureWithDescriptor:d];
	}
	id<MTLBlitCommandEncoder> b = [mc_frame_cmd(enc) blitCommandEncoder];
	[b copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(t.width, t.height, 1) toTexture:*copy
		destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
	[b endEncoding];
	return *copy;
}

// Returns 0, or -1 when the textures don't fit (no dispatch).
int mcl_seam_probe(LodSeam *s, Enc *enc, id<MTLTexture> color, id<MTLTexture> depth, const void *frame, int frameLength, id<MTLBuffer> ring,
	id<MTLBuffer> marks, id<MTLBuffer> stats, id<MTLBuffer> changes, int width, int height) {
	if (!color || !depth || (int) color.width != width || (int) color.height != height || (int) depth.width != width || (int) depth.height != height) return -1;
	@autoreleasepool {
		mc_frame_cmd(enc);
		id<MTLTexture> c = readable(s, enc, color, &s->colorCopy);
		id<MTLTexture> d = readable(s, enc, depth, &s->depthCopy);
		id<MTLComputeCommandEncoder> ce = [mc_frame_cmd(enc) computeCommandEncoder];
		ce.label = @"lod seam probe";
		[ce setComputePipelineState:s->probe];
		[ce setBytes:frame length:frameLength atIndex:0];
		[ce setBuffer:ring offset:0 atIndex:1];
		[ce setBuffer:marks offset:0 atIndex:2];
		[ce setBuffer:stats offset:0 atIndex:3];
		[ce setBuffer:changes offset:0 atIndex:4];
		[ce setTexture:c atIndex:0];
		[ce setTexture:d atIndex:1];
		[ce dispatchThreads:MTLSizeMake((NSUInteger) width, (NSUInteger) height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
		[ce memoryBarrierWithScope:MTLBarrierScopeBuffers];
		[ce setComputePipelineState:s->blob];
		[ce dispatchThreads:MTLSizeMake((NSUInteger) width, (NSUInteger) height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
		[ce endEncoding];
	}
	return 0;
}

// -Dmcopt.lod.publish=gpu: count staged tiles' words into the clipmap, in the pre command buffer (before the cull, which
// opens its own encoder after this one). The destination buffers are hazard-tracked (LodClip with publish=gpu).
void mcl_seam_publish(LodSeam *s, Enc *enc, const void *frame, int frameLength, id<MTLBuffer> tiles, id<MTLBuffer> staging, id<MTLBuffer> geom,
	id<MTLBuffer> color, id<MTLBuffer> crown, id<MTLBuffer> tex, int count) {
	if (count <= 0) return;
	mc_pre_end_encoders(enc);
	@autoreleasepool {
		id<MTLComputeCommandEncoder> c = [mc_pre(enc) computeCommandEncoder];
		c.label = @"lod publish";
		[c setComputePipelineState:s->publish];
		[c setBytes:frame length:frameLength atIndex:0];
		[c setBuffer:tiles offset:0 atIndex:1];
		[c setBuffer:staging offset:0 atIndex:2];
		[c setBuffer:geom offset:0 atIndex:3];
		[c setBuffer:color offset:0 atIndex:4];
		[c setBuffer:crown offset:0 atIndex:5];
		[c setBuffer:tex offset:0 atIndex:6];
		[c dispatchThreads:MTLSizeMake(4096, (NSUInteger) count, 1) threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
		[c endEncoding];
	}
}

// -Dmcopt.lod.taa (LodTaa): the far terrain's temporal filter over rows [r0, r0 + rows) of the frame, at the end of the level.
// Returns 1 when the history textures were (re)made (the caller restarts its history), 0 otherwise, -1 when it can't run.
int mcl_seam_taa(LodSeam *s, Enc *enc, id<MTLTexture> color, id<MTLTexture> depth, const void *frame, int frameLength, int r0, int rows) {
	if (!color || !depth || color.width != depth.width || color.height != depth.height || rows <= 0) return -1;
	int made = 0;
	@autoreleasepool {
		if (!s->taaTex[0] || s->taaTex[0].width != color.width || s->taaTex[0].height != color.height || s->taaTex[0].pixelFormat != color.pixelFormat) {
			for (int i = 0; i < 2; i++) {
				if (s->taaTex[i]) [s->taaTex[i] release];
				MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:color.pixelFormat width:color.width height:color.height mipmapped:NO];
				d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
				d.storageMode = MTLStorageModePrivate;
				s->taaTex[i] = [s->ctx->device newTextureWithDescriptor:d];
			}
			made = 1;
		}
		mc_frame_cmd(enc);
		id<MTLTexture> c = readable(s, enc, color, &s->colorCopy);
		id<MTLTexture> d = readable(s, enc, depth, &s->depthCopy);
		id<MTLTexture> out = s->taaTex[s->taaCur], hist = s->taaTex[1 - s->taaCur];
		id<MTLComputeCommandEncoder> ce = [mc_frame_cmd(enc) computeCommandEncoder];
		ce.label = @"lod taa";
		[ce setComputePipelineState:s->taa];
		[ce setBytes:frame length:frameLength atIndex:0];
		[ce setTexture:c atIndex:0];
		[ce setTexture:d atIndex:1];
		[ce setTexture:hist atIndex:2];
		[ce setTexture:out atIndex:3];
		[ce dispatchThreads:MTLSizeMake(color.width, (NSUInteger) rows, 1) threadsPerThreadgroup:MTLSizeMake(32, 8, 1)];
		[ce endEncoding];
		id<MTLBlitCommandEncoder> b = [mc_frame_cmd(enc) blitCommandEncoder];
		b.label = @"lod taa copy";
		[b copyFromTexture:out sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, (NSUInteger) r0, 0) sourceSize:MTLSizeMake(color.width, (NSUInteger) rows, 1)
			toTexture:color destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, (NSUInteger) r0, 0)];
		[b endEncoding];
		s->taaCur = 1 - s->taaCur;
	}
	return made;
}

// ---- -Dmcopt.lod.taa in the mesh's fragment stage (mclod.m binds these when gSeamTaaOn) ----

int gSeamTaaOn;
id<MTLTexture> gSeamTaaHist;
uint8_t gSeamTaaBytes[96];
static id<MTLTexture> gSeamTaaTex;

// The constants for this frame's draw (SeamTaaFrame: prevVP, camDelta, params).
void mcl_seam_taa_set(const void *bytes, int length) {
	memcpy(gSeamTaaBytes, bytes, length < (int) sizeof gSeamTaaBytes ? (size_t) length : sizeof gSeamTaaBytes);
	gSeamTaaOn = gSeamTaaTex != nil;
	gSeamTaaHist = gSeamTaaTex;
}

// Top of the level: the previous frame's picture (still in the main target: nothing cleared it yet) over rows [r0, r0 + rows)
// into the history. Returns 1 when the history texture was (re)made (its contents aren't a frame yet), 0 otherwise.
int mcl_seam_taa_history(Ctx *ctx, Enc *enc, id<MTLTexture> color, int r0, int rows) {
	int made = 0;
	@autoreleasepool {
		if (!gSeamTaaTex || gSeamTaaTex.width != color.width || gSeamTaaTex.height != color.height || gSeamTaaTex.pixelFormat != color.pixelFormat) {
			if (gSeamTaaTex) [gSeamTaaTex release];
			MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:color.pixelFormat width:color.width height:color.height mipmapped:NO];
			d.usage = MTLTextureUsageShaderRead;
			d.storageMode = MTLStorageModePrivate;
			gSeamTaaTex = [ctx->device newTextureWithDescriptor:d];
			made = 1;
		}
		if (rows > 0 && r0 >= 0 && r0 + rows <= (int) color.height) {
			id<MTLBlitCommandEncoder> b = mc_blit(enc);
			[b copyFromTexture:color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, (NSUInteger) r0, 0) sourceSize:MTLSizeMake(color.width, (NSUInteger) rows, 1)
				toTexture:gSeamTaaTex destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, (NSUInteger) r0, 0)];
		}
	}
	return made;
}

// -Dmcopt.lod.taaTile (LodTaa): the far filter as a tile function dispatched inside the open level encoder (the frame's
// colour stays in tile memory: nothing is stored or reloaded). mode 1: the bare dispatch (an empty kernel), 2: the filter.
// Returns 1 when its history was (re)made, 0 when it ran, -1 when it couldn't (no open render encoder with one colour
// attachment, or no pipeline); err gets the reason once.
int mcl_seam_tile(LodSeam *s, Enc *enc, const void *frame, int frameLength, char *err, int errCap) {
	id<MTLRenderCommandEncoder> r = enc->render;
	if (!r || enc->colorCount != 1 || !enc->colors[0] || !s->tileFn) return -1;
	id<MTLTexture> color = enc->colors[0];
	int made = 0;
	@autoreleasepool {
		if (!s->tilePso || s->tileFormat != color.pixelFormat) {
			if (s->tilePso) [s->tilePso release];
			MTLTileRenderPipelineDescriptor *d = [[MTLTileRenderPipelineDescriptor new] autorelease];
			d.tileFunction = s->tileFn;
			d.colorAttachments[0].pixelFormat = color.pixelFormat;
			d.rasterSampleCount = 1;
			d.threadgroupSizeMatchesTileSize = YES;
			NSError *e = nil;
			s->tilePso = [s->ctx->device newRenderPipelineStateWithTileDescriptor:d options:MTLPipelineOptionNone reflection:nil error:&e];
			s->tileFormat = color.pixelFormat;
			if (!s->tilePso) {
				snprintf(err, errCap, "seam_tile pipeline: %s", e ? e.description.UTF8String : "?");
				return -1;
			}
		}
		if (!s->tileTex[0] || s->tileTex[0].width != color.width || s->tileTex[0].height != color.height || s->tileTex[0].pixelFormat != color.pixelFormat) {
			for (int i = 0; i < 2; i++) {
				if (s->tileTex[i]) [s->tileTex[i] release];
				MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:color.pixelFormat width:color.width height:color.height mipmapped:NO];
				td.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
				td.storageMode = MTLStorageModePrivate;
				s->tileTex[i] = [s->ctx->device newTextureWithDescriptor:td];
			}
			made = 1;
		}
		[r setRenderPipelineState:s->tilePso];
		[r setTileBytes:frame length:frameLength atIndex:0];
		[r setTileTexture:s->tileTex[1 - s->tileCur] atIndex:0];
		[r setTileTexture:s->tileTex[s->tileCur] atIndex:1];
		[r dispatchThreadsPerTile:MTLSizeMake(r.tileWidth, r.tileHeight, 1)];
		s->tileCur = 1 - s->tileCur;
	}
	return made;
}
