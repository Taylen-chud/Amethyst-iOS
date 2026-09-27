#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RendererCrashTracker : NSObject

+ (NSUInteger)consecutiveFailuresForRenderer:(NSString *)renderer;
+ (void)recordLaunchAttemptForRenderer:(NSString *)renderer;
+ (void)markLaunchStableForRenderer:(NSString *)renderer;

@end

NS_ASSUME_NONNULL_END