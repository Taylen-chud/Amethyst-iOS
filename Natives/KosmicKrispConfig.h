#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Environment for the Kosmic Krisp Vulkan driver. Call before the driver is loaded.
@interface KosmicKrispConfig : NSObject

+ (void)applyEnvironmentFromPreferences;
+ (NSString *)activeConfigSummary;

@end

NS_ASSUME_NONNULL_END
