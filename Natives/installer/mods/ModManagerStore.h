#import <Foundation/Foundation.h>

@interface ModManagerStore : NSObject

@property(nonatomic, readonly) NSString *profileName;
@property(nonatomic, readonly) NSMutableDictionary *profile;
@property(nonatomic, readonly) NSString *profileGameDir;
@property(nonatomic, readonly) NSString *modsDir;
@property(nonatomic, readonly) NSString *metadataPath;
@property(nonatomic, readonly) NSDictionary *profileInfo;

- (instancetype)initWithProfileName:(NSString *)profileName profile:(NSMutableDictionary *)profile;

+ (NSDictionary *)profileInfoForVersionId:(NSString *)versionId;
+ (BOOL)profileInfoSupportsModInstall:(NSDictionary *)profileInfo;
+ (NSString *)displayNameForLoader:(NSString *)loader;

- (NSArray<NSMutableDictionary *> *)installedMods;
- (NSArray<NSMutableDictionary *> *)installedModsMatchingQuery:(NSString *)query;
- (BOOL)containsInstalledProjectWithSource:(NSString *)source projectId:(id)projectId;
- (NSArray<NSDictionary *> *)dependentModsForMod:(NSDictionary *)mod includeDisabled:(BOOL)includeDisabled;

- (BOOL)enableMod:(NSDictionary *)mod error:(NSError **)error;
- (BOOL)disableMod:(NSDictionary *)mod error:(NSError **)error;
- (BOOL)removeMod:(NSDictionary *)mod error:(NSError **)error;

- (NSDictionary *)installPlanForFiles:(NSArray<NSDictionary *> *)files error:(NSError **)error;
- (NSError *)saveMetadataRecords:(NSArray<NSDictionary *> *)records
               replacingFileNames:(NSArray<NSString *> *)replacedFileNames
                     replacements:(NSArray<NSDictionary *> *)replacements;

@end
