// A spinning lit cube, drawn with WebGL 2: a canvas that asked for a "webgl2" context gets an
// OpenGL 4.1 core context in the host, and each frame's drawing buffer is copied into the canvas
// bitmap the display list paints.
//
// The cube has six coloured faces, one directional light with a little ambient and a rim term, and
// a depth buffer. Everything here is the page's own code: a projection matrix, a model rotation,
// and one indexed draw call per frame.

const stage = document.getElementById("stage") as HTMLCanvasElement;
const gl = stage.getContext("webgl2", { antialias: true });

// Everything the cube needs from a context. A host that can't make one — a machine with no
// OpenGL driver, where both the macOS and the Linux host's context requests fail — gets the HUD's
// note instead: getContext answers null where the platform has no WebGL 2, exactly as a browser
// without the feature does, and the animation below never starts.
function start(gl: WebGL2RenderingContext): void {
  // The canvas bitmap is in device pixels, so the drawing fills the window crisply on a 2x display.
  let width = 1;
  let height = 1;
  let aspect = 1;

  function resizeToWindow(): void {
    const dpr = window.devicePixelRatio;
    width = Math.max(1, Math.round(window.innerWidth * dpr));
    height = Math.max(1, Math.round(window.innerHeight * dpr));
    aspect = width / height;
    stage.width = width;
    stage.height = height;
    gl.viewport(0, 0, width, height);
  }
  resizeToWindow();
  window.addEventListener("resize", resizeToWindow);

  // --- Matrices (column-major, as GL wants them) ---------------------------------------------

  function perspective(fovY: number, aspectRatio: number, near: number, far: number): Float32Array {
    const f = 1 / Math.tan(fovY / 2);
    const out = new Float32Array(16);
    out[0] = f / aspectRatio;
    out[5] = f;
    out[10] = (far + near) / (near - far);
    out[11] = -1;
    out[14] = (2 * far * near) / (near - far);
    return out;
  }

  function multiply(a: Float32Array, b: Float32Array): Float32Array {
    const out = new Float32Array(16);
    for (let c = 0; c < 4; c++) {
      for (let r = 0; r < 4; r++) {
        out[c * 4 + r] = a[r] * b[c * 4] + a[4 + r] * b[c * 4 + 1] + a[8 + r] * b[c * 4 + 2] + a[12 + r] * b[c * 4 + 3];
      }
    }
    return out;
  }

  function translation(x: number, y: number, z: number): Float32Array {
    const out = new Float32Array(16);
    out[0] = 1;
    out[5] = 1;
    out[10] = 1;
    out[15] = 1;
    out[12] = x;
    out[13] = y;
    out[14] = z;
    return out;
  }

  function rotationX(angle: number): Float32Array {
    const c = Math.cos(angle);
    const s = Math.sin(angle);
    const out = new Float32Array(16);
    out[0] = 1;
    out[5] = c;
    out[6] = s;
    out[9] = -s;
    out[10] = c;
    out[15] = 1;
    return out;
  }

  function rotationY(angle: number): Float32Array {
    const c = Math.cos(angle);
    const s = Math.sin(angle);
    const out = new Float32Array(16);
    out[0] = c;
    out[2] = -s;
    out[5] = 1;
    out[8] = s;
    out[10] = c;
    out[15] = 1;
    return out;
  }

  // --- The cube ------------------------------------------------------------------------------

  // Each face is its centre, two tangent axes chosen so u x v is the outward normal, and a colour.
  // The four corners run counter-clockwise seen from outside, which is the front face back-face
  // culling keeps.
  const FACES: number[][] = [
    [1, 0, 0, 0, 1, 0, 0, 0, 1, 0.95, 0.35, 0.32], // +x: u = y, v = z
    [-1, 0, 0, 0, 0, 1, 0, 1, 0, 0.35, 0.62, 0.95], // -x: u = z, v = y
    [0, 1, 0, 0, 0, 1, 1, 0, 0, 0.45, 0.85, 0.5], // +y: u = z, v = x
    [0, -1, 0, 1, 0, 0, 0, 0, 1, 0.9, 0.75, 0.3], // -y: u = x, v = z
    [0, 0, 1, 1, 0, 0, 0, 1, 0, 0.8, 0.45, 0.9], // +z: u = x, v = y
    [0, 0, -1, 0, 1, 0, 1, 0, 0, 0.95, 0.9, 0.85], // -z: u = y, v = x
  ];

  // The corner offsets, as multiples of u and v.
  const CORNER_U = [-1, 1, 1, -1];
  const CORNER_V = [-1, -1, 1, 1];

  const vertexData: number[] = [];
  const indexData: number[] = [];
  for (let f = 0; f < FACES.length; f++) {
    const face = FACES[f];
    for (let i = 0; i < 4; i++) {
      const x = face[0] + face[3] * CORNER_U[i] + face[6] * CORNER_V[i];
      const y = face[1] + face[4] * CORNER_U[i] + face[7] * CORNER_V[i];
      const z = face[2] + face[5] * CORNER_U[i] + face[8] * CORNER_V[i];
      vertexData.push(x, y, z, face[0], face[1], face[2], face[9], face[10], face[11]);
    }
    const first = f * 4;
    indexData.push(first, first + 1, first + 2, first, first + 2, first + 3);
  }

  const VERTEX_SHADER = `#version 300 es
  in vec3 aPosition;
  in vec3 aNormal;
  in vec3 aColor;
  uniform mat4 uProjection;
  uniform mat4 uModel;
  uniform mat3 uNormalMatrix;
  out vec3 vNormal;
  out vec3 vColor;
  void main() {
    vNormal = uNormalMatrix * aNormal;
    vColor = aColor;
    gl_Position = uProjection * uModel * vec4(aPosition, 1.0);
  }`;

  const FRAGMENT_SHADER = `#version 300 es
  precision highp float;
  in vec3 vNormal;
  in vec3 vColor;
  uniform vec3 uLight;
  out vec4 outColor;
  void main() {
    vec3 n = normalize(vNormal);
    float diffuse = max(dot(n, uLight), 0.0);
    vec3 halfway = normalize(uLight + vec3(0.0, 0.0, 1.0));
    float specular = pow(max(dot(n, halfway), 0.0), 32.0) * 0.35;
    vec3 color = vColor * (0.22 + 0.78 * diffuse) + vec3(specular);
    outColor = vec4(color, 1.0);
  }`;

  function compile(type: number, source: string): WebGLShader {
    const shader = gl.createShader(type)!;
    gl.shaderSource(shader, source);
    gl.compileShader(shader);
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(shader));
    return shader;
  }

  const program = gl.createProgram()!;
  gl.attachShader(program, compile(gl.VERTEX_SHADER, VERTEX_SHADER));
  gl.attachShader(program, compile(gl.FRAGMENT_SHADER, FRAGMENT_SHADER));
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program));

  const positionLocation = gl.getAttribLocation(program, "aPosition");
  const normalLocation = gl.getAttribLocation(program, "aNormal");
  const colorLocation = gl.getAttribLocation(program, "aColor");
  const projectionLocation = gl.getUniformLocation(program, "uProjection")!;
  const modelLocation = gl.getUniformLocation(program, "uModel")!;
  const normalMatrixLocation = gl.getUniformLocation(program, "uNormalMatrix")!;
  const lightLocation = gl.getUniformLocation(program, "uLight")!;

  const vertexArray = gl.createVertexArray()!;
  gl.bindVertexArray(vertexArray);

  const vertexBuffer = gl.createBuffer()!;
  gl.bindBuffer(gl.ARRAY_BUFFER, vertexBuffer);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(vertexData), gl.STATIC_DRAW);
  const stride = 9 * 4;
  gl.enableVertexAttribArray(positionLocation);
  gl.vertexAttribPointer(positionLocation, 3, gl.FLOAT, false, stride, 0);
  gl.enableVertexAttribArray(normalLocation);
  gl.vertexAttribPointer(normalLocation, 3, gl.FLOAT, false, stride, 12);
  gl.enableVertexAttribArray(colorLocation);
  gl.vertexAttribPointer(colorLocation, 3, gl.FLOAT, false, stride, 24);

  const indexBuffer = gl.createBuffer()!;
  gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, indexBuffer);
  gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, new Uint16Array(indexData), gl.STATIC_DRAW);

  // The light comes from above, to the right, and in front.
  const light = new Float32Array([0.45, 0.7, 0.6]);
  const lightLength = Math.sqrt(light[0] * light[0] + light[1] * light[1] + light[2] * light[2]);
  for (let i = 0; i < 3; i++) light[i] = light[i] / lightLength;

  gl.enable(gl.DEPTH_TEST);
  gl.enable(gl.CULL_FACE);
  gl.cullFace(gl.BACK);
  gl.useProgram(program);
  gl.uniform3fv(lightLocation, light);

  // Reduced motion holds the cube at a fixed corner-on angle.
  const calm = matchMedia("(prefers-reduced-motion: reduce)");

  function draw(time: number): void {
    const angle = calm.matches ? 0.7 : (time / 1000) * 0.8;
    const model = multiply(rotationY(angle), rotationX(0.45));
    const projection = perspective(0.9, aspect, 0.1, 20);
    const view = translation(0, 0, -6);
    gl.clearColor(0.043, 0.063, 0.133, 1);
    gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);
    gl.uniformMatrix4fv(projectionLocation, false, multiply(projection, view));
    gl.uniformMatrix4fv(modelLocation, false, model);
    gl.uniformMatrix3fv(normalMatrixLocation, false, new Float32Array([
      model[0], model[1], model[2],
      model[4], model[5], model[6],
      model[8], model[9], model[10],
    ]));
    gl.drawElements(gl.TRIANGLES, indexData.length, gl.UNSIGNED_SHORT, 0);
  }

  function frameAt(time: number): void {
    requestAnimationFrame(frameAt);
    draw(time);
  }

  draw(0);
  requestAnimationFrame(frameAt);
}

if (gl === null) {
  document.getElementById("hud")!.textContent = "WEBGL2 IS NOT AVAILABLE ON THIS PLATFORM";
} else {
  start(gl);
}
