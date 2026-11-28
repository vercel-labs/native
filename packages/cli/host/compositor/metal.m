// The Metal backend: textures as MTLTextures, every layer as one textured quad drawn with one
// pipeline, into a CAMetalLayer's drawable or an offscreen texture. It implements the same table
// software.c does, with the same pixels at an integer offset, so the Linux oracle and the Mac
// window path run the compositor's own code.

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurface.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "backend.h"
#include "metal.h"
#include "shader_manifest.h"

// A quad's uniform block. It must match the shader's `Uniforms` byte for byte.
typedef struct {
  float m[16];     // source pixels -> device pixels, column-major
  float params[4]; // opacity, source width, source height, corner radius
  float view[2];   // device width, height
  float flags[2];  // MT_SAMPLE_* bits, then unused
  float tint[4];   // colour multiplied into the sample, white for a plain quad
} MTUniforms;

// How a quad samples its texture: by default the nearest texel, which is the texel itself when
// the quad lands on whole device pixels at scale 1.
#define MT_SAMPLE_PREMULTIPLY 1 // the texels are straight alpha (a WebGL buffer): multiply it in
#define MT_SAMPLE_OPAQUE 2      // the texels' alpha is not the page's: every texel is opaque
#define MT_SAMPLE_LINEAR 4 // the quad scales or turns its texels: filter between them
#define MT_SAMPLE_TRACKED 8 // the host writes the texture itself: remember the frames reading it

#define MT_MAX_TEX 4096

/** One frame the main thread has drawn, on its way to the display: three of them let the
 *  renderer start the next frame while the presenter is waiting for a drawable. */
@interface MtStage : NSObject
// 0 free, 1 the main thread is drawing it, 2 drawn and waiting for the presenter, 3 presenting.
@property(nonatomic) int state;
@property(nonatomic) int width;
@property(nonatomic) int height;
@property(nonatomic, strong) id<MTLTexture> texture;
@end

@implementation MtStage
@end

@interface MtBackend : NSObject
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) id<MTLCommandQueue> queue;
// Every pipeline shader_manifest.h names, in the manifest's order, built with the same
// descriptors the build captured.
@property(nonatomic, strong) NSMutableArray<id<MTLRenderPipelineState>> *pipelines;
// The manifest's "quad" pipeline, the one every layer draws with.
@property(nonatomic, strong) id<MTLRenderPipelineState> quadPipeline;
@property(nonatomic, strong) id<MTLRenderPipelineState> maskPipeline;
@property(nonatomic, strong) id<MTLTexture> white;
// Untyped: a destroyed texture's slot holds NSNull, which a generic array would reject.
@property(nonatomic, strong) NSMutableArray *textures;
// The slots a destroyed texture freed, so a long-running window reuses them instead of growing
// the table until it fills.
@property(nonatomic, strong) NSMutableIndexSet *freeSlots;
@property(nonatomic, strong) id<MTLTexture> target;
// A pass into an offscreen surface the host draws a mask's image and content with, on a command
// buffer of its own so it never shares the frame's pass.
@property(nonatomic, strong) id<MTLCommandBuffer> surfaceBuffer;
@property(nonatomic, strong) id<MTLRenderCommandEncoder> surfaceEncoder;
@property(nonatomic) int surfaceWidth;
@property(nonatomic) int surfaceHeight;
@property(nonatomic, strong) CAMetalLayer *layer;
@property(nonatomic, strong) id<CAMetalDrawable> drawable;
@property(nonatomic, strong) id<MTLCommandBuffer> commandBuffer;
@property(nonatomic, strong) id<MTLCommandBuffer> lastCommandBuffer;
@property(nonatomic, strong) id<MTLRenderCommandEncoder> encoder;
@property(nonatomic) int width;
@property(nonatomic) int height;
@property(nonatomic) int ownsTarget;
// The presenter: frames drawn into stage textures here, handed to a thread that acquires the
// drawable, so the thread doing the page's work never waits for the display.
@property(nonatomic) BOOL presenterOn;
@property(nonatomic, strong) NSCondition *stageLock;
@property(nonatomic, strong) NSMutableArray *stages;
@property(nonatomic, strong) MtStage *drawing;
@property(nonatomic) BOOL quit;
@property(nonatomic) BOOL presenterDone;
@property(nonatomic) int framesPresented;
@property(nonatomic) int framesDropped;
@property(nonatomic) double drawableWaitMs;
@property(nonatomic) double drawableWaitMax;
// The last command buffer that sampled each MT_SAMPLE_TRACKED texture, by slot.
@property(nonatomic, strong) NSMutableDictionary *readers;
@end


// The build compiles compositor/shaders.metal into the library this header carries, so the
// first launch opens a metallib instead of compiling the shaders. A build with no Metal
// toolchain leaves the library empty, and the header's source is compiled at launch instead.
#include "native-metal-shaders.h"

/** Whether the backend prints what it is drawing to, for a host whose pixels go missing. */
static int mt_debug(void) {
  static int on = -1;
  if (on < 0) {
    const char *env = getenv("NATIVE_METAL_DEBUG");
    on = env != NULL && env[0] != 0;
  }
  return on;
}

static int mt_present_stage(MtBackend *m, MtStage *s);

static MtBackend *impl_of(CompBackend *b) {
  return (__bridge MtBackend *)b->impl;
}

static void mt_end_frame(MtBackend *m) {
  if (m.encoder != nil) {
    [m.encoder endEncoding];
    m.encoder = nil;
  }
  if (m.commandBuffer != nil) {
    if (m.drawable != nil) [m.commandBuffer presentDrawable:m.drawable];
    [m.commandBuffer commit];
    m.lastCommandBuffer = m.commandBuffer;
    m.commandBuffer = nil;
  }
  m.drawable = nil;
  if (m.drawing != nil) {
    // This frame was drawn into a stage of its own: the presenter takes it from here, and this
    // thread goes back to the page. The wait for a drawable is paid over there.
    MtStage *s = m.drawing;
    m.drawing = nil;
    m.target = nil;
    m.ownsTarget = 0;
    [m.stageLock lock];
    s.state = 2;
    [m.stageLock broadcast];
    [m.stageLock unlock];
  }
}

static id<MTLTexture> mt_texture(MtBackend *m, int tex) {
  if (tex < 0 || (NSUInteger)tex >= m.textures.count) return nil;
  id obj = m.textures[(NSUInteger)tex];
  return obj == (id)[NSNull null] ? nil : (id<MTLTexture>)obj;
}

static id<MTLTexture> mt_make_texture(MtBackend *m, int w, int h, MTLTextureUsage usage) {
  MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                               width:(NSUInteger)w
                                                                              height:(NSUInteger)h
                                                                           mipmapped:NO];
  d.usage = usage;
  d.storageMode = MTLStorageModeShared;
  return [m.device newTextureWithDescriptor:d];
}

/** How many frames can be in flight between the page and the display: one being drawn, one
 *  waiting for the presenter, one the presenter is copying. */
#define MT_STAGE_SLOTS 3

/** Whether the presenter thread takes the frames: `NATIVE_PRESENTER=0` draws into the drawable
 *  on the calling thread, as before. */
static int mt_presenter_on(void) {
  const char *env = getenv("NATIVE_PRESENTER");
  return !(env != NULL && env[0] == '0' && env[1] == 0);
}

/** Whether the presenter prints its frame and wait counters. */
static int mt_presenter_debug(void) {
  const char *env = getenv("NATIVE_PRESENTER_DEBUG");
  return env != NULL && env[0] != 0 && env[0] != '0';
}

/** Whether NATIVE_PRESENT_STATS prints a line per presented frame: its size and how many colours
 *  it holds. A frame that painted nothing but the page's background is one colour, so a test that
 *  resizes a window past the display reads these lines to check the page keeps reaching it. */
static int mt_present_stats(void) {
  const char *env = getenv("NATIVE_PRESENT_STATS");
  return env != NULL && env[0] != 0 && env[0] != '0';
}

/** The distinct colours a presented frame holds, on a grid of samples: one for a frame that drew
 *  only its background. Answers -1 when the frame's pixels can't be read. */
static int mt_stage_colours(id<MTLTexture> tex) {
  if (tex == nil || tex.storageMode != MTLStorageModeShared) return -1;
  NSUInteger w = tex.width, h = tex.height;
  if (w == 0 || h == 0) return 0;
  unsigned char *px = (unsigned char *)malloc((size_t)w * 4u * (size_t)h);
  if (px == NULL) return -1;
  [tex getBytes:px bytesPerRow:(NSUInteger)w * 4u
     fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
  unsigned int keys[4096];
  unsigned char used[4096];
  memset(used, 0, sizeof(used));
  int count = 0;
  NSUInteger stepx = w > 256 ? w / 256 : 1, stepy = h > 256 ? h / 256 : 1;
  for (NSUInteger y = 0; y < h; y += stepy) {
    const unsigned char *row = px + (size_t)y * (size_t)w * 4u;
    for (NSUInteger x = 0; x < w; x += stepx) {
      const unsigned char *p = row + (size_t)x * 4u;
      unsigned int key = ((unsigned int)p[0] << 24) | ((unsigned int)p[1] << 16) |
                         ((unsigned int)p[2] << 8) | (unsigned int)p[3];
      unsigned int slot = (key * 2654435761u) & 4095u;
      // The probe is bounded by the table: a frame with more colours than it has slots stops
      // counting instead of searching for a free slot that isn't there.
      for (int probe = 0; probe < 4096; probe++) {
        if (used[slot] == 0) {
          used[slot] = 1;
          keys[slot] = key;
          count++;
          break;
        }
        if (keys[slot] == key) break;
        slot = (slot + 1) & 4095u;
      }
    }
  }
  free(px);
  return count;
}

/** The stage the next frame draws into, or nil when every one is with the presenter: a frame
 *  with nowhere to go is dropped rather than waited for, which is the point of the whole
 *  arrangement. A frame drawn but not yet presented is the one the display will never show, so
 *  its stage is the one to take. */
static MtStage *mt_stage_take(MtBackend *m, int w, int h) {
  MtStage *pick = nil;
  [m.stageLock lock];
  for (MtStage *s in m.stages) {
    if (s.state == 0) {
      pick = s;
      break;
    }
  }
  if (pick == nil) {
    // Every stage is with the presenter, and it may be reading any of them right now: drawing
    // into one would show a frame mid-clear (a blank window), and no frame is better than a
    // broken one. This one is dropped and the window keeps the picture it has.
  }
  if (pick != nil) {
    pick.state = 1;
    if (pick.texture == nil || pick.width != w || pick.height != h) {
      id<MTLTexture> t = mt_make_texture(m, w, h, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
      if (t == nil) {
        pick.state = 0;
        pick = nil;
      } else {
        pick.texture = t;
        pick.width = w;
        pick.height = h;
      }
    }
  }
  if (pick == nil) m.framesDropped++;
  [m.stageLock unlock];
  return pick;
}

/** Draws a finished stage into the layer's drawable and presents it: the one place a frame waits
 *  for the display, and it is not the thread that runs the page. */

/** Starts a pass into surface `target`, cleared to transparent black, on a command buffer of the
 *  host's own: a mask's image and content are drawn with mt_surface_draw and committed with
 *  mt_surface_end, apart from the frame's pass. */
void mt_surface_begin(CompBackend *backend, int target, int w, int h) {
  if (backend == NULL) return;
  MtBackend *m = (__bridge MtBackend *)backend->impl;
  if (m == nil || w <= 0 || h <= 0) return;
  id<MTLTexture> tex = mt_texture(m, target);
  if (tex == nil) return;
  mt_end_frame(m);
  MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
  rp.colorAttachments[0].texture = tex;
  rp.colorAttachments[0].loadAction = MTLLoadActionClear;
  rp.colorAttachments[0].storeAction = MTLStoreActionStore;
  rp.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 0.0);
  m.surfaceBuffer = [m.queue commandBuffer];
  m.surfaceEncoder = [m.surfaceBuffer renderCommandEncoderWithDescriptor:rp];
  m.surfaceWidth = w;
  m.surfaceHeight = h;
  const char *dbg = getenv("NATIVE_MASK_SPLIT_DEBUG");
  if (dbg != NULL && dbg[0] == '1') {
    fprintf(stderr, "native: surface begin target=%d tex=%p %ux%u usage=%lu enc=%d pipe=%p\n",
            target, (__bridge void *)tex, (unsigned)tex.width, (unsigned)tex.height,
            (unsigned long)tex.usage, m.surfaceEncoder != nil, (__bridge void *)m.quadPipeline);
  }
}

/** Draws `tex`'s `src` rectangle into the open surface, as draw_quad would into a frame. */
void mt_surface_draw(CompBackend *backend, int tex, CompRect src, const CompMatrix *matrix,
                     float opacity, const CompRect *clip) {
  if (backend == NULL) return;
  MtBackend *m = (__bridge MtBackend *)backend->impl;
  if (m == nil || m.surfaceEncoder == nil) return;
  id<MTLTexture> t = mt_texture(m, tex);
  if (t == nil || opacity <= 0.0f || src.w <= 0 || src.h <= 0) return;
  MTUniforms u;
  memset(&u, 0, sizeof(u));
  if (matrix != NULL) memcpy(u.m, matrix->m, sizeof(u.m));
  else for (int i = 0; i < 4; i++) u.m[i * 5] = 1.0f;
  u.params[0] = opacity;
  u.params[1] = (float)src.w;
  u.params[2] = (float)src.h;
  u.view[0] = (float)m.surfaceWidth;
  u.view[1] = (float)m.surfaceHeight;
  u.tint[0] = u.tint[1] = u.tint[2] = u.tint[3] = 1.0f;
  [m.surfaceEncoder setRenderPipelineState:m.quadPipeline];
  [m.surfaceEncoder setVertexBytes:&u length:sizeof(u) atIndex:0];
  [m.surfaceEncoder setFragmentBytes:&u length:sizeof(u) atIndex:0];
  [m.surfaceEncoder setFragmentTexture:t atIndex:0];
  MTLScissorRect scissor = {0, 0, (NSUInteger)m.surfaceWidth, (NSUInteger)m.surfaceHeight};
  if (clip != NULL && clip->w > 0 && clip->h > 0) {
    int x0 = clip->x > 0 ? clip->x : 0;
    int y0 = clip->y > 0 ? clip->y : 0;
    int x1 = clip->x + clip->w < m.surfaceWidth ? clip->x + clip->w : m.surfaceWidth;
    int y1 = clip->y + clip->h < m.surfaceHeight ? clip->y + clip->h : m.surfaceHeight;
    if (x1 <= x0 || y1 <= y0) return;
    scissor = (MTLScissorRect){(NSUInteger)x0, (NSUInteger)y0, (NSUInteger)(x1 - x0),
                               (NSUInteger)(y1 - y0)};
  }
  [m.surfaceEncoder setScissorRect:scissor];
  [m.surfaceEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

/** Draws the content through the mask's alpha into the open surface, so the product is rounded
 *  to the surface's eight bits before the frame blends it, as the flat replay's image is. */
int mt_surface_draw_masked(CompBackend *backend, int content, int mask, CompRect src,
                           const CompMatrix *matrix, float opacity) {
  if (backend == NULL) return 0;
  MtBackend *m = (__bridge MtBackend *)backend->impl;
  if (m == nil || m.surfaceEncoder == nil || m.maskPipeline == nil) return 0;
  id<MTLTexture> ct = mt_texture(m, content);
  id<MTLTexture> mt = mt_texture(m, mask);
  if (ct == nil || mt == nil || src.w <= 0 || src.h <= 0) return 0;
  MTUniforms u;
  memset(&u, 0, sizeof(u));
  if (matrix != NULL) memcpy(u.m, matrix->m, sizeof(u.m));
  else for (int i = 0; i < 4; i++) u.m[i * 5] = 1.0f;
  u.params[0] = opacity;
  u.params[1] = (float)src.w;
  u.params[2] = (float)src.h;
  u.view[0] = (float)m.surfaceWidth;
  u.view[1] = (float)m.surfaceHeight;
  u.tint[0] = u.tint[1] = u.tint[2] = u.tint[3] = 1.0f;
  [m.surfaceEncoder setRenderPipelineState:m.maskPipeline];
  [m.surfaceEncoder setVertexBytes:&u length:sizeof(u) atIndex:0];
  [m.surfaceEncoder setFragmentBytes:&u length:sizeof(u) atIndex:0];
  [m.surfaceEncoder setFragmentTexture:ct atIndex:0];
  [m.surfaceEncoder setFragmentTexture:mt atIndex:1];
  [m.surfaceEncoder setScissorRect:(MTLScissorRect){0, 0, (NSUInteger)m.surfaceWidth,
                                                   (NSUInteger)m.surfaceHeight}];
  [m.surfaceEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  return 1;
}

/** Ends the surface pass and commits it. */
void mt_surface_end(CompBackend *backend) {
  if (backend == NULL) return;
  MtBackend *m = (__bridge MtBackend *)backend->impl;
  if (m == nil) return;
  if (m.surfaceEncoder != nil) {
    [m.surfaceEncoder endEncoding];
    m.surfaceEncoder = nil;
  }
  if (m.surfaceBuffer != nil) {
    [m.surfaceBuffer commit];
    m.lastCommandBuffer = m.surfaceBuffer;
    m.surfaceBuffer = nil;
  }
}

int mt_mask_composite_available(CompBackend *backend) {
  if (backend == NULL) return 0;
  MtBackend *m = (__bridge MtBackend *)backend->impl;
  return m != nil && m.maskPipeline != nil;
}

/**
 * Draws a content texture through a mask image's alpha: one quad sampling both textures over the
 * same rect and multiplying the premultiplied content by the coverage. It is the pass a mask the
 * walk split runs instead of the CPU multiply over the whole masked box.
 */
int mt_draw_quad_masked(CompBackend *backend, int content, int mask, CompRect src,
                        const CompMatrix *matrix, float opacity, const CompRect *clip) {
  if (backend == NULL) return 0;
  MtBackend *m = (__bridge MtBackend *)backend->impl;
  if (m == nil) return 0;
  id<MTLTexture> ct = mt_texture(m, content);
  id<MTLTexture> mt = mt_texture(m, mask);
  if (m.encoder == nil || m.maskPipeline == nil || ct == nil || mt == nil || opacity <= 0.0f ||
      src.w <= 0 || src.h <= 0) {
    return 0;
  }
  MTUniforms u;
  memset(&u, 0, sizeof(u));
  if (matrix != NULL) memcpy(u.m, matrix->m, sizeof(u.m));
  else for (int i = 0; i < 4; i++) u.m[i * 5] = 1.0f;
  u.params[0] = opacity;
  u.params[1] = (float)src.w;
  u.params[2] = (float)src.h;
  u.view[0] = (float)m.width;
  u.view[1] = (float)m.height;
  u.tint[0] = u.tint[1] = u.tint[2] = u.tint[3] = 1.0f;
  [m.encoder setVertexBytes:&u length:sizeof(u) atIndex:0];
  [m.encoder setFragmentBytes:&u length:sizeof(u) atIndex:0];
  [m.encoder setRenderPipelineState:m.maskPipeline];
  [m.encoder setFragmentTexture:ct atIndex:0];
  [m.encoder setFragmentTexture:mt atIndex:1];
  MTLScissorRect scissor = {0, 0, (NSUInteger)m.width, (NSUInteger)m.height};
  if (clip != NULL && clip->w > 0 && clip->h > 0) {
    int x0 = clip->x > 0 ? clip->x : 0;
    int y0 = clip->y > 0 ? clip->y : 0;
    int x1 = clip->x + clip->w < m.width ? clip->x + clip->w : m.width;
    int y1 = clip->y + clip->h < m.height ? clip->y + clip->h : m.height;
    if (x1 <= x0 || y1 <= y0) return 0;
    scissor = (MTLScissorRect){(NSUInteger)x0, (NSUInteger)y0, (NSUInteger)(x1 - x0),
                               (NSUInteger)(y1 - y0)};
  }
  [m.encoder setScissorRect:scissor];
  [m.encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  return 1;
}

static int mt_present_stage(MtBackend *m, MtStage *s) {
  double started = CACurrentMediaTime() * 1000.0;
  id<CAMetalDrawable> d = [m.layer nextDrawable];
  double waited = CACurrentMediaTime() * 1000.0 - started;
  if (d == nil || s.texture == nil) {
    if (mt_present_stats()) fprintf(stderr, "native: present drop %dx%d drawable=%s\n",
                                    s.width, s.height, d == nil ? "none" : "ok");
    return 0;
  }
  MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = d.texture;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
  id<MTLCommandBuffer> cb = [m.queue commandBuffer];
  id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
  MTUniforms u;
  memset(&u, 0, sizeof(u));
  double sw = (double)s.texture.width, sh = (double)s.texture.height;
  // The stage is the whole frame at the device scale, so the quad covers the drawable one to one.
  u.m[0] = (float)((double)d.texture.width / (sw > 0 ? sw : 1.0));
  u.m[5] = (float)((double)d.texture.height / (sh > 0 ? sh : 1.0));
  u.m[10] = 1.0f;
  u.m[15] = 1.0f;
  u.params[0] = 1.0f;
  u.params[1] = (float)sw;
  u.params[2] = (float)sh;
  u.view[0] = (float)d.texture.width;
  u.view[1] = (float)d.texture.height;
  u.tint[0] = u.tint[1] = u.tint[2] = u.tint[3] = 1.0f;
  [enc setRenderPipelineState:m.quadPipeline];
  [enc setVertexBytes:&u length:sizeof(u) atIndex:0];
  [enc setFragmentBytes:&u length:sizeof(u) atIndex:0];
  [enc setFragmentTexture:s.texture atIndex:0];
  [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  [enc endEncoding];
  [cb presentDrawable:d];
  // The stage is free again once the GPU has read it: until then the page would be drawing
  // into a texture this pass is still copying out of.
  MtBackend *mm = m;
  MtStage *ss = s;
  [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
    // Read the frame back before the stage is free for the page to draw into again.
    if (mt_present_stats() && done.status == MTLCommandBufferStatusCompleted) {
      fprintf(stderr, "native: present %dx%d colours=%d\n", (int)ss.width, (int)ss.height,
              mt_stage_colours(ss.texture));
    }
    [mm.stageLock lock];
    ss.state = 0;
    [mm.stageLock broadcast];
    [mm.stageLock unlock];
  }];
  [cb commit];
  [m.stageLock lock];
  m.framesPresented++;
  m.drawableWaitMs += waited;
  if (waited > m.drawableWaitMax) m.drawableWaitMax = waited;
  if (mt_presenter_debug() && m.framesPresented % 30 == 0) {
    fprintf(stderr, "native: presenter frames=%d dropped=%d drawable-wait=%.1f ms/frame max=%.1f\n",
            m.framesPresented, m.framesDropped, m.drawableWaitMs / (double)m.framesPresented,
            m.drawableWaitMax);
  }
  [m.stageLock unlock];
  return 1;
}

@implementation MtBackend
/** The presenter: waits for a drawn stage, presents it, hands it back. */
- (void)presentLoop {
  for (;;) {
    @autoreleasepool {
      MtStage *pick = nil;
      [self.stageLock lock];
      while (!self.quit) {
        for (MtStage *s in self.stages) {
          if (s.state == 2) {
            pick = s;
            break;
          }
        }
        if (pick != nil) break;
        [self.stageLock wait];
      }
      if (pick == nil) {
        self.presenterDone = YES;
        [self.stageLock broadcast];
        [self.stageLock unlock];
        return;
      }
      pick.state = 3;
      [self.stageLock unlock];
      if (!mt_present_stage(self, pick)) {
        // No drawable this time: the stage goes straight back, nothing is reading it.
        [self.stageLock lock];
        pick.state = 0;
        [self.stageLock broadcast];
        [self.stageLock unlock];
      }
    }
  }
}
@end

static int mt_tex_create(CompBackend *b, int w, int h) {
  MtBackend *m = impl_of(b);
  if (w <= 0 || h <= 0) return -1;
  if (m.freeSlots.count == 0 && m.textures.count >= MT_MAX_TEX) return -1;
  id<MTLTexture> t = mt_make_texture(m, w, h, MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget);
  if (t == nil) return -1;
  NSUInteger slot = m.freeSlots.firstIndex;
  if (slot != NSNotFound) {
    [m.freeSlots removeIndex:slot];
    [m.textures replaceObjectAtIndex:slot withObject:t];
    return (int)slot;
  }
  [m.textures addObject:t];
  return (int)m.textures.count - 1;
}

static void mt_tex_upload(CompBackend *b, int tex, CompRect dst, const unsigned char *pixels, int stride) {
  MtBackend *m = impl_of(b);
  id<MTLTexture> t = mt_texture(m, tex);
  if (t == nil || pixels == NULL || dst.w <= 0 || dst.h <= 0) return;
  // A rect that reaches past the texture is cut to it, as the software backend cuts one.
  if (dst.x < 0) { pixels += (size_t)(-dst.x) * 4u; dst.w += dst.x; dst.x = 0; }
  if (dst.y < 0) { pixels += (size_t)(-dst.y) * (size_t)stride; dst.h += dst.y; dst.y = 0; }
  if (dst.x + dst.w > (int)t.width) dst.w = (int)t.width - dst.x;
  if (dst.y + dst.h > (int)t.height) dst.h = (int)t.height - dst.y;
  if (dst.w <= 0 || dst.h <= 0) return;
  // The core holds premultiplied RGBA; Metal's BGRA8 wants the channels the other way round.
  unsigned char *rows = (unsigned char *)malloc((size_t)dst.w * 4u * (size_t)dst.h);
  if (rows == NULL) return;
  for (int y = 0; y < dst.h; y++) {
    const unsigned char *src = pixels + (size_t)y * (size_t)stride;
    unsigned char *out = rows + (size_t)y * (size_t)dst.w * 4u;
    for (int x = 0; x < dst.w; x++) {
      out[x * 4 + 0] = src[x * 4 + 2];
      out[x * 4 + 1] = src[x * 4 + 1];
      out[x * 4 + 2] = src[x * 4 + 0];
      out[x * 4 + 3] = src[x * 4 + 3];
    }
  }
  [t replaceRegion:MTLRegionMake2D((NSUInteger)dst.x, (NSUInteger)dst.y, (NSUInteger)dst.w, (NSUInteger)dst.h)
       mipmapLevel:0
             withBytes:rows
           bytesPerRow:(NSUInteger)dst.w * 4u];
  free(rows);
}

static void mt_tex_destroy(CompBackend *b, int tex) {
  MtBackend *m = impl_of(b);
  if (tex < 0 || (NSUInteger)tex >= m.textures.count) return;
  id t = m.textures[(NSUInteger)tex];
  if (t == (id)[NSNull null]) return;
  if (t == m.target) m.target = nil;
  [m.readers removeObjectForKey:@(tex)];
  [m.textures replaceObjectAtIndex:(NSUInteger)tex withObject:[NSNull null]];
  [m.freeSlots addIndex:(NSUInteger)tex];
  (void)t;
}

static void mt_pass_begin(CompBackend *b, int target, int w, int h, uint32_t background) {
  MtBackend *m = impl_of(b);
  mt_end_frame(m);
  if (w <= 0 || h <= 0) return;
  m.width = w;
  m.height = h;
  id<MTLTexture> tex = nil;
  if (target >= 0) {
    tex = mt_texture(m, target);
    m.ownsTarget = 0;
  } else if (m.layer != nil && m.presenterOn) {
    // A stage of its own: the presenter takes the frame to the drawable, so this thread never
    // waits for the display.
    MtStage *s = mt_stage_take(m, w, h);
    if (s == nil) return;
    m.drawing = s;
    tex = s.texture;
    m.ownsTarget = 0;
  } else if (m.layer != nil) {
    // The same frame, drawn on this thread: the wait for a drawable is this thread's to pay.
    double started = CACurrentMediaTime() * 1000.0;
    m.drawable = [m.layer nextDrawable];
    [m.stageLock lock];
    double waited = CACurrentMediaTime() * 1000.0 - started;
    m.framesPresented++;
    m.drawableWaitMs += waited;
    if (waited > m.drawableWaitMax) m.drawableWaitMax = waited;
    if (mt_presenter_debug() && m.framesPresented % 30 == 0) {
      fprintf(stderr, "native: presenter frames=%d dropped=%d drawable-wait=%.1f ms/frame max=%.1f\n",
              m.framesPresented, m.framesDropped, m.drawableWaitMs / (double)m.framesPresented,
              m.drawableWaitMax);
    }
    [m.stageLock unlock];
    tex = m.drawable.texture;
    m.ownsTarget = 0;
  } else {
    tex = mt_make_texture(m, w, h, MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
    m.ownsTarget = 1;
  }
  if (tex == nil) return;
  m.target = tex;
  if (mt_debug()) {
    fprintf(stderr, "native: metal pass target=%p %dx%d storage=%d draws=%s\n",
            (__bridge void *)tex, w, h, (int)tex.storageMode,
            m.drawing != nil ? "stage" : (m.layer != nil ? "drawable" : "offscreen"));
  }
  MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = tex;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  pass.colorAttachments[0].clearColor = MTLClearColorMake(
      (double)((background >> 24) & 255) / 255.0,
      (double)((background >> 16) & 255) / 255.0,
      (double)((background >> 8) & 255) / 255.0,
      (double)(background & 255) / 255.0);
  m.commandBuffer = [m.queue commandBuffer];
  m.encoder = [m.commandBuffer renderCommandEncoderWithDescriptor:pass];
}

static void mt_draw(CompBackend *b, int tex, CompRect src, const CompMatrix *matrix, float opacity,
                    const CompRect *clip, float radius, const float tint[4], int flags) {
  MtBackend *m = impl_of(b);
  id<MTLTexture> t = mt_texture(m, tex);
  if (m.encoder == nil || t == nil || opacity <= 0.0f || src.w <= 0 || src.h <= 0) return;
  MTUniforms u;
  memset(&u, 0, sizeof(u));
  if (matrix != NULL) memcpy(u.m, matrix->m, sizeof(u.m));
  else for (int i = 0; i < 4; i++) u.m[i * 5] = 1.0f;
  u.params[0] = opacity;
  u.params[1] = (float)src.w;
  u.params[2] = (float)src.h;
  u.params[3] = radius > 0.0f ? radius : 0.0f;
  u.view[0] = (float)m.width;
  u.view[1] = (float)m.height;
  memcpy(u.tint, tint, sizeof(u.tint));
  u.flags[0] = (float)flags;
  if (mt_debug()) {
    fprintf(stderr, "native: metal draw enc=%p tex=%p pipe=%p opacity=%.2f src=%dx%d view=%dx%d\n",
            (__bridge void *)m.encoder, (__bridge void *)t, (__bridge void *)m.quadPipeline,
            opacity, src.w, src.h, m.width, m.height);
  }
  [m.encoder setRenderPipelineState:m.quadPipeline];
  [m.encoder setVertexBytes:&u length:sizeof(u) atIndex:0];
  [m.encoder setFragmentBytes:&u length:sizeof(u) atIndex:0];
  [m.encoder setFragmentTexture:t atIndex:0];
  MTLScissorRect scissor = {0, 0, (NSUInteger)m.width, (NSUInteger)m.height};
  if (clip != NULL && clip->w > 0 && clip->h > 0) {
    int x0 = clip->x > 0 ? clip->x : 0;
    int y0 = clip->y > 0 ? clip->y : 0;
    int x1 = clip->x + clip->w < m.width ? clip->x + clip->w : m.width;
    int y1 = clip->y + clip->h < m.height ? clip->y + clip->h : m.height;
    if (x1 <= x0 || y1 <= y0) return;
    scissor = (MTLScissorRect){(NSUInteger)x0, (NSUInteger)y0, (NSUInteger)(x1 - x0), (NSUInteger)(y1 - y0)};
  }
  [m.encoder setScissorRect:scissor];
  [m.encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  // A texture the host writes into itself (a canvas's buffer) must not be written again while a
  // frame on the GPU still reads it: remember the work, so mt_tex_wait_idle can wait for it.
  if ((flags & MT_SAMPLE_TRACKED) != 0 && m.commandBuffer != nil) {
    if (m.readers == nil) m.readers = [NSMutableDictionary dictionary];
    m.readers[@(tex)] = m.commandBuffer;
  }
}

static void mt_draw_quad(CompBackend *b, int tex, CompRect src, const CompMatrix *matrix, float opacity,
                         const CompRect *clip, float radius) {
  static const float white[4] = {1.0f, 1.0f, 1.0f, 1.0f};
  mt_draw(b, tex, src, matrix, opacity, clip, radius, white, 0);
}

/** mt_draw_quad with MT_SAMPLE_* flags, for the window host's own draws. */
static void mt_draw_quad_sampled(CompBackend *b, int tex, CompRect src, const CompMatrix *matrix,
                                 float opacity, const CompRect *clip, int flags) {
  static const float white[4] = {1.0f, 1.0f, 1.0f, 1.0f};
  mt_draw(b, tex, src, matrix, opacity, clip, 0.0f, white, flags);
}

static void mt_fill_rect(CompBackend *b, CompRect rect, uint32_t color) {
  MtBackend *m = impl_of(b);
  if (m.white == nil || rect.w <= 0 || rect.h <= 0) return;
  CompMatrix mtx = comp_matrix_mul(comp_matrix_translate((float)rect.x, (float)rect.y),
                                   comp_matrix_scale((float)rect.w, (float)rect.h));
  float tint[4] = {
      (float)((color >> 24) & 255) / 255.0f,
      (float)((color >> 16) & 255) / 255.0f,
      (float)((color >> 8) & 255) / 255.0f,
      1.0f,
  };
  mt_draw(b, 0, (CompRect){0, 0, 1, 1}, &mtx, (float)(color & 255) / 255.0f, NULL, 0.0f, tint, 0);
}

static int mt_readback(CompBackend *b, int target, CompRect rect, unsigned char *out, int stride) {
  MtBackend *m = impl_of(b);
  if (out == NULL) return 0;
  mt_end_frame(m);
  // A read waits for the work that drew it, so the pixels are the pass's own.
  if (m.lastCommandBuffer != nil) [m.lastCommandBuffer waitUntilCompleted];
  id<MTLTexture> t = target >= 0 ? mt_texture(m, target) : m.target;
  if (t == nil || t.storageMode != MTLStorageModeShared) return 0;
  // The part of the read that the texture holds; everything else answers transparent black, as
  // the software backend answers for pixels outside the target.
  int rx = rect.x < 0 ? 0 : rect.x;
  int ry = rect.y < 0 ? 0 : rect.y;
  int rw = rect.x < 0 ? rect.w + rect.x : rect.w;
  int rh = rect.y < 0 ? rect.h + rect.y : rect.h;
  if (rx + rw > (int)t.width) rw = (int)t.width - rx;
  if (ry + rh > (int)t.height) rh = (int)t.height - ry;
  if (rw < 0) rw = 0;
  if (rh < 0) rh = 0;
  unsigned char *rows = NULL;
  if (rw > 0 && rh > 0) {
    rows = (unsigned char *)malloc((size_t)rw * 4u * (size_t)rh);
    if (rows == NULL) return 0;
    [t getBytes:rows bytesPerRow:(NSUInteger)rw * 4u
      fromRegion:MTLRegionMake2D((NSUInteger)rx, (NSUInteger)ry, (NSUInteger)rw, (NSUInteger)rh)
     mipmapLevel:0];
    if (mt_debug()) {
      fprintf(stderr, "native: metal readback id=%d tex=%p %dx%d fmt=%d storage=%d cmd=%ld raw=%d,%d,%d,%d\n",
              target, (__bridge void *)t, (int)t.width, (int)t.height, (int)t.pixelFormat,
              (int)t.storageMode, (long)m.lastCommandBuffer.status,
              rows[0], rows[1], rows[2], rows[3]);
    }
  }
  for (int y = 0; y < rect.h; y++) {
    unsigned char *dst = out + (size_t)y * (size_t)stride;
    int insideY = y >= ry && y < ry + rh;
    for (int x = 0; x < rect.w; x++) {
      if (!insideY || x < rx || x >= rx + rw) {
        dst[x * 4 + 0] = dst[x * 4 + 1] = dst[x * 4 + 2] = dst[x * 4 + 3] = 0;
        continue;
      }
      const unsigned char *px = rows + (size_t)(y - ry) * (size_t)rw * 4u + (size_t)(x - rx) * 4u;
      unsigned a = px[3];
      if (a == 0) {
        dst[x * 4 + 0] = dst[x * 4 + 1] = dst[x * 4 + 2] = dst[x * 4 + 3] = 0;
      } else {
        // BGRA premultiplied to straight RGBA.
        dst[x * 4 + 0] = (unsigned char)((px[2] * 255u + a / 2u) / a);
        dst[x * 4 + 1] = (unsigned char)((px[1] * 255u + a / 2u) / a);
        dst[x * 4 + 2] = (unsigned char)((px[0] * 255u + a / 2u) / a);
        dst[x * 4 + 3] = (unsigned char)a;
      }
    }
  }
  free(rows);
  return 1;
}

static void mt_present(CompBackend *b) {
  MtBackend *m = impl_of(b);
  mt_end_frame(m);
}

static void mt_destroy(CompBackend *b) {
  MtBackend *m = (__bridge_transfer MtBackend *)b->impl;
  mt_end_frame(m);
  if (m.presenterOn) {
    [m.stageLock lock];
    m.quit = YES;
    [m.stageLock broadcast];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:0.3];
    while (!m.presenterDone && [deadline timeIntervalSinceNow] > 0) [m.stageLock waitUntilDate:deadline];
    [m.stageLock unlock];
  }
  (void)m;
  b->impl = NULL;
  free(b);
}

// Textures the page's canvases draw into, which the window host draws as they are instead of
// rastering the canvas into a chunk: a WebGL drawing buffer shares an IOSurface with GL, and a 2D
// canvas's bitmap is copied in as it is, premultiplied RGBA.

/** Puts a texture into a free slot of the table; -1 when the table is full. */
static int mt_tex_slot(MtBackend *m, id<MTLTexture> t) {
  if (t == nil) return -1;
  if (m.freeSlots.count == 0 && m.textures.count >= MT_MAX_TEX) return -1;
  NSUInteger slot = m.freeSlots.firstIndex;
  if (slot != NSNotFound) {
    [m.freeSlots removeIndex:slot];
    [m.textures replaceObjectAtIndex:slot withObject:t];
    return (int)slot;
  }
  [m.textures addObject:t];
  return (int)m.textures.count - 1;
}

/** A texture over an IOSurface's BGRA pixels, which GL draws into; -1 when Metal can't wrap it. */
static int mt_tex_wrap_iosurface(CompBackend *b, IOSurfaceRef surface) {
  MtBackend *m = impl_of(b);
  if (surface == NULL) return -1;
  MTLTextureDescriptor *d = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                   width:(NSUInteger)IOSurfaceGetWidth(surface)
                                  height:(NSUInteger)IOSurfaceGetHeight(surface)
                               mipmapped:NO];
  d.usage = MTLTextureUsageShaderRead;
  return mt_tex_slot(m, [m.device newTextureWithDescriptor:d iosurface:surface plane:0]);
}

/** A texture holding premultiplied RGBA as a CoreGraphics bitmap stores it, for a 2D canvas. */
static int mt_tex_create_rgba(CompBackend *b, int w, int h) {
  MtBackend *m = impl_of(b);
  if (w <= 0 || h <= 0) return -1;
  MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                               width:(NSUInteger)w
                                                                              height:(NSUInteger)h
                                                                           mipmapped:NO];
  d.usage = MTLTextureUsageShaderRead;
  d.storageMode = MTLStorageModeShared;
  return mt_tex_slot(m, [m.device newTextureWithDescriptor:d]);
}

/** Copies a bitmap's rows into a texture from mt_tex_create_rgba as they are. */
static void mt_tex_upload_rgba(CompBackend *b, int tex, const unsigned char *pixels, size_t stride) {
  MtBackend *m = impl_of(b);
  id<MTLTexture> t = mt_texture(m, tex);
  if (t == nil || pixels == NULL) return;
  [t replaceRegion:MTLRegionMake2D(0, 0, t.width, t.height) mipmapLevel:0 withBytes:pixels
       bytesPerRow:(NSUInteger)stride];
}

/** Waits until no committed frame still samples `tex`, so the host can write into it. A frame
 *  still being recorded hasn't read it yet: a write now lands before that frame runs. */
static void mt_tex_wait_idle(CompBackend *b, int tex) {
  MtBackend *m = impl_of(b);
  id<MTLCommandBuffer> cb = m.readers[@(tex)];
  if (cb == nil || cb == m.commandBuffer) return;
  if (cb.status < MTLCommandBufferStatusCompleted) [cb waitUntilCompleted];
  [m.readers removeObjectForKey:@(tex)];
}

static const CompBackendVTable MT_VT = {
    mt_tex_create, mt_tex_upload, mt_tex_destroy, mt_pass_begin,
    mt_draw_quad, mt_fill_rect, mt_readback, mt_present, mt_destroy,
};

static CompBackend *mt_backend_with_layer(void *layer) {
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  if (device == nil) return NULL;
  MtBackend *m = [[MtBackend alloc] init];
  m.device = device;
  if (mt_debug()) fprintf(stderr, "native: metal device=%s\n", [[device name] UTF8String]);
  m.queue = [device newCommandQueue];
  if (m.queue == nil) return NULL;
  NSError *error = nil;
  id<MTLLibrary> library = nil;
  if (native_quad_metallib_len > 0) {
    // The build compiled the shaders, so the first launch opens them instead of running the
    // compiler: this is what makes a freshly built app's first frame quick.
    dispatch_data_t data = dispatch_data_create(native_quad_metallib, native_quad_metallib_len, NULL,
                                                DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    library = [device newLibraryWithData:data error:&error];
    if (mt_debug()) {
      fprintf(stderr, "native: metal library=precompiled %s\n", library != nil ? "opened" : "failed");
    }
    if (library == nil) {
      fprintf(stderr, "native: the precompiled Metal shaders did not load (%s); compiling them from source instead\n",
              error == nil ? "unknown error" : [[error description] UTF8String]);
    }
  } else {
    fprintf(stderr, "native: this build has no precompiled Metal shaders (the Metal toolchain was missing when it was built); compiling them when the app starts\n");
  }
  if (library == nil) {
    if (mt_debug()) fprintf(stderr, "native: metal library=source compiled at launch\n");
    error = nil;
    library = [device newLibraryWithSource:[NSString stringWithUTF8String:native_quad_shader_source]
                                   options:nil
                                     error:&error];
    if (library == nil) {
      fprintf(stderr, "native: the compositor's Metal shaders did not compile: %s\n",
              error == nil ? "unknown error" : [[error description] UTF8String]);
      return NULL;
    }
  }
  // Every pipeline the manifest names, from the descriptors the build captured: a captured
  // library holds every function the shaders declare, so the mask pass's function is there too.
  // The textures hold premultiplied alpha, so a quad's source is taken as it is.
  m.pipelines = [NSMutableArray arrayWithCapacity:NATIVE_SHADER_PIPELINE_COUNT];
  for (size_t i = 0; i < NATIVE_SHADER_PIPELINE_COUNT; i++) {
    MTLRenderPipelineDescriptor *pd = native_shader_descriptor(library, &kNativeShaderPipelines[i]);
    id<MTLRenderPipelineState> state = [device newRenderPipelineStateWithDescriptor:pd error:&error];
    if (state == nil) {
      fprintf(stderr, "native: the compositor's %s Metal pipeline did not build: %s\n",
              kNativeShaderPipelines[i].name,
              error == nil ? "unknown error" : [[error description] UTF8String]);
      return NULL;
    }
    [m.pipelines addObject:state];
  }
  int quad = native_shader_pipeline_index("quad");
  if (quad < 0) {
    fprintf(stderr, "native: shader_manifest.h has no quad pipeline\n");
    return NULL;
  }
  m.quadPipeline = m.pipelines[(NSUInteger)quad];
  int mask = native_shader_pipeline_index("mask");
  if (mask < 0) {
    fprintf(stderr, "native: shader_manifest.h has no mask pipeline\n");
    return NULL;
  }
  m.maskPipeline = m.pipelines[(NSUInteger)mask];
  m.textures = [NSMutableArray array];
  m.freeSlots = [NSMutableIndexSet indexSet];
  id<MTLTexture> white = mt_make_texture(m, 1, 1, MTLTextureUsageShaderRead);
  if (white == nil) return NULL;
  const unsigned char opaque_white[4] = {255, 255, 255, 255};
  [white replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:opaque_white bytesPerRow:4];
  m.white = white;
  [m.textures addObject:white]; // texture 0 is the fill colour's source
  if (layer != NULL) m.layer = (__bridge CAMetalLayer *)layer;
  m.stageLock = [[NSCondition alloc] init];
  m.stages = [NSMutableArray array];
  m.presenterOn = layer != NULL && mt_presenter_on();
  if (m.presenterOn) {
    for (int i = 0; i < MT_STAGE_SLOTS; i++) [m.stages addObject:[[MtStage alloc] init]];
    [NSThread detachNewThreadSelector:@selector(presentLoop) toTarget:m withObject:nil];
  }
  CompBackend *b = (CompBackend *)calloc(1, sizeof(CompBackend));
  if (b == NULL) return NULL;
  b->vt = &MT_VT;
  b->impl = (__bridge_retained void *)m;
  return b;
}

CompBackend *comp_metal_backend(void) { return mt_backend_with_layer(NULL); }

CompBackend *comp_metal_backend_for_layer(void *layer) { return mt_backend_with_layer(layer); }
