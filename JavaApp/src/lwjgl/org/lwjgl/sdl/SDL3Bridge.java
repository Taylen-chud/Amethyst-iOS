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
    static native long nativeInvokeOnMain(long functionAddress, long a0, long a1, long a2, long a3);

    // runs an SDL function on the iOS main thread. integer/pointer args only, returns raw x0
    static long invokeOnMain(long functionAddress, long a0, long a1, long a2, long a3) {
        return nativeInvokeOnMain(functionAddress, a0, a1, a2, a3);
    }

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
