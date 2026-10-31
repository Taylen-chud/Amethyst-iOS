#pragma once

#import <UIKit/UIKit.h>

#import "GameSurfaceView.h"
#import "PLLogOutputView.h"
#import "SurfaceGlobals.h"

@interface SurfaceViewController : UIViewController

- (instancetype)initWithMetadata:(NSDictionary *)metadata;
- (void)sendTouchPoint:(CGPoint)location withEvent:(int)event;
- (void)updateSavedResolution;
- (void)updateGrabState;

+ (GameSurfaceView *)surface;
+ (BOOL)isRunning;

@end
