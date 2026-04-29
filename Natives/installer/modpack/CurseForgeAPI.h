#import <Foundation/Foundation.h>
#import "ModpackAPI.h"

@interface CurseForgeAPI : ModpackAPI
+ (BOOL)isConfigured;
- (NSString *)sha1HashForFile:(NSDictionary *)file;
- (NSString *)downloadURLForFile:(NSDictionary *)file projectID:(NSNumber *)projectID;
- (NSDictionary *)projectInfoForProjectID:(NSNumber *)projectID cache:(NSMutableDictionary *)cache;
- (NSArray *)fileMetadataForFileIDs:(NSArray<NSNumber *> *)fileIDs;
- (NSString *)manualDownloadPageURLForFile:(NSDictionary *)file projectID:(NSNumber *)projectID cache:(NSMutableDictionary *)cache;
- (NSArray *)filesForModID:(id)modID;
@end
