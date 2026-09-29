package org.lwjgl.sdl;

final class SDL3Bridge {
    private SDL3Bridge() {
    }

    static native void nativePrepare();
    static native void nativeLoaded();
    static native boolean nativeInit(long functionAddress, int flags);
    static native boolean nativeInitSubSystem(long functionAddress, int flags);
    static native long nativeCreateWindow(long functionAddress, long title, int w, int h, long flags);
    static native long nativeCreateWindowWithProperties(long functionAddress, int props);
    static native void nativeAttachWindow(long sdlWindow, long uiWindow);

    static void attachWindow(long sdlWindow) {
        System.out.println("[SDL3 TRACE] attachWindow(" + sdlWindow + ")");
        if (sdlWindow == 0L) {
            return;
        }

        int properties = SDLVideo.SDL_GetWindowProperties(sdlWindow);
        if (properties == 0) {
            return;
        }

        long uiWindow = SDLProperties.SDL_GetPointerProperty(
            properties,
            SDLVideo.SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER,
            0L
        );

        nativeAttachWindow(sdlWindow, uiWindow);
    }
}
