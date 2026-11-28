// The compositor's pipelines: every layer is a textured quad drawn with quad_vertex and
// quad_fragment, and a 2D canvas's fills can be drawn with sdf_vertex and sdf_fragment, which work
// out each edge's coverage from the shape instead of sampling it. The build compiles this file into
// the metallib the app carries, so a launch never compiles it.
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

// A canvas fill an implicit shape describes: a rect or an oval. The host sends one per shape in one
// vertex buffer, and each shape is a quad over its device-space bounds, padded by a pixel and a
// half so the edge's coverage ramp has room. The fragment converts the interpolated local point to
// a distance in device pixels and turns that into coverage, which is smooth at any fractional
// position without multisampling.
struct SdfShape {
  float4 m;      // a, b, c, d: local x, local y -> device x = a*x + c*y + tx, y = b*x + d*y + ty
  float4 origin; // tx, ty, kind (1 rect, 2 oval), unused
  float4 box;    // x, y, w, h in local space
  float4 radii;  // oval: rx, ry; rect: unused
  float4 color;  // premultiplied
};

struct SdfOut { float4 pos [[position]]; float2 local; uint which [[flat]]; };

static float2 sdf_device(const device SdfShape &s, float2 p) {
  return float2(s.m.x * p.x + s.m.z * p.y + s.origin.x,
                s.m.y * p.x + s.m.w * p.y + s.origin.y);
}

vertex SdfOut sdf_vertex(uint vid [[vertex_id]], const device SdfShape *shapes [[buffer(0)]],
                         constant float2 &view [[buffer(1)]]) {
  uint which = vid / 6u;
  const device SdfShape &s = shapes[which];
  // Two triangles for the shape's quad: (0,0) (1,0) (1,1), then (0,0) (1,1) (0,1).
  uint k = vid % 6u;
  float2 corner = float2((k == 1u || k == 2u || k == 4u) ? 1.0f : 0.0f,
                         (k == 2u || k == 4u || k == 5u) ? 1.0f : 0.0f);
  float2 q00 = sdf_device(s, s.box.xy);
  float2 q10 = sdf_device(s, s.box.xy + float2(s.box.z, 0.0f));
  float2 q11 = sdf_device(s, s.box.xy + s.box.zw);
  float2 q01 = sdf_device(s, s.box.xy + float2(0.0f, s.box.w));
  float2 lo = min(min(q00, q10), min(q11, q01)) - 1.5f;
  float2 hi = max(max(q00, q10), max(q11, q01)) + 1.5f;
  float2 q = float2(corner.x > 0.5f ? hi.x : lo.x, corner.y > 0.5f ? hi.y : lo.y);
  SdfOut o;
  o.pos = float4(q.x / view.x * 2.0f - 1.0f, 1.0f - q.y / view.y * 2.0f, 0.0f, 1.0f);
  // The local point this padded corner maps back to, so the local coordinate the fragment gets is
  // the exact inverse of the shape's transform at every pixel.
  float det = s.m.x * s.m.w - s.m.y * s.m.z;
  float2 t = q - s.origin.xy;
  o.local = float2((s.m.w * t.x - s.m.z * t.y) / det, (-s.m.y * t.x + s.m.x * t.y) / det);
  o.which = which;
  return o;
}

fragment float4 sdf_fragment(SdfOut in [[stage_in]], const device SdfShape *shapes [[buffer(0)]]) {
  const SdfShape s = shapes[in.which];
  float2 p = in.local;
  float2 c = s.box.xy + s.box.zw * 0.5f;
  float det = s.m.x * s.m.w - s.m.y * s.m.z;
  float cov;
  if (s.origin.z < 1.5f) {
    // A rect's coverage is the product of its two edges' coverages: the area of the pixel on the
    // shape's side of each edge, which is exact for an axis-aligned rect and a close estimate
    // when it is turned. The device distance along each local axis is the local distance over the
    // length of that axis's device-space gradient.
    float2 h = s.box.zw * 0.5f;
    float2 v = abs(p - c) - h;
    float sx = length(float2(s.m.w / det, -s.m.z / det));
    float sy = length(float2(-s.m.y / det, s.m.x / det));
    float cx = clamp(0.5f - v.x / max(sx, 1e-6f), 0.0f, 1.0f);
    float cy = clamp(0.5f - v.y / max(sy, 1e-6f), 0.0f, 1.0f);
    cov = cx * cy;
  } else {
    // An oval's edge at the pixel centre: its implicit value over its device-space gradient.
    float2 r = max(s.radii.xy, float2(1e-5f));
    float2 u = (p - c) / r;
    float l = max(length(u), 1e-5f);
    float2 g = (p - c) / (r * r * l);
    float2 dg = float2((s.m.w * g.x - s.m.y * g.y) / det, (-s.m.z * g.x + s.m.x * g.y) / det);
    cov = clamp(0.5f - (l - 1.0f) / max(length(dg), 1e-6f), 0.0f, 1.0f);
  }
  return float4(s.color.rgb * cov, s.color.a * cov);
}
