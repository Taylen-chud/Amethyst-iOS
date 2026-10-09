#import "mcmetal.h"
#include <dispatch/dispatch.h>
#include <stdatomic.h>
#include <string.h>

#define REC_SLOTS_MAX 16
enum { SLOT_FREE, SLOT_GPU, SLOT_READY, SLOT_FAILED };

typedef struct {
	Ctx *ctx;
	id<MTLComputePipelineState> pso;
	id<MTLBuffer> slots[REC_SLOTS_MAX];
	int slotCount;
	_Atomic int state[REC_SLOTS_MAX];
	_Atomic int64_t frame[REC_SLOTS_MAX];
	dispatch_semaphore_t ready;
	id<MTLTexture> copy;  // a readable copy, only if the frame's texture isn't shader-readable
} Rec;

Rec *mcr_new(Ctx *ctx, const char *source, int slots, uint64_t slotBytes, char *err, int errCap) {
	@autoreleasepool {
		if (slots < 1 || slots > REC_SLOTS_MAX) {
			snprintf(err, errCap, "slots %d out of range", slots);
			return NULL;
		}
		MTLCompileOptions *o = [[MTLCompileOptions new] autorelease];
		o.languageVersion = MTLLanguageVersion3_1;
		NSError *e = nil;
		id<MTLLibrary> lib = [[ctx->device newLibraryWithSource:[NSString stringWithUTF8String:source] options:o error:&e] autorelease];
		if (!lib) {
			snprintf(err, errCap, "rec.metal: %s", e ? e.description.UTF8String : "?");
			return NULL;
		}
		id<MTLFunction> fn = [[lib newFunctionWithName:@"rec_yuv"] autorelease];
		id<MTLComputePipelineState> pso = fn ? [ctx->device newComputePipelineStateWithFunction:fn error:&e] : nil;
		if (!pso) {
			snprintf(err, errCap, "rec_yuv: %s", e ? e.description.UTF8String : "no function");
			return NULL;
		}
		Rec *r = calloc(1, sizeof(Rec));
		r->ctx = ctx;
		r->pso = pso;
		r->slotCount = slots;
		for (int i = 0; i < slots; i++) {
			r->slots[i] = [ctx->device newBufferWithLength:slotBytes options:MTLResourceStorageModeShared];
			if (!r->slots[i]) {
				snprintf(err, errCap, "slot buffer of %llu bytes failed", (unsigned long long) slotBytes);
				return NULL;
			}
			atomic_store(&r->state[i], SLOT_FREE);
		}
		r->ready = dispatch_semaphore_create(0);
		return r;
	}
}

// A free slot, now owned by the caller (the render thread), or -1 when every slot is on the GPU or with the writer.
int mcr_take(Rec *r) {
	for (int i = 0; i < r->slotCount; i++) {
		int expected = SLOT_FREE;
		if (atomic_compare_exchange_strong(&r->state[i], &expected, SLOT_GPU)) return i;
	}
	return -1;
}

// Hands a slot taken with mcr_take back without using it.
void mcr_untake(Rec *r, int slot) {
	atomic_store(&r->state[slot], SLOT_FREE);
}

// Encodes the conversion of src into slot (taken with mcr_take) at the end of the frame's command buffer. gridW x gridH:
// output blocks of 2 x 2. Returns 0, or -1 when nothing was encoded (the slot is free again).
int mcr_capture(Rec *r, Enc *enc, id<MTLTexture> src, int slot, int64_t frame, const void *params, int paramsLength, int gridW, int gridH) {
	if (!src || slot < 0 || slot >= r->slotCount) return -1;
	@autoreleasepool {
		id<MTLCommandBuffer> cb = mc_frame_cmd(enc);
		id<MTLTexture> t = src;
		if (!(src.usage & MTLTextureUsageShaderRead)) {
			if (!r->copy || r->copy.width != src.width || r->copy.height != src.height || r->copy.pixelFormat != src.pixelFormat) {
				if (r->copy) [r->copy release];
				MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat width:src.width height:src.height mipmapped:NO];
				d.usage = MTLTextureUsageShaderRead;
				d.storageMode = MTLStorageModePrivate;
				r->copy = [r->ctx->device newTextureWithDescriptor:d];
			}
			id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
			[b copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(src.width, src.height, 1)
				toTexture:r->copy destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
			[b endEncoding];
			t = r->copy;
		}
		atomic_store(&r->frame[slot], frame);
		id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
		ce.label = @"mcopt rec";
		[ce setComputePipelineState:r->pso];
		[ce setTexture:t atIndex:0];
		[ce setBuffer:r->slots[slot] offset:0 atIndex:0];
		[ce setBytes:params length:paramsLength atIndex:1];
		[ce dispatchThreads:MTLSizeMake((NSUInteger) gridW, (NSUInteger) gridH, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
		[ce endEncoding];
		Rec *rr = r;
		int s = slot;
		[cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
			atomic_store(&rr->state[s], done.status == MTLCommandBufferStatusCompleted ? SLOT_READY : SLOT_FAILED);
			dispatch_semaphore_signal(rr->ready);
		}];
	}
	return 0;
}

// Writer thread: waits up to timeoutMs for a slot to finish on the GPU. Returns the finished slot with the lowest frame
// (ready or failed; mcr_state tells which), -1 on timeout.
int mcr_wait(Rec *r, int timeoutMs) {
	if (dispatch_semaphore_wait(r->ready, dispatch_time(DISPATCH_TIME_NOW, (int64_t) timeoutMs * NSEC_PER_MSEC)) != 0) return -1;
	int best = -1;
	int64_t bestFrame = 0;
	for (int i = 0; i < r->slotCount; i++) {
		int st = atomic_load(&r->state[i]);
		if (st != SLOT_READY && st != SLOT_FAILED) continue;
		int64_t f = atomic_load(&r->frame[i]);
		if (best < 0 || f < bestFrame) {
			best = i;
			bestFrame = f;
		}
	}
	return best;
}

int mcr_state(Rec *r, int slot) { return atomic_load(&r->state[slot]); }
int64_t mcr_frame(Rec *r, int slot) { return atomic_load(&r->frame[slot]); }
void *mcr_contents(Rec *r, int slot) { return r->slots[slot].contents; }

// Writer thread: done with a finished slot.
void mcr_release(Rec *r, int slot) {
	atomic_store(&r->state[slot], SLOT_FREE);
}

// Slots on the GPU or finished and not yet released (the writer drains to 0 before closing the file).
int mcr_busy(Rec *r) {
	int n = 0;
	for (int i = 0; i < r->slotCount; i++) n += atomic_load(&r->state[i]) != SLOT_FREE;
	return n;
}

// ---- in-process encoding (-Dmcopt.rec.codec=vt, the default) ----
// The kernel (rec_nv12_tex) writes each recorded frame into an IOSurface-backed NV12 pixel buffer from a pool, and
// VideoToolbox encodes that buffer in place: no copies, no raw frames through a pipe. A serial queue hands frames to the
// encoder in tick order (the last picture again for ticks without one, so the stream is constant 60 fps); the encoder's
// output (H.264, Annex B) goes through a pipe to ffmpeg, which only muxes it into the mp4 (-c copy). VideoToolbox and
// CoreMedia are opened here, at the recorder's start: without the recorder the process never loads them.
#include <CoreVideo/CoreVideo.h>
#include <CoreMedia/CoreMedia.h>
#include <VideoToolbox/VideoToolbox.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static __typeof__(VTCompressionSessionCreate) *pVTCreate;
static __typeof__(VTSessionSetProperty) *pVTSet;
static __typeof__(VTCompressionSessionPrepareToEncodeFrames) *pVTPrepare;
static __typeof__(VTCompressionSessionEncodeFrame) *pVTEncode;
static __typeof__(VTCompressionSessionCompleteFrames) *pVTComplete;
static __typeof__(VTCompressionSessionInvalidate) *pVTInvalidate;
static __typeof__(CMSampleBufferGetDataBuffer) *pCMData;
static __typeof__(CMBlockBufferGetDataLength) *pCMLength;
static __typeof__(CMBlockBufferCopyDataBytes) *pCMCopy;
static __typeof__(CMSampleBufferGetFormatDescription) *pCMFormat;
static __typeof__(CMVideoFormatDescriptionGetH264ParameterSetAtIndex) *pCMParams;
static __typeof__(CMSampleBufferGetSampleAttachmentsArray) *pCMAttachments;
static CFStringRef kNotSync, kRealTime, kProfile, kHigh, kBitRate, kFrameRate, kKeyInterval, kReorder, kPrimaries, kTransfer, kMatrix, kRequireHw, kSpeed;

static int vtLoad(char *err, int errCap) {
	static int loaded;
	if (loaded) return 0;
	void *vt = dlopen("/System/Library/Frameworks/VideoToolbox.framework/VideoToolbox", RTLD_NOW | RTLD_LOCAL);
	void *cm = dlopen("/System/Library/Frameworks/CoreMedia.framework/CoreMedia", RTLD_NOW | RTLD_LOCAL);
	if (!vt || !cm) {
		snprintf(err, errCap, "can't open VideoToolbox/CoreMedia: %s", dlerror());
		return -1;
	}
#define FN(p, lib, name) if (!(p = dlsym(lib, name))) { snprintf(err, errCap, "missing %s", name); return -1; }
#define KEY(k, lib, name) { CFStringRef *s = dlsym(lib, name); if (!s) { snprintf(err, errCap, "missing %s", name); return -1; } k = *s; }
	FN(pVTCreate, vt, "VTCompressionSessionCreate")
	FN(pVTSet, vt, "VTSessionSetProperty")
	FN(pVTPrepare, vt, "VTCompressionSessionPrepareToEncodeFrames")
	FN(pVTEncode, vt, "VTCompressionSessionEncodeFrame")
	FN(pVTComplete, vt, "VTCompressionSessionCompleteFrames")
	FN(pVTInvalidate, vt, "VTCompressionSessionInvalidate")
	FN(pCMData, cm, "CMSampleBufferGetDataBuffer")
	FN(pCMLength, cm, "CMBlockBufferGetDataLength")
	FN(pCMCopy, cm, "CMBlockBufferCopyDataBytes")
	FN(pCMFormat, cm, "CMSampleBufferGetFormatDescription")
	FN(pCMParams, cm, "CMVideoFormatDescriptionGetH264ParameterSetAtIndex")
	FN(pCMAttachments, cm, "CMSampleBufferGetSampleAttachmentsArray")
	KEY(kNotSync, cm, "kCMSampleAttachmentKey_NotSync")
	KEY(kRealTime, vt, "kVTCompressionPropertyKey_RealTime")
	KEY(kProfile, vt, "kVTCompressionPropertyKey_ProfileLevel")
	KEY(kHigh, vt, "kVTProfileLevel_H264_High_AutoLevel")
	KEY(kBitRate, vt, "kVTCompressionPropertyKey_AverageBitRate")
	KEY(kFrameRate, vt, "kVTCompressionPropertyKey_ExpectedFrameRate")
	KEY(kKeyInterval, vt, "kVTCompressionPropertyKey_MaxKeyFrameInterval")
	KEY(kReorder, vt, "kVTCompressionPropertyKey_AllowFrameReordering")
	KEY(kPrimaries, vt, "kVTCompressionPropertyKey_ColorPrimaries")
	KEY(kTransfer, vt, "kVTCompressionPropertyKey_TransferFunction")
	KEY(kMatrix, vt, "kVTCompressionPropertyKey_YCbCrMatrix")
	KEY(kRequireHw, vt, "kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder")
	KEY(kSpeed, vt, "kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality")
#undef FN
#undef KEY
	loaded = 1;
	return 0;
}

typedef struct {
	Ctx *ctx;
	id<MTLComputePipelineState> pso;
	CVMetalTextureCacheRef cache;
	CVPixelBufferPoolRef pool;
	CFDictionaryRef aux;
	VTCompressionSessionRef vt;
	int w, h, timescale, perFrame;
	int fd;
	pid_t ffmpeg;
	dispatch_queue_t q;
	CVPixelBufferRef last;  // the picture of tick lastFrame (repeated for ticks without one)
	int64_t lastFrame;
	_Atomic int pending;
	_Atomic int64_t encoded, repeated, failed, late, dropped, bytes;
	uint8_t *au, *nal;      // Annex B access unit and the encoder's output (VideoToolbox's output thread only)
	size_t auCap, nalCap, auLen;
	int broken;
} RecVT;

static void auPut(RecVT *v, const void *p, size_t n) {
	if (v->auLen + n > v->auCap) {
		v->auCap = (v->auLen + n) * 2;
		v->au = realloc(v->au, v->auCap);
	}
	memcpy(v->au + v->auLen, p, n);
	v->auLen += n;
}

// VideoToolbox's output, one frame at a time in order: AVCC (length-prefixed NAL units) to Annex B (start codes, with the
// parameter sets in front of every keyframe), one write per frame into ffmpeg's pipe.
static void vtOutput(void *ref, void *frameRef, OSStatus status, VTEncodeInfoFlags flags, CMSampleBufferRef sb) {
	RecVT *v = ref;
	(void) frameRef;
	if (status != noErr || !sb || (flags & kVTEncodeInfo_FrameDropped)) {
		atomic_fetch_add(&v->failed, 1);
		return;
	}
	static const uint8_t start[4] = {0, 0, 0, 1};
	int key = 1;
	CFArrayRef att = pCMAttachments(sb, false);
	if (att && CFArrayGetCount(att) > 0) {
		CFDictionaryRef d = CFArrayGetValueAtIndex(att, 0);
		const void *notSync = NULL;
		if (CFDictionaryGetValueIfPresent(d, kNotSync, &notSync) && notSync == kCFBooleanTrue) key = 0;
	}
	v->auLen = 0;
	int nalLen = 4;
	if (key) {
		CMFormatDescriptionRef fmt = pCMFormat(sb);
		size_t count = 0;
		if (pCMParams(fmt, 0, NULL, NULL, &count, &nalLen) == noErr) {
			for (size_t i = 0; i < count; i++) {
				const uint8_t *ps;
				size_t n;
				if (pCMParams(fmt, i, &ps, &n, NULL, NULL) == noErr) {
					auPut(v, start, 4);
					auPut(v, ps, n);
				}
			}
		}
	}
	CMBlockBufferRef bb = pCMData(sb);
	size_t len = bb ? pCMLength(bb) : 0;
	if (len > v->nalCap) {
		v->nalCap = len * 2;
		v->nal = realloc(v->nal, v->nalCap);
	}
	if (!bb || pCMCopy(bb, 0, len, v->nal) != kCMBlockBufferNoErr) {
		atomic_fetch_add(&v->failed, 1);
		return;
	}
	for (size_t at = 0; at + (size_t) nalLen <= len;) {
		uint32_t n = 0;
		for (int i = 0; i < nalLen; i++) n = n << 8 | v->nal[at + i];
		at += (size_t) nalLen;
		if (at + n > len) break;
		auPut(v, start, 4);
		auPut(v, v->nal + at, n);
		at += n;
	}
	for (size_t done = 0; !v->broken && done < v->auLen;) {
		ssize_t w = write(v->fd, v->au + done, v->auLen - done);
		if (w > 0) done += (size_t) w;
		else if (w < 0 && errno == EINTR) continue;
		else v->broken = 1;  // ffmpeg gone: count the frames, write nothing more
	}
	atomic_fetch_add(&v->bytes, (int64_t) v->auLen);
	atomic_fetch_add(&v->encoded, 1);
}

static void cfSetInt(VTCompressionSessionRef s, CFStringRef k, int64_t value) {
	CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt64Type, &value);
	pVTSet(s, k, n);
	CFRelease(n);
}

// Opens the encoder and the muxer (ffmpeg -f h264 ... -c copy OUT, its messages into LOG). fps must be a whole number.
RecVT *mcr_vt_open(Ctx *ctx, const char *source, int w, int h, int fps, int64_t bitrate, int speed, const char *ffmpeg, const char *out,
	const char *log, char *err, int errCap) {
	@autoreleasepool {
		if (vtLoad(err, errCap) != 0) return NULL;
		MTLCompileOptions *o = [[MTLCompileOptions new] autorelease];
		o.languageVersion = MTLLanguageVersion3_1;
		NSError *e = nil;
		id<MTLLibrary> lib = [[ctx->device newLibraryWithSource:[NSString stringWithUTF8String:source] options:o error:&e] autorelease];
		id<MTLFunction> fn = lib ? [[lib newFunctionWithName:@"rec_nv12_tex"] autorelease] : nil;
		id<MTLComputePipelineState> pso = fn ? [ctx->device newComputePipelineStateWithFunction:fn error:&e] : nil;
		if (!pso) {
			snprintf(err, errCap, "rec_nv12_tex: %s", e ? e.description.UTF8String : "no function");
			return NULL;
		}
		RecVT *v = calloc(1, sizeof(RecVT));
		v->ctx = ctx;
		v->pso = pso;
		v->w = w;
		v->h = h;
		v->timescale = fps * 1000;
		v->perFrame = 1000;
		v->lastFrame = -1;
		v->fd = -1;
		if (CVMetalTextureCacheCreate(NULL, NULL, ctx->device, NULL, &v->cache) != kCVReturnSuccess) {
			snprintf(err, errCap, "CVMetalTextureCacheCreate failed");
			return NULL;
		}
		NSDictionary *pb = @{
			(id) kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
			(id) kCVPixelBufferWidthKey: @(w), (id) kCVPixelBufferHeightKey: @(h),
			(id) kCVPixelBufferIOSurfacePropertiesKey: @{}, (id) kCVPixelBufferMetalCompatibilityKey: @YES,
		};
		NSDictionary *poolAttrs = @{(id) kCVPixelBufferPoolMinimumBufferCountKey: @6};
		if (CVPixelBufferPoolCreate(NULL, (CFDictionaryRef) poolAttrs, (CFDictionaryRef) pb, &v->pool) != kCVReturnSuccess) {
			snprintf(err, errCap, "CVPixelBufferPoolCreate failed");
			return NULL;
		}
		// past this many buffers (on the GPU, with the encoder, the last picture) a tick is skipped instead of allocating more
		v->aux = (CFDictionaryRef) [@{(id) kCVPixelBufferPoolAllocationThresholdKey: @16} retain];
		NSDictionary *spec = @{(id) kRequireHw: @YES};
		OSStatus st = pVTCreate(NULL, w, h, kCMVideoCodecType_H264, (CFDictionaryRef) spec, NULL, NULL, vtOutput, v, &v->vt);
		if (st != noErr) {
			snprintf(err, errCap, "VTCompressionSessionCreate: %d", (int) st);
			return NULL;
		}
		pVTSet(v->vt, kRealTime, kCFBooleanTrue);
		pVTSet(v->vt, kProfile, kHigh);
		pVTSet(v->vt, kReorder, kCFBooleanFalse);
		cfSetInt(v->vt, kBitRate, bitrate);
		cfSetInt(v->vt, kFrameRate, fps);
		cfSetInt(v->vt, kKeyInterval, (int64_t) fps * 2);
		pVTSet(v->vt, kPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2);
		pVTSet(v->vt, kTransfer, kCVImageBufferTransferFunction_ITU_R_709_2);
		pVTSet(v->vt, kMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2);
		if (speed) pVTSet(v->vt, kSpeed, kCFBooleanTrue);
		pVTPrepare(v->vt);
		// the muxer: Annex B in, mp4 out, nothing re-encoded
		int pipeFd[2];
		if (pipe(pipeFd) != 0) {
			snprintf(err, errCap, "pipe: %s", strerror(errno));
			return NULL;
		}
		fcntl(pipeFd[1], F_SETNOSIGPIPE, 1);
		char rate[16], setts[96];
		snprintf(rate, sizeof rate, "%d", fps);
		// (a raw H.264 stream has no timestamps: frame n is at n / fps, no reordering)
		snprintf(setts, sizeof setts, "setts=pts=N/(%d*TB):dts=N/(%d*TB)", fps, fps);
		const char *argv[] = {ffmpeg, "-hide_banner", "-nostats", "-loglevel", "warning", "-y", "-f", "h264", "-framerate", rate, "-i", "pipe:0", "-c:v", "copy",
			"-bsf:v", setts,
			"-movflags", "+faststart", out, NULL};
		posix_spawn_file_actions_t fa;
		posix_spawn_file_actions_init(&fa);
		posix_spawn_file_actions_adddup2(&fa, pipeFd[0], 0);
		posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0);
		posix_spawn_file_actions_addopen(&fa, 2, log, O_WRONLY | O_CREAT | O_TRUNC, 0644);
		posix_spawnattr_t sa;
		posix_spawnattr_init(&sa);
		posix_spawnattr_setflags(&sa, POSIX_SPAWN_CLOEXEC_DEFAULT);  // only 0-2 go to the child
		int rc = posix_spawn(&v->ffmpeg, ffmpeg, &fa, &sa, (char *const *) argv, environ);
		posix_spawn_file_actions_destroy(&fa);
		posix_spawnattr_destroy(&sa);
		close(pipeFd[0]);
		if (rc != 0) {
			close(pipeFd[1]);
			snprintf(err, errCap, "can't start %s: %s", ffmpeg, strerror(rc));
			return NULL;
		}
		v->fd = pipeFd[1];
		v->q = dispatch_queue_create("mcopt.rec.vt", DISPATCH_QUEUE_SERIAL);
		return v;
	}
}

// (CMTime by hand: CMTimeMake and kCMTimeInvalid live in CoreMedia, which isn't linked)
static const CMTime noTime = {0, 0, 0, 0};

static void vtEncode(RecVT *v, CVPixelBufferRef pb, int64_t frame) {
	VTEncodeInfoFlags flags = 0;
	CMTime pts = {frame * v->perFrame, v->timescale, kCMTimeFlags_Valid, 0};
	if (pVTEncode(v->vt, pb, pts, noTime, NULL, NULL, &flags) != noErr) atomic_fetch_add(&v->failed, 1);
}

// Serial queue: frame `frame` is on its pixel buffer; ticks since the last frame get the last picture again.
static void vtSubmit(RecVT *v, CVPixelBufferRef pb, int64_t frame) {
	if (frame <= v->lastFrame) {
		atomic_fetch_add(&v->late, 1);
		return;
	}
	for (int64_t k = v->lastFrame + 1; k < frame; k++) {
		vtEncode(v, v->last ? v->last : pb, k);
		atomic_fetch_add(&v->repeated, 1);
	}
	vtEncode(v, pb, frame);
	if (v->last) CVPixelBufferRelease(v->last);
	v->last = CVPixelBufferRetain(pb);
	v->lastFrame = frame;
}

// Render thread: encodes tick `frame`'s conversion into a fresh pixel buffer at the end of the frame's command buffer.
// Returns 0; -2 when the pool is at its limit (skip this tick); -1 on failure.
int mcr_vt_capture(RecVT *v, Enc *enc, id<MTLTexture> src, int64_t frame, const void *params, int paramsLength, int gridW, int gridH) {
	if (!src || !(src.usage & MTLTextureUsageShaderRead)) return -1;
	// the texture cache keeps each texture (and its pixel buffer, out of the pool) until flushed, even once released
	CVMetalTextureCacheFlush(v->cache, 0);
	CVPixelBufferRef pb = NULL;
	CVReturn cr = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(NULL, v->pool, v->aux, &pb);
	if (cr == kCVReturnWouldExceedAllocationThreshold || !pb) {
		atomic_fetch_add(&v->dropped, 1);
		return -2;
	}
	CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
	CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
	CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
	CVMetalTextureRef ty = NULL, tuv = NULL;
	// (the cache's textures are shader-read only unless asked: the kernel writes them)
	static CFDictionaryRef writable;
	if (!writable) writable = (CFDictionaryRef) [@{(id) kCVMetalTextureUsage: @(MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite)} retain];
	CVMetalTextureCacheCreateTextureFromImage(NULL, v->cache, pb, writable, MTLPixelFormatR8Unorm, v->w, v->h, 0, &ty);
	CVMetalTextureCacheCreateTextureFromImage(NULL, v->cache, pb, writable, MTLPixelFormatRG8Unorm, v->w / 2, v->h / 2, 1, &tuv);
	id<MTLTexture> yt = ty ? CVMetalTextureGetTexture(ty) : nil, uvt = tuv ? CVMetalTextureGetTexture(tuv) : nil;
	if (!yt || !uvt || !(yt.usage & MTLTextureUsageShaderWrite) || !(uvt.usage & MTLTextureUsageShaderWrite)) {
		if (ty) CFRelease(ty);
		if (tuv) CFRelease(tuv);
		CVPixelBufferRelease(pb);
		return -1;
	}
	@autoreleasepool {
		id<MTLCommandBuffer> cb = mc_frame_cmd(enc);
		id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
		ce.label = @"mcopt rec";
		[ce setComputePipelineState:v->pso];
		[ce setTexture:src atIndex:0];
		[ce setTexture:yt atIndex:1];
		[ce setTexture:uvt atIndex:2];
		[ce setBytes:params length:paramsLength atIndex:1];
		[ce dispatchThreads:MTLSizeMake((NSUInteger) gridW, (NSUInteger) gridH, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
		[ce endEncoding];
		atomic_fetch_add(&v->pending, 1);
		RecVT *vv = v;
		[cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
			int ok = done.status == MTLCommandBufferStatusCompleted;
			CFRelease(ty);
			CFRelease(tuv);
			dispatch_async(vv->q, ^{
				if (ok) vtSubmit(vv, pb, frame);
				else atomic_fetch_add(&vv->failed, 1);
				CVPixelBufferRelease(pb);
				atomic_fetch_sub(&vv->pending, 1);
			});
		}];
	}
	return 0;
}

// Counters: encoded, repeated, failed, late, dropped (pool at its limit), bytes of H.264, captures not yet submitted.
void mcr_vt_stats(RecVT *v, int64_t *out) {
	out[0] = atomic_load(&v->encoded);
	out[1] = atomic_load(&v->repeated);
	out[2] = atomic_load(&v->failed);
	out[3] = atomic_load(&v->late);
	out[4] = atomic_load(&v->dropped);
	out[5] = atomic_load(&v->bytes);
	out[6] = atomic_load(&v->pending);
}

// Finishes the file (not the render thread: it waits): the GPU's last captures (at most 3 s), the encoder's last frames, ffmpeg
// (at most 60 s). Returns ffmpeg's exit status, or -1.
int mcr_vt_close(RecVT *v) {
	for (int i = 0; i < 300 && atomic_load(&v->pending) > 0; i++) usleep(10000);
	dispatch_sync(v->q, ^{
	});
	pVTComplete(v->vt, noTime);
	pVTInvalidate(v->vt);
	dispatch_sync(v->q, ^{
		if (v->last) CVPixelBufferRelease(v->last);
		v->last = NULL;
	});
	close(v->fd);
	int status = -1;
	for (int i = 0; i < 600; i++) {
		pid_t r = waitpid(v->ffmpeg, &status, WNOHANG);
		if (r == v->ffmpeg) return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
		if (r < 0) return -1;
		usleep(100000);
	}
	kill(v->ffmpeg, SIGTERM);
	return -1;
}
