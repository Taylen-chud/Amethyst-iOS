package org.lwjgl.sdl;

final class SDL3Bridge {
    private SDL3Bridge() {
    }

    static native void nativePrepare();
    static native void nativeLoaded();
    static native void nativeAttachWindow(long sdlWindow, long uiWindow);

    static void attachWindow(long sdlWindow) {
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
