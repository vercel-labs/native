// The compositor's one pipeline: every layer is a textured quad drawn with these two functions.
// The build compiles this file into the metallib the app carries, so a launch never compiles it.
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
  float4x4 m;
  float4 params;
  float2 view;
  float2 flags; // MT_SAMPLE_* bits (metal.m), then unused
  float4 tint;
};
struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut quad_vertex(uint vid [[vertex_id]], constant Uniforms &u [[buffer(0)]]) {
  float2 c = float2((vid & 1) ? 1.0f : 0.0f, (vid & 2) ? 1.0f : 0.0f);
  float2 src = float2(c.x * u.params.y, c.y * u.params.z);
  float4 d = u.m * float4(src, 0.0f, 1.0f);
  VOut o;
  o.pos = float4(d.x / u.view.x * 2.0f - 1.0f, 1.0f - d.y / u.view.y * 2.0f, 0.0, 1.0);
  o.uv = c;
  return o;
}

fragment float4 quad_fragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],
                              constant Uniforms &u [[buffer(0)]]) {
  constexpr sampler s(coord::normalized, filter::nearest, address::clamp_to_edge);
  if (u.params.w > 0.0f) {
    float2 size = float2(u.params.y, u.params.z);
    float2 p = in.uv * size;
    float2 q = abs(p - size * 0.5f) - (size * 0.5f - u.params.w);
    if (max(q.x, q.y) > 0.0f) discard_fragment();
  }
  constexpr sampler lin(coord::normalized, filter::linear, address::clamp_to_edge);
  uint f = uint(u.flags.x);
  // A quad that scales or turns its texels filters between them (MT_SAMPLE_LINEAR).
  float4 c = (f & 4u) != 0u ? tex.sample(lin, in.uv) : tex.sample(s, in.uv);
  // A WebGL buffer holds straight colour (MT_SAMPLE_PREMULTIPLY), and one without `alpha` is
  // opaque whatever its alpha channel says (MT_SAMPLE_OPAQUE).
  if ((f & 2u) != 0u) c.a = 1.0f;
  if ((f & 1u) != 0u) c.rgb *= c.a;
  return float4(c.rgb * u.tint.rgb, c.a * u.tint.a) * u.params.x;
}

// A mask the compositor split: the content's texels cut by the mask image's alpha, both sampled at
// the same point of the same rect. The content is premultiplied, so scaling every channel by the
// coverage is what the CPU path's per-channel multiply does.
fragment float4 quad_mask_fragment(VOut in [[stage_in]], texture2d<float> content [[texture(0)]],
                                   texture2d<float> mask [[texture(1)]],
                                   constant Uniforms &u [[buffer(0)]]) {
  constexpr sampler s(coord::normalized, filter::nearest, address::clamp_to_edge);
  float4 c = content.sample(s, in.uv);
  float a = mask.sample(s, in.uv).a;
  return c * a * u.params.x;
}
