// The compositor's Metal pipelines, written once and used by both sides that need them: metal.m
// builds them at runtime, and capture-shaders.m names them to the Metal compiler at build time on
// a Mac without Xcode's Metal toolchain.
//
// The two sides must ask for exactly the same descriptor. A binary archive entry is keyed on the
// whole render pipeline descriptor, so a captured pipeline that differs from the runtime one in
// sample count, pixel format, or stencil format writes an entry the app never opens, and the
// compiler may then leave that function out of the metallib the app carries.
//
// A pipeline's functions are the ones the archive carries: capture-shaders archives an entry for
// every entry here, so adding a pipeline here is what makes its shader functions part of the
// build's metallib.
#ifndef NATIVE_SHADER_MANIFEST_H
#define NATIVE_SHADER_MANIFEST_H

#import <Metal/Metal.h>

#include <string.h>

/** How a pipeline blends its fragment colour into the render target. */
typedef enum {
  /** Replace the destination: the fragment writes the pixel. */
  NativeShaderBlendNone,
  /** The targets hold premultiplied colour: source + destination * (1 - source alpha). */
  NativeShaderBlendPremultiplied,
} NativeShaderBlend;

/** One render pipeline: a vertex and a fragment function, and the attachments they draw into. */
typedef struct {
  /** Short name the host asks for, as in native_shader_pipeline_index. */
  const char *name;
  const char *vertex;
  const char *fragment;
  /** Colour attachment's format and the stencil attachment's, or MTLPixelFormatInvalid for none. */
  MTLPixelFormat colorFormat;
  MTLPixelFormat stencilFormat;
  NSUInteger sampleCount;
  NativeShaderBlend blend;
} NativeShaderPipeline;

static const NativeShaderPipeline kNativeShaderPipelines[] = {
  { "quad", "quad_vertex", "quad_fragment", MTLPixelFormatBGRA8Unorm, MTLPixelFormatInvalid, 1,
    NativeShaderBlendPremultiplied },
};

#define NATIVE_SHADER_PIPELINE_COUNT (sizeof(kNativeShaderPipelines) / sizeof(kNativeShaderPipelines[0]))

/** The source's compute kernels, or just NULL when it has none yet. */
static const char *const kNativeShaderKernels[] = { NULL };

/** The descriptor the runtime builds and the build captures: one definition, so the two agree.
 *  The caller owns the returned descriptor. A function the library does not have is left nil,
 *  and building the descriptor raises that. */
static inline MTLRenderPipelineDescriptor *native_shader_descriptor(id<MTLLibrary> library,
                                                                   const NativeShaderPipeline *pipeline) {
  MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
  pd.label = [NSString stringWithUTF8String:pipeline->name];
  pd.vertexFunction = [library newFunctionWithName:[NSString stringWithUTF8String:pipeline->vertex]];
  pd.fragmentFunction = [library newFunctionWithName:[NSString stringWithUTF8String:pipeline->fragment]];
  pd.rasterSampleCount = pipeline->sampleCount;
  if (pipeline->stencilFormat != MTLPixelFormatInvalid) {
    pd.stencilAttachmentPixelFormat = pipeline->stencilFormat;
  }
  MTLRenderPipelineColorAttachmentDescriptor *att = pd.colorAttachments[0];
  att.pixelFormat = pipeline->colorFormat;
  if (pipeline->blend == NativeShaderBlendPremultiplied) {
    att.blendingEnabled = YES;
    att.rgbBlendOperation = MTLBlendOperationAdd;
    att.alphaBlendOperation = MTLBlendOperationAdd;
    att.sourceRGBBlendFactor = MTLBlendFactorOne;
    att.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    att.sourceAlphaBlendFactor = MTLBlendFactorOne;
    att.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  }
  return pd;
}

/** Where a named pipeline is in kNativeShaderPipelines, or -1. */
static inline int native_shader_pipeline_index(const char *name) {
  for (size_t i = 0; i < NATIVE_SHADER_PIPELINE_COUNT; i++) {
    if (strcmp(kNativeShaderPipelines[i].name, name) == 0) return (int)i;
  }
  return -1;
}

#endif
