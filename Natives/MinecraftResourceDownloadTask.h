#import <UIKit/UIKit.h>

@class ModpackAPI;
@class ModManagerStore;

@interface MinecraftResourceDownloadTask : NSObject
@property NSProgress *progress, *textProgress;
@property NSMutableArray *fileList, *progressList;
@property NSMutableDictionary* metadata;
@property NSString *postInstallInstallerPath;
@property BOOL postInstallHitEnter;
@property NSArray<NSDictionary *> *postInstallManualDownloads;
@property NSDictionary *postInstallModpackMetadataPlan;
@property(nonatomic, copy) void(^handleError)(void);
@property(nonatomic, copy) void(^allDownloadTasksFinishedHandler)(void);

- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path;
- (void)finishDownloadWithErrorString:(NSString *)error;
- (void)finishAddingDownloadTasks;
- (BOOL)allDownloadTasksFinished;
- (void)markAllDownloadTasksComplete;

- (void)downloadVersion:(NSDictionary *)version;
- (void)downloadModpackFromAPI:(ModpackAPI *)api detail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion;
- (void)downloadModsWithPlan:(NSDictionary *)plan store:(ModManagerStore *)store;
- (void)finalizeModInstall;
- (void)finalizeModpackMetadata;

@end
