#import <Foundation/Foundation.h>
#import "ModpackUtils.h"
#import "UnzipKit.h"

@class MinecraftResourceDownloadTask;

@interface ModpackAPI : NSObject
@property(nonatomic) NSString *baseURL;
@property(nonatomic) NSError *lastError;
@property(nonatomic) BOOL reachedLastPage;

- (instancetype)initWithURL:(NSString *)url;
- (NSMutableArray *)searchModWithFilters:(NSDictionary *)filters previousPageResult:(NSMutableArray *)prevResult;
- (void)loadDetailsOfMod:(NSMutableDictionary *)item;

- (void)installModpackFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion;
- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath;

- (NSDictionary *)requestHeaders;
- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params;
- (id)postEndpoint:(NSString *)endpoint body:(NSDictionary *)body;
- (NSString *)downloadURLForModDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion;
- (NSString *)manualDownloadPageURLForModDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion;

@end
