#import "AWTInputBridge.h"
#include "utils.h"

static jclass class_CTCAndroidInput;
static jmethodID method_ReceiveInput;

void AWTInputBridge_nativeSendData(int type, int i1, int i2, int i3, int i4) {
    if (!runtimeJNIEnvPtr) {
        return;
    }

    if (!method_ReceiveInput) {
        class_CTCAndroidInput = (*runtimeJNIEnvPtr)->FindClass(runtimeJNIEnvPtr, "net/java/openjdk/cacio/ctc/CTCAndroidInput");
        if ((*runtimeJNIEnvPtr)->ExceptionCheck(runtimeJNIEnvPtr) == JNI_TRUE) {
            (*runtimeJNIEnvPtr)->ExceptionClear(runtimeJNIEnvPtr);
            class_CTCAndroidInput = (*runtimeJNIEnvPtr)->FindClass(runtimeJNIEnvPtr, "com/github/caciocavallosilano/cacio/ctc/CTCAndroidInput");
        }
        assert(class_CTCAndroidInput != NULL);
        method_ReceiveInput = (*runtimeJNIEnvPtr)->GetStaticMethodID(runtimeJNIEnvPtr, class_CTCAndroidInput, "receiveData", "(IIIII)V");
        assert(method_ReceiveInput != NULL);
    }

    (*runtimeJNIEnvPtr)->CallStaticVoidMethod(
        runtimeJNIEnvPtr,
        class_CTCAndroidInput,
        method_ReceiveInput,
        type, i1, i2, i3, i4
    );
}

void AWTInputBridge_sendChar(jchar keychar) {
    AWTInputBridge_nativeSendData(EVENT_TYPE_CHAR, (unsigned int)keychar, 0, 0, 0);
}

void AWTInputBridge_sendKey(int keycode) {
    // TODO: iOS -> AWT keycode mapping
    AWTInputBridge_nativeSendData(EVENT_TYPE_KEY, ' ', keycode, 1, 0);
    AWTInputBridge_nativeSendData(EVENT_TYPE_KEY, ' ', keycode, 0, 0);
}

static JNIEnv *surfaceJNIEnv;
static jclass class_CTCScreen;
static jmethodID method_GetRGB;
static int *rgbArray;

const int *AWTScreenBridge_copyCurrentScreen(void) {
    if (!runtimeJavaVMPtr) {
        // JVM is not ready yet
        return NULL;
    } else if (!surfaceJNIEnv) {
        // Obtain JNIEnvs
        (*runtimeJavaVMPtr)->AttachCurrentThread(runtimeJavaVMPtr, &surfaceJNIEnv, NULL);
        assert(surfaceJNIEnv);
        dispatch_async(dispatch_get_main_queue(), ^{
            (*runtimeJavaVMPtr)->AttachCurrentThread(runtimeJavaVMPtr, &runtimeJNIEnvPtr, NULL);
            assert(runtimeJNIEnvPtr);
        });

        // Obtain CTCScreen.getCurrentScreenRGB()
        class_CTCScreen = (*surfaceJNIEnv)->FindClass(surfaceJNIEnv, "net/java/openjdk/cacio/ctc/CTCScreen");
        if ((*surfaceJNIEnv)->ExceptionCheck(surfaceJNIEnv) == JNI_TRUE) {
            (*surfaceJNIEnv)->ExceptionClear(surfaceJNIEnv);
            class_CTCScreen = (*surfaceJNIEnv)->FindClass(surfaceJNIEnv, "com/github/caciocavallosilano/cacio/ctc/CTCScreen");
        }
        assert(class_CTCScreen != NULL);
        method_GetRGB = (*surfaceJNIEnv)->GetStaticMethodID(surfaceJNIEnv, class_CTCScreen, "getCurrentScreenRGB", "()[I");
        assert(method_GetRGB != NULL);
        rgbArray = calloc(4, (size_t) (windowWidth * windowHeight));
    }

    jintArray jreRgbArray = (jintArray) (*surfaceJNIEnv)->CallStaticObjectMethod(
        surfaceJNIEnv,
        class_CTCScreen,
        method_GetRGB
    );
    if (!jreRgbArray) {
        return NULL;
    }
    int *tmpArray = (*surfaceJNIEnv)->GetIntArrayElements(surfaceJNIEnv, jreRgbArray, 0);
    memcpy(rgbArray, tmpArray, windowWidth * windowHeight * 4);
    (*surfaceJNIEnv)->ReleaseIntArrayElements(surfaceJNIEnv, jreRgbArray, tmpArray, JNI_ABORT);
    return rgbArray;
}
