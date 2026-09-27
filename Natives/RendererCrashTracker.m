#import "RendererCrashTracker.h"

#include <stdlib.h>

static NSString * const kHealthFileName = @"renderer_health.plist";
static NSString * const kRendererKey = @"renderer";
static NSString * const kFailureCountKey = @"pendingFailureCount";

@implementation RendererCrashTracker

+ (nullable NSString *)healthFilePath {
    const char *home = getenv("POJAV_HOME");
    if (!home || !*home) return nil;
    return [[NSString stringWithUTF8String:home] stringByAppendingPathComponent:kHealthFileName];
}

+ (NSDictionary *)loadState {
    NSString *path = [self healthFilePath];
    if (!path) return @{};
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
    return dict ?: @{};
}

+ (void)saveState:(NSDictionary *)state {
    NSString *path = [self healthFilePath];
    if (!path) return;
    [state writeToFile:path atomically:YES];
}

+ (NSUInteger)consecutiveFailuresForRenderer:(NSString *)renderer {
    if (renderer == nil) return 0;
    NSDictionary *state = [self loadState];
    NSString *trackedRenderer = state[kRendererKey];
    if (![trackedRenderer isEqualToString:renderer]) {
        return 0;
    }
    NSNumber *count = state[kFailureCountKey];
    return count ? count.unsignedIntegerValue : 0;
}

+ (void)recordLaunchAttemptForRenderer:(NSString *)renderer {
    if (renderer == nil) return;
    NSDictionary *state = [self loadState];
    NSString *trackedRenderer = state[kRendererKey];
    NSUInteger currentCount = 0;
    if ([trackedRenderer isEqualToString:renderer]) {
        NSNumber *count = state[kFailureCountKey];
        currentCount = count ? count.unsignedIntegerValue : 0;
    }
    [self saveState:@{
        kRendererKey: renderer,
        kFailureCountKey: @(currentCount + 1),
    }];
}

+ (void)markLaunchStableForRenderer:(NSString *)renderer {
    if (renderer == nil) return;
    NSDictionary *state = [self loadState];
    NSString *trackedRenderer = state[kRendererKey];
    // Only clear if this is still the same renderer that was recorded - this
    // stops a stale delayed block from an earlier launch clearing a count
    // that belongs to a renderer the user has since switched to.
    if (![trackedRenderer isEqualToString:renderer]) return;
    [self saveState:@{
        kRendererKey: renderer,
        kFailureCountKey: @(0),
    }];
}

@end
