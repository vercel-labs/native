// Build-time helper for a Mac without Xcode's Metal toolchain: it compiles compositor/shaders.metal
// with the Metal compiler every Mac has, and writes the AIR metallib that compiler produced for the
// compositor's pipelines. `xcrun metal` and `metallib` are the usual way to make that file, but
// they ship with Xcode; a Mac with only the command line tools has no way to ask the compiler for
// its output. It does leave the AIR library in its cache when a binary archive is written, so the
// helper writes one and takes the library.
//
// The pipelines it archives are shader_manifest.h's, the same descriptors the app builds at
// runtime, so an archive entry always matches the pipeline the app asks for. The compiler writes
// AIR only for the functions an entry names, so the helper also archives a pipeline for every
// function the source declares that no manifest entry names, and checks that the library it takes
// has every one of them.
//
// The app opens what it wrote with newLibraryWithData, the same as a metallib from `xcrun metal`.
// The build only uses the file after loading it and building the compositor's pipelines from it;
// when the helper cannot, the build falls back to compiling the shaders at launch.
//
// Usage: capture-shaders <source.metal> <out.metallib>

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <limits.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "shader_manifest.h"

/** The directory the Metal compiler keeps its per-user work in. */
static NSString *cache_root(void) {
  char buf[PATH_MAX];
  size_t n = confstr(_CS_DARWIN_USER_CACHE_DIR, buf, sizeof buf);
  if (n == 0) return nil;
  return [[NSString stringWithUTF8String:buf] stringByAppendingPathComponent:@"com.apple.gpuarchiver"];
}

/** Every AIR library the compiler has written to its cache. */
static NSArray<NSString *> *air_libraries(void) {
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *root = cache_root();
  NSMutableArray *out = [NSMutableArray array];
  for (NSString *dir in [fm contentsOfDirectoryAtPath:root error:NULL] ?: @[]) {
    NSString *base = [root stringByAppendingPathComponent:dir];
    for (NSString *sub in [fm contentsOfDirectoryAtPath:base error:NULL] ?: @[]) {
      // The AIR directories carry the version, as in air64_v28.
      if (![sub hasPrefix:@"air"]) continue;
      NSString *air = [base stringByAppendingPathComponent:sub];
      for (NSString *file in [fm contentsOfDirectoryAtPath:air error:NULL] ?: @[]) {
        if ([file hasSuffix:@".metallib"]) [out addObject:[air stringByAppendingPathComponent:file]];
      }
    }
  }
  return out;
}

/** Builds every manifest pipeline from a library, which is what says the library is the shaders a
 *  render pass can use. */
static BOOL usable(id<MTLDevice> device, id<MTLLibrary> library) {
  for (size_t i = 0; i < NATIVE_SHADER_PIPELINE_COUNT; i++) {
    MTLRenderPipelineDescriptor *pd = native_shader_descriptor(library, &kNativeShaderPipelines[i]);
    if (pd.vertexFunction == nil || pd.fragmentFunction == nil) return NO;
    if ([device newRenderPipelineStateWithDescriptor:pd error:NULL] == nil) return NO;
  }
  return YES;
}

/** A render pipeline that pairs two of the library's functions, if the pair compiles: a vertex
 *  and a fragment whose inputs and outputs agree. Pairing is how the helper gives a function that
 *  no manifest pipeline names an archive entry of its own. */
static MTLRenderPipelineDescriptor *pairing(id<MTLDevice> device, id<MTLLibrary> library,
                                            NSString *vertex, NSString *fragment) {
  MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
  pd.vertexFunction = [library newFunctionWithName:vertex];
  pd.fragmentFunction = [library newFunctionWithName:fragment];
  pd.colorAttachments[0].pixelFormat = kNativeShaderPipelines[0].colorFormat;
  if ([device newRenderPipelineStateWithDescriptor:pd error:NULL] == nil) return nil;
  return pd;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 3) {
      fprintf(stderr, "usage: %s <source.metal> <out.metallib>\n", argv[0]);
      return 2;
    }
    NSString *source = [NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[1]]
                                                 encoding:NSUTF8StringEncoding
                                                    error:NULL];
    if (source == nil) {
      fprintf(stderr, "capture-shaders: cannot read %s\n", argv[1]);
      return 1;
    }
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device == nil) {
      fprintf(stderr, "capture-shaders: no Metal device on this Mac\n");
      return 1;
    }
    // A function of this run's own makes the compiler compile this source rather than take an
    // entry from its cache. It is not part of any pipeline, and the archive below does not name
    // it, so it is not in the library the helper takes.
    NSString *marker = [NSString stringWithFormat:@"native_build_%d_marker", getpid()];
    NSString *marked = [source stringByAppendingFormat:
        @"\nvertex float4 %@_vertex(uint i [[vertex_id]]) { return float4(0.0); }\n", marker];
    NSSet<NSString *> *before = [NSSet setWithArray:air_libraries()];
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:marked options:NULL error:&error];
    if (library == nil || !usable(device, library)) {
      fprintf(stderr, "capture-shaders: the shaders did not compile: %s\n",
              error == nil ? "unknown error" : [[error description] UTF8String]);
      return 1;
    }
    // The manifest's own pipelines first: they are what the app builds, so their entries must
    // match the app's descriptors exactly.
    NSMutableArray<MTLRenderPipelineDescriptor *> *pipelines = [NSMutableArray array];
    NSMutableSet<NSString *> *named = [NSMutableSet set];
    for (size_t i = 0; i < NATIVE_SHADER_PIPELINE_COUNT; i++) {
      const NativeShaderPipeline *entry = &kNativeShaderPipelines[i];
      MTLRenderPipelineDescriptor *pd = native_shader_descriptor(library, entry);
      if (pd.vertexFunction == nil || pd.fragmentFunction == nil) {
        fprintf(stderr, "capture-shaders: the source has no %s or %s for the %s pipeline\n",
                entry->vertex, entry->fragment, entry->name);
        return 1;
      }
      [pipelines addObject:pd];
      [named addObject:[NSString stringWithUTF8String:entry->vertex]];
      [named addObject:[NSString stringWithUTF8String:entry->fragment]];
    }
    // Then a pipeline for every function the source declares that those did not name, so the
    // archive asks the compiler for that function's AIR too. It is paired with a function of the
    // other kind it compiles against; a function that pairs with none is reported, since the
    // library would otherwise leave it out without saying so.
    NSMutableArray<NSString *> *vertices = [NSMutableArray array];
    NSMutableArray<NSString *> *fragments = [NSMutableArray array];
    NSMutableArray<NSString *> *kernels = [NSMutableArray array];
    for (NSString *name in library.functionNames) {
      if ([name hasPrefix:marker]) continue;
      id<MTLFunction> function = [library newFunctionWithName:name];
      if (function == nil) continue;
      switch (function.functionType) {
        case MTLFunctionTypeVertex: [vertices addObject:name]; break;
        case MTLFunctionTypeFragment: [fragments addObject:name]; break;
        case MTLFunctionTypeKernel: [kernels addObject:name]; break;
        default: break;
      }
    }
    for (NSString *fragment in fragments) {
      if ([named containsObject:fragment]) continue;
      MTLRenderPipelineDescriptor *pd = nil;
      for (NSString *vertex in vertices) {
        if ((pd = pairing(device, library, vertex, fragment)) != nil) break;
      }
      if (pd == nil) {
        fprintf(stderr, "capture-shaders: no vertex function pairs with %s; the build cannot carry it\n",
                [fragment UTF8String]);
        return 1;
      }
      [pipelines addObject:pd];
    }
    for (NSString *vertex in vertices) {
      if ([named containsObject:vertex]) continue;
      MTLRenderPipelineDescriptor *pd = nil;
      for (NSString *fragment in fragments) {
        if ((pd = pairing(device, library, vertex, fragment)) != nil) break;
      }
      if (pd == nil) {
        fprintf(stderr, "capture-shaders: no fragment function pairs with %s; the build cannot carry it\n",
                [vertex UTF8String]);
        return 1;
      }
      [pipelines addObject:pd];
    }
    NSMutableArray<MTLComputePipelineDescriptor *> *computes = [NSMutableArray array];
    for (NSString *kernel in kernels) {
      MTLComputePipelineDescriptor *cp = [[MTLComputePipelineDescriptor alloc] init];
      cp.computeFunction = [library newFunctionWithName:kernel];
      if (cp.computeFunction == nil) continue;
      [computes addObject:cp];
    }
    // Writing an archive is what makes the compiler put the AIR library in its cache.
    MTLBinaryArchiveDescriptor *bd = [[MTLBinaryArchiveDescriptor alloc] init];
    id<MTLBinaryArchive> archive = [device newBinaryArchiveWithDescriptor:bd error:&error];
    NSString *scratch = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"native-shaders-%d.archive", getpid()]];
    BOOL archived = archive != nil;
    for (MTLRenderPipelineDescriptor *pd in pipelines) {
      if (archived && ![archive addRenderPipelineFunctionsWithDescriptor:pd error:&error]) {
        fprintf(stderr, "capture-shaders: cannot archive the %s pipeline: %s\n",
                [[pd label] UTF8String], error == nil ? "unknown error" : [[error description] UTF8String]);
        archived = NO;
      }
    }
    for (MTLComputePipelineDescriptor *cp in computes) {
      if (archived && ![archive addComputePipelineFunctionsWithDescriptor:cp error:&error]) {
        fprintf(stderr, "capture-shaders: cannot archive a compute pipeline: %s\n",
                error == nil ? "unknown error" : [[error description] UTF8String]);
        archived = NO;
      }
    }
    if (!archived || ![archive serializeToURL:[NSURL fileURLWithPath:scratch] error:&error]) {
      fprintf(stderr, "capture-shaders: the Metal compiler did not write an archive: %s\n",
              error == nil ? "unknown error" : [[error description] UTF8String]);
      return 1;
    }
    [[NSFileManager defaultManager] removeItemAtPath:scratch error:NULL];
    // Every function the source declares must be in the library this build carries: one that is
    // not is a pipeline the app cannot build, and the pass it draws never runs.
    NSMutableArray<NSString *> *declared = [NSMutableArray array];
    for (NSString *name in library.functionNames) {
      if (![name hasPrefix:marker]) [declared addObject:name];
    }
    // The archive's library is the one the compiler wrote for this run; earlier builds' entries
    // were in the cache before it started, so they are not candidates.
    NSData *chosen = nil;
    NSArray<NSString *> *missing = nil;
    for (NSString *path in air_libraries()) {
      if ([before containsObject:path]) continue;
      NSData *data = [NSData dataWithContentsOfFile:path];
      if (data.length == 0) continue;
      dispatch_data_t bytes = dispatch_data_create(data.bytes, data.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
      id<MTLLibrary> candidate = [device newLibraryWithData:bytes error:NULL];
      // A dynamic library shares the compiler's cache but has no render entry points; asking it
      // for a function fails, so it is left alone.
      if (candidate == nil || candidate.type != MTLLibraryTypeExecutable) continue;
      if (!usable(device, candidate)) continue;
      NSMutableArray<NSString *> *absent = [NSMutableArray array];
      for (NSString *name in declared) {
        if ([candidate newFunctionWithName:name] == nil) [absent addObject:name];
      }
      if (absent.count == 0) {
        chosen = data;
        break;
      }
      if (missing == nil) missing = absent;
    }
    if (chosen == nil) {
      if (missing != nil) {
        fprintf(stderr, "capture-shaders: the compiler's library is missing %s; a pipeline in shader_manifest.h has to name each of them\n",
                [[missing componentsJoinedByString:@", "] UTF8String]);
      } else {
        fprintf(stderr, "capture-shaders: the compiler wrote no metallib this build can use\n");
      }
      return 1;
    }
    if (![chosen writeToFile:[NSString stringWithUTF8String:argv[2]] atomically:YES]) {
      fprintf(stderr, "capture-shaders: cannot write %s\n", argv[2]);
      return 1;
    }
    printf("capture-shaders: wrote %lu bytes\n", (unsigned long)chosen.length);
    return 0;
  }
}
