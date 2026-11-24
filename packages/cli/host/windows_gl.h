// What the Windows host needs from EGL and OpenGL ES, so that a canvas with a "webgl2" context can
// be drawn by ANGLE when its libraries are present. The types, constants and entry points here are
// the ones the backend uses; ANGLE's DLLs are loaded at run time, so nothing links against them and
// a build without them still runs, with getContext("webgl2") answering null as a browser without
// WebGL does.
//
// Every entry point is a variable holding the address resolved from the DLL, called exactly like
// the GL function it names.

#ifndef NATIVE_WINDOWS_GL_H
#define NATIVE_WINDOWS_GL_H

typedef unsigned int GLenum;
typedef unsigned int GLuint;
typedef int GLint;
typedef int GLsizei;
typedef unsigned char GLboolean;
typedef unsigned int GLbitfield;
typedef float GLfloat;
typedef double GLdouble;
typedef char GLchar;
typedef unsigned char GLubyte;
typedef long long GLintptr;
typedef long long GLsizeiptr;
typedef void GLvoid;

typedef void *EGLDisplay;
typedef void *EGLConfig;
typedef void *EGLSurface;
typedef void *EGLContext;
typedef void *EGLNativeDisplayType;
typedef int EGLint;
typedef unsigned int EGLBoolean;
typedef unsigned int EGLenum;
typedef long long EGLAttrib;
typedef void *EGLDeviceEXT;

// Constants, as the OpenGL ES 3.0 and EGL 1.5 specifications number them.
#define GL_COLOR_BUFFER_BIT 0x4000
#define GL_DEPTH_BUFFER_BIT 0x0100
#define GL_STENCIL_BUFFER_BIT 0x0400
#define GL_BACK 0x0405
#define GL_UNSIGNED_BYTE 0x1401
#define GL_RGBA 0x1908
#define GL_RGBA8 0x8058
#define GL_TEXTURE_2D 0x0DE1
#define GL_TEXTURE_MAG_FILTER 0x2800
#define GL_TEXTURE_MIN_FILTER 0x2801
#define GL_TEXTURE_WRAP_S 0x2802
#define GL_TEXTURE_WRAP_T 0x2803
#define GL_NEAREST 0x2600
#define GL_LINEAR 0x2601
#define GL_UNPACK_ALIGNMENT 0x0CF5
#define GL_PACK_ALIGNMENT 0x0D05
#define GL_FRAMEBUFFER 0x8D40
#define GL_READ_FRAMEBUFFER 0x8CA8
#define GL_DRAW_FRAMEBUFFER 0x8CA9
#define GL_READ_FRAMEBUFFER_BINDING 0x8CAA
#define GL_DRAW_FRAMEBUFFER_BINDING 0x8CA6
#define GL_RENDERBUFFER 0x8D41
#define GL_COLOR_ATTACHMENT0 0x8CE0
#define GL_DEPTH_ATTACHMENT 0x8D00
#define GL_DEPTH_STENCIL_ATTACHMENT 0x821A
#define GL_DEPTH_COMPONENT24 0x81A6
#define GL_DEPTH24_STENCIL8 0x88F0
#define GL_STENCIL_INDEX8 0x8D48
#define GL_MAX_SAMPLES 0x8D57
#define GL_CLAMP_TO_EDGE 0x812F
#define GL_NUM_EXTENSIONS 0x821D
#define GL_EXTENSIONS 0x1F03
#define GL_RENDERER 0x1F01

#define EGL_NONE 0x3038
#define EGL_SURFACE_TYPE 0x3033
#define EGL_PBUFFER_BIT 0x0001
#define EGL_RENDERABLE_TYPE 0x3040
#define EGL_OPENGL_ES3_BIT 0x0040
#define EGL_COLOR_BUFFER_TYPE 0x303F
#define EGL_RGB_BUFFER 0x308E
#define EGL_RED_SIZE 0x3024
#define EGL_GREEN_SIZE 0x3023
#define EGL_BLUE_SIZE 0x3022
#define EGL_ALPHA_SIZE 0x3021
#define EGL_DEPTH_SIZE 0x3025
#define EGL_STENCIL_SIZE 0x3026
#define EGL_CONTEXT_MAJOR_VERSION 0x3098
#define EGL_CONTEXT_MINOR_VERSION 0x30FB
#define EGL_OPENGL_ES_API 0x30A0
#define EGL_WIDTH 0x3057
#define EGL_HEIGHT 0x3056
#define EGL_NO_CONTEXT ((EGLContext)0)
#define EGL_NO_DISPLAY ((EGLDisplay)0)
#define EGL_NO_SURFACE ((EGLSurface)0)

// EGL_ANGLE_platform_angle: which native API behind EGL should draw.
#define EGL_PLATFORM_ANGLE_ANGLE 0x3202
#define EGL_PLATFORM_ANGLE_TYPE_ANGLE 0x3203
#define EGL_PLATFORM_ANGLE_TYPE_D3D11_ANGLE 0x3208
#define EGL_PLATFORM_ANGLE_DEVICE_TYPE_ANGLE 0x3209
#define EGL_PLATFORM_ANGLE_DEVICE_TYPE_HARDWARE_ANGLE 0x320A
#define EGL_PLATFORM_ANGLE_DEVICE_TYPE_D3D_WARP_ANGLE 0x320B
#define EGL_DEFAULT_DISPLAY ((EGLNativeDisplayType)0)

// EGL
EGLDisplay (*eglGetDisplay)(EGLNativeDisplayType);
EGLDisplay (*eglGetPlatformDisplayEXT)(EGLenum, void *, const EGLint *);
EGLBoolean (*eglInitialize)(EGLDisplay, EGLint *, EGLint *);
EGLBoolean (*eglChooseConfig)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *);
EGLContext (*eglCreateContext)(EGLDisplay, EGLConfig, EGLContext, const EGLint *);
EGLBoolean (*eglDestroyContext)(EGLDisplay, EGLContext);
EGLBoolean (*eglMakeCurrent)(EGLDisplay, EGLSurface, EGLSurface, EGLContext);
EGLContext (*eglGetCurrentContext)(void);
EGLBoolean (*eglBindAPI)(EGLenum);
EGLSurface (*eglCreatePbufferSurface)(EGLDisplay, EGLConfig, const EGLint *);
EGLBoolean (*eglDestroySurface)(EGLDisplay, EGLSurface);
const char *(*eglQueryString)(EGLDisplay, EGLint);
EGLint (*eglGetError)(void);
EGLBoolean (*eglQueryDisplayAttribANGLE)(EGLDisplay, EGLint, EGLAttrib *);
EGLBoolean (*eglQueryDeviceAttribEXT)(EGLDeviceEXT, EGLint, EGLAttrib *);
EGLSurface (*eglCreatePbufferFromClientBuffer)(EGLDisplay, EGLenum, void *, EGLConfig, const EGLint *);
void *(*eglGetProcAddress)(const char *);

// GL functions the host calls, each resolved from the loaded library.
GLenum (*glGetError)(void);
const GLubyte *(*glGetString)(GLenum);
const GLubyte *(*glGetStringi)(GLenum, GLuint);
void (*glGetIntegerv)(GLenum, GLint *);
void (*glGetFloatv)(GLenum, GLfloat *);
void (*glFinish)(void);
void (*glFlush)(void);
void (*glReadPixels)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *);
void (*glPixelStorei)(GLenum, GLint);
void (*glViewport)(GLint, GLint, GLsizei, GLsizei);
void (*glScissor)(GLint, GLint, GLsizei, GLsizei);
void (*glEnable)(GLenum);
void (*glDisable)(GLenum);
void (*glClear)(GLbitfield);
void (*glClearColor)(GLfloat, GLfloat, GLfloat, GLfloat);
void (*glClearDepthf)(GLfloat);
void (*glClearStencil)(GLint);
void (*glColorMask)(GLboolean, GLboolean, GLboolean, GLboolean);
void (*glDepthMask)(GLboolean);
void (*glStencilMask)(GLuint);
void (*glCullFace)(GLenum);
void (*glFrontFace)(GLenum);
void (*glDepthFunc)(GLenum);
void (*glDepthRangef)(GLfloat, GLfloat);
void (*glBlendFunc)(GLenum, GLenum);
void (*glBlendFuncSeparate)(GLenum, GLenum, GLenum, GLenum);
void (*glBlendEquation)(GLenum);
void (*glBlendEquationSeparate)(GLenum, GLenum);
void (*glBlendColor)(GLfloat, GLfloat, GLfloat, GLfloat);
void (*glPolygonOffset)(GLfloat, GLfloat);
void (*glStencilFunc)(GLenum, GLint, GLuint);
void (*glStencilOp)(GLenum, GLenum, GLenum);
void (*glLineWidth)(GLfloat);
void (*glBindFramebuffer)(GLenum, GLuint);
void (*glBindRenderbuffer)(GLenum, GLuint);
void (*glFramebufferTexture2D)(GLenum, GLenum, GLenum, GLuint, GLint);
void (*glFramebufferRenderbuffer)(GLenum, GLenum, GLenum, GLuint);
void (*glRenderbufferStorage)(GLenum, GLenum, GLsizei, GLsizei);
void (*glRenderbufferStorageMultisample)(GLenum, GLsizei, GLenum, GLsizei, GLsizei);
GLenum (*glCheckFramebufferStatus)(GLenum);
void (*glBlitFramebuffer)(GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLbitfield, GLenum);
void (*glDrawBuffers)(GLsizei, const GLenum *);
void (*glGenFramebuffers)(GLsizei, GLuint *);
void (*glDeleteFramebuffers)(GLsizei, const GLuint *);
void (*glGenRenderbuffers)(GLsizei, GLuint *);
void (*glDeleteRenderbuffers)(GLsizei, const GLuint *);
void (*glGenTextures)(GLsizei, GLuint *);
void (*glDeleteTextures)(GLsizei, const GLuint *);
void (*glBindTexture)(GLenum, GLuint);
void (*glActiveTexture)(GLenum);
void (*glTexImage2D)(GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *);
void (*glTexImage3D)(GLenum, GLint, GLint, GLsizei, GLsizei, GLsizei, GLint, GLenum, GLenum, const void *);
void (*glTexSubImage2D)(GLenum, GLint, GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, const void *);
void (*glTexStorage2D)(GLenum, GLsizei, GLenum, GLsizei, GLsizei);
void (*glTexParameteri)(GLenum, GLenum, GLint);
void (*glTexParameterf)(GLenum, GLenum, GLfloat);
void (*glGenerateMipmap)(GLenum);
void (*glGenBuffers)(GLsizei, GLuint *);
void (*glDeleteBuffers)(GLsizei, const GLuint *);
void (*glBindBuffer)(GLenum, GLuint);
void (*glBufferData)(GLenum, GLsizeiptr, const void *, GLenum);
void (*glBufferSubData)(GLenum, GLintptr, GLsizeiptr, const void *);
GLuint (*glCreateShader)(GLenum);
void (*glDeleteShader)(GLuint);
void (*glShaderSource)(GLuint, GLsizei, const GLchar *const *, const GLint *);
void (*glCompileShader)(GLuint);
void (*glGetShaderiv)(GLuint, GLenum, GLint *);
void (*glGetShaderInfoLog)(GLuint, GLsizei, GLsizei *, GLchar *);
void (*glAttachShader)(GLuint, GLuint);
void (*glDetachShader)(GLuint, GLuint);
void (*glBindAttribLocation)(GLuint, GLuint, const GLchar *);
GLuint (*glCreateProgram)(void);
void (*glDeleteProgram)(GLuint);
void (*glLinkProgram)(GLuint);
void (*glUseProgram)(GLuint);
void (*glGetProgramiv)(GLuint, GLenum, GLint *);
void (*glGetProgramInfoLog)(GLuint, GLsizei, GLsizei *, GLchar *);
GLint (*glGetAttribLocation)(GLuint, const GLchar *);
GLint (*glGetUniformLocation)(GLuint, const GLchar *);
GLuint (*glGetUniformBlockIndex)(GLuint, const GLchar *);
void (*glGetActiveUniform)(GLuint, GLuint, GLsizei, GLsizei *, GLint *, GLenum *, GLchar *);
void (*glGetActiveAttrib)(GLuint, GLuint, GLsizei, GLsizei *, GLint *, GLenum *, GLchar *);
void (*glUniform1f)(GLint, GLfloat);
void (*glUniform1fv)(GLint, GLsizei, const GLfloat *);
void (*glUniform2fv)(GLint, GLsizei, const GLfloat *);
void (*glUniform3fv)(GLint, GLsizei, const GLfloat *);
void (*glUniform4fv)(GLint, GLsizei, const GLfloat *);
void (*glUniform1i)(GLint, GLint);
void (*glUniform1iv)(GLint, GLsizei, const GLint *);
void (*glUniform2iv)(GLint, GLsizei, const GLint *);
void (*glUniform3iv)(GLint, GLsizei, const GLint *);
void (*glUniform4iv)(GLint, GLsizei, const GLint *);
void (*glUniform1uiv)(GLint, GLsizei, const GLuint *);
void (*glUniform2uiv)(GLint, GLsizei, const GLuint *);
void (*glUniform3uiv)(GLint, GLsizei, const GLuint *);
void (*glUniform4uiv)(GLint, GLsizei, const GLuint *);
void (*glUniformMatrix2fv)(GLint, GLsizei, GLboolean, const GLfloat *);
void (*glUniformMatrix3fv)(GLint, GLsizei, GLboolean, const GLfloat *);
void (*glUniformMatrix4fv)(GLint, GLsizei, GLboolean, const GLfloat *);
void (*glGenVertexArrays)(GLsizei, GLuint *);
void (*glDeleteVertexArrays)(GLsizei, const GLuint *);
void (*glBindVertexArray)(GLuint);
void (*glEnableVertexAttribArray)(GLuint);
void (*glDisableVertexAttribArray)(GLuint);
void (*glVertexAttribPointer)(GLuint, GLint, GLenum, GLboolean, GLsizei, const void *);
void (*glVertexAttribIPointer)(GLuint, GLint, GLenum, GLsizei, const void *);
void (*glVertexAttribDivisor)(GLuint, GLuint);
void (*glVertexAttrib1fv)(GLuint, const GLfloat *);
void (*glVertexAttrib2fv)(GLuint, const GLfloat *);
void (*glVertexAttrib3fv)(GLuint, const GLfloat *);
void (*glVertexAttrib4fv)(GLuint, const GLfloat *);
void (*glDrawArrays)(GLenum, GLint, GLsizei);
void (*glDrawElements)(GLenum, GLsizei, GLenum, const void *);
void (*glDrawArraysInstanced)(GLenum, GLint, GLsizei, GLsizei);
void (*glDrawElementsInstanced)(GLenum, GLsizei, GLenum, const void *, GLsizei);

#endif
