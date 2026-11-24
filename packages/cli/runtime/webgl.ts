// WebGL 2: the drawing half of a <canvas> that asked for a "webgl2" context.
//
// The API runs on the host's own OpenGL 4.1 core context (host/macos.m, "WebGL2"): each canvas
// owns one, and the calls below forward one-to-one. Object handles are the GL context's names
// wrapped in classes so page code gets the API's own types. Shader sources arrive as GLSL ES 3.00
// and the host makes them desktop GLSL; every other call is shared between the two.
//
// The drawing buffer is a framebuffer object, and painting the canvas reads it back into the
// canvas bitmap, so the display list and everything else stays CoreGraphics.

import { hostCanvasCreate, hostCanvasResize, hostGlAttach, hostGlSetAlpha, hostGlActiveTexture,
  hostGlCreateBuffer, hostGlCreateTexture, hostGlCreateFramebuffer, hostGlCreateRenderbuffer,
  hostGlCreateProgram, hostGlCreateShader, hostGlCreateVertexArray, hostGlDeleteObject,
  hostGlBindBuffer, hostGlBufferData, hostGlBufferDataSize, hostGlBufferSubData, hostGlBindTexture,
  hostGlTexImage2D, hostGlTexImage2DNull, hostGlTexImage3D, hostGlTexSubImage2D,
  hostGlTexParameteri, hostGlTexParameterf, hostGlTexStorage2D, hostGlGenerateMipmap, hostGlPixelStorei,
  hostGlShaderSource, hostGlCompileShader, hostGlGetShaderParameter, hostGlGetShaderInfoLog,
  hostGlAttachShader, hostGlDetachShader, hostGlBindAttribLocation, hostGlLinkProgram,
  hostGlUseProgram, hostGlGetProgramParameter, hostGlGetProgramInfoLog, hostGlGetAttribLocation,
  hostGlGetUniformLocation, hostGlActiveUniformName, hostGlActiveUniformType, hostGlActiveUniformSize,
  hostGlActiveAttribName, hostGlActiveAttribType, hostGlActiveAttribSize, hostGlUniform1f,
  hostGlUniform1i, hostGlUniform, hostGlUniformMatrix, hostGlBindVertexArray,
  hostGlEnableVertexAttribArray, hostGlDisableVertexAttribArray, hostGlVertexAttribPointer,
  hostGlVertexAttribIPointer, hostGlVertexAttribDivisor, hostGlVertexAttrib,
  hostGlBindFramebuffer, hostGlBindRenderbuffer, hostGlFramebufferTexture2D,
  hostGlFramebufferRenderbuffer, hostGlRenderbufferStorage, hostGlCheckFramebufferStatus,
  hostGlDrawArrays, hostGlDrawElements, hostGlDrawArraysInstanced, hostGlDrawElementsInstanced,
  hostGlEnable, hostGlDisable, hostGlClear, hostGlClearColor, hostGlClearDepth, hostGlClearStencil,
  hostGlColorMask, hostGlDepthMask, hostGlStencilMask, hostGlCullFace, hostGlFrontFace,
  hostGlDepthFunc, hostGlDepthRange, hostGlBlendFunc, hostGlBlendFuncSeparate, hostGlBlendEquation,
  hostGlBlendEquationSeparate, hostGlBlendColor, hostGlPolygonOffset, hostGlStencilFunc,
  hostGlStencilOp, hostGlViewport, hostGlScissor, hostGlLineWidth, hostGlFinish, hostGlFlush,
  hostGlGetParameterInt, hostGlGetParameterInts, hostGlGetParameterFloats,
  hostGlGetParameterString, hostGlExtensionCount, hostGlExtensionString,
  hostGlTexImage2DFromImage, hostGlTexSubImage2DFromImage, hostGlDrawBuffers,
  hostGlGetError, hostGlReadPixels } from "./host.ts";
import { Event } from "./dom.ts";
import type { HTMLCanvasElement } from "./dom.ts";
import { invalidatePaint } from "./invalidation.ts";

// The array types the API accepts as data: typed arrays, or plain arrays when the page has them.
type GlView = Float32Array | Uint8Array | Uint16Array | Uint32Array | Int32Array;

/**
 * An element a texture upload reads instead of pixels: the DOM's <img>, which the host has
 * already decoded. An image uploads as RGBA8, as a browser's own does whatever the file encodes.
 */
export interface ImageSource {
  width: number;
  height: number;
  /** The host's id for the decoded image, or -1 before it loads. */
  decodedImageId(): number;
}
type FloatList = Float32Array | number[];
type IntList = Int32Array | number[];
type UIntList = Uint32Array | number[];

function toFloat32(v: FloatList): Float32Array {
  if (v instanceof Float32Array) return v;
  const out = new Float32Array(v.length);
  for (let i = 0; i < v.length; i++) out[i] = v[i];
  return out;
}

function toInt32(v: IntList): Int32Array {
  if (v instanceof Int32Array) return v;
  const out = new Int32Array(v.length);
  for (let i = 0; i < v.length; i++) out[i] = v[i];
  return out;
}

function toUint32(v: UIntList): Uint32Array {
  if (v instanceof Uint32Array) return v;
  const out = new Uint32Array(v.length);
  for (let i = 0; i < v.length; i++) out[i] = v[i];
  return out;
}

// The bytes of a typed array, as the host takes buffer and texture data.
function viewBytes(v: GlView): Uint8Array {
  if (v instanceof Uint8Array) return v;
  if (v instanceof Float32Array) return new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
  if (v instanceof Uint16Array) return new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
  if (v instanceof Uint32Array) return new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
  const ints = v as Int32Array;
  return new Uint8Array(ints.buffer, ints.byteOffset, ints.byteLength);
}

/** True when an upload's last argument is an element to read, not numbers: an <img>. */
function isImageSource(v: any): v is ImageSource {
  return v !== null && v !== undefined && typeof v === "object" &&
    typeof (v as ImageSource).decodedImageId === "function";
}

/**
 * A canvas an upload can read: its pixels are its drawing context's. The canvas class lives in
 * dom.ts, which this module is imported by, so the shape is read through the API itself rather
 * than by importing the class (which would be a cycle).
 */
interface CanvasSource {
  width: number;
  height: number;
  getContext(kind: string): any;
}

/** The pixel view of an ImageData, or of a canvas read back through its 2D context. */
interface PixelSource {
  width: number;
  height: number;
  data: Uint8Array | Uint8ClampedArray;
}

function isPixelSource(v: any): v is PixelSource {
  return v !== null && v !== undefined && typeof v === "object" &&
    typeof v.width === "number" && typeof v.height === "number" &&
    (v.data instanceof Uint8ClampedArray || v.data instanceof Uint8Array);
}

function isCanvasSource(v: any): v is CanvasSource {
  return v !== null && v !== undefined && typeof v === "object" &&
    typeof v.getContext === "function" && typeof v.width === "number" &&
    typeof v.height === "number" && !isImageSource(v) && !isPixelSource(v);
}

/** A canvas's pixels as straight RGBA, or null when it has no context that can read them. */
function canvasPixels(canvas: CanvasSource): PixelSource | null {
  const w = Math.floor(canvas.width);
  const h = Math.floor(canvas.height);
  if (!(w > 0) || !(h > 0)) return null;
  const two = canvas.getContext("2d");
  if (two !== null && two !== undefined) return two.getImageData(0, 0, w, h);
  // A canvas that draws with WebGL has no 2D context; its drawing buffer is the picture, and
  // readPixels gives it in the same straight RGBA rows.
  const gl = canvas.getContext("webgl2");
  if (gl === null || gl === undefined) return null;
  const data = new Uint8Array(w * h * 4);
  gl.readPixels(0, 0, w, h, 0x1908, 0x1401, data);
  return { width: w, height: h, data };
}

const RGBA = 0x1908;
const UNSIGNED_BYTE = 0x1401;

/** One upload's pixels with the two unpack options applied, for RGBA8 data only. */
function unpackPixels(bytes: Uint8Array, width: number, height: number, format: number, type: number,
                      flipY: boolean, premultiply: boolean): Uint8Array {
  if ((!flipY && !premultiply) || format !== RGBA || type !== UNSIGNED_BYTE) return bytes;
  const stride = width * 4;
  const out = new Uint8Array(bytes.length);
  for (let y = 0; y < height; y++) {
    const from = (flipY ? height - 1 - y : y) * stride;
    const to = y * stride;
    for (let x = 0; x < width; x++) {
      const s = from + x * 4;
      const d = to + x * 4;
      let r = bytes[s], g = bytes[s + 1], b = bytes[s + 2];
      const a = bytes[s + 3];
      if (premultiply) {
        r = (r * a + 127) / 255 | 0;
        g = (g * a + 127) / 255 | 0;
        b = (b * a + 127) / 255 | 0;
      }
      out[d] = r;
      out[d + 1] = g;
      out[d + 2] = b;
      out[d + 3] = a;
    }
  }
  return out;
}

function floatBytes(v: FloatList): Uint8Array {
  const f = toFloat32(v);
  return new Uint8Array(f.buffer, f.byteOffset, f.byteLength);
}

function intBytes(v: IntList): Uint8Array {
  const i = toInt32(v);
  return new Uint8Array(i.buffer, i.byteOffset, i.byteLength);
}

function uintBytes(v: UIntList): Uint8Array {
  const u = toUint32(v);
  return new Uint8Array(u.buffer, u.byteOffset, u.byteLength);
}

// The GL location of a uniform, or -1 for the null location that drawing has no effect on.
function loc(location: WebGLUniformLocation | null): number {
  return location === null ? -1 : location.location;
}

// ---------------------------------------------------------------------------
// The objects a context hands out. They carry the GL name and nothing else: the API gives them no
// methods or state of their own.

export class WebGLBuffer {
  get [Symbol.toStringTag](): string { return "WebGLBuffer"; }
  readonly id: number;
  constructor(id: number) {
    this.id = id;
  }
}

export class WebGLTexture {
  get [Symbol.toStringTag](): string { return "WebGLTexture"; }
  readonly id: number;
  constructor(id: number) {
    this.id = id;
  }
}

export class WebGLFramebuffer {
  get [Symbol.toStringTag](): string { return "WebGLFramebuffer"; }
  readonly id: number;
  constructor(id: number) {
    this.id = id;
  }
}

export class WebGLRenderbuffer {
  get [Symbol.toStringTag](): string { return "WebGLRenderbuffer"; }
  readonly id: number;
  constructor(id: number) {
    this.id = id;
  }
}

export class WebGLProgram {
  get [Symbol.toStringTag](): string { return "WebGLProgram"; }
  readonly id: number;
  constructor(id: number) {
    this.id = id;
  }
}

export class WebGLShader {
  get [Symbol.toStringTag](): string { return "WebGLShader"; }
  readonly id: number;
  constructor(id: number) {
    this.id = id;
  }
}

export class WebGLVertexArrayObject {
  get [Symbol.toStringTag](): string { return "WebGLVertexArrayObject"; }
  readonly id: number;
  constructor(id: number) {
    this.id = id;
  }
}

export class WebGLUniformLocation {
  get [Symbol.toStringTag](): string { return "WebGLUniformLocation"; }
  readonly location: number;
  constructor(location: number) {
    this.location = location;
  }
}

export class WebGLActiveInfo {
  get [Symbol.toStringTag](): string { return "WebGLActiveInfo"; }
  readonly size: number;
  readonly type: number;
  readonly name: string;
  constructor(size: number, type: number, name: string) {
    this.size = size;
    this.type = type;
    this.name = name;
  }
}

export class WebGLShaderPrecisionFormat {
  get [Symbol.toStringTag](): string { return "WebGLShaderPrecisionFormat"; }
  readonly rangeMin: number;
  readonly rangeMax: number;
  readonly precision: number;
  constructor(rangeMin: number, rangeMax: number, precision: number) {
    this.rangeMin = rangeMin;
    this.rangeMax = rangeMax;
    this.precision = precision;
  }
}

/**
 * A WebGL extension object. Most of the API's extensions have nothing to call: the capability
 * behind them is the context's own, and a page only asks whether getExtension() returned one.
 */
export class WebGLExtension {}

/** EXT_texture_filter_anisotropic: the two pnames that go to texParameteri/texParameterf. */
export class WebGLAnisotropicFilteringExtension extends WebGLExtension {
  get [Symbol.toStringTag](): string { return "WebGLAnisotropicFilteringExtension"; }
  readonly TEXTURE_MAX_ANISOTROPY_EXT = 0x84FE;
  readonly MAX_TEXTURE_MAX_ANISOTROPY_EXT = 0x84FF;
}

/** WEBGL_debug_renderer_info: the two pnames that name the driver behind the context. */
export class WebGLDebugRendererInfoExtension extends WebGLExtension {
  get [Symbol.toStringTag](): string { return "WebGLDebugRendererInfoExtension"; }
  readonly UNMASKED_VENDOR_WEBGL = 0x9245;
  readonly UNMASKED_RENDERER_WEBGL = 0x9246;
}

const UNMASKED_VENDOR_WEBGL = 0x9245;
const UNMASKED_RENDERER_WEBGL = 0x9246;

/** The attributes a context was created with, as `getContext("webgl2", attributes)` gave them. */
export interface WebGLContextAttributes {
  alpha?: boolean;
  depth?: boolean;
  stencil?: boolean;
  antialias?: boolean;
  premultipliedAlpha?: boolean;
  preserveDrawingBuffer?: boolean;
  powerPreference?: string;
  failIfMajorPerformanceCaveat?: boolean;
  desynchronized?: boolean;
}

function given(value: boolean | undefined, fallback: boolean): boolean {
  return value === undefined ? fallback : value;
}

// The attributes a context runs with: what the page asked for, over the browser defaults.
class Attributes {
  alpha = true;
  depth = true;
  stencil = false;
  antialias = true;
  premultipliedAlpha = true;
  preserveDrawingBuffer = false;
  powerPreference = "default";
  failIfMajorPerformanceCaveat = false;
  desynchronized = false;

  constructor(asked: WebGLContextAttributes | null) {
    if (asked === null) return;
    this.alpha = given(asked.alpha, true);
    this.depth = given(asked.depth, true);
    this.stencil = given(asked.stencil, false);
    this.antialias = given(asked.antialias, true);
    this.premultipliedAlpha = given(asked.premultipliedAlpha, true);
    this.preserveDrawingBuffer = given(asked.preserveDrawingBuffer, false);
    this.failIfMajorPerformanceCaveat = given(asked.failIfMajorPerformanceCaveat, false);
    this.desynchronized = given(asked.desynchronized, false);
    const preference = asked.powerPreference;
    if (preference !== undefined) this.powerPreference = preference;
  }
}

/** Makes the drawing buffer and GL context for a newly requested "webgl2" canvas context. */
export function createWebGL2Context(canvas: HTMLCanvasElement, width: number, height: number,
                                    asked: WebGLContextAttributes | null): WebGL2RenderingContext | null {
  const w = width < 1 ? 1 : width;
  const h = height < 1 ? 1 : height;
  const attributes = new Attributes(asked);
  const hostId = hostCanvasCreate(w, h);
  const ok = hostGlAttach(hostId, w, h, attributes.depth ? 1 : 0, attributes.stencil ? 1 : 0,
                          attributes.antialias ? 1 : 0);
  if (ok <= 0) {
    // The spec has the element announce the failure before getContext answers null, so a page can
    // tell a machine without WebGL from one that refused this particular context.
    const failure = new Event("webglcontextcreationerror") as Event & { statusMessage: string };
    failure.statusMessage = "Could not create a WebGL 2 context";
    canvas.dispatchEvent(failure);
    return null;
  }
  return new WebGL2RenderingContext(canvas, hostId, w, h, asked);
}

export class WebGL2RenderingContext {
  get [Symbol.toStringTag](): string { return "WebGL2RenderingContext"; }
  /** The host canvas whose bitmap painting reads the drawing buffer into. */
  readonly hostId: number;
  readonly canvas: HTMLCanvasElement;
  drawingBufferWidth: number;
  drawingBufferHeight: number;

  private attributes: Attributes;
  private depthBuffer: boolean;
  private stencilBuffer: boolean;
  private antialiasBuffer: boolean;
  // The pixel-store settings WebGL keeps for itself; the host never sees these.
  private unpackFlipY = false;
  private unpackPremultiplyAlpha = false;
  private unpackColorSpaceConversion = 0x9244; // BROWSER_DEFAULT_WEBGL
  private generateMipmapHint = 0x1100; // DONT_CARE
  /** The colour spaces of the drawing buffer and of unpacked pixels. Kept because pages (three.js
   *  among them) set them and read them back; there is no colour management behind them yet. */
  drawingBufferColorSpace = "srgb";
  unpackColorSpace = "srgb";
  /** The extension names and objects this context offers, worked out once on first ask. */
  private extensionNames: string[] | null = null;
  private extensionObjects: WebGLExtension[] = [];

  constructor(canvas: HTMLCanvasElement, hostId: number, width: number, height: number,
              asked: WebGLContextAttributes | null) {
    this.canvas = canvas;
    this.hostId = hostId;
    this.drawingBufferWidth = width;
    this.drawingBufferHeight = height;
    this.attributes = new Attributes(asked);
    this.depthBuffer = this.attributes.depth;
    this.stencilBuffer = this.attributes.stencil;
    this.antialiasBuffer = this.attributes.antialias;
    hostGlSetAlpha(hostId, this.attributes.alpha ? 1 : 0);
  }

  // The API's constants (GLenum values), as the WebGL 2 specification defines them.
  readonly ACTIVE_ATTRIBUTES = 0x8B89;
  readonly ACTIVE_TEXTURE = 0x84E0;
  readonly ACTIVE_UNIFORMS = 0x8B86;
  readonly ACTIVE_UNIFORM_BLOCKS = 0x8A36;
  readonly ALIASED_LINE_WIDTH_RANGE = 0x846E;
  readonly ALIASED_POINT_SIZE_RANGE = 0x846D;
  readonly ALPHA = 0x1906;
  readonly ALPHA_BITS = 0xD55;
  readonly ALREADY_SIGNALED = 0x911A;
  readonly ALWAYS = 0x207;
  readonly ANY_SAMPLES_PASSED = 0x8C2F;
  readonly ANY_SAMPLES_PASSED_CONSERVATIVE = 0x8D6A;
  readonly ARRAY_BUFFER = 0x8892;
  readonly ARRAY_BUFFER_BINDING = 0x8894;
  readonly ATTACHED_SHADERS = 0x8B85;
  readonly BACK = 0x405;
  readonly BLEND = 0xBE2;
  readonly BLEND_COLOR = 0x8005;
  readonly BLEND_DST_ALPHA = 0x80CA;
  readonly BLEND_DST_RGB = 0x80C8;
  readonly BLEND_EQUATION = 0x8009;
  readonly BLEND_EQUATION_ALPHA = 0x883D;
  readonly BLEND_EQUATION_RGB = 0x8009;
  readonly BLEND_SRC_ALPHA = 0x80CB;
  readonly BLEND_SRC_RGB = 0x80C9;
  readonly BLUE_BITS = 0xD54;
  readonly BOOL = 0x8B56;
  readonly BOOL_VEC2 = 0x8B57;
  readonly BOOL_VEC3 = 0x8B58;
  readonly BOOL_VEC4 = 0x8B59;
  readonly BROWSER_DEFAULT_WEBGL = 0x9244;
  readonly BUFFER_SIZE = 0x8764;
  readonly BUFFER_USAGE = 0x8765;
  readonly BYTE = 0x1400;
  readonly CCW = 0x901;
  readonly CLAMP_TO_EDGE = 0x812F;
  readonly COLOR = 0x1800;
  readonly COLOR_ATTACHMENT0 = 0x8CE0;
  readonly COLOR_ATTACHMENT1 = 0x8CE1;
  readonly COLOR_ATTACHMENT10 = 0x8CEA;
  readonly COLOR_ATTACHMENT11 = 0x8CEB;
  readonly COLOR_ATTACHMENT12 = 0x8CEC;
  readonly COLOR_ATTACHMENT13 = 0x8CED;
  readonly COLOR_ATTACHMENT14 = 0x8CEE;
  readonly COLOR_ATTACHMENT15 = 0x8CEF;
  readonly COLOR_ATTACHMENT2 = 0x8CE2;
  readonly COLOR_ATTACHMENT3 = 0x8CE3;
  readonly COLOR_ATTACHMENT4 = 0x8CE4;
  readonly COLOR_ATTACHMENT5 = 0x8CE5;
  readonly COLOR_ATTACHMENT6 = 0x8CE6;
  readonly COLOR_ATTACHMENT7 = 0x8CE7;
  readonly COLOR_ATTACHMENT8 = 0x8CE8;
  readonly COLOR_ATTACHMENT9 = 0x8CE9;
  readonly COLOR_BUFFER_BIT = 0x4000;
  readonly COLOR_CLEAR_VALUE = 0xC22;
  readonly COLOR_WRITEMASK = 0xC23;
  readonly COMPARE_REF_TO_TEXTURE = 0x884E;
  readonly COMPILE_STATUS = 0x8B81;
  readonly COMPRESSED_TEXTURE_FORMATS = 0x86A3;
  readonly CONDITION_SATISFIED = 0x911C;
  readonly CONSTANT_ALPHA = 0x8003;
  readonly CONSTANT_COLOR = 0x8001;
  readonly CONTEXT_LOST_WEBGL = 0x9242;
  readonly COPY_READ_BUFFER = 0x8F36;
  readonly COPY_READ_BUFFER_BINDING = 0x8F36;
  readonly COPY_WRITE_BUFFER = 0x8F37;
  readonly COPY_WRITE_BUFFER_BINDING = 0x8F37;
  readonly CULL_FACE = 0xB44;
  readonly CULL_FACE_MODE = 0xB45;
  readonly CURRENT_PROGRAM = 0x8B8D;
  readonly CURRENT_QUERY = 0x8865;
  readonly CURRENT_VERTEX_ATTRIB = 0x8626;
  readonly CW = 0x900;
  readonly DECR = 0x1E03;
  readonly DECR_WRAP = 0x8508;
  readonly DELETE_STATUS = 0x8B80;
  readonly DEPTH = 0x1801;
  readonly DEPTH24_STENCIL8 = 0x88F0;
  readonly DEPTH32F_STENCIL8 = 0x8CAD;
  readonly DEPTH_ATTACHMENT = 0x8D00;
  readonly DEPTH_BITS = 0xD56;
  readonly DEPTH_BUFFER_BIT = 0x100;
  readonly DEPTH_CLEAR_VALUE = 0xB73;
  readonly DEPTH_COMPONENT = 0x1902;
  readonly DEPTH_COMPONENT16 = 0x81A5;
  readonly DEPTH_COMPONENT24 = 0x81A6;
  readonly DEPTH_COMPONENT32F = 0x8CAC;
  readonly DEPTH_FUNC = 0xB74;
  readonly DEPTH_RANGE = 0xB70;
  readonly DEPTH_STENCIL = 0x84F9;
  readonly DEPTH_STENCIL_ATTACHMENT = 0x821A;
  readonly DEPTH_TEST = 0xB71;
  readonly DEPTH_WRITEMASK = 0xB72;
  readonly DITHER = 0xBD0;
  readonly DONT_CARE = 0x1100;
  readonly DRAW_BUFFER0 = 0x8825;
  readonly DRAW_BUFFER1 = 0x8826;
  readonly DRAW_BUFFER10 = 0x882F;
  readonly DRAW_BUFFER11 = 0x8830;
  readonly DRAW_BUFFER12 = 0x8831;
  readonly DRAW_BUFFER13 = 0x8832;
  readonly DRAW_BUFFER14 = 0x8833;
  readonly DRAW_BUFFER15 = 0x8834;
  readonly DRAW_BUFFER2 = 0x8827;
  readonly DRAW_BUFFER3 = 0x8828;
  readonly DRAW_BUFFER4 = 0x8829;
  readonly DRAW_BUFFER5 = 0x882A;
  readonly DRAW_BUFFER6 = 0x882B;
  readonly DRAW_BUFFER7 = 0x882C;
  readonly DRAW_BUFFER8 = 0x882D;
  readonly DRAW_BUFFER9 = 0x882E;
  readonly DRAW_FRAMEBUFFER = 0x8CA9;
  readonly DRAW_FRAMEBUFFER_BINDING = 0x8CA6;
  readonly DST_ALPHA = 0x304;
  readonly DST_COLOR = 0x306;
  readonly DYNAMIC_COPY = 0x88EA;
  readonly DYNAMIC_DRAW = 0x88E8;
  readonly DYNAMIC_READ = 0x88E9;
  readonly ELEMENT_ARRAY_BUFFER = 0x8893;
  readonly ELEMENT_ARRAY_BUFFER_BINDING = 0x8895;
  readonly EQUAL = 0x202;
  readonly FASTEST = 0x1101;
  readonly FLOAT = 0x1406;
  readonly FLOAT_32_UNSIGNED_INT_24_8_REV = 0x8DAD;
  readonly FLOAT_MAT2 = 0x8B5A;
  readonly FLOAT_MAT3 = 0x8B5B;
  readonly FLOAT_MAT4 = 0x8B5C;
  readonly FLOAT_VEC2 = 0x8B50;
  readonly FLOAT_VEC3 = 0x8B51;
  readonly FLOAT_VEC4 = 0x8B52;
  readonly FRAGMENT_SHADER = 0x8B30;
  readonly FRAGMENT_SHADER_DERIVATIVE_HINT = 0x8B8B;
  readonly FRAMEBUFFER = 0x8D40;
  readonly FRAMEBUFFER_ATTACHMENT_ALPHA_SIZE = 0x8215;
  readonly FRAMEBUFFER_ATTACHMENT_BLUE_SIZE = 0x8214;
  readonly FRAMEBUFFER_ATTACHMENT_COLOR_ENCODING = 0x8210;
  readonly FRAMEBUFFER_ATTACHMENT_COMPONENT_TYPE = 0x8211;
  readonly FRAMEBUFFER_ATTACHMENT_DEPTH_SIZE = 0x8216;
  readonly FRAMEBUFFER_ATTACHMENT_GREEN_SIZE = 0x8213;
  readonly FRAMEBUFFER_ATTACHMENT_OBJECT_NAME = 0x8CD1;
  readonly FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE = 0x8CD0;
  readonly FRAMEBUFFER_ATTACHMENT_RED_SIZE = 0x8212;
  readonly FRAMEBUFFER_ATTACHMENT_STENCIL_SIZE = 0x8217;
  readonly FRAMEBUFFER_ATTACHMENT_TEXTURE_CUBE_MAP_FACE = 0x8CD3;
  readonly FRAMEBUFFER_ATTACHMENT_TEXTURE_LAYER = 0x8CD4;
  readonly FRAMEBUFFER_ATTACHMENT_TEXTURE_LEVEL = 0x8CD2;
  readonly FRAMEBUFFER_BINDING = 0x8CA6;
  readonly FRAMEBUFFER_COMPLETE = 0x8CD5;
  readonly FRAMEBUFFER_DEFAULT = 0x8218;
  readonly FRAMEBUFFER_INCOMPLETE_ATTACHMENT = 0x8CD6;
  readonly FRAMEBUFFER_INCOMPLETE_DIMENSIONS = 0x8CD9;
  readonly FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT = 0x8CD7;
  readonly FRAMEBUFFER_INCOMPLETE_MULTISAMPLE = 0x8D56;
  readonly FRAMEBUFFER_UNSUPPORTED = 0x8CDD;
  readonly FRONT = 0x404;
  readonly FRONT_AND_BACK = 0x408;
  readonly FRONT_FACE = 0xB46;
  readonly FUNC_ADD = 0x8006;
  readonly FUNC_REVERSE_SUBTRACT = 0x800B;
  readonly FUNC_SUBTRACT = 0x800A;
  readonly GENERATE_MIPMAP_HINT = 0x8192;
  readonly GEQUAL = 0x206;
  readonly GREATER = 0x204;
  readonly GREEN_BITS = 0xD53;
  readonly HALF_FLOAT = 0x140B;
  readonly HIGH_FLOAT = 0x8DF2;
  readonly HIGH_INT = 0x8DF5;
  readonly IMPLEMENTATION_COLOR_READ_FORMAT = 0x8B9B;
  readonly IMPLEMENTATION_COLOR_READ_TYPE = 0x8B9A;
  readonly INCR = 0x1E02;
  readonly INCR_WRAP = 0x8507;
  readonly INT = 0x1404;
  readonly INTERLEAVED_ATTRIBS = 0x8C8C;
  readonly INT_2_10_10_10_REV = 0x8D9F;
  readonly INT_SAMPLER_2D = 0x8DCA;
  readonly INT_SAMPLER_2D_ARRAY = 0x8DCF;
  readonly INT_SAMPLER_3D = 0x8DCB;
  readonly INT_SAMPLER_CUBE = 0x8DCC;
  readonly INT_VEC2 = 0x8B53;
  readonly INT_VEC3 = 0x8B54;
  readonly INT_VEC4 = 0x8B55;
  readonly INVALID_ENUM = 0x500;
  readonly INVALID_FRAMEBUFFER_OPERATION = 0x506;
  readonly INVALID_INDEX = 0xFFFFFFFF;
  readonly INVALID_OPERATION = 0x502;
  readonly INVALID_VALUE = 0x501;
  readonly INVERT = 0x150A;
  readonly KEEP = 0x1E00;
  readonly LEQUAL = 0x203;
  readonly LESS = 0x201;
  readonly LINEAR = 0x2601;
  readonly LINEAR_MIPMAP_LINEAR = 0x2703;
  readonly LINEAR_MIPMAP_NEAREST = 0x2701;
  readonly LINES = 0x1;
  readonly LINE_LOOP = 0x2;
  readonly LINE_STRIP = 0x3;
  readonly LINE_WIDTH = 0xB21;
  readonly LINK_STATUS = 0x8B82;
  readonly LOW_FLOAT = 0x8DF0;
  readonly LOW_INT = 0x8DF3;
  readonly LUMINANCE = 0x1909;
  readonly LUMINANCE_ALPHA = 0x190A;
  readonly MAX = 0x8008;
  readonly MAX_3D_TEXTURE_SIZE = 0x8073;
  readonly MAX_ARRAY_TEXTURE_LAYERS = 0x88FF;
  readonly MAX_CLIENT_WAIT_TIMEOUT_WEBGL = 0x9247;
  readonly MAX_COLOR_ATTACHMENTS = 0x8CDF;
  readonly MAX_COMBINED_FRAGMENT_UNIFORM_COMPONENTS = 0x8A33;
  readonly MAX_COMBINED_TEXTURE_IMAGE_UNITS = 0x8B4D;
  readonly MAX_COMBINED_UNIFORM_BLOCKS = 0x8A2E;
  readonly MAX_COMBINED_VERTEX_UNIFORM_COMPONENTS = 0x8A31;
  readonly MAX_CUBE_MAP_TEXTURE_SIZE = 0x851C;
  readonly MAX_DRAW_BUFFERS = 0x8824;
  readonly MAX_ELEMENTS_INDICES = 0x80E9;
  readonly MAX_ELEMENTS_VERTICES = 0x80E8;
  readonly MAX_ELEMENT_INDEX = 0x8D6B;
  readonly MAX_FRAGMENT_INPUT_COMPONENTS = 0x9125;
  readonly MAX_FRAGMENT_UNIFORM_BLOCKS = 0x8A2D;
  readonly MAX_FRAGMENT_UNIFORM_COMPONENTS = 0x8B49;
  readonly MAX_FRAGMENT_UNIFORM_VECTORS = 0x8DFD;
  readonly MAX_PROGRAM_TEXEL_OFFSET = 0x8905;
  readonly MAX_RENDERBUFFER_SIZE = 0x84E8;
  readonly MAX_SAMPLES = 0x8D57;
  readonly MAX_SERVER_WAIT_TIMEOUT = 0x9111;
  readonly MAX_TEXTURE_IMAGE_UNITS = 0x8872;
  readonly MAX_TEXTURE_LOD_BIAS = 0x84FD;
  readonly MAX_TEXTURE_SIZE = 0xD33;
  readonly MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS = 0x8C8A;
  readonly MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS = 0x8C8B;
  readonly MAX_TRANSFORM_FEEDBACK_SEPARATE_COMPONENTS = 0x8C80;
  readonly MAX_UNIFORM_BLOCK_SIZE = 0x8A30;
  readonly MAX_UNIFORM_BUFFER_BINDINGS = 0x8A2F;
  readonly MAX_VARYING_COMPONENTS = 0x8B4B;
  readonly MAX_VARYING_VECTORS = 0x8DFC;
  readonly MAX_VERTEX_ATTRIBS = 0x8869;
  readonly MAX_VERTEX_OUTPUT_COMPONENTS = 0x9122;
  readonly MAX_VERTEX_TEXTURE_IMAGE_UNITS = 0x8B4C;
  readonly MAX_VERTEX_UNIFORM_BLOCKS = 0x8A2B;
  readonly MAX_VERTEX_UNIFORM_COMPONENTS = 0x8B4A;
  readonly MAX_VERTEX_UNIFORM_VECTORS = 0x8DFB;
  readonly MAX_VIEWPORT_DIMS = 0xD3A;
  readonly MEDIUM_FLOAT = 0x8DF1;
  readonly MEDIUM_INT = 0x8DF4;
  readonly MIN = 0x8007;
  readonly MIN_PROGRAM_TEXEL_OFFSET = 0x8904;
  readonly MIRRORED_REPEAT = 0x8370;
  readonly NEAREST = 0x2600;
  readonly NEAREST_MIPMAP_LINEAR = 0x2702;
  readonly NEAREST_MIPMAP_NEAREST = 0x2700;
  readonly NEVER = 0x200;
  readonly NICEST = 0x1102;
  readonly NOTEQUAL = 0x205;
  readonly OBJECT_TYPE = 0x9112;
  readonly ONE_MINUS_CONSTANT_ALPHA = 0x8004;
  readonly ONE_MINUS_CONSTANT_COLOR = 0x8002;
  readonly ONE_MINUS_DST_ALPHA = 0x305;
  readonly ONE_MINUS_DST_COLOR = 0x307;
  readonly ZERO = 0;
  readonly ONE = 1;
  readonly NONE = 0;
  readonly NO_ERROR = 0;
  readonly ONE_MINUS_SRC_ALPHA = 0x303;
  readonly ONE_MINUS_SRC_COLOR = 0x301;
  readonly OUT_OF_MEMORY = 0x505;
  readonly PACK_ALIGNMENT = 0xD05;
  readonly PACK_ROW_LENGTH = 0xD02;
  readonly PACK_SKIP_PIXELS = 0xD04;
  readonly PACK_SKIP_ROWS = 0xD03;
  readonly PIXEL_PACK_BUFFER = 0x88EB;
  readonly PIXEL_PACK_BUFFER_BINDING = 0x88ED;
  readonly PIXEL_UNPACK_BUFFER = 0x88EC;
  readonly PIXEL_UNPACK_BUFFER_BINDING = 0x88EF;
  readonly POINTS = 0x0;
  readonly POLYGON_OFFSET_FACTOR = 0x8038;
  readonly POLYGON_OFFSET_FILL = 0x8037;
  readonly POLYGON_OFFSET_UNITS = 0x2A00;
  readonly QUERY_RESULT = 0x8866;
  readonly QUERY_RESULT_AVAILABLE = 0x8867;
  readonly R11F_G11F_B10F = 0x8C3A;
  readonly R16F = 0x822D;
  readonly R16I = 0x8233;
  readonly R16UI = 0x8234;
  readonly R32F = 0x822E;
  readonly R32I = 0x8235;
  readonly R32UI = 0x8236;
  readonly R8 = 0x8229;
  readonly R8I = 0x8231;
  readonly R8UI = 0x8232;
  readonly R8_SNORM = 0x8F94;
  readonly RASTERIZER_DISCARD = 0x8C89;
  readonly READ_BUFFER = 0xC02;
  readonly READ_FRAMEBUFFER = 0x8CA8;
  readonly READ_FRAMEBUFFER_BINDING = 0x8CAA;
  readonly RED = 0x1903;
  readonly RED_BITS = 0xD52;
  readonly RED_INTEGER = 0x8D94;
  readonly RENDERBUFFER = 0x8D41;
  readonly RENDERBUFFER_ALPHA_SIZE = 0x8D53;
  readonly RENDERBUFFER_BINDING = 0x8CA7;
  readonly RENDERBUFFER_BLUE_SIZE = 0x8D52;
  readonly RENDERBUFFER_DEPTH_SIZE = 0x8D54;
  readonly RENDERBUFFER_GREEN_SIZE = 0x8D51;
  readonly RENDERBUFFER_HEIGHT = 0x8D43;
  readonly RENDERBUFFER_INTERNAL_FORMAT = 0x8D44;
  readonly RENDERBUFFER_RED_SIZE = 0x8D50;
  readonly RENDERBUFFER_SAMPLES = 0x8CAB;
  readonly RENDERBUFFER_STENCIL_SIZE = 0x8D55;
  readonly RENDERBUFFER_WIDTH = 0x8D42;
  readonly RENDERER = 0x1F01;
  readonly REPEAT = 0x2901;
  readonly REPLACE = 0x1E01;
  readonly RG = 0x8227;
  readonly RG16F = 0x822F;
  readonly RG16I = 0x8239;
  readonly RG16UI = 0x823A;
  readonly RG32F = 0x8230;
  readonly RG32I = 0x823B;
  readonly RG32UI = 0x823C;
  readonly RG8 = 0x822B;
  readonly RG8I = 0x8237;
  readonly RG8UI = 0x8238;
  readonly RG8_SNORM = 0x8F95;
  readonly RGB = 0x1907;
  readonly RGB10_A2 = 0x8059;
  readonly RGB10_A2UI = 0x906F;
  readonly RGB16F = 0x881B;
  readonly RGB16I = 0x8D89;
  readonly RGB16UI = 0x8D77;
  readonly RGB32F = 0x8815;
  readonly RGB32I = 0x8D83;
  readonly RGB32UI = 0x8D71;
  readonly RGB565 = 0x8D62;
  readonly RGB5_A1 = 0x8057;
  readonly RGB8 = 0x8051;
  readonly RGB8I = 0x8D8F;
  readonly RGB8UI = 0x8D7D;
  readonly RGB8_SNORM = 0x8F96;
  readonly RGB9_E5 = 0x8C3D;
  readonly RGBA = 0x1908;
  readonly RGBA16F = 0x881A;
  readonly RGBA16I = 0x8D88;
  readonly RGBA16UI = 0x8D76;
  readonly RGBA32F = 0x8814;
  readonly RGBA32I = 0x8D82;
  readonly RGBA32UI = 0x8D70;
  readonly RGBA4 = 0x8056;
  readonly RGBA8 = 0x8058;
  readonly RGBA8I = 0x8D8E;
  readonly RGBA8UI = 0x8D7C;
  readonly RGBA8_SNORM = 0x8F97;
  readonly RGBA_INTEGER = 0x8D99;
  readonly RGB_INTEGER = 0x8D98;
  readonly RG_INTEGER = 0x8228;
  readonly SAMPLER_2D = 0x8B5E;
  readonly SAMPLER_2D_ARRAY = 0x8DC1;
  readonly SAMPLER_2D_ARRAY_SHADOW = 0x8DC4;
  readonly SAMPLER_2D_SHADOW = 0x8B62;
  readonly SAMPLER_3D = 0x8B5F;
  readonly SAMPLER_BINDING = 0x8919;
  readonly SAMPLER_CUBE = 0x8B60;
  readonly SAMPLER_CUBE_SHADOW = 0x8DC5;
  readonly SAMPLES = 0x80A9;
  readonly SAMPLE_ALPHA_TO_COVERAGE = 0x809E;
  readonly SAMPLE_BUFFERS = 0x80A8;
  readonly SAMPLE_COVERAGE = 0x80A0;
  readonly SAMPLE_COVERAGE_INVERT = 0x80AB;
  readonly SAMPLE_COVERAGE_VALUE = 0x80AA;
  readonly SCISSOR_BOX = 0xC10;
  readonly SCISSOR_TEST = 0xC11;
  readonly SEPARATE_ATTRIBS = 0x8C8D;
  readonly SHADER_TYPE = 0x8B4F;
  readonly SHADING_LANGUAGE_VERSION = 0x8B8C;
  readonly SHORT = 0x1402;
  readonly SIGNALED = 0x9119;
  readonly SIGNED_NORMALIZED = 0x8F9C;
  readonly SRC_ALPHA = 0x302;
  readonly SRC_ALPHA_SATURATE = 0x308;
  readonly SRC_COLOR = 0x300;
  readonly SRGB = 0x8C40;
  readonly SRGB8 = 0x8C41;
  readonly SRGB8_ALPHA8 = 0x8C43;
  readonly STATIC_COPY = 0x88E6;
  readonly STATIC_DRAW = 0x88E4;
  readonly STATIC_READ = 0x88E5;
  readonly STENCIL = 0x1802;
  readonly STENCIL_ATTACHMENT = 0x8D20;
  readonly STENCIL_BACK_FAIL = 0x8801;
  readonly STENCIL_BACK_FUNC = 0x8800;
  readonly STENCIL_BACK_PASS_DEPTH_FAIL = 0x8802;
  readonly STENCIL_BACK_PASS_DEPTH_PASS = 0x8803;
  readonly STENCIL_BACK_REF = 0x8CA3;
  readonly STENCIL_BACK_VALUE_MASK = 0x8CA4;
  readonly STENCIL_BACK_WRITEMASK = 0x8CA5;
  readonly STENCIL_BITS = 0xD57;
  readonly STENCIL_BUFFER_BIT = 0x400;
  readonly STENCIL_CLEAR_VALUE = 0xB91;
  readonly STENCIL_FAIL = 0xB94;
  readonly STENCIL_FUNC = 0xB92;
  readonly STENCIL_INDEX8 = 0x8D48;
  readonly STENCIL_PASS_DEPTH_FAIL = 0xB95;
  readonly STENCIL_PASS_DEPTH_PASS = 0xB96;
  readonly STENCIL_REF = 0xB97;
  readonly STENCIL_TEST = 0xB90;
  readonly STENCIL_VALUE_MASK = 0xB93;
  readonly STENCIL_WRITEMASK = 0xB98;
  readonly STREAM_COPY = 0x88E2;
  readonly STREAM_DRAW = 0x88E0;
  readonly STREAM_READ = 0x88E1;
  readonly SUBPIXEL_BITS = 0xD50;
  readonly SYNC_CONDITION = 0x9113;
  readonly SYNC_FENCE = 0x9116;
  readonly SYNC_FLAGS = 0x9115;
  readonly SYNC_FLUSH_COMMANDS_BIT = 0x1;
  readonly SYNC_GPU_COMMANDS_COMPLETE = 0x9117;
  readonly SYNC_STATUS = 0x9114;
  readonly TEXTURE = 0x1702;
  readonly TEXTURE0 = 0x84C0;
  readonly TEXTURE1 = 0x84C1;
  readonly TEXTURE10 = 0x84CA;
  readonly TEXTURE11 = 0x84CB;
  readonly TEXTURE12 = 0x84CC;
  readonly TEXTURE13 = 0x84CD;
  readonly TEXTURE14 = 0x84CE;
  readonly TEXTURE15 = 0x84CF;
  readonly TEXTURE16 = 0x84D0;
  readonly TEXTURE17 = 0x84D1;
  readonly TEXTURE18 = 0x84D2;
  readonly TEXTURE19 = 0x84D3;
  readonly TEXTURE2 = 0x84C2;
  readonly TEXTURE20 = 0x84D4;
  readonly TEXTURE21 = 0x84D5;
  readonly TEXTURE22 = 0x84D6;
  readonly TEXTURE23 = 0x84D7;
  readonly TEXTURE24 = 0x84D8;
  readonly TEXTURE25 = 0x84D9;
  readonly TEXTURE26 = 0x84DA;
  readonly TEXTURE27 = 0x84DB;
  readonly TEXTURE28 = 0x84DC;
  readonly TEXTURE29 = 0x84DD;
  readonly TEXTURE3 = 0x84C3;
  readonly TEXTURE30 = 0x84DE;
  readonly TEXTURE31 = 0x84DF;
  readonly TEXTURE4 = 0x84C4;
  readonly TEXTURE5 = 0x84C5;
  readonly TEXTURE6 = 0x84C6;
  readonly TEXTURE7 = 0x84C7;
  readonly TEXTURE8 = 0x84C8;
  readonly TEXTURE9 = 0x84C9;
  readonly TEXTURE_2D = 0xDE1;
  readonly TEXTURE_2D_ARRAY = 0x8C1A;
  readonly TEXTURE_3D = 0x806F;
  readonly TEXTURE_BASE_LEVEL = 0x813C;
  readonly TEXTURE_BINDING_2D = 0x8069;
  readonly TEXTURE_BINDING_2D_ARRAY = 0x8C1D;
  readonly TEXTURE_BINDING_3D = 0x806A;
  readonly TEXTURE_BINDING_CUBE_MAP = 0x8514;
  readonly TEXTURE_COMPARE_FUNC = 0x884D;
  readonly TEXTURE_COMPARE_MODE = 0x884C;
  readonly TEXTURE_CUBE_MAP = 0x8513;
  readonly TEXTURE_CUBE_MAP_NEGATIVE_X = 0x8516;
  readonly TEXTURE_CUBE_MAP_NEGATIVE_Y = 0x8518;
  readonly TEXTURE_CUBE_MAP_NEGATIVE_Z = 0x851A;
  readonly TEXTURE_CUBE_MAP_POSITIVE_X = 0x8515;
  readonly TEXTURE_CUBE_MAP_POSITIVE_Y = 0x8517;
  readonly TEXTURE_CUBE_MAP_POSITIVE_Z = 0x8519;
  readonly TEXTURE_IMMUTABLE_FORMAT = 0x912F;
  readonly TEXTURE_IMMUTABLE_LEVELS = 0x82DF;
  readonly TEXTURE_MAG_FILTER = 0x2800;
  readonly TEXTURE_MAX_LEVEL = 0x813D;
  readonly TEXTURE_MAX_LOD = 0x813B;
  readonly TEXTURE_MIN_FILTER = 0x2801;
  readonly TEXTURE_MIN_LOD = 0x813A;
  readonly TEXTURE_WRAP_R = 0x8072;
  readonly TEXTURE_WRAP_S = 0x2802;
  readonly TEXTURE_WRAP_T = 0x2803;
  readonly TIMEOUT_EXPIRED = 0x911B;
  readonly TRANSFORM_FEEDBACK = 0x8E22;
  readonly TRANSFORM_FEEDBACK_ACTIVE = 0x8E24;
  readonly TRANSFORM_FEEDBACK_BINDING = 0x8E25;
  readonly TRANSFORM_FEEDBACK_BUFFER = 0x8C8E;
  readonly TRANSFORM_FEEDBACK_BUFFER_BINDING = 0x8C8F;
  readonly TRANSFORM_FEEDBACK_BUFFER_MODE = 0x8C7F;
  readonly TRANSFORM_FEEDBACK_BUFFER_SIZE = 0x8C85;
  readonly TRANSFORM_FEEDBACK_BUFFER_START = 0x8C84;
  readonly TRANSFORM_FEEDBACK_PAUSED = 0x8E23;
  readonly TRANSFORM_FEEDBACK_PRIMITIVES_WRITTEN = 0x8C88;
  readonly TRANSFORM_FEEDBACK_VARYINGS = 0x8C83;
  readonly TRIANGLES = 0x4;
  readonly TRIANGLE_FAN = 0x6;
  readonly TRIANGLE_STRIP = 0x5;
  readonly UNIFORM_ARRAY_STRIDE = 0x8A3C;
  readonly UNIFORM_BLOCK_ACTIVE_UNIFORMS = 0x8A42;
  readonly UNIFORM_BLOCK_ACTIVE_UNIFORM_INDICES = 0x8A43;
  readonly UNIFORM_BLOCK_BINDING = 0x8A3F;
  readonly UNIFORM_BLOCK_DATA_SIZE = 0x8A40;
  readonly UNIFORM_BLOCK_INDEX = 0x8A3A;
  readonly UNIFORM_BLOCK_REFERENCED_BY_FRAGMENT_SHADER = 0x8A46;
  readonly UNIFORM_BLOCK_REFERENCED_BY_VERTEX_SHADER = 0x8A44;
  readonly UNIFORM_BUFFER = 0x8A11;
  readonly UNIFORM_BUFFER_BINDING = 0x8A28;
  readonly UNIFORM_BUFFER_OFFSET_ALIGNMENT = 0x8A34;
  readonly UNIFORM_BUFFER_SIZE = 0x8A2A;
  readonly UNIFORM_BUFFER_START = 0x8A29;
  readonly UNIFORM_IS_ROW_MAJOR = 0x8A3E;
  readonly UNIFORM_MATRIX_STRIDE = 0x8A3D;
  readonly UNIFORM_OFFSET = 0x8A3B;
  readonly UNIFORM_SIZE = 0x8A38;
  readonly UNIFORM_TYPE = 0x8A37;
  readonly UNPACK_ALIGNMENT = 0xCF5;
  readonly UNPACK_COLORSPACE_CONVERSION_WEBGL = 0x9243;
  readonly UNPACK_FLIP_Y_WEBGL = 0x9240;
  readonly UNPACK_IMAGE_HEIGHT = 0x806E;
  readonly UNPACK_PREMULTIPLY_ALPHA_WEBGL = 0x9241;
  readonly UNPACK_ROW_LENGTH = 0xCF2;
  readonly UNPACK_SKIP_IMAGES = 0x806D;
  readonly UNPACK_SKIP_PIXELS = 0xCF4;
  readonly UNPACK_SKIP_ROWS = 0xCF3;
  readonly UNSIGNALED = 0x9118;
  readonly UNSIGNED_BYTE = 0x1401;
  readonly UNSIGNED_INT = 0x1405;
  readonly UNSIGNED_INT_10F_11F_11F_REV = 0x8C3B;
  readonly UNSIGNED_INT_24_8 = 0x84FA;
  readonly UNSIGNED_INT_2_10_10_10_REV = 0x8368;
  readonly UNSIGNED_INT_5_9_9_9_REV = 0x8C3E;
  readonly UNSIGNED_INT_SAMPLER_2D = 0x8DD2;
  readonly UNSIGNED_INT_SAMPLER_2D_ARRAY = 0x8DD7;
  readonly UNSIGNED_INT_SAMPLER_3D = 0x8DD3;
  readonly UNSIGNED_INT_SAMPLER_CUBE = 0x8DD4;
  readonly UNSIGNED_INT_VEC2 = 0x8DC6;
  readonly UNSIGNED_INT_VEC3 = 0x8DC7;
  readonly UNSIGNED_INT_VEC4 = 0x8DC8;
  readonly UNSIGNED_NORMALIZED = 0x8C17;
  readonly UNSIGNED_SHORT = 0x1403;
  readonly UNSIGNED_SHORT_4_4_4_4 = 0x8033;
  readonly UNSIGNED_SHORT_5_5_5_1 = 0x8034;
  readonly UNSIGNED_SHORT_5_6_5 = 0x8363;
  readonly VALIDATE_STATUS = 0x8B83;
  readonly VENDOR = 0x1F00;
  readonly VERSION = 0x1F02;
  readonly VERTEX_ARRAY_BINDING = 0x85B5;
  readonly VERTEX_ATTRIB_ARRAY_BUFFER_BINDING = 0x889F;
  readonly VERTEX_ATTRIB_ARRAY_DIVISOR = 0x88FE;
  readonly VERTEX_ATTRIB_ARRAY_ENABLED = 0x8622;
  readonly VERTEX_ATTRIB_ARRAY_INTEGER = 0x88FD;
  readonly VERTEX_ATTRIB_ARRAY_NORMALIZED = 0x886A;
  readonly VERTEX_ATTRIB_ARRAY_POINTER = 0x8645;
  readonly VERTEX_ATTRIB_ARRAY_SIZE = 0x8623;
  readonly VERTEX_ATTRIB_ARRAY_STRIDE = 0x8624;
  readonly VERTEX_ATTRIB_ARRAY_TYPE = 0x8625;
  readonly VERTEX_SHADER = 0x8B31;
  readonly VIEWPORT = 0xBA2;
  readonly WAIT_FAILED = 0x911D;

  /** Grows or shrinks the drawing buffer, as setting the canvas's width or height does. */
  resize(width: number, height: number): void {
    const w = width < 1 ? 1 : width;
    const h = height < 1 ? 1 : height;
    this.drawingBufferWidth = w;
    this.drawingBufferHeight = h;
    hostCanvasResize(this.hostId, w, h);
    hostGlAttach(this.hostId, w, h, this.depthBuffer ? 1 : 0, this.stencilBuffer ? 1 : 0,
                 this.antialiasBuffer ? 1 : 0);
    invalidatePaint();
  }

  getContextAttributes(): WebGLContextAttributes {
    const a = this.attributes;
    return { alpha: a.alpha, depth: a.depth, stencil: a.stencil, antialias: a.antialias,
      premultipliedAlpha: a.premultipliedAlpha, preserveDrawingBuffer: a.preserveDrawingBuffer,
      powerPreference: a.powerPreference, failIfMajorPerformanceCaveat: a.failIfMajorPerformanceCaveat,
      desynchronized: a.desynchronized };
  }

  isContextLost(): boolean {
    return false;
  }

  getError(): number {
    return hostGlGetError(this.hostId);
  }

  getExtension(name: string): any {
    const index = this.extensions().indexOf(name);
    return index < 0 ? null : this.extensionObjects[index];
  }

  getSupportedExtensions(): string[] {
    return this.extensions().slice();
  }

  /**
   * The extensions this context offers, each one only when the GL context can back it:
   * - EXT_texture_filter_anisotropic is still an extension in GL 4.1, so its name comes from
   *   GL's own list and nothing is assumed about the driver;
   * - EXT_color_buffer_float, EXT_color_buffer_half_float and OES_texture_float_linear are core
   *   in a desktop GL 3.0+ context, which is the only kind the host makes (4.1 core): float and
   *   half-float colour buffers are renderable there and their textures filter linearly.
   * - WEBGL_debug_renderer_info always answers: the vendor and renderer strings are GL's, and a
   *   browser without the extension in front of a driver still reports them to this API.
   * Everything else is absent, the way a browser without the extension answers.
   */
  private extensions(): string[] {
    if (this.extensionNames !== null) return this.extensionNames;
    const names: string[] = ["WEBGL_debug_renderer_info"];
    const objects: WebGLExtension[] = [new WebGLDebugRendererInfoExtension()];
    if (this.parameterInt(0x821B) >= 3) { // GL_MAJOR_VERSION
      names.push("OES_texture_float_linear", "EXT_color_buffer_float", "EXT_color_buffer_half_float");
      objects.push(new WebGLExtension(), new WebGLExtension(), new WebGLExtension());
    }
    if (this.hostExtensions().indexOf("GL_EXT_texture_filter_anisotropic") >= 0) {
      names.push("EXT_texture_filter_anisotropic");
      objects.push(new WebGLAnisotropicFilteringExtension());
    }
    this.extensionNames = names;
    this.extensionObjects = objects;
    return names;
  }

  /** GL's extension list, which a core context keeps indexed rather than as one string. */
  private hostExtensions(): string[] {
    const names: string[] = [];
    const count = hostGlExtensionCount(this.hostId);
    for (let i = 0; i < count; i++) {
      hostGlExtensionString(this.hostId, i, (name: string) => {
        names.push(name);
      });
    }
    return names;
  }

  getShaderPrecisionFormat(shaderType: number, precisionType: number): WebGLShaderPrecisionFormat {
    if (precisionType === this.LOW_INT || precisionType === this.MEDIUM_INT || precisionType === this.HIGH_INT) {
      return new WebGLShaderPrecisionFormat(31, 31, 0);
    }
    return new WebGLShaderPrecisionFormat(127, 127, 23);
  }

  getParameter(pname: number): any {
    if (pname === this.VERSION) return "WebGL 2.0 (" + this.parameterString(0x1F02) + ")";
    if (pname === this.SHADING_LANGUAGE_VERSION) {
      return "WebGL GLSL ES 3.00 (" + this.parameterString(0x1F02) + ")";
    }
    if (pname === this.VENDOR || pname === this.RENDERER) return this.parameterString(pname);
    // WEBGL_debug_renderer_info's pnames read the driver's own strings (GL_VENDOR, GL_RENDERER).
    if (pname === UNMASKED_VENDOR_WEBGL) return this.parameterString(0x1F00);
    if (pname === UNMASKED_RENDERER_WEBGL) return this.parameterString(0x1F01);
    // The vector limits are component counts in desktop GL.
    if (pname === this.MAX_VERTEX_UNIFORM_VECTORS) return this.parameterInt(0x8B4A) / 4;
    if (pname === this.MAX_FRAGMENT_UNIFORM_VECTORS) return this.parameterInt(0x8B49) / 4;
    if (pname === this.MAX_VARYING_VECTORS) return this.parameterInt(0x8B4B) / 4;
    if (pname === this.MAX_ELEMENT_INDEX) return 4294967295;
    if (pname === this.MAX_CLIENT_WAIT_TIMEOUT_WEBGL) return 0;
    if (pname === this.DRAW_FRAMEBUFFER_BINDING || pname === this.FRAMEBUFFER_BINDING) return 0;
    if (pname === this.READ_FRAMEBUFFER_BINDING) return 0;
    if (pname === this.GENERATE_MIPMAP_HINT) return this.generateMipmapHint;
    if (pname === this.UNPACK_FLIP_Y_WEBGL) return this.unpackFlipY;
    if (pname === this.UNPACK_PREMULTIPLY_ALPHA_WEBGL) return this.unpackPremultiplyAlpha;
    if (pname === this.UNPACK_COLORSPACE_CONVERSION_WEBGL) return this.unpackColorSpaceConversion;
    if (pname === this.SAMPLES) return this.antialiasBuffer ? 4 : 0;
    if (pname === this.DEPTH_BITS) return this.depthBuffer ? 24 : 0;
    if (pname === this.STENCIL_BITS) return this.stencilBuffer ? 8 : 0;
    if (pname === this.RED_BITS || pname === this.GREEN_BITS || pname === this.BLUE_BITS) return 8;
    if (pname === this.ALPHA_BITS) return this.attributes.alpha ? 8 : 0;
    if (pname === this.VIEWPORT || pname === this.SCISSOR_BOX) return this.parameterInts(pname, 4);
    if (pname === this.MAX_VIEWPORT_DIMS) return this.parameterInts(pname, 2);
    if (pname === this.COLOR_CLEAR_VALUE || pname === this.BLEND_COLOR || pname === this.DEPTH_RANGE) {
      return this.parameterFloats(pname, 4);
    }
    if (pname === this.ALIASED_LINE_WIDTH_RANGE) return this.parameterFloats(pname, 2);
    if (pname === this.ALIASED_POINT_SIZE_RANGE) return new Float32Array([1, 1]);
    if (pname === this.COLOR_WRITEMASK) {
      const mask = this.parameterInts(0x0C23, 4);
      const out = [mask[0] !== 0, mask[1] !== 0, mask[2] !== 0, mask[3] !== 0];
      return out;
    }
    return this.parameterInt(pname);
  }

  private parameterString(pname: number): string {
    let value = "";
    hostGlGetParameterString(this.hostId, pname, (v: string) => {
      value = v;
    });
    return value;
  }

  private parameterInt(pname: number): number {
    return hostGlGetParameterInt(this.hostId, pname);
  }

  private parameterInts(pname: number, count: number): Int32Array {
    const bytes = new Uint8Array(count * 4);
    hostGlGetParameterInts(this.hostId, pname, bytes);
    return new Int32Array(bytes.buffer);
  }

  private parameterFloats(pname: number, count: number): Float32Array {
    const bytes = new Uint8Array(count * 4);
    hostGlGetParameterFloats(this.hostId, pname, bytes);
    return new Float32Array(bytes.buffer);
  }

  // Buffers
  createBuffer(): WebGLBuffer {
    return new WebGLBuffer(hostGlCreateBuffer(this.hostId));
  }

  deleteBuffer(buffer: WebGLBuffer | null): void {
    if (buffer !== null) hostGlDeleteObject(this.hostId, 0, buffer.id);
  }

  bindBuffer(target: number, buffer: WebGLBuffer | null): void {
    hostGlBindBuffer(this.hostId, target, buffer === null ? 0 : buffer.id);
  }

  bufferData(target: number, data: GlView | number, usage: number): void {
    if (typeof data === "number") hostGlBufferDataSize(this.hostId, target, data, usage);
    else hostGlBufferData(this.hostId, target, usage, viewBytes(data));
  }

  bufferSubData(target: number, offset: number, data: GlView): void {
    hostGlBufferSubData(this.hostId, target, offset, viewBytes(data));
  }

  // Textures
  createTexture(): WebGLTexture {
    return new WebGLTexture(hostGlCreateTexture(this.hostId));
  }

  deleteTexture(texture: WebGLTexture | null): void {
    if (texture !== null) hostGlDeleteObject(this.hostId, 1, texture.id);
  }

  activeTexture(texture: number): void {
    hostGlActiveTexture(this.hostId, texture);
  }

  bindTexture(target: number, texture: WebGLTexture | null): void {
    hostGlBindTexture(this.hostId, target, texture === null ? 0 : texture.id);
  }

  texParameteri(target: number, pname: number, param: number): void {
    hostGlTexParameteri(this.hostId, target, pname, param);
  }

  texParameterf(target: number, pname: number, param: number): void {
    hostGlTexParameterf(this.hostId, target, pname, param);
  }

  generateMipmap(target: number): void {
    hostGlGenerateMipmap(this.hostId, target);
  }

  // The IDL converts a boolean here too, which is how three.js sets flipY and premultiplyAlpha.
  pixelStorei(pname: number, param: number | boolean): void {
    const value = Number(param);
    if (pname === 0x9240) this.unpackFlipY = value !== 0;
    else if (pname === 0x9241) this.unpackPremultiplyAlpha = value !== 0;
    else if (pname === 0x9243) this.unpackColorSpaceConversion = value;
    else hostGlPixelStorei(this.hostId, pname, value);
  }

  // Uploads take any typed array, as the IDL's ArrayBufferView allows: three.js sends half-float
  // (Uint16Array) and float (Float32Array) data as well as bytes. The short form uploads a source
  // instead — an <img>, an ImageData, or a canvas read through its own context — which the host
  // or this module turns into RGBA8 rows.
  texImage2D(target: number, level: number, internalformat: number, width: number, height: number,
             border: number, format: number, type: number, pixels: GlView | null): void;
  texImage2D(target: number, level: number, internalformat: number, format: number, type: number,
             source: ImageSource | PixelSource | CanvasSource): void;
  texImage2D(target: number, level: number, internalformat: number, width: number,
             heightOrType: number, borderOrSource: number | ImageSource | PixelSource | CanvasSource | null = null,
             format: number = 0, type: number = 0, pixels: GlView | null = null): void {
    if (isImageSource(borderOrSource)) {
      const id = borderOrSource.decodedImageId();
      if (id >= 0) {
        hostGlTexImage2DFromImage(this.hostId, target, level, internalformat, id, this.unpackFlipY ? 1 : 0,
                                  this.unpackPremultiplyAlpha ? 1 : 0);
      }
      return;
    }
    const source = isPixelSource(borderOrSource) ? borderOrSource
      : isCanvasSource(borderOrSource) ? canvasPixels(borderOrSource) : null;
    if (source !== null) {
      this.uploadPixels(target, level, internalformat, source);
      return;
    }
    const height = heightOrType;
    const border = typeof borderOrSource === "number" ? borderOrSource : 0;
    if (pixels === null) {
      hostGlTexImage2DNull(this.hostId, target, level, internalformat, width, height, border, format, type);
    } else {
      hostGlTexImage2D(this.hostId, target, level, internalformat, width, height, border, format, type,
                       viewBytes(pixels));
    }
  }

  /** A whole texture from a canvas or ImageData: straight RGBA8 rows, unpack options applied. */
  private uploadPixels(target: number, level: number, internalformat: number, source: PixelSource): void {
    const width = Math.floor(source.width);
    const height = Math.floor(source.height);
    if (!(width > 0) || !(height > 0)) return;
    const bytes = source.data instanceof Uint8Array ? source.data : new Uint8Array(source.data);
    hostGlTexImage2D(this.hostId, target, level, internalformat, width, height, 0, RGBA, UNSIGNED_BYTE,
                     unpackPixels(bytes, width, height, RGBA, UNSIGNED_BYTE, this.unpackFlipY,
                                  this.unpackPremultiplyAlpha));
  }

  texImage3D(target: number, level: number, internalformat: number, width: number, height: number,
             depth: number, border: number, format: number, type: number, pixels: GlView | null): void {
    hostGlTexImage3D(this.hostId, target, level, internalformat, width, height, depth, border, format, type,
                     pixels === null ? new Uint8Array(0) : viewBytes(pixels));
  }

  texSubImage2D(target: number, level: number, x: number, y: number, width: number, height: number,
                format: number, type: number, pixels: GlView): void;
  texSubImage2D(target: number, level: number, x: number, y: number, format: number, type: number,
                source: ImageSource | PixelSource | CanvasSource): void;
  texSubImage2D(target: number, level: number, x: number, y: number, width: number,
                heightOrFormat: number, formatOrType: number | ImageSource | PixelSource | CanvasSource | null = null,
                typeOrSource: number | ImageSource | PixelSource | CanvasSource | null = null,
                pixels: GlView | null = null): void {
    if (isImageSource(formatOrType)) {
      const id = formatOrType.decodedImageId();
      if (id >= 0) {
        hostGlTexSubImage2DFromImage(this.hostId, target, level, x, y, id, this.unpackFlipY ? 1 : 0,
                                     this.unpackPremultiplyAlpha ? 1 : 0);
      }
      return;
    }
    const source = isPixelSource(formatOrType) ? formatOrType
      : isCanvasSource(formatOrType) ? canvasPixels(formatOrType) : null;
    if (source !== null) {
      this.uploadSubPixels(target, level, x, y, source);
      return;
    }
    if (pixels === null) return;
    const height = heightOrFormat;
    const format = typeof formatOrType === "number" ? formatOrType : 0;
    const type = typeof typeOrSource === "number" ? typeOrSource : 0;
    hostGlTexSubImage2D(this.hostId, target, level, x, y, width, height, format, type, viewBytes(pixels));
  }

  /** A sub-rect of a texture from a canvas or ImageData: straight RGBA8 rows, unpack applied. */
  private uploadSubPixels(target: number, level: number, x: number, y: number, source: PixelSource): void {
    const width = Math.floor(source.width);
    const height = Math.floor(source.height);
    if (!(width > 0) || !(height > 0)) return;
    const bytes = source.data instanceof Uint8Array ? source.data : new Uint8Array(source.data);
    hostGlTexSubImage2D(this.hostId, target, level, x, y, width, height, RGBA, UNSIGNED_BYTE,
                        unpackPixels(bytes, width, height, RGBA, UNSIGNED_BYTE, this.unpackFlipY,
                                     this.unpackPremultiplyAlpha));
  }

  texStorage2D(target: number, levels: number, internalformat: number, width: number, height: number): void {
    hostGlTexStorage2D(this.hostId, target, levels, internalformat, width, height);
  }

  // Shaders and programs
  createShader(type: number): WebGLShader {
    return new WebGLShader(hostGlCreateShader(this.hostId, type));
  }

  deleteShader(shader: WebGLShader | null): void {
    if (shader !== null) hostGlDeleteObject(this.hostId, 5, shader.id);
  }

  shaderSource(shader: WebGLShader, source: string): void {
    hostGlShaderSource(this.hostId, shader.id, source);
  }

  compileShader(shader: WebGLShader): void {
    hostGlCompileShader(this.hostId, shader.id);
  }

  /** The status queries answer with a boolean and the rest with a number, as browsers do. */
  getShaderParameter(shader: WebGLShader, pname: number): any {
    const value = hostGlGetShaderParameter(this.hostId, shader.id, pname);
    if (pname === this.DELETE_STATUS || pname === this.COMPILE_STATUS) return value !== 0;
    return value;
  }

  getShaderInfoLog(shader: WebGLShader): string {
    let log = "";
    hostGlGetShaderInfoLog(this.hostId, shader.id, (v: string) => {
      log = v;
    });
    return log;
  }

  createProgram(): WebGLProgram {
    return new WebGLProgram(hostGlCreateProgram(this.hostId));
  }

  deleteProgram(program: WebGLProgram | null): void {
    if (program !== null) hostGlDeleteObject(this.hostId, 4, program.id);
  }

  attachShader(program: WebGLProgram, shader: WebGLShader): void {
    hostGlAttachShader(this.hostId, program.id, shader.id);
  }

  detachShader(program: WebGLProgram, shader: WebGLShader): void {
    hostGlDetachShader(this.hostId, program.id, shader.id);
  }

  bindAttribLocation(program: WebGLProgram, index: number, name: string): void {
    hostGlBindAttribLocation(this.hostId, program.id, index, name);
  }

  linkProgram(program: WebGLProgram): void {
    hostGlLinkProgram(this.hostId, program.id);
  }

  useProgram(program: WebGLProgram | null): void {
    hostGlUseProgram(this.hostId, program === null ? 0 : program.id);
  }

  /** The status queries answer with a boolean and the rest with a number, as browsers do. */
  getProgramParameter(program: WebGLProgram, pname: number): any {
    const value = hostGlGetProgramParameter(this.hostId, program.id, pname);
    if (pname === this.DELETE_STATUS || pname === this.LINK_STATUS || pname === this.VALIDATE_STATUS) return value !== 0;
    return value;
  }

  getProgramInfoLog(program: WebGLProgram): string {
    let log = "";
    hostGlGetProgramInfoLog(this.hostId, program.id, (v: string) => {
      log = v;
    });
    return log;
  }

  getAttribLocation(program: WebGLProgram, name: string): number {
    return hostGlGetAttribLocation(this.hostId, program.id, name);
  }

  getUniformLocation(program: WebGLProgram, name: string): WebGLUniformLocation | null {
    const location = hostGlGetUniformLocation(this.hostId, program.id, name);
    return location < 0 ? null : new WebGLUniformLocation(location);
  }

  getActiveUniform(program: WebGLProgram, index: number): WebGLActiveInfo | null {
    let name = "";
    hostGlActiveUniformName(this.hostId, program.id, index, (v: string) => {
      name = v;
    });
    const size = hostGlActiveUniformSize(this.hostId, program.id, index);
    const type = hostGlActiveUniformType(this.hostId, program.id, index);
    return name === "" ? null : new WebGLActiveInfo(size, type, name);
  }

  getActiveAttrib(program: WebGLProgram, index: number): WebGLActiveInfo | null {
    let name = "";
    hostGlActiveAttribName(this.hostId, program.id, index, (v: string) => {
      name = v;
    });
    const size = hostGlActiveAttribSize(this.hostId, program.id, index);
    const type = hostGlActiveAttribType(this.hostId, program.id, index);
    return name === "" ? null : new WebGLActiveInfo(size, type, name);
  }

  // Uniforms. The vector forms pack their components for one host call; `kind` names the shape.
  uniform1f(location: WebGLUniformLocation | null, x: number): void {
    hostGlUniform1f(this.hostId, loc(location), x);
  }

  // WebGL's IDL converts a boolean argument to a number, and three.js uploads a `bool` uniform
  // through uniform1i with the value it kept for the cache, which is the boolean itself.
  uniform1i(location: WebGLUniformLocation | null, x: number | boolean): void {
    hostGlUniform1i(this.hostId, loc(location), Number(x));
  }

  uniform2f(location: WebGLUniformLocation | null, x: number, y: number): void {
    hostGlUniform(this.hostId, loc(location), 2, floatBytes([x, y]));
  }

  uniform2i(location: WebGLUniformLocation | null, x: number, y: number): void {
    hostGlUniform(this.hostId, loc(location), 6, intBytes([x, y]));
  }

  uniform3f(location: WebGLUniformLocation | null, x: number, y: number, z: number): void {
    hostGlUniform(this.hostId, loc(location), 3, floatBytes([x, y, z]));
  }

  uniform3i(location: WebGLUniformLocation | null, x: number, y: number, z: number): void {
    hostGlUniform(this.hostId, loc(location), 7, intBytes([x, y, z]));
  }

  uniform4f(location: WebGLUniformLocation | null, x: number, y: number, z: number, w: number): void {
    hostGlUniform(this.hostId, loc(location), 4, floatBytes([x, y, z, w]));
  }

  uniform4i(location: WebGLUniformLocation | null, x: number, y: number, z: number, w: number): void {
    hostGlUniform(this.hostId, loc(location), 8, intBytes([x, y, z, w]));
  }

  uniform1fv(location: WebGLUniformLocation | null, value: FloatList): void {
    hostGlUniform(this.hostId, loc(location), 1, floatBytes(value));
  }

  uniform2fv(location: WebGLUniformLocation | null, value: FloatList): void {
    hostGlUniform(this.hostId, loc(location), 2, floatBytes(value));
  }

  uniform3fv(location: WebGLUniformLocation | null, value: FloatList): void {
    hostGlUniform(this.hostId, loc(location), 3, floatBytes(value));
  }

  uniform4fv(location: WebGLUniformLocation | null, value: FloatList): void {
    hostGlUniform(this.hostId, loc(location), 4, floatBytes(value));
  }

  uniform1iv(location: WebGLUniformLocation | null, value: IntList): void {
    hostGlUniform(this.hostId, loc(location), 5, intBytes(value));
  }

  uniform2iv(location: WebGLUniformLocation | null, value: IntList): void {
    hostGlUniform(this.hostId, loc(location), 6, intBytes(value));
  }

  uniform3iv(location: WebGLUniformLocation | null, value: IntList): void {
    hostGlUniform(this.hostId, loc(location), 7, intBytes(value));
  }

  uniform4iv(location: WebGLUniformLocation | null, value: IntList): void {
    hostGlUniform(this.hostId, loc(location), 8, intBytes(value));
  }

  uniform1uiv(location: WebGLUniformLocation | null, value: UIntList): void {
    hostGlUniform(this.hostId, loc(location), 9, uintBytes(value));
  }

  uniform2uiv(location: WebGLUniformLocation | null, value: UIntList): void {
    hostGlUniform(this.hostId, loc(location), 10, uintBytes(value));
  }

  uniform3uiv(location: WebGLUniformLocation | null, value: UIntList): void {
    hostGlUniform(this.hostId, loc(location), 11, uintBytes(value));
  }

  uniform4uiv(location: WebGLUniformLocation | null, value: UIntList): void {
    hostGlUniform(this.hostId, loc(location), 12, uintBytes(value));
  }

  uniformMatrix2fv(location: WebGLUniformLocation | null, transpose: boolean, value: FloatList): void {
    hostGlUniformMatrix(this.hostId, loc(location), 2, transpose ? 1 : 0, floatBytes(value));
  }

  uniformMatrix3fv(location: WebGLUniformLocation | null, transpose: boolean, value: FloatList): void {
    hostGlUniformMatrix(this.hostId, loc(location), 3, transpose ? 1 : 0, floatBytes(value));
  }

  uniformMatrix4fv(location: WebGLUniformLocation | null, transpose: boolean, value: FloatList): void {
    hostGlUniformMatrix(this.hostId, loc(location), 4, transpose ? 1 : 0, floatBytes(value));
  }

  // Vertex attributes
  createVertexArray(): WebGLVertexArrayObject {
    return new WebGLVertexArrayObject(hostGlCreateVertexArray(this.hostId));
  }

  deleteVertexArray(array: WebGLVertexArrayObject | null): void {
    if (array !== null) hostGlDeleteObject(this.hostId, 6, array.id);
  }

  bindVertexArray(array: WebGLVertexArrayObject | null): void {
    hostGlBindVertexArray(this.hostId, array === null ? 0 : array.id);
  }

  enableVertexAttribArray(index: number): void {
    hostGlEnableVertexAttribArray(this.hostId, index);
  }

  disableVertexAttribArray(index: number): void {
    hostGlDisableVertexAttribArray(this.hostId, index);
  }

  vertexAttribPointer(index: number, size: number, type: number, normalized: boolean, stride: number,
                      offset: number): void {
    hostGlVertexAttribPointer(this.hostId, index, size, type, normalized ? 1 : 0, stride, offset);
  }

  vertexAttribIPointer(index: number, size: number, type: number, stride: number, offset: number): void {
    hostGlVertexAttribIPointer(this.hostId, index, size, type, stride, offset);
  }

  vertexAttribDivisor(index: number, divisor: number): void {
    hostGlVertexAttribDivisor(this.hostId, index, divisor);
  }

  vertexAttrib1f(index: number, x: number): void {
    hostGlVertexAttrib(this.hostId, index, 1, floatBytes([x]));
  }

  vertexAttrib2f(index: number, x: number, y: number): void {
    hostGlVertexAttrib(this.hostId, index, 2, floatBytes([x, y]));
  }

  vertexAttrib3f(index: number, x: number, y: number, z: number): void {
    hostGlVertexAttrib(this.hostId, index, 3, floatBytes([x, y, z]));
  }

  vertexAttrib4f(index: number, x: number, y: number, z: number, w: number): void {
    hostGlVertexAttrib(this.hostId, index, 4, floatBytes([x, y, z, w]));
  }

  vertexAttrib1fv(index: number, value: FloatList): void {
    hostGlVertexAttrib(this.hostId, index, 1, floatBytes(value));
  }

  vertexAttrib2fv(index: number, value: FloatList): void {
    hostGlVertexAttrib(this.hostId, index, 2, floatBytes(value));
  }

  vertexAttrib3fv(index: number, value: FloatList): void {
    hostGlVertexAttrib(this.hostId, index, 3, floatBytes(value));
  }

  vertexAttrib4fv(index: number, value: FloatList): void {
    hostGlVertexAttrib(this.hostId, index, 4, floatBytes(value));
  }

  // Framebuffers and renderbuffers
  createFramebuffer(): WebGLFramebuffer {
    return new WebGLFramebuffer(hostGlCreateFramebuffer(this.hostId));
  }

  deleteFramebuffer(framebuffer: WebGLFramebuffer | null): void {
    if (framebuffer !== null) hostGlDeleteObject(this.hostId, 2, framebuffer.id);
  }

  bindFramebuffer(target: number, framebuffer: WebGLFramebuffer | null): void {
    hostGlBindFramebuffer(this.hostId, target, framebuffer === null ? 0 : framebuffer.id);
  }

  createRenderbuffer(): WebGLRenderbuffer {
    return new WebGLRenderbuffer(hostGlCreateRenderbuffer(this.hostId));
  }

  deleteRenderbuffer(renderbuffer: WebGLRenderbuffer | null): void {
    if (renderbuffer !== null) hostGlDeleteObject(this.hostId, 3, renderbuffer.id);
  }

  bindRenderbuffer(target: number, renderbuffer: WebGLRenderbuffer | null): void {
    hostGlBindRenderbuffer(this.hostId, target, renderbuffer === null ? 0 : renderbuffer.id);
  }

  renderbufferStorage(target: number, internalformat: number, width: number, height: number): void {
    hostGlRenderbufferStorage(this.hostId, target, internalformat, width, height);
  }

  framebufferTexture2D(target: number, attachment: number, textarget: number,
                       texture: WebGLTexture | null, level: number): void {
    hostGlFramebufferTexture2D(this.hostId, target, attachment, textarget,
                               texture === null ? 0 : texture.id, level);
  }

  framebufferRenderbuffer(target: number, attachment: number, rbTarget: number,
                          renderbuffer: WebGLRenderbuffer | null): void {
    hostGlFramebufferRenderbuffer(this.hostId, target, attachment, rbTarget,
                                  renderbuffer === null ? 0 : renderbuffer.id);
  }

  checkFramebufferStatus(target: number): number {
    return hostGlCheckFramebufferStatus(this.hostId, target);
  }

  /**
   * The colour attachments a draw writes to. A browser calls this after binding a framebuffer:
   * BACK means the canvas itself, COLOR_ATTACHMENTi a render target's texture, null means none.
   */
  drawBuffers(buffers: (number | null)[]): void {
    const ids = new Uint32Array(buffers.length);
    for (let i = 0; i < buffers.length; i++) ids[i] = buffers[i] === null ? 0 : (buffers[i] as number);
    hostGlDrawBuffers(this.hostId, ids.length, viewBytes(ids));
  }

  // Drawing. The canvas is repainted after every change to the drawing buffer.
  drawArrays(mode: number, first: number, count: number): void {
    hostGlDrawArrays(this.hostId, mode, first, count);
    invalidatePaint();
  }

  drawElements(mode: number, count: number, type: number, offset: number): void {
    hostGlDrawElements(this.hostId, mode, count, type, offset);
    invalidatePaint();
  }

  drawArraysInstanced(mode: number, first: number, count: number, instanceCount: number): void {
    hostGlDrawArraysInstanced(this.hostId, mode, first, count, instanceCount);
    invalidatePaint();
  }

  drawElementsInstanced(mode: number, count: number, type: number, offset: number, instanceCount: number): void {
    hostGlDrawElementsInstanced(this.hostId, mode, count, type, offset, instanceCount);
    invalidatePaint();
  }

  clear(mask: number): void {
    hostGlClear(this.hostId, mask);
    invalidatePaint();
  }

  clearColor(red: number, green: number, blue: number, alpha: number): void {
    hostGlClearColor(this.hostId, red, green, blue, alpha);
  }

  clearDepth(depth: number): void {
    hostGlClearDepth(this.hostId, depth);
  }

  clearStencil(s: number): void {
    hostGlClearStencil(this.hostId, s);
  }

  colorMask(red: boolean, green: boolean, blue: boolean, alpha: boolean): void {
    hostGlColorMask(this.hostId, red ? 1 : 0, green ? 1 : 0, blue ? 1 : 0, alpha ? 1 : 0);
  }

  depthMask(flag: boolean): void {
    hostGlDepthMask(this.hostId, flag ? 1 : 0);
  }

  stencilMask(mask: number): void {
    hostGlStencilMask(this.hostId, mask);
  }

  cullFace(mode: number): void {
    hostGlCullFace(this.hostId, mode);
  }

  frontFace(mode: number): void {
    hostGlFrontFace(this.hostId, mode);
  }

  depthFunc(func: number): void {
    hostGlDepthFunc(this.hostId, func);
  }

  depthRange(near: number, far: number): void {
    hostGlDepthRange(this.hostId, near, far);
  }

  blendFunc(src: number, dst: number): void {
    hostGlBlendFunc(this.hostId, src, dst);
  }

  blendFuncSeparate(srcRGB: number, dstRGB: number, srcAlpha: number, dstAlpha: number): void {
    hostGlBlendFuncSeparate(this.hostId, srcRGB, dstRGB, srcAlpha, dstAlpha);
  }

  blendEquation(mode: number): void {
    hostGlBlendEquation(this.hostId, mode);
  }

  blendEquationSeparate(rgb: number, alpha: number): void {
    hostGlBlendEquationSeparate(this.hostId, rgb, alpha);
  }

  blendColor(red: number, green: number, blue: number, alpha: number): void {
    hostGlBlendColor(this.hostId, red, green, blue, alpha);
  }

  polygonOffset(factor: number, units: number): void {
    hostGlPolygonOffset(this.hostId, factor, units);
  }

  stencilFunc(func: number, ref: number, mask: number): void {
    hostGlStencilFunc(this.hostId, func, ref, mask);
  }

  stencilOp(fail: number, zfail: number, zpass: number): void {
    hostGlStencilOp(this.hostId, fail, zfail, zpass);
  }

  enable(cap: number): void {
    hostGlEnable(this.hostId, cap);
  }

  disable(cap: number): void {
    hostGlDisable(this.hostId, cap);
  }

  viewport(x: number, y: number, width: number, height: number): void {
    hostGlViewport(this.hostId, x, y, width, height);
  }

  scissor(x: number, y: number, width: number, height: number): void {
    hostGlScissor(this.hostId, x, y, width, height);
  }

  lineWidth(width: number): void {
    hostGlLineWidth(this.hostId, width);
  }

  hint(target: number, mode: number): void {
    if (target === this.GENERATE_MIPMAP_HINT) this.generateMipmapHint = mode;
  }

  finish(): void {
    hostGlFinish(this.hostId);
  }

  flush(): void {
    hostGlFlush(this.hostId);
  }

  readPixels(x: number, y: number, width: number, height: number, format: number, type: number,
             pixels: Uint8Array): void {
    hostGlReadPixels(this.hostId, x, y, width, height, pixels);
  }
}
