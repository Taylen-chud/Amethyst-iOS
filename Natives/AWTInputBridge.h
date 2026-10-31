#pragma once

#import <Foundation/Foundation.h>
#include "jni.h"

// CTCAndroidInput.receiveData(type, i1, i2, i3, i4)
void AWTInputBridge_nativeSendData(int type, int i1, int i2, int i3, int i4);
void AWTInputBridge_sendChar(jchar keychar);
void AWTInputBridge_sendKey(int keycode);

const int *AWTScreenBridge_copyCurrentScreen(void);
