#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface JavaRuntimeExtractor : NSObject

+ (nullable NSString *)extractTarXZ:(NSString *)inPath
                                 to:(NSString *)outPath
                           progress:(NSProgress *)progress
                       fileProgress:(NSProgress *)fileProgress
                       fileCallback:(void (^)(NSString *name))fileCallback
                           validate:(NSString *_Nullable (^)(NSString *runtimePath))validate;

@end

NS_ASSUME_NONNULL_END
