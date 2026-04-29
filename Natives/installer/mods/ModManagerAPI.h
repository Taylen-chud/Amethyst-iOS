#import <Foundation/Foundation.h>

@class ModManagerStore;

@interface ModManagerAPI : NSObject

@property(nonatomic) NSError *lastError;

- (NSArray<NSMutableDictionary *> *)searchModsWithQuery:(NSString *)query source:(NSString *)source profileInfo:(NSDictionary *)profileInfo;
- (NSArray<NSDictionary *> *)versionsForProject:(NSDictionary *)project profileInfo:(NSDictionary *)profileInfo;
- (NSDictionary *)latestVersionForInstalledMod:(NSDictionary *)mod profileInfo:(NSDictionary *)profileInfo error:(NSError **)error;
- (BOOL)resolveDependenciesForVersion:(NSDictionary *)version
                           profileInfo:(NSDictionary *)profileInfo
                                 store:(ModManagerStore *)store
                              required:(NSArray<NSDictionary *> **)required
                              optional:(NSArray<NSDictionary *> **)optional
                                 error:(NSError **)error;

@end
