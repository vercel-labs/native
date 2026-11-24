// The D3D11 backend: textures on the host's own device, every layer a textured quad drawn by
// one pipeline, into the window's swap chain's back buffer or an offscreen texture. It
// implements the same table software.c and metal.m do, so the chunk walk, the layer cache and
// the compositor's own code are shared across the platforms.
//
// The textures are BGRA8 surfaces Direct2D can also target (see d3d11.h): the host rasters a
// chunk through its existing paint code straight into a texture, and the quad that composites it
// reads the very same surface. No pixel is read back on the way from paint to screen.

#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <d3dcompiler.h>

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "backend.h"
#include "d3d11_backend.h"

#define D11_MAX_TEX 4096

/** A quad's uniform block. It must match the shader's `U` byte for byte. */
typedef struct {
  float m[16];     // source pixels -> device pixels, column-major
  float params[4]; // opacity, source width, source height, corner radius
  float view[2];   // device width, height
  float pad[2];
  float tint[4];   // colour multiplied into the sample, white for a plain quad
} D11Uniforms;

typedef struct {
  ID3D11Texture2D *tex;
  ID3D11ShaderResourceView *srv;
  ID3D11RenderTargetView *rtv; // made on first use, for a pass that draws into this texture
  int w, h;
} D11Texture;

typedef struct {
  ID3D11Device *device;
  ID3D11DeviceContext *context;
  ID3D11VertexShader *vs;
  ID3D11PixelShader *ps;
  ID3D11Buffer *uniforms;
  ID3D11BlendState *blend;
  ID3D11RasterizerState *raster;
  ID3D11SamplerState *sampler;
  ID3D11SamplerState *linear;      // for a quad not at whole device pixels, which resamples
  ID3D11SamplerState *bound;       // the sampler the pass has bound
  ID3D11ShaderResourceView *white; // a 1x1 opaque white texel, the fill colour's source
  ID3D11Texture2D *white_tex;
  HMODULE compiler;                // d3dcompiler_47, which made the shaders and owns their blobs
  IDXGISwapChain1 *swap;           // the window's chain, when there is one
  ID3D11Texture2D *drawable;       // the back buffer a pass drew into
  ID3D11RenderTargetView *drawable_rtv;
  ID3D11Texture2D *target;         // the texture the current pass draws into
  int target_slot;                 // its slot, or -1 for the drawable
  D11Texture textures[D11_MAX_TEX];
  int free_slots[D11_MAX_TEX];
  int free_count;
  int used;
  int width, height;
  int at_drawable;
  uint32_t clear_background;
  int last_target; // the texture the last pass drew into, for a readback of -1
  int lost;
} D11Backend;

static const char *D11_SHADER =
    "cbuffer U : register(b0) {\n"
    "  float4x4 m;\n"
    "  float4 params;\n"
    "  float2 view;\n"
    "  float2 pad;\n"
    "  float4 tint;\n"
    "};\n"
    "struct VOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; };\n"
    "VOut vs_main(uint vid : SV_VertexID) {\n"
    "  float2 c = float2((vid & 1) ? 1.0 : 0.0, (vid & 2) ? 1.0 : 0.0);\n"
    "  float2 src = float2(c.x * params.y, c.y * params.z);\n"
    "  float4 d = mul(m, float4(src, 0.0, 1.0));\n"
    "  VOut o;\n"
    "  o.pos = float4(d.x / view.x * 2.0 - 1.0, 1.0 - d.y / view.y * 2.0, 0.0, 1.0);\n"
    "  o.uv = c;\n"
    "  return o;\n"
    "}\n"
    "Texture2D tex : register(t0);\n"
    "SamplerState samp : register(s0);\n"
    "float4 ps_main(VOut i) : SV_TARGET {\n"
    "  if (params.w > 0.0) {\n"
    "    float2 size = float2(params.y, params.z);\n"
    "    float2 p = i.uv * size;\n"
    "    float2 q = abs(p - size * 0.5) - (size * 0.5 - params.w);\n"
    "    if (max(q.x, q.y) > 0.0) discard;\n"
    "  }\n"
    "  float4 c = tex.Sample(samp, i.uv);\n"
    "  return float4(c.rgb * tint.rgb, c.a * tint.a) * params.x;\n"
    "}\n";

/** Whether the backend prints what it is drawing to, for a host whose pixels go missing. */
static int d11_debug(void) {
  static int on = -1;
  if (on < 0) {
    const char *env = getenv("NATIVE_D3D11_DEBUG");
    on = env != NULL && env[0] != 0;
  }
  return on;
}

static D11Backend *d11_of(CompBackend *b) { return (D11Backend *)b->impl; }

static D11Texture *d11_tex(D11Backend *d, int tex) {
  if (tex < 0 || tex >= D11_MAX_TEX) return NULL;
  return d->textures[tex].tex != NULL ? &d->textures[tex] : NULL;
}

/** Compiles one shader stage from the backend's source, through the system's shader compiler. */
typedef HRESULT(WINAPI *D3DCompileFn)(LPCVOID, SIZE_T, LPCSTR, const D3D_SHADER_MACRO *, ID3DInclude *,
                                      LPCSTR, LPCSTR, UINT, UINT, ID3DBlob **, ID3DBlob **);

static ID3DBlob *d11_compile(D11Backend *d, const char *entry, const char *target) {
  // The blob's own code lives in the compiler library, so the library stays loaded for as long
  // as the backend might read it.
  if (d->compiler == NULL) d->compiler = LoadLibraryA("d3dcompiler_47.dll");
  if (d->compiler == NULL) return NULL;
  D3DCompileFn compile = (D3DCompileFn)(void *)GetProcAddress(d->compiler, "D3DCompile");
  ID3DBlob *code = NULL;
  ID3DBlob *errors = NULL;
  if (compile == NULL) return NULL;
  HRESULT hr = compile(D11_SHADER, strlen(D11_SHADER), "compositor", NULL, NULL, entry, target,
                       D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &code, &errors);
  if (FAILED(hr)) {
    if (errors != NULL) {
      fprintf(stderr, "native: the compositor's D3D11 shaders did not compile (%.*s)\n",
              (int)errors->GetBufferSize(), (const char *)errors->GetBufferPointer());
      errors->Release();
    }
    code = NULL;
  } else if (errors != NULL) {
    errors->Release();
  }
  return code;
}

static int d11_make_pipeline(D11Backend *d) {
  ID3DBlob *vs = d11_compile(d, "vs_main", "vs_4_0");
  ID3DBlob *ps = d11_compile(d, "ps_main", "ps_4_0");
  if (vs == NULL || ps == NULL) {
    if (vs) vs->Release();
    if (ps) ps->Release();
    return 0;
  }
  HRESULT hr = d->device->CreateVertexShader(vs->GetBufferPointer(), vs->GetBufferSize(), NULL, &d->vs);
  if (SUCCEEDED(hr))
    hr = d->device->CreatePixelShader(ps->GetBufferPointer(), ps->GetBufferSize(), NULL, &d->ps);
  vs->Release();
  ps->Release();
  if (FAILED(hr)) return 0;

  D3D11_BUFFER_DESC cb = {};
  cb.ByteWidth = sizeof(D11Uniforms);
  cb.Usage = D3D11_USAGE_DYNAMIC;
  cb.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
  cb.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
  if (FAILED(d->device->CreateBuffer(&cb, NULL, &d->uniforms))) return 0;

  D3D11_BLEND_DESC bd = {};
  bd.RenderTarget[0].BlendEnable = TRUE;
  // The textures hold premultiplied alpha, so the source is taken as it is.
  bd.RenderTarget[0].SrcBlend = D3D11_BLEND_ONE;
  bd.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
  bd.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
  bd.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
  bd.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA;
  bd.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
  bd.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
  if (FAILED(d->device->CreateBlendState(&bd, &d->blend))) return 0;

  D3D11_RASTERIZER_DESC rd = {};
  rd.FillMode = D3D11_FILL_SOLID;
  rd.CullMode = D3D11_CULL_NONE;
  rd.ScissorEnable = TRUE;
  rd.DepthClipEnable = TRUE;
  if (FAILED(d->device->CreateRasterizerState(&rd, &d->raster))) return 0;

  D3D11_SAMPLER_DESC sd = {};
  sd.Filter = D3D11_FILTER_MIN_MAG_MIP_POINT;
  sd.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
  sd.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
  sd.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
  sd.MaxLOD = D3D11_FLOAT32_MAX;
  if (FAILED(d->device->CreateSamplerState(&sd, &d->sampler))) return 0;
  sd.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
  if (FAILED(d->device->CreateSamplerState(&sd, &d->linear))) return 0;
  return 1;
}

static int d11_make_white(D11Backend *d) {
  D3D11_TEXTURE2D_DESC td = {};
  td.Width = 1;
  td.Height = 1;
  td.MipLevels = 1;
  td.ArraySize = 1;
  td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  td.SampleDesc.Count = 1;
  td.Usage = D3D11_USAGE_DEFAULT;
  td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
  const unsigned char texel[4] = {255, 255, 255, 255};
  D3D11_SUBRESOURCE_DATA data = {};
  data.pSysMem = texel;
  data.SysMemPitch = 4;
  if (FAILED(d->device->CreateTexture2D(&td, &data, &d->white_tex))) return 0;
  return SUCCEEDED(d->device->CreateShaderResourceView((ID3D11Resource *)d->white_tex, NULL, &d->white));
}

static int d11_tex_create(CompBackend *b, int w, int h) {
  D11Backend *d = d11_of(b);
  if (w <= 0 || h <= 0) return -1;
  if (d->free_count == 0 && d->used >= D11_MAX_TEX) return -1;
  D3D11_TEXTURE2D_DESC td = {};
  td.Width = (UINT)w;
  td.Height = (UINT)h;
  td.MipLevels = 1;
  td.ArraySize = 1;
  td.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  td.SampleDesc.Count = 1;
  td.Usage = D3D11_USAGE_DEFAULT;
  // A render target so Direct2D can paint into it, and a shader resource so the quad reads it.
  td.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
  ID3D11Texture2D *tex = NULL;
  HRESULT hr = d->device->CreateTexture2D(&td, NULL, &tex);
  if (FAILED(hr) || tex == NULL) return -1;
  ID3D11ShaderResourceView *srv = NULL;
  if (FAILED(d->device->CreateShaderResourceView((ID3D11Resource *)tex, NULL, &srv))) {
    tex->Release();
    return -1;
  }
  int slot;
  if (d->free_count > 0) {
    slot = d->free_slots[--d->free_count];
  } else {
    slot = d->used++;
  }
  D11Texture *t = &d->textures[slot];
  t->tex = tex;
  t->srv = srv;
  t->rtv = NULL;
  t->w = w;
  t->h = h;
  return slot;
}

static void d11_tex_upload(CompBackend *b, int tex, CompRect dst, const unsigned char *pixels, int stride) {
  D11Backend *d = d11_of(b);
  D11Texture *t = d11_tex(d, tex);
  if (t == NULL || pixels == NULL || dst.w <= 0 || dst.h <= 0) return;
  if (dst.x < 0) { pixels += (size_t)(-dst.x) * 4u; dst.w += dst.x; dst.x = 0; }
  if (dst.y < 0) { pixels += (size_t)(-dst.y) * (size_t)stride; dst.h += dst.y; dst.y = 0; }
  if (dst.x + dst.w > t->w) dst.w = t->w - dst.x;
  if (dst.y + dst.h > t->h) dst.h = t->h - dst.y;
  if (dst.w <= 0 || dst.h <= 0) return;
  // The core holds premultiplied RGBA; the texture is BGRA.
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
  D3D11_BOX box;
  box.left = (UINT)dst.x;
  box.top = (UINT)dst.y;
  box.front = 0;
  box.right = (UINT)(dst.x + dst.w);
  box.bottom = (UINT)(dst.y + dst.h);
  box.back = 1;
  d->context->UpdateSubresource((ID3D11Resource *)t->tex, 0, &box, rows, (UINT)dst.w * 4u, 0);
  free(rows);
}

static void d11_tex_destroy(CompBackend *b, int tex) {
  D11Backend *d = d11_of(b);
  D11Texture *t = d11_tex(d, tex);
  if (t == NULL) return;
  if (d->target == t->tex) {
    d->context->OMSetRenderTargets(0, NULL, NULL);
    if (d->drawable_rtv != NULL) {
      d->drawable_rtv->Release();
      d->drawable_rtv = NULL;
    }
    d->target = NULL;
    d->target_slot = -1;
    d->at_drawable = 0;
  }
  if (t->srv) t->srv->Release();
  if (t->rtv) t->rtv->Release();
  t->tex->Release();
  t->tex = NULL;
  t->srv = NULL;
  t->rtv = NULL;
  t->w = t->h = 0;
  if (d->free_count < D11_MAX_TEX) d->free_slots[d->free_count++] = tex;
}

static void d11_clear(D11Backend *d, uint32_t background) {
  float rgba[4];
  float a = (float)(background & 255u) / 255.0f;
  // The target holds premultiplied alpha, as Direct2D's clear of the same colour stores it.
  rgba[0] = (float)((background >> 24) & 255u) / 255.0f * a;
  rgba[1] = (float)((background >> 16) & 255u) / 255.0f * a;
  rgba[2] = (float)((background >> 8) & 255u) / 255.0f * a;
  rgba[3] = a;
  d->context->ClearRenderTargetView(d->drawable_rtv, rgba);
}

/** Ends any pass in flight: unbinds the target and the quad's texture, and nothing is presented
 *  until `present`. */
static void d11_end_pass(D11Backend *d) {
  if (d->target != NULL || d->drawable_rtv != NULL) {
    ID3D11ShaderResourceView *none = NULL;
    d->context->PSSetShaderResources(0, 1, &none);
    d->context->OMSetRenderTargets(0, NULL, NULL);
  }
  if (d->drawable_rtv != NULL) {
    d->drawable_rtv->Release();
    d->drawable_rtv = NULL;
  }
  if (d->drawable != NULL) {
    d->drawable->Release();
    d->drawable = NULL;
  }
  d->target = NULL;
  d->target_slot = -1;
  d->at_drawable = 0;
}

static void d11_pass_begin(CompBackend *b, int target, int w, int h, uint32_t background) {
  D11Backend *d = d11_of(b);
  d11_end_pass(d);
  if (w <= 0 || h <= 0) return;
  d->width = w;
  d->height = h;
  d->last_target = target;
  if (target >= 0) {
    D11Texture *t = d11_tex(d, target);
    if (t == NULL) return;
    if (t->rtv == NULL) {
      if (FAILED(d->device->CreateRenderTargetView((ID3D11Resource *)t->tex, NULL, &t->rtv))) return;
    }
    d->target = t->tex;
    d->target_slot = target;
    d->drawable_rtv = t->rtv;
    d->drawable_rtv->AddRef();
  } else {
    if (d->swap == NULL) return;
    ID3D11Texture2D *back = NULL;
    if (FAILED(d->swap->GetBuffer(0, __uuidof(ID3D11Texture2D), (void **)&back)) || back == NULL) return;
    ID3D11RenderTargetView *rtv = NULL;
    if (FAILED(d->device->CreateRenderTargetView((ID3D11Resource *)back, NULL, &rtv))) {
      back->Release();
      return;
    }
    d->drawable = back;
    d->drawable_rtv = rtv;
    d->at_drawable = 1;
  }
  D3D11_VIEWPORT vp = {};
  vp.Width = (FLOAT)w;
  vp.Height = (FLOAT)h;
  vp.MaxDepth = 1.0f;
  d->context->RSSetViewports(1, &vp);
  D3D11_RECT scissor = {0, 0, w, h};
  d->context->RSSetScissorRects(1, &scissor);
  d->context->OMSetRenderTargets(1, &d->drawable_rtv, NULL);
  d->clear_background = background;
  d11_clear(d, background);
  d->context->IASetInputLayout(NULL);
  d->context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
  d->context->VSSetShader(d->vs, NULL, 0);
  d->context->PSSetShader(d->ps, NULL, 0);
  d->context->PSSetSamplers(0, 1, &d->sampler);
  d->bound = d->sampler;
  d->context->OMSetBlendState(d->blend, NULL, 0xffffffff);
  d->context->RSSetState(d->raster);
  d->context->VSSetConstantBuffers(0, 1, &d->uniforms);
  d->context->PSSetConstantBuffers(0, 1, &d->uniforms);
  if (d11_debug())
    fprintf(stderr, "native: d3d11 pass target=%d %dx%d bg=%08x\n", target, w, h, (unsigned)background);
}

static void d11_draw(CompBackend *b, int tex, CompRect src, const CompMatrix *matrix, float opacity,
                     const CompRect *clip, float radius, const float tint[4]) {
  D11Backend *d = d11_of(b);
  D11Texture *t = d11_tex(d, tex);
  if (d->drawable_rtv == NULL || t == NULL || opacity <= 0.0f || src.w <= 0 || src.h <= 0) return;
  D11Uniforms u;
  memset(&u, 0, sizeof(u));
  if (matrix != NULL) memcpy(u.m, matrix->m, sizeof(u.m));
  else {
    u.m[0] = u.m[5] = u.m[10] = u.m[15] = 1.0f;
  }
  u.params[0] = opacity;
  u.params[1] = (float)src.w;
  u.params[2] = (float)src.h;
  u.params[3] = radius > 0.0f ? radius : 0.0f;
  u.view[0] = (float)d->width;
  u.view[1] = (float)d->height;
  memcpy(u.tint, tint, sizeof(u.tint));
  D3D11_MAPPED_SUBRESOURCE mapped;
  if (FAILED(d->context->Map((ID3D11Resource *)d->uniforms, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped))) return;
  memcpy(mapped.pData, &u, sizeof(u));
  d->context->Unmap((ID3D11Resource *)d->uniforms, 0);
  D3D11_RECT scissor = {0, 0, d->width, d->height};
  if (clip != NULL && clip->w > 0 && clip->h > 0) {
    int x0 = clip->x > 0 ? clip->x : 0;
    int y0 = clip->y > 0 ? clip->y : 0;
    int x1 = clip->x + clip->w < d->width ? clip->x + clip->w : d->width;
    int y1 = clip->y + clip->h < d->height ? clip->y + clip->h : d->height;
    if (x1 <= x0 || y1 <= y0) return;
    scissor.left = x0;
    scissor.top = y0;
    scissor.right = x1;
    scissor.bottom = y1;
  }
  d->context->RSSetScissorRects(1, &scissor);
  // A texel lands on a device pixel only under a whole-pixel translation; any other matrix (a
  // moving or turning layer drawn from a picture rastered elsewhere) samples between texels.
  int exact = u.m[0] == 1.0f && u.m[1] == 0.0f && u.m[4] == 0.0f && u.m[5] == 1.0f &&
              u.m[12] == floorf(u.m[12]) && u.m[13] == floorf(u.m[13]);
  ID3D11SamplerState *want = exact || d->linear == NULL ? d->sampler : d->linear;
  if (want != d->bound) {
    d->context->PSSetSamplers(0, 1, &want);
    d->bound = want;
  }
  d->context->PSSetShaderResources(0, 1, &t->srv);
  d->context->Draw(4, 0);
  if (d11_debug())
    fprintf(stderr, "native: d3d11 draw tex=%d src=%dx%d opacity=%.2f view=%dx%d\n", tex, src.w,
            src.h, opacity, d->width, d->height);
}

static void d11_draw_quad(CompBackend *b, int tex, CompRect src, const CompMatrix *matrix, float opacity,
                          const CompRect *clip, float radius) {
  static const float white[4] = {1.0f, 1.0f, 1.0f, 1.0f};
  d11_draw(b, tex, src, matrix, opacity, clip, radius, white);
}

static void d11_fill_rect(CompBackend *b, CompRect rect, uint32_t color) {
  D11Backend *d = d11_of(b);
  if (d->white == NULL || rect.w <= 0 || rect.h <= 0) return;
  CompMatrix mtx = comp_matrix_mul(comp_matrix_translate((float)rect.x, (float)rect.y),
                                   comp_matrix_scale((float)rect.w, (float)rect.h));
  float tint[4] = {
      (float)((color >> 24) & 255u) / 255.0f,
      (float)((color >> 16) & 255u) / 255.0f,
      (float)((color >> 8) & 255u) / 255.0f,
      1.0f,
  };
  // The fill goes through the same quad shader, with the one white texel bound instead of a
  // texture slot.
  if (d->drawable_rtv == NULL) return;
  D11Uniforms uni;
  memset(&uni, 0, sizeof(uni));
  memcpy(uni.m, mtx.m, sizeof(uni.m));
  uni.params[0] = (float)(color & 255u) / 255.0f;
  uni.params[1] = 1.0f;
  uni.params[2] = 1.0f;
  uni.params[3] = 0.0f;
  uni.view[0] = (float)d->width;
  uni.view[1] = (float)d->height;
  memcpy(uni.tint, tint, sizeof(uni.tint));
  D3D11_MAPPED_SUBRESOURCE mapped;
  if (FAILED(d->context->Map((ID3D11Resource *)d->uniforms, 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped))) return;
  memcpy(mapped.pData, &uni, sizeof(uni));
  d->context->Unmap((ID3D11Resource *)d->uniforms, 0);
  D3D11_RECT scissor = {0, 0, d->width, d->height};
  d->context->RSSetScissorRects(1, &scissor);
  d->context->PSSetShaderResources(0, 1, &d->white);
  d->context->Draw(4, 0);
}

static int d11_readback(CompBackend *b, int target, CompRect rect, unsigned char *out, int stride) {
  D11Backend *d = d11_of(b);
  if (out == NULL) return 0;
  d11_end_pass(d);
  D11Texture *t = target >= 0 ? d11_tex(d, target) : (d->last_target >= 0 ? d11_tex(d, d->last_target) : NULL);
  if (t == NULL) return 0;
  int rx = rect.x < 0 ? 0 : rect.x;
  int ry = rect.y < 0 ? 0 : rect.y;
  int rw = rect.x < 0 ? rect.w + rect.x : rect.w;
  int rh = rect.y < 0 ? rect.h + rect.y : rect.h;
  if (rx + rw > t->w) rw = t->w - rx;
  if (ry + rh > t->h) rh = t->h - ry;
  if (rw < 0) rw = 0;
  if (rh < 0) rh = 0;
  unsigned char *rows = NULL;
  if (rw > 0 && rh > 0) {
    D3D11_TEXTURE2D_DESC sd = {};
    sd.Width = (UINT)rw;
    sd.Height = (UINT)rh;
    sd.MipLevels = 1;
    sd.ArraySize = 1;
    sd.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    sd.SampleDesc.Count = 1;
    sd.Usage = D3D11_USAGE_STAGING;
    sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ID3D11Texture2D *staging = NULL;
    if (FAILED(d->device->CreateTexture2D(&sd, NULL, &staging)) || staging == NULL) return 0;
    D3D11_BOX box;
    box.left = (UINT)rx;
    box.top = (UINT)ry;
    box.front = 0;
    box.right = (UINT)(rx + rw);
    box.bottom = (UINT)(ry + rh);
    box.back = 1;
    d->context->CopySubresourceRegion((ID3D11Resource *)staging, 0, 0, 0, 0, (ID3D11Resource *)t->tex, 0,
                                      &box);
    D3D11_MAPPED_SUBRESOURCE mapped;
    if (SUCCEEDED(d->context->Map((ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &mapped))) {
      rows = (unsigned char *)malloc((size_t)rw * 4u * (size_t)rh);
      if (rows != NULL) {
        for (int y = 0; y < rh; y++)
          memcpy(rows + (size_t)y * (size_t)rw * 4u,
                 (const unsigned char *)mapped.pData + (size_t)y * (size_t)mapped.RowPitch,
                 (size_t)rw * 4u);
      }
      d->context->Unmap((ID3D11Resource *)staging, 0);
    }
    staging->Release();
  }
  for (int y = 0; y < rect.h; y++) {
    unsigned char *dst = out + (size_t)y * (size_t)stride;
    int insideY = y >= ry && y < ry + rh;
    for (int x = 0; x < rect.w; x++) {
      if (!insideY || x < rx || x >= rx + rw || rows == NULL) {
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

static void d11_present(CompBackend *b) {
  D11Backend *d = d11_of(b);
  int was_drawable = d->at_drawable;
  d11_end_pass(d);
  if (was_drawable && d->swap != NULL) {
    // Not synced to the vertical blank: the host's frame loop already paces itself to the display,
    // and the desktop compositor shows the newest frame at each refresh, so a windowed flip-model
    // chain doesn't tear. A sync interval of 1 would make this call wait for the blank as well,
    // and on a display whose blank comes late or not at all (a remote session's, a second
    // adapter's) every frame waited a refresh or more on top of the loop's own wait.
    HRESULT hr = d->swap->Present(0, 0);
    if (hr == DXGI_ERROR_DEVICE_REMOVED || hr == DXGI_ERROR_DEVICE_RESET) d->lost = 1;
  }
}

/** Releases everything a backend's state holds, and the state. */
static void d11_free(D11Backend *d) {
  if (d == NULL) return;
  d11_end_pass(d);
  for (int i = 0; i < d->used; i++) {
    D11Texture *t = &d->textures[i];
    if (t->srv) t->srv->Release();
    if (t->rtv) t->rtv->Release();
    if (t->tex) t->tex->Release();
  }
  if (d->white) d->white->Release();
  if (d->white_tex) d->white_tex->Release();
  if (d->sampler) d->sampler->Release();
  if (d->linear) d->linear->Release();
  if (d->raster) d->raster->Release();
  if (d->blend) d->blend->Release();
  if (d->uniforms) d->uniforms->Release();
  if (d->ps) d->ps->Release();
  if (d->vs) d->vs->Release();
  if (d->swap) d->swap->Release();
  if (d->compiler) FreeLibrary(d->compiler);
  if (d->context) d->context->Release();
  if (d->device) d->device->Release();
  free(d);
}

static void d11_destroy(CompBackend *b) {
  if (b == NULL) return;
  d11_free((D11Backend *)b->impl);
  b->impl = NULL;
  free(b);
}

int comp_d3d11_has_target(CompBackend *b);

static const CompBackendVTable D11_VT = {
    d11_tex_create, d11_tex_upload, d11_tex_destroy, d11_pass_begin,
    d11_draw_quad,  d11_fill_rect,  d11_readback,    d11_present,    d11_destroy,
};

CompBackend *comp_d3d11_backend(void *device) {
  if (device == NULL) return NULL;
  D11Backend *d = (D11Backend *)calloc(1, sizeof(D11Backend));
  if (d == NULL) return NULL;
  d->device = (ID3D11Device *)device;
  d->device->AddRef();
  d->device->GetImmediateContext(&d->context);
  if (d->context == NULL) {
    d->device->Release();
    free(d);
    return NULL;
  }
  d->target_slot = -1;
  d->last_target = -1;
  if (d11_debug()) { fprintf(stderr, "native: d3d11 backend start\n"); fflush(stderr); }
  if (!d11_make_pipeline(d) || !d11_make_white(d)) {
    if (d11_debug()) { fprintf(stderr, "native: d3d11 backend has no pipeline\n"); fflush(stderr); }
    d11_free(d); // the pipeline or its resources could not be made: the replay draws the window
    return NULL;
  }
  if (d11_debug()) { fprintf(stderr, "native: d3d11 backend ready\n"); fflush(stderr); }
  CompBackend *b = (CompBackend *)calloc(1, sizeof(CompBackend));
  if (b == NULL) {
    d11_free(d);
    return NULL;
  }
  b->vt = &D11_VT;
  b->impl = d;
  return b;
}

void comp_d3d11_set_swap_chain(CompBackend *b, void *swap) {
  if (b == NULL || b->impl == NULL) return;
  D11Backend *d = d11_of(b);
  if (d->swap == (IDXGISwapChain1 *)swap) return;
  if (d->swap) d->swap->Release();
  d->swap = (IDXGISwapChain1 *)swap;
  if (d->swap) d->swap->AddRef();
}

void *comp_d3d11_texture(CompBackend *b, int tex) {
  if (b == NULL || b->impl == NULL) return NULL;
  D11Texture *t = d11_tex(d11_of(b), tex);
  return t != NULL ? (void *)t->tex : NULL;
}

int comp_d3d11_device_lost(CompBackend *b) {
  if (b == NULL || b->impl == NULL) return 1;
  return d11_of(b)->lost;
}

int comp_d3d11_has_target(CompBackend *b) {
  if (b == NULL || b->impl == NULL) return 0;
  return d11_of(b)->drawable_rtv != NULL;
}
