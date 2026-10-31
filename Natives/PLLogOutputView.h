#pragma once

#import <UIKit/UIKit.h>

@interface PLLogOutputView : UIView
+ (void)appendToLog:(NSString *)line;
+ (BOOL)handleExitCode:(int)code;
@end
