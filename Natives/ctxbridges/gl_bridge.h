#pragma once

#include <EGL/egl.h>

typedef struct {
    PFNEGLBINDAPIPROC eglBindAPI;
    PFNEGLCHOOSECONFIGPROC eglChooseConfig;
    PFNEGLCREATECONTEXTPROC eglCreateContext;
    PFNEGLCREATEWINDOWSURFACEPROC eglCreateWindowSurface;
    PFNEGLDESTROYCONTEXTPROC eglDestroyContext;
    PFNEGLDESTROYSURFACEPROC eglDestroySurface;
    PFNEGLGETCONFIGATTRIBPROC eglGetConfigAttrib;
    PFNEGLGETCONFIGSPROC eglGetConfigs;
    PFNEGLGETCURRENTCONTEXTPROC eglGetCurrentContext;
    PFNEGLGETCURRENTSURFACEPROC eglGetCurrentSurface;
    PFNEGLGETDISPLAYPROC eglGetDisplay;
    PFNEGLGETERRORPROC eglGetError;
    PFNEGLGETPLATFORMDISPLAYPROC eglGetPlatformDisplay;
    PFNEGLINITIALIZEPROC eglInitialize;
    PFNEGLMAKECURRENTPROC eglMakeCurrent;
    PFNEGLQUERYSTRINGPROC eglQueryString;
    PFNEGLRELEASETHREADPROC eglReleaseThread;
    PFNEGLSWAPBUFFERSPROC eglSwapBuffers;
    PFNEGLSWAPINTERVALPROC eglSwapInterval;
    PFNEGLTERMINATEPROC eglTerminate;
} egl_library;

typedef struct {
    //struct ANativeWindow *nativeSurface;
    EGLConfig  config;
    EGLint     format;
    EGLContext context;
    EGLSurface surface;
    EGLint surfaceWidth;
    EGLint surfaceHeight;
} gl_render_window_t;

void gl_notify_screen_size(int width, int height);

void set_gl_bridge_tbl();
