#import "GameSurfaceView.h"
#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "utils.h"

@interface GameSurfaceView()
@end

@implementation GameSurfaceView

- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    self.layer.drawsAsynchronously = YES;
    self.layer.opaque = YES;

    if ([self.layer respondsToSelector:NSSelectorFromString(@"setPreferredFrameRateRange:")]) {
        NSMethodSignature *sig = [self.layer methodSignatureForSelector:NSSelectorFromString(@"setPreferredFrameRateRange:")];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        inv.target = self.layer;
        inv.selector = NSSelectorFromString(@"setPreferredFrameRateRange:");
        // CAFrameRateRange is {float minimum, float maximum, float preferred}
        float range[3] = {30.0f, 120.0f, 120.0f};
        [inv setArgument:&range atIndex:2];
        [inv invoke];
    }

    return self;
}

+ (Class)layerClass {
    if ([[PLProfiles resolveKeyForCurrentProfile:@"renderer"] hasPrefix:@"libOSMesa"]) {
        return CALayer.class;
    } else {
        return CAMetalLayer.class;
    }
}

@end
