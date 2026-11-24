// A texture loaded from a file, drawn with WebGL 2. The page uploads chequer.png through
// texImage2D from an <img> element, paints it across the canvas with one quad and reads one pixel
// back, so the line it prints is what the GL pipeline actually sampled rather than what the code
// meant it to. A click moves the sampling point a quarter of the way across the texture: the frame
// shows another quadrant and the line reports the colour that landed under the middle of the canvas.
//
// The picture is four quadrants with a small block of its own colour in the middle, so the sampled
// point is unambiguous: #7EE787 while the shift is zero, #2EC4B6 once the click has moved it.

const stage = document.getElementById("stage") as HTMLCanvasElement;
const picture = document.getElementById("picture") as HTMLImageElement;
const sample = document.getElementById("sample")!;
const gl = stage.getContext("webgl2", { antialias: false, premultipliedAlpha: false });

const DIGITS = "0123456789ABCDEF";

function hex2(value: number): string {
  return DIGITS[(value >> 4) & 15] + DIGITS[value & 15];
}

if (gl === null) {
  document.getElementById("hud")!.textContent = "WEBGL2 IS NOT AVAILABLE ON THIS PLATFORM";
} else {
  start(gl);
}

function start(gl: WebGL2RenderingContext): void {
  const vertexSource = `#version 300 es
in vec2 position;
out vec2 uv;
void main() {
  uv = position * 0.5 + 0.5;
  gl_Position = vec4(position, 0.0, 1.0);
}`;
  const fragmentSource = `#version 300 es
precision mediump float;
in vec2 uv;
uniform sampler2D picture;
uniform vec2 shift;
out vec4 colour;
void main() {
  colour = texture(picture, uv + shift);
}`;

  function shader(kind: number, source: string): WebGLShader | null {
    const made = gl.createShader(kind);
    if (made === null) return null;
    gl.shaderSource(made, source);
    gl.compileShader(made);
    if (gl.getShaderParameter(made, gl.COMPILE_STATUS) !== true) {
      sample.textContent = "shader: " + gl.getShaderInfoLog(made);
      return null;
    }
    return made;
  }

  const vertex = shader(gl.VERTEX_SHADER, vertexSource);
  const fragment = shader(gl.FRAGMENT_SHADER, fragmentSource);
  if (vertex === null || fragment === null) return;
  const program = gl.createProgram();
  gl.attachShader(program, vertex);
  gl.attachShader(program, fragment);
  gl.bindAttribLocation(program, 0, "position");
  gl.linkProgram(program);
  if (gl.getProgramParameter(program, gl.LINK_STATUS) !== true) {
    sample.textContent = "link: " + gl.getProgramInfoLog(program);
    return;
  }
  const shiftLocation = gl.getUniformLocation(program, "shift");
  const pictureLocation = gl.getUniformLocation(program, "picture");

  // One quad across the whole drawing buffer.
  const quad = new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]);
  const buffer = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
  gl.bufferData(gl.ARRAY_BUFFER, quad, gl.STATIC_DRAW);
  gl.enableVertexAttribArray(0);
  gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);

  const texture = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, texture);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  // The file's first row is its top one; WebGL's texture rows start at the bottom.
  gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);

  let uploaded = false;
  let shift = 0;

  function upload(): void {
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, picture);
    uploaded = true;
  }

  function resize(): void {
    const dpr = window.devicePixelRatio;
    const width = Math.max(1, Math.round(window.innerWidth * dpr));
    const height = Math.max(1, Math.round(window.innerHeight * dpr));
    if (stage.width === width && stage.height === height) return;
    stage.width = width;
    stage.height = height;
    gl.viewport(0, 0, width, height);
  }

  function draw(): void {
    resize();
    if (!uploaded) upload();
    gl.clearColor(0.063, 0.075, 0.11, 1);
    gl.clear(gl.COLOR_BUFFER_BIT);
    gl.useProgram(program);
    gl.uniform1i(pictureLocation, 0);
    gl.uniform2f(shiftLocation, shift, shift);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    const pixel = new Uint8Array(4);
    gl.readPixels(Math.floor(stage.width / 2), Math.floor(stage.height / 2), 1, 1, gl.RGBA,
                  gl.UNSIGNED_BYTE, pixel);
    sample.textContent = "TEXTURE #" + hex2(pixel[0]) + hex2(pixel[1]) + hex2(pixel[2]);
  }

  // The file is decoded off the page's own thread, so the first draw waits for it.
  picture.addEventListener("load", () => {
    uploaded = false;
    draw();
  });
  picture.addEventListener("error", () => {
    sample.textContent = "the picture did not load";
  });
  stage.addEventListener("click", () => {
    shift = shift === 0 ? 0.25 : 0;
    draw();
  });
  window.addEventListener("resize", draw);

  draw();
}
