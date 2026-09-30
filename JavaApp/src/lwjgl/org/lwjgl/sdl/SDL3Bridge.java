package org.lwjgl.sdl;

import java.nio.ByteBuffer;
import org.lwjgl.system.MemoryStack;
import org.lwjgl.system.MemoryUtil;

final class SDL3Bridge {
    private SDL3Bridge() {
    }

    // minecraft replaces System.out/err with log4j streams (INFO/ERROR, and log4j has no config
    // here) so use fd 2 directly, that one ends up in latestlog.txt
    private static final java.io.FileOutputStream RAW_ERR = new java.io.FileOutputStream(java.io.FileDescriptor.err);

    static void trace(String line) {
        try {
            RAW_ERR.write((line + "\n").getBytes("UTF-8"));
        } catch (Throwable ignored) {
        }
    }

    static native void nativePrepare();
    static native void nativeLoaded();
    static native boolean nativeInit(long functionAddress, int flags);
    static native boolean nativeInitSubSystem(long functionAddress, int flags);
    static native long nativeCreateWindow(long functionAddress, long title, int w, int h, long flags);
    static native long nativeCreateWindowWithProperties(long functionAddress, int props);
    static native void nativeAttachWindow(long sdlWindow, long uiWindow);
    static native long nativeInvokeOnMain(long functionAddress, long a0, long a1, long a2, long a3);
    static native void nativeRegisterInput();
    static native void nativeSetGrabbing(boolean grabbing);

    // runs an SDL function on the iOS main thread. integer/pointer args only, returns raw x0
    static long invokeOnMain(long functionAddress, long a0, long a1, long a2, long a3) {
        return nativeInvokeOnMain(functionAddress, a0, a1, a2, a3);
    }

    static void attachWindow(long sdlWindow) {
        // note: minecraft swaps System.out for a log4j stream with no config, so anything
        // on System.out after startup vanishes. System.err still shows up
        trace("[SDL3 TRACE] attachWindow(" + sdlWindow + ")");
        if (sdlWindow == 0L) {
            return;
        }
        registerInput(sdlWindow);

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

    // ---------------------------------------------------------------------
    // input: amethyst's touch/keyboard/control code talks GLFW callbacks, minecraft 26.x
    // reads SDL events instead. native forwards everything to onInput() and we turn it
    // into SDL events with SDL_PushEvent
    // ---------------------------------------------------------------------

    private static final int INPUT_CURSOR = 0;
    private static final int INPUT_BUTTON = 1;
    private static final int INPUT_KEY = 2;
    private static final int INPUT_CHAR = 3;
    private static final int INPUT_SCROLL = 4;

    private static final int ACTION_DOWN = 0;
    private static final int ACTION_UP = 1;
    private static final int ACTION_MOVE = 2;
    private static final int ACTION_MOVE_MOTION = 3;

    private static final int GLFW_KEY_ENTER = 257;
    private static final int GLFW_KEY_ESCAPE = 256;
    private static final int GLFW_KEY_TAB = 258;
    private static final int GLFW_KEY_BACKSPACE = 259;
    private static final int GLFW_KEY_DELETE = 261;

    private static final int[] SCANCODES = new int[349];

    private static long inputWindow;
    private static int inputWindowId;
    private static boolean registered;
    private static volatile boolean grabbed;
    private static float curX, curY, lastX, lastY;
    private static int buttonState;
    private static int inputCount;
    private static int cursorTraces, buttonTraces;
    private static int winW, winH, pixW, pixH;
    private static long winSizeAt;
    private static int pushOk, pushFail;
    private static final int[] polled = new int[0x1400];
    private static long lastSummary = System.nanoTime();
    private static int lastPolledTotal;
    private static final ByteBuffer[] textRing = new ByteBuffer[64];
    private static int textRingPos;

    static {
        trace("[SDL3 BUILD] input bridge v2 loaded");
        for (int i = 0; i < 26; i++) {
            SCANCODES[65 + i] = SDLScancode.SDL_SCANCODE_A + i;
        }
        SCANCODES[48] = SDLScancode.SDL_SCANCODE_0;
        for (int i = 1; i < 10; i++) {
            SCANCODES[48 + i] = SDLScancode.SDL_SCANCODE_1 + (i - 1);
        }
        for (int i = 0; i < 12; i++) {
            SCANCODES[290 + i] = SDLScancode.SDL_SCANCODE_F1 + i;
        }
        for (int i = 0; i < 12; i++) {
            SCANCODES[302 + i] = SDLScancode.SDL_SCANCODE_F13 + i; // F13..F24, F25 has no SDL equivalent
        }
        SCANCODES[320] = SDLScancode.SDL_SCANCODE_KP_0;
        for (int i = 1; i < 10; i++) {
            SCANCODES[320 + i] = SDLScancode.SDL_SCANCODE_KP_1 + (i - 1);
        }
        SCANCODES[32] = SDLScancode.SDL_SCANCODE_SPACE;
        SCANCODES[39] = SDLScancode.SDL_SCANCODE_APOSTROPHE;
        SCANCODES[44] = SDLScancode.SDL_SCANCODE_COMMA;
        SCANCODES[45] = SDLScancode.SDL_SCANCODE_MINUS;
        SCANCODES[46] = SDLScancode.SDL_SCANCODE_PERIOD;
        SCANCODES[47] = SDLScancode.SDL_SCANCODE_SLASH;
        SCANCODES[59] = SDLScancode.SDL_SCANCODE_SEMICOLON;
        SCANCODES[61] = SDLScancode.SDL_SCANCODE_EQUALS;
        SCANCODES[91] = SDLScancode.SDL_SCANCODE_LEFTBRACKET;
        SCANCODES[92] = SDLScancode.SDL_SCANCODE_BACKSLASH;
        SCANCODES[93] = SDLScancode.SDL_SCANCODE_RIGHTBRACKET;
        SCANCODES[96] = SDLScancode.SDL_SCANCODE_GRAVE;
        SCANCODES[161] = SDLScancode.SDL_SCANCODE_NONUSBACKSLASH;
        SCANCODES[256] = SDLScancode.SDL_SCANCODE_ESCAPE;
        SCANCODES[257] = SDLScancode.SDL_SCANCODE_RETURN;
        SCANCODES[258] = SDLScancode.SDL_SCANCODE_TAB;
        SCANCODES[259] = SDLScancode.SDL_SCANCODE_BACKSPACE;
        SCANCODES[260] = SDLScancode.SDL_SCANCODE_INSERT;
        SCANCODES[261] = SDLScancode.SDL_SCANCODE_DELETE;
        SCANCODES[262] = SDLScancode.SDL_SCANCODE_RIGHT;
        SCANCODES[263] = SDLScancode.SDL_SCANCODE_LEFT;
        SCANCODES[264] = SDLScancode.SDL_SCANCODE_DOWN;
        SCANCODES[265] = SDLScancode.SDL_SCANCODE_UP;
        SCANCODES[266] = SDLScancode.SDL_SCANCODE_PAGEUP;
        SCANCODES[267] = SDLScancode.SDL_SCANCODE_PAGEDOWN;
        SCANCODES[268] = SDLScancode.SDL_SCANCODE_HOME;
        SCANCODES[269] = SDLScancode.SDL_SCANCODE_END;
        SCANCODES[280] = SDLScancode.SDL_SCANCODE_CAPSLOCK;
        SCANCODES[281] = SDLScancode.SDL_SCANCODE_SCROLLLOCK;
        SCANCODES[282] = SDLScancode.SDL_SCANCODE_NUMLOCKCLEAR;
        SCANCODES[283] = SDLScancode.SDL_SCANCODE_PRINTSCREEN;
        SCANCODES[284] = SDLScancode.SDL_SCANCODE_PAUSE;
        SCANCODES[330] = SDLScancode.SDL_SCANCODE_KP_PERIOD;
        SCANCODES[331] = SDLScancode.SDL_SCANCODE_KP_DIVIDE;
        SCANCODES[332] = SDLScancode.SDL_SCANCODE_KP_MULTIPLY;
        SCANCODES[333] = SDLScancode.SDL_SCANCODE_KP_MINUS;
        SCANCODES[334] = SDLScancode.SDL_SCANCODE_KP_PLUS;
        SCANCODES[335] = SDLScancode.SDL_SCANCODE_KP_ENTER;
        SCANCODES[336] = SDLScancode.SDL_SCANCODE_KP_EQUALS;
        SCANCODES[340] = SDLScancode.SDL_SCANCODE_LSHIFT;
        SCANCODES[341] = SDLScancode.SDL_SCANCODE_LCTRL;
        SCANCODES[342] = SDLScancode.SDL_SCANCODE_LALT;
        SCANCODES[343] = SDLScancode.SDL_SCANCODE_LGUI;
        SCANCODES[344] = SDLScancode.SDL_SCANCODE_RSHIFT;
        SCANCODES[345] = SDLScancode.SDL_SCANCODE_RCTRL;
        SCANCODES[346] = SDLScancode.SDL_SCANCODE_RALT;
        SCANCODES[347] = SDLScancode.SDL_SCANCODE_RGUI;
        SCANCODES[348] = SDLScancode.SDL_SCANCODE_APPLICATION;
    }

    private static synchronized void registerInput(long sdlWindow) {
        inputWindow = sdlWindow;
        inputWindowId = SDLVideo.SDL_GetWindowID(sdlWindow);
        if (!registered) {
            registered = true;
            nativeRegisterInput();
        }
        trace("[SDL3 TRACE] input bridge registered, windowID=" + inputWindowId);
        winW = 0;
        refreshWindowSize();
    }

    // relative mouse mode == amethyst's "grabbing" (hides the virtual mouse, shows in-game controls)
    static void setGrabbing(boolean enabled) {
        grabbed = enabled;
        nativeSetGrabbing(enabled);
    }

    // called from native on whatever thread uikit delivered the event on
    static synchronized void onInput(int kind, int a, int b, int c, int d, float f1, float f2) {
        if (inputWindow == 0L) {
            return;
        }
        try {
            switch (kind) {
                case INPUT_CURSOR:
                    onCursor(a, b != 0, f1, f2);
                    break;
                case INPUT_BUTTON:
                    onButton(a, b != 0);
                    break;
                case INPUT_KEY:
                    onKey(a, b, c != 0, d);
                    break;
                case INPUT_CHAR:
                    onChar(a);
                    break;
                case INPUT_SCROLL:
                    onScroll(f1, f2);
                    break;
                default:
                    break;
            }
        } catch (Throwable t) {
            t.printStackTrace();
        }
        if (++inputCount <= 12) {
            trace("[SDL3 TRACE] input kind=" + kind + " a=" + a + " b=" + b + " c=" + c + " f=" + f1 + "," + f2);
        }
    }

    // SDL's logical window size (points) and pixel size. amethyst sends absolute cursor positions
    // as a 0..1 fraction of its own game window so they can be scaled to whatever SDL calls the window
    private static void refreshWindowSize() {
        long now = System.nanoTime();
        if (winW > 0 && now - winSizeAt < 250000000L) {
            return;
        }
        winSizeAt = now;
        try (MemoryStack stack = MemoryStack.stackPush()) {
            java.nio.IntBuffer w = stack.mallocInt(1);
            java.nio.IntBuffer h = stack.mallocInt(1);
            java.nio.IntBuffer pw = stack.mallocInt(1);
            java.nio.IntBuffer ph = stack.mallocInt(1);
            if (!SDLVideo.SDL_GetWindowSize(inputWindow, w, h)) {
                return;
            }
            SDLVideo.SDL_GetWindowSizeInPixels(inputWindow, pw, ph);
            if (w.get(0) != winW || h.get(0) != winH || pw.get(0) != pixW || ph.get(0) != pixH) {
                winW = w.get(0);
                winH = h.get(0);
                pixW = pw.get(0);
                pixH = ph.get(0);
                trace("[SDL3 TRACE] sdl window size points=" + winW + "x" + winH + " pixels=" + pixW + "x" + pixH);
            }
        } catch (Throwable t) {
            // keep the old values
        }
    }

    private static void onCursor(int action, boolean normalized, float x, float y) {
        if (normalized) {
            refreshWindowSize();
            if (winW <= 0 || winH <= 0) {
                return;
            }
            x *= winW;
            y *= winH;
        }
        if (cursorTraces++ < 12) {
            trace("[SDL3 TRACE] cursor action=" + action + " normalized=" + normalized + " -> " + x + "," + y
                + " (window " + winW + "x" + winH + ")");
        }
        float dx;
        float dy;
        switch (action) {
            case ACTION_MOVE_MOTION:
                // x/y are already deltas
                dx = x;
                dy = y;
                break;
            case ACTION_MOVE:
                dx = x - lastX;
                dy = y - lastY;
                lastX = x;
                lastY = y;
                break;
            default: // ACTION_DOWN / ACTION_UP just (re)position
                dx = x - curX;
                dy = y - curY;
                lastX = x;
                lastY = y;
                if (grabbed) {
                    return;
                }
                break;
        }

        if (grabbed) {
            curX += dx;
            curY += dy;
        } else if (action == ACTION_MOVE_MOTION) {
            curX += dx;
            curY += dy;
        } else {
            curX = x;
            curY = y;
        }
        if (dx == 0f && dy == 0f) {
            return;
        }
        pushMotion(dx, dy);
    }

    private static void onButton(int glfwButton, boolean down) {
        int sdlButton;
        switch (glfwButton) {
            case 0: sdlButton = 1; break; // left
            case 1: sdlButton = 3; break; // right
            case 2: sdlButton = 2; break; // middle
            case 3: sdlButton = 4; break; // X1
            case 4: sdlButton = 5; break; // X2
            default: return;
        }
        if (buttonTraces++ < 12) {
            trace("[SDL3 TRACE] button glfw=" + glfwButton + " sdl=" + sdlButton + " down=" + down + " at " + curX + "," + curY);
        }
        int mask = 1 << (sdlButton - 1);
        buttonState = down ? (buttonState | mask) : (buttonState & ~mask);

        try (MemoryStack stack = MemoryStack.stackPush()) {
            SDL_Event ev = SDL_Event.calloc(stack);
            ev.button().set(
                down ? SDLEvents.SDL_EVENT_MOUSE_BUTTON_DOWN : SDLEvents.SDL_EVENT_MOUSE_BUTTON_UP,
                0L, inputWindowId, 0, (byte) sdlButton, down, (byte) 1, curX, curY);
            push(ev);
        }
    }

    private static void onScroll(float x, float y) {
        try (MemoryStack stack = MemoryStack.stackPush()) {
            SDL_Event ev = SDL_Event.calloc(stack);
            ev.wheel().set(
                SDLEvents.SDL_EVENT_MOUSE_WHEEL,
                0L, inputWindowId, 0, x, y, 0, curX, curY, Math.round(x), Math.round(y));
            push(ev);
        }
    }

    private static void onKey(int glfwKey, int glfwScancode, boolean down, int glfwMods) {
        if (glfwKey < 0 || glfwKey >= SCANCODES.length) {
            return;
        }
        int scancode = SCANCODES[glfwKey];
        if (scancode == 0) {
            return;
        }

        try (MemoryStack stack = MemoryStack.stackPush()) {
            SDL_Event ev = SDL_Event.calloc(stack);
            ev.key().set(
                down ? SDLEvents.SDL_EVENT_KEY_DOWN : SDLEvents.SDL_EVENT_KEY_UP,
                0L, inputWindowId, 0, scancode, keycodeFor(glfwKey, scancode),
                (short) sdlMods(glfwMods), (short) 0, down, false);
            push(ev);
        }
    }

    private static void onChar(int codepoint) {
        if (codepoint <= 0 || codepoint > 0x10FFFF) {
            return;
        }
        ByteBuffer text = MemoryUtil.memUTF8(new String(Character.toChars(codepoint)));
        // keep the last few strings alive, don't rely on whether SDL copies the pointer or not
        ByteBuffer old = textRing[textRingPos];
        textRing[textRingPos] = text;
        textRingPos = (textRingPos + 1) % textRing.length;
        if (old != null) {
            MemoryUtil.memFree(old);
        }

        try (MemoryStack stack = MemoryStack.stackPush()) {
            SDL_Event ev = SDL_Event.calloc(stack);
            ev.text().type(SDLEvents.SDL_EVENT_TEXT_INPUT).windowID(inputWindowId).text(text);
            push(ev);
        }
    }

    private static void pushMotion(float dx, float dy) {
        try (MemoryStack stack = MemoryStack.stackPush()) {
            SDL_Event ev = SDL_Event.calloc(stack);
            ev.motion().set(
                SDLEvents.SDL_EVENT_MOUSE_MOTION,
                0L, inputWindowId, 0, buttonState, curX, curY, dx, dy);
            push(ev);
        }
    }

    private static void push(SDL_Event ev) {
        boolean ok = SDLEvents.SDL_PushEvent(ev);
        if (ok) {
            pushOk++;
        } else if (pushFail++ < 5) {
            trace("[SDL3 TRACE] SDL_PushEvent failed: " + SDLError.SDL_GetError());
        }
    }

    // called for every event minecraft pulls out of SDL (PollEvent/WaitEvent*)
    static void polledEvent(int type) {
        if (type < 0 || type >= polled.length) {
            return;
        }
        if (polled[type]++ == 0) {
            trace("[SDL3 TRACE] first polled event type=0x" + Integer.toHexString(type));
        }
        long now = System.nanoTime();
        if (now - lastSummary < 5000000000L) {
            return;
        }
        lastSummary = now;
        int total = 0;
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < polled.length; i++) {
            if (polled[i] != 0) {
                total += polled[i];
                sb.append(" 0x").append(Integer.toHexString(i)).append("=").append(polled[i]);
            }
        }
        if (total != lastPolledTotal) {
            lastPolledTotal = total;
            trace("[SDL3 TRACE] polled:" + sb + " | pushed ok=" + pushOk + " failed=" + pushFail + " grabbed=" + grabbed);
        }
    }

    private static int keycodeFor(int glfwKey, int scancode) {
        if (glfwKey >= 65 && glfwKey <= 90) {
            return glfwKey + 32; // SDL keycodes for letters are lowercase
        }
        if (glfwKey >= 32 && glfwKey <= 96) {
            return glfwKey; // space, punctuation and digits match ASCII
        }
        switch (glfwKey) {
            case GLFW_KEY_ENTER: return '\r';
            case GLFW_KEY_ESCAPE: return 27;
            case GLFW_KEY_TAB: return '\t';
            case GLFW_KEY_BACKSPACE: return '\b';
            case GLFW_KEY_DELETE: return 127;
            default: return scancode | SDLKeycode.SDLK_SCANCODE_MASK;
        }
    }

    private static int sdlMods(int glfwMods) {
        int mods = 0;
        if ((glfwMods & 1) != 0) mods |= SDLKeycode.SDL_KMOD_LSHIFT;
        if ((glfwMods & 2) != 0) mods |= SDLKeycode.SDL_KMOD_LCTRL;
        if ((glfwMods & 4) != 0) mods |= SDLKeycode.SDL_KMOD_LALT;
        if ((glfwMods & 8) != 0) mods |= SDLKeycode.SDL_KMOD_LGUI;
        if ((glfwMods & 16) != 0) mods |= SDLKeycode.SDL_KMOD_CAPS;
        if ((glfwMods & 32) != 0) mods |= SDLKeycode.SDL_KMOD_NUM;
        return mods;
    }
}
