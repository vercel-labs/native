// Build-time helper for a Mac without Xcode's Metal toolchain: it compiles compositor/shaders.metal
// with the Metal compiler every Mac has, and writes the AIR metallib that compiler produced for
// the compositor's pipeline. `xcrun metal` and `metallib` are the usual way to make that file,
// but they ship with Xcode; a Mac with only the command line tools has no way to ask the compiler
// for its output. It does leave the AIR library in its cache when a binary archive is written, so
// the helper writes one and takes the library.
//
// The app opens what it wrote with newLibraryWithData, the same as a metallib from `xcrun metal`.
// The build only uses the file after loading it and building the compositor's pipeline from it;
// when the helper cannot, the build falls back to compiling the shaders at launch.
//
// Usage: capture-shaders <source.metal> <out.metallib>

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <limits.h>
#include <stdio.h>
#include <unistd.h>

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

/** Builds the compositor's pipeline from a library, which is what says the library is the
 *  shaders a render pass can use. */
static BOOL usable(id<MTLDevice> device, id<MTLLibrary> library) {
  id<MTLFunction> vertex = [library newFunctionWithName:@"quad_vertex"];
  id<MTLFunction> fragment = [library newFunctionWithName:@"quad_fragment"];
  if (vertex == nil || fragment == nil) return NO;
  MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
  pd.vertexFunction = vertex;
  pd.fragmentFunction = fragment;
  pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
  return [device newRenderPipelineStateWithDescriptor:pd error:NULL] != nil;
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
    // entry from its cache. It is not part of the pipeline, and the archive below holds only the
    // pipeline's functions.
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
    MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
    pd.vertexFunction = [library newFunctionWithName:@"quad_vertex"];
    pd.fragmentFunction = [library newFunctionWithName:@"quad_fragment"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    // Writing an archive is what makes the compiler put the AIR library in its cache.
    MTLBinaryArchiveDescriptor *bd = [[MTLBinaryArchiveDescriptor alloc] init];
    id<MTLBinaryArchive> archive = [device newBinaryArchiveWithDescriptor:bd error:&error];
    NSString *scratch = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"native-shaders-%d.archive", getpid()]];
    // Every fragment function the source has must reach the archive: the compiler writes the AIR
    // for the functions a pipeline names, and an archive that named only the quad would drop the
    // blur and backdrop fragments the compositor also builds pipelines from.
    NSMutableArray<MTLRenderPipelineDescriptor *> *pipelines = [NSMutableArray array];
    [pipelines addObject:pd];
    for (NSString *name in @[@"blur_fragment", @"backdrop_fragment"]) {
      id<MTLFunction> fragment = [library newFunctionWithName:name];
      if (fragment == nil) continue;
      MTLRenderPipelineDescriptor *extra = [[MTLRenderPipelineDescriptor alloc] init];
      extra.vertexFunction = [library newFunctionWithName:@"quad_vertex"];
      extra.fragmentFunction = fragment;
      extra.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
      [pipelines addObject:extra];
    }
    BOOL archived = archive != nil;
    for (MTLRenderPipelineDescriptor *p in pipelines) {
      if (archived && ![archive addRenderPipelineFunctionsWithDescriptor:p error:&error]) archived = NO;
    }
    if (!archived ||
        ![archive serializeToURL:[NSURL fileURLWithPath:scratch] error:&error]) {
      fprintf(stderr, "capture-shaders: the Metal compiler did not write an archive: %s\n",
              error == nil ? "unknown error" : [[error description] UTF8String]);
      return 1;
    }
    [[NSFileManager defaultManager] removeItemAtPath:scratch error:NULL];
    // The archive's library is the one the compiler wrote for this run; earlier builds' entries
    // were in the cache before it started, so they are not candidates.
    NSData *chosen = nil;
    for (NSString *path in air_libraries()) {
      if ([before containsObject:path]) continue;
      NSData *data = [NSData dataWithContentsOfFile:path];
      if (data.length == 0) continue;
      dispatch_data_t bytes = dispatch_data_create(data.bytes, data.length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
      id<MTLLibrary> candidate = [device newLibraryWithData:bytes error:NULL];
      // A dynamic library shares the compiler's cache but has no render entry points; asking it
      // for a function fails, so it is left alone.
      if (candidate == nil || candidate.type != MTLLibraryTypeExecutable) continue;
      if (usable(device, candidate)) {
        chosen = data;
        break;
      }
    }
    if (chosen == nil) {
      fprintf(stderr, "capture-shaders: the compiler wrote no metallib this build can use\n");
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
