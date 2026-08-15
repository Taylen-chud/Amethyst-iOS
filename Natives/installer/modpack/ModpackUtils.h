#import <Foundation/Foundation.h>
#import "UnzipKit.h"

@interface ModpackUtils : NSObject

+ (BOOL)isSafeRelativePath:(NSString *)path;
+ (BOOL)isVersionInstalled:(NSString *)versionId;
+ (void)archive:(UZKArchive *)archive extractDirectory:(NSString *)dir toPath:(NSString *)path error:(NSError **)error;
+ (NSDictionary *)infoForDependencies:(NSDictionary *)dependency;
+ (NSDictionary *)infoForCurseForgeMinecraft:(NSDictionary *)minecraft;

@end
