#import <UIKit/UIKit.h>

@class ModpackAPI;
@class ModManagerStore;

@interface MinecraftResourceDownloadTask : NSObject

@property NSProgress *progress, *textProgress;
@property NSMutableArray *fileList, *progressList;
@property NSMutableDictionary *metadata;
@property (nonatomic, copy) void(^handleError)(void);
@property (nonatomic, copy) void(^allDownloadTasksFinishedHandler)(void);

// Post-install properties
@property NSArray<NSDictionary *> *postInstallManualDownloads;
@property NSString *postInstallInstallerPath;
@property BOOL postInstallHitEnter;

// Task control & status
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path;
- (void)finishDownloadWithErrorString:(NSString *)error;
- (BOOL)allDownloadTasksFinished;
- (void)markAllDownloadTasksComplete;

// Finalization helpers
- (void)finalizeModInstall;
- (void)finalizeModpackMetadata;

// Download routines
- (void)downloadVersion:(NSDictionary *)version;
- (void)downloadModpackFromAPI:(ModpackAPI *)api detail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion;
- (void)downloadModsWithPlan:(NSDictionary *)plan store:(ModManagerStore *)store;

@end