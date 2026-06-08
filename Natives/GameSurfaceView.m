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

    if (@available(iOS 16.0, *)) {
        if ([self.layer isKindOfClass:CAMetalLayer.class]) {
            CAMetalLayer *metalLayer = (CAMetalLayer *)self.layer;
            metalLayer.preferredFrameRateRange = CAFrameRateRangeMake(30, 120, 120);
        }
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
