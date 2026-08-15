#include <CommonCrypto/CommonDigest.h>

#import "authenticator/BaseAuthenticator.h"
#import "installer/modpack/CurseForgeManualDownloadViewController.h"
#import "installer/modpack/ModpackAPI.h"
#import "installer/modpack/ModpackUtils.h"
#import "AFNetworking.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceDownloadTask.h"
#import "MinecraftResourceUtils.h"
#import "installer/mods/ModManagerStore.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

@interface MinecraftResourceDownloadTask ()
@property AFURLSessionManager* manager;
@property(nonatomic) NSUInteger pendingDownloadTaskCount;
@property(nonatomic) BOOL finishedAddingDownloadTasks;
@property(nonatomic) BOOL notifiedAllDownloadTasksFinished;
@property(nonatomic) NSDictionary *postInstallModPlan;
@property(nonatomic) ModManagerStore *postInstallModStore;
@end

@implementation MinecraftResourceDownloadTask

- (void)markProgressComplete:(NSProgress *)progress {
    if (!progress) {
        return;
    }

    int64_t completed = progress.completedUnitCount;
    int64_t total = progress.totalUnitCount;
    if (completed <= 0 && total <= 0) {
        completed = 1;
        total = 1;
    } else if (total <= 0 || completed > total) {
        total = completed;
    } else if (completed < total) {
        completed = total;
    }
    progress.totalUnitCount = total;
    progress.completedUnitCount = completed;
}

- (void)noteDownloadTaskAdded {
    @synchronized (self) {
        self.pendingDownloadTaskCount++;
    }
}

- (void)notifyAllDownloadTasksFinishedIfNeeded {
    void (^handler)(void) = nil;
    @synchronized (self) {
        if (self.notifiedAllDownloadTasksFinished ||
            !self.finishedAddingDownloadTasks ||
            self.pendingDownloadTaskCount != 0 ||
            self.progress.cancelled) {
            return;
        }
        self.notifiedAllDownloadTasksFinished = YES;
        handler = self.allDownloadTasksFinishedHandler;
    }
    [self markAllDownloadTasksComplete];
    if (handler) {
        handler();
    }
}

- (void)noteDownloadTaskFinished {
    BOOL shouldComplete = NO;
    @synchronized (self) {
        if (self.pendingDownloadTaskCount > 0) {
            self.pendingDownloadTaskCount--;
        }
        shouldComplete = self.finishedAddingDownloadTasks && self.pendingDownloadTaskCount == 0 && !self.progress.cancelled;
    }
    if (shouldComplete) {
        [self notifyAllDownloadTasksFinishedIfNeeded];
    }
}

- (BOOL)allDownloadTasksFinished {
    @synchronized (self) {
        return self.finishedAddingDownloadTasks && self.pendingDownloadTaskCount == 0 && !self.progress.cancelled;
    }
}

- (void)markAllDownloadTasksComplete {
    [self markProgressComplete:self.progress];
    [self markProgressComplete:self.textProgress];
}

- (instancetype)init {
    self = [super init];
    // TODO: implement background download
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    configuration.timeoutIntervalForRequest = 86400;
    //backgroundSessionConfigurationWithIdentifier:@"net.kdt.pojavlauncher.downloadtask"];
    self.manager = [[AFURLSessionManager alloc] initWithSessionConfiguration:configuration];
    self.fileList = [NSMutableArray new];
    self.progressList = [NSMutableArray new];
    return self;
}

// Add file to the queue
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path success:(void (^)())success {
    BOOL fileExists = [NSFileManager.defaultManager fileExistsAtPath:path];
    // logSuccess?
    if (fileExists && [self checkSHA:sha forFile:path altName:altName]) {
        if (success) success();
        return nil;
    } else if (![self checkAccessWithDialog:YES]) {
        return nil;
    }

    NSString *name = altName ?: path.lastPathComponent;
    NSURL *downloadURL = [url isKindOfClass:NSString.class] ? [NSURL URLWithString:url] : nil;
    NSString *scheme = downloadURL.scheme.lowercaseString;
    if (!downloadURL || (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"])) {
        [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Invalid download URL for %@", name]];
        return nil;
    }

    NSURLRequest *request = [NSURLRequest requestWithURL:downloadURL];
    __block NSProgress *progress;
    __block NSURLSessionDownloadTask *task = [self.manager downloadTaskWithRequest:request progress:nil
    destination:^NSURL * _Nonnull(NSURL * _Nonnull targetPath, NSURLResponse * _Nonnull response) {
        NSLog(@"[MCDL] Downloading %@", name);
        progress = [self.manager downloadProgressForTask:task];
        [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        return [NSURL fileURLWithPath:path];
    } completionHandler:^(NSURLResponse * _Nonnull response, NSURL * _Nullable filePath, NSError * _Nullable error) {
        if (self.progress.cancelled) {
            // Ignore any further errors
        } else if (error != nil) {
            [self finishDownloadWithError:error file:name];
        } else if (![self checkSHA:sha forFile:path altName:altName]) {
            [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to verify file %@: SHA1 mismatch", path.lastPathComponent]];
        } else {
            if (!progress) {
                progress = [self.manager downloadProgressForTask:task];
            }
            [self markProgressComplete:progress];
            if (success) success();
            [self noteDownloadTaskFinished];
        }
    }];

    if (task) {
        [self addDownloadTaskToProgress:task size:size];
        [self.fileList addObject:name];
    }

    return task;
}

- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path {
    return [self createDownloadTask:url size:size sha:sha altName:altName toPath:path success:nil];
}

- (void)addDownloadTaskToProgress:(NSURLSessionDownloadTask *)task size:(NSInteger)size {
    NSProgress *progress = [self.manager downloadProgressForTask:task];
    NSUInteger fileSize = size>0 ? size : 1;
    progress.kind = NSProgressKindFile;
    if (size > 0) {
        progress.totalUnitCount = fileSize;
    }
    [self.progressList addObject:progress];
    [self.progress addChild:progress withPendingUnitCount:fileSize];
    self.progress.totalUnitCount += fileSize;
    self.textProgress.totalUnitCount = self.progress.totalUnitCount;
    [self noteDownloadTaskAdded];
}

- (void)finishAddingDownloadTasks {
    // Remove the fake byte inserted by prepareForDownload once all real tasks are queued.
    if (self.progress.totalUnitCount > 0) {
        self.progress.totalUnitCount--;
    }
    if (self.textProgress.totalUnitCount > 0) {
        self.textProgress.totalUnitCount--;
    }

    @synchronized (self) {
        self.finishedAddingDownloadTasks = YES;
    }

    if (self.progress.totalUnitCount <= 0) {
        self.progress.totalUnitCount = 1;
        self.progress.completedUnitCount = 1;
        self.textProgress.totalUnitCount = 1;
        self.textProgress.completedUnitCount = 1;
    } else if (self.progress.completedUnitCount >= self.progress.totalUnitCount) {
        self.progress.completedUnitCount = self.progress.totalUnitCount;
        self.textProgress.completedUnitCount = self.textProgress.totalUnitCount;
    }

    if ([self allDownloadTasksFinished]) {
        [self notifyAllDownloadTasksFinishedIfNeeded];
    }
}

- (void)downloadVersionMetadata:(NSDictionary *)version success:(void (^)())success {
    // Download base json
    NSString *versionStr = version[@"id"];
    if ([versionStr isEqualToString:@"latest-release"]) {
        versionStr = getPrefObject(@"internal.latest_version.release");
    } else if ([versionStr isEqualToString:@"latest-snapshot"]) {
        versionStr = getPrefObject(@"internal.latest_version.snapshot");
    }

    NSString *path = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), versionStr];
    // Find it again to resolve latest-*
    version = (id)[MinecraftResourceUtils findVersion:versionStr inList:remoteVersionList];
    __block NSMutableDictionary *localInheritedVersion = nil;

    void(^completionBlock)(void) = ^{
        NSMutableDictionary *metadata = parseJSONFromFile(path);
        if (metadata[@"NSErrorObject"]) {
            [self finishDownloadWithErrorString:[metadata[@"NSErrorObject"] localizedDescription]];
            return;
        }

        if (localInheritedVersion) {
            id inheritedJavaVersion = metadata[@"javaVersion"];
            [MinecraftResourceUtils processVersion:localInheritedVersion inheritsFrom:metadata];
            if ([inheritedJavaVersion isKindOfClass:NSDictionary.class]) {
                metadata[@"javaVersion"] = inheritedJavaVersion;
            }
            self.metadata = metadata;
        } else if (metadata[@"inheritsFrom"]) {
            NSMutableDictionary *inheritsFromDict = parseJSONFromFile([NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), metadata[@"inheritsFrom"]]);
            if (inheritsFromDict) {
                id inheritedJavaVersion = inheritsFromDict[@"javaVersion"];
                [MinecraftResourceUtils processVersion:metadata inheritsFrom:inheritsFromDict];
                if ([inheritedJavaVersion isKindOfClass:NSDictionary.class]) {
                    inheritsFromDict[@"javaVersion"] = inheritedJavaVersion;
                }
                self.metadata = inheritsFromDict;
            } else {
                self.metadata = metadata;
            }
        } else {
            self.metadata = metadata;
        }
        [MinecraftResourceUtils tweakVersionJson:self.metadata];
        success();
    };

    if (!version) {
        // This is likely local version, check if json exists and has inheritsFrom
        NSMutableDictionary *json = parseJSONFromFile(path);
        if (json[@"NSErrorObject"]) {
            [self finishDownloadWithErrorString:[json[@"NSErrorObject"] localizedDescription]];
            return;
        } else if (json[@"inheritsFrom"]) {
            localInheritedVersion = json;
            version = (id)[MinecraftResourceUtils findVersion:json[@"inheritsFrom"] inList:remoteVersionList];
            path = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), json[@"inheritsFrom"]];
        } else {
            completionBlock();
            return;
        }
    }

    if (!version) {
        [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to find inherited Minecraft version for %@.", versionStr]];
        return;
    }

    versionStr = version[@"id"];
    NSString *url = version[@"url"];
    NSString *sha = url.stringByDeletingLastPathComponent.lastPathComponent;
    NSUInteger size = [version[@"size"] unsignedLongLongValue];

    NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:nil toPath:path success:completionBlock];
    [task resume];
}

#pragma mark - Minecraft installation

- (void)downloadAssetMetadataWithSuccess:(void (^)())success {
    NSDictionary *assetIndex = self.metadata[@"assetIndex"];
    if (!assetIndex) {
        success();
        return;
    }
    NSString *name = [NSString stringWithFormat:@"assets/indexes/%@.json", assetIndex[@"id"]];
    NSString *path = [@(getenv("POJAV_GAME_DIR")) stringByAppendingPathComponent:name];
    NSString *url = assetIndex[@"url"];
    NSString *sha = url.stringByDeletingLastPathComponent.lastPathComponent;
    NSUInteger size = [assetIndex[@"size"] unsignedLongLongValue];
    NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:name toPath:path success:^{
        self.metadata[@"assetIndexObj"] = parseJSONFromFile(path);
        success();
    }];
    [task resume];
}

- (NSArray *)downloadClientLibraries {
    NSMutableArray *tasks = [NSMutableArray new];
    for (NSDictionary *library in self.metadata[@"libraries"]) {
        NSString *name = library[@"name"];

        NSMutableDictionary *artifact = library[@"downloads"][@"artifact"];
        if (artifact == nil && [name containsString:@":"]) {
            NSLog(@"[MCDL] Unknown artifact object for %@, attempting to generate one", name);
            artifact = [[NSMutableDictionary alloc] init];
            NSString *prefix = library[@"url"] == nil ? @"https://libraries.minecraft.net/" : [library[@"url"] stringByReplacingOccurrencesOfString:@"http://" withString:@"https://"];
            NSArray *libParts = [name componentsSeparatedByString:@":"];
            artifact[@"path"] = [NSString stringWithFormat:@"%1$@/%2$@/%3$@/%2$@-%3$@.jar", [libParts[0] stringByReplacingOccurrencesOfString:@"." withString:@"/"], libParts[1], libParts[2]];
            artifact[@"url"] = [NSString stringWithFormat:@"%@%@", prefix, artifact[@"path"]];
            artifact[@"sha1"] = library[@"checksums"][0];
        }

        NSString *path = [NSString stringWithFormat:@"%s/libraries/%@", getenv("POJAV_GAME_DIR"), artifact[@"path"]];
        NSString *sha = artifact[@"sha1"];
        NSUInteger size = [artifact[@"size"] unsignedLongLongValue];
        NSString *url = artifact[@"url"];
        if ([library[@"skip"] boolValue]) {
            NSLog(@"[MDCL] Skipped library %@", name);
            continue;
        }

        NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:name toPath:path success:nil];
        if (task) {
            [tasks addObject:task];
        } else if (self.progress.cancelled) {
            return nil;
        }
    }
    return tasks;
}

- (NSArray *)downloadClientAssets {
    NSMutableArray *tasks = [NSMutableArray new];
    NSDictionary *assets = self.metadata[@"assetIndexObj"];
    if (!assets) {
        return @[];
    }
    for (NSString *name in assets[@"objects"]) {
        NSDictionary *object = assets[@"objects"][name];
        NSString *hash = object[@"hash"];
        NSString *pathname = [NSString stringWithFormat:@"%@/%@", [hash substringToIndex:2], hash];
        NSUInteger size = [object[@"size"] unsignedLongLongValue];

        NSString *path;
        if ([assets[@"map_to_resources"] boolValue]) {
            path = [NSString stringWithFormat:@"%s/resources/%@", getenv("POJAV_GAME_DIR"), name];
        } else {
            path = [NSString stringWithFormat:@"%s/assets/objects/%@", getenv("POJAV_GAME_DIR"), pathname];
        }

        /* Special case for 1.19+
         * Since 1.19-pre1, setting the window icon on macOS invokes ObjC.
         * However, if an IOException occurs, it won't try to set.
         * We skip downloading the icon file to workaround this. */
        if ([name hasSuffix:@"/minecraft.icns"]) {
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
            continue;
        }

        NSString *url = [NSString stringWithFormat:@"https://resources.download.minecraft.net/%@", pathname];
        NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:hash altName:name toPath:path success:nil];
        if (task) {
            [tasks addObject:task];
        } else if (self.progress.cancelled) {
            return nil;
        }
    }
    return tasks;
}

- (void)downloadVersion:(NSDictionary *)version {
    [self prepareForDownload];
    [self downloadVersionMetadata:version success:^{
        [self downloadAssetMetadataWithSuccess:^{
            NSArray *libTasks = [self downloadClientLibraries];
            NSArray *assetTasks = [self downloadClientAssets];
            [self finishAddingDownloadTasks];
            [libTasks makeObjectsPerformSelector:@selector(resume)];
            [assetTasks makeObjectsPerformSelector:@selector(resume)];
            [self.metadata removeObjectForKey:@"assetIndexObj"];
        }];
    }];
}

#pragma mark - Modpack installation

- (void)downloadModpackFromAPI:(ModpackAPI *)api detail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    [self prepareForDownload];

    NSArray *sizes = [modDetail[@"versionSizes"] isKindOfClass:NSArray.class] ? modDetail[@"versionSizes"] : @[];
    NSArray *hashes = [modDetail[@"versionHashes"] isKindOfClass:NSArray.class] ? modDetail[@"versionHashes"] : @[];
    id sizeValue = selectedVersion < sizes.count ? sizes[selectedVersion] : nil;
    NSUInteger size = [sizeValue respondsToSelector:@selector(unsignedLongLongValue)] ? [sizeValue unsignedLongLongValue] : 0;
    NSString *sha = selectedVersion < hashes.count ? hashes[selectedVersion] : nil;
    if (![sha isKindOfClass:NSString.class]) {
        sha = nil;
    }
    NSString *rawName = modDetail[@"title"];
    if (![rawName isKindOfClass:NSString.class] || rawName.length == 0) {
        rawName = [NSString stringWithFormat:@"modpack_%@", modDetail[@"id"] ?: @"download"];
    }
    NSString *name = [rawName.lowercaseString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    name = [name stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    NSMutableCharacterSet *unsafeNameCharacters = NSCharacterSet.alphanumericCharacterSet.invertedSet.mutableCopy;
    [unsafeNameCharacters removeCharactersInString:@"-_."];
    NSArray<NSString *> *nameParts = [name componentsSeparatedByCharactersInSet:unsafeNameCharacters];
    name = [[nameParts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]] componentsJoinedByString:@"_"];
    if (![ModpackUtils isSafeRelativePath:name]) {
        [self finishDownloadWithErrorString:@"Selected modpack has an invalid name."];
        return;
    }
    NSString *packagePath = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.zip", name]];
    [NSFileManager.defaultManager removeItemAtPath:packagePath error:nil];
    NSString *path = [NSString stringWithFormat:@"%s/custom_gamedir/%@", getenv("POJAV_GAME_DIR"), name];

    NSString *url = [api downloadURLForModDetail:modDetail atIndex:selectedVersion];
    if (url.length == 0) {
        NSString *manualURL = [api manualDownloadPageURLForModDetail:modDetail atIndex:selectedVersion];
        if (manualURL.length == 0) {
            [self finishDownloadWithErrorString:@"Failed to get a download URL for the selected modpack file."];
            return;
        }

        NSDictionary *manualDownload = @{
            @"title": rawName,
            @"fileName": packagePath.lastPathComponent,
            @"url": manualURL,
            @"destinationPath": packagePath,
            @"sha": sha ?: @""
        };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            CurseForgeManualDownloadViewController *vc = [[CurseForgeManualDownloadViewController alloc]
                initWithDownloads:@[manualDownload]
                introTitle:@"CurseForge Modpack Download"
                introMessage:@"CurseForge did not provide a direct download for this modpack. We are downloading it through CurseForge. Please do not close the app or this webpage until the download finishes."
                completion:^{
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                        if (self.progress.cancelled) {
                            return;
                        }
                        if (![NSFileManager.defaultManager fileExistsAtPath:packagePath]) {
                            [self finishDownloadWithErrorString:@"The CurseForge modpack download was not completed."];
                            return;
                        }
                        [api downloader:self submitDownloadTasksFromPackage:packagePath toPath:path];
                    });
                }];
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
            [currentVC() presentViewController:nav animated:YES completion:nil];
        });
        return;
    }

    NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:nil toPath:packagePath success:^{
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            if (self.progress.cancelled) {
                return;
            }
            [api downloader:self submitDownloadTasksFromPackage:packagePath toPath:path];
        });
    }];
    if (task) {
        [task resume];
    }
}

#pragma mark - Mod manager installation

- (void)downloadModsWithPlan:(NSDictionary *)plan store:(ModManagerStore *)store {
    [self prepareForDownload];
    self.postInstallModPlan = plan;
    self.postInstallModStore = store;

    NSArray *downloads = [plan[@"downloads"] isKindOfClass:NSArray.class] ? plan[@"downloads"] : @[];
    NSArray *manualDownloads = [plan[@"manualDownloads"] isKindOfClass:NSArray.class] ? plan[@"manualDownloads"] : @[];
    self.postInstallManualDownloads = manualDownloads;

    for (NSDictionary *download in downloads) {
        if (![download isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSString *url = download[@"url"];
        NSString *destinationPath = download[@"destinationPath"];
        NSString *fileName = download[@"fileName"] ?: destinationPath.lastPathComponent;
        NSString *sha = [download[@"sha"] isKindOfClass:NSString.class] ? download[@"sha"] : nil;
        NSUInteger size = [download[@"size"] respondsToSelector:@selector(unsignedLongLongValue)] ? [download[@"size"] unsignedLongLongValue] : 0;
        if (![destinationPath isKindOfClass:NSString.class] || destinationPath.length == 0) {
            [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Invalid destination for %@", fileName ?: @"mod"]];
            return;
        }

        if ([NSFileManager.defaultManager fileExistsAtPath:destinationPath] &&
            [self checkSHA:sha forFile:destinationPath altName:fileName]) {
            continue;
        }

        NSString *temporaryPath = [destinationPath stringByAppendingString:@".download"];
        [NSFileManager.defaultManager removeItemAtPath:temporaryPath error:nil];
        NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:fileName toPath:temporaryPath success:^{
            NSError *error = nil;
            [NSFileManager.defaultManager createDirectoryAtPath:destinationPath.stringByDeletingLastPathComponent
                withIntermediateDirectories:YES
                attributes:nil
                error:&error];
            if (error) {
                [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to create mods directory: %@", error.localizedDescription]];
                return;
            }
            [NSFileManager.defaultManager removeItemAtPath:destinationPath error:nil];
            if (![NSFileManager.defaultManager moveItemAtPath:temporaryPath toPath:destinationPath error:&error]) {
                [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to install %@: %@", fileName, error.localizedDescription]];
            }
        }];
        if (task) {
            [task resume];
        } else if (self.progress.cancelled) {
            return;
        }
    }

    [self finishAddingDownloadTasks];
}

- (void)finalizeModInstall {
    if (!self.postInstallModPlan || !self.postInstallModStore) {
        return;
    }

    NSArray *manualDownloads = [self.postInstallModPlan[@"manualDownloads"] isKindOfClass:NSArray.class] ? self.postInstallModPlan[@"manualDownloads"] : @[];
    NSMutableSet *skippedManualFileNames = [NSMutableSet new];
    for (NSDictionary *manualDownload in manualDownloads) {
        NSString *temporaryPath = manualDownload[@"destinationPath"];
        NSString *finalPath = manualDownload[@"finalDestinationPath"];
        if (![temporaryPath isKindOfClass:NSString.class] ||
            ![finalPath isKindOfClass:NSString.class] ||
            temporaryPath.length == 0 ||
            finalPath.length == 0) {
            continue;
        }
         NSString *sha = [manualDownload[@"sha"] isKindOfClass:NSString.class] ? manualDownload[@"sha"] : nil;
            if ([NSFileManager.defaultManager fileExistsAtPath:finalPath] &&
                [self checkSHA:sha forFile:finalPath altName:finalPath.lastPathComponent]) {
                continue;
            } else {
                [skippedManualFileNames addObject:finalPath.lastPathComponent];
                continue;
            }

        NSError *moveError = nil;
        [NSFileManager.defaultManager createDirectoryAtPath:finalPath.stringByDeletingLastPathComponent
            withIntermediateDirectories:YES
            attributes:nil
            error:&moveError];
        if (!moveError) {
            [NSFileManager.defaultManager removeItemAtPath:finalPath error:nil];
            [NSFileManager.defaultManager moveItemAtPath:temporaryPath toPath:finalPath error:&moveError];
        }
        if (moveError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                showDialog(localize(@"Error", nil), [NSString stringWithFormat:@"Failed to install %@: %@", finalPath.lastPathComponent, moveError.localizedDescription]);
            });
            return;
        }
    }

    NSArray *records = [self.postInstallModPlan[@"records"] isKindOfClass:NSArray.class] ? self.postInstallModPlan[@"records"] : @[];
    if (skippedManualFileNames.count > 0) {
        NSMutableArray *filteredRecords = [NSMutableArray new];
        for (NSDictionary *record in records) {
            NSString *fileName = record[@"fileName"];
            if (![skippedManualFileNames containsObject:fileName]) {
                [filteredRecords addObject:record];
            }
        }
        records = filteredRecords;
    }
    NSArray *replaced = [self.postInstallModPlan[@"replacedFileNames"] isKindOfClass:NSArray.class] ? self.postInstallModPlan[@"replacedFileNames"] : @[];
    NSArray *replacements = [self.postInstallModPlan[@"replacements"] isKindOfClass:NSArray.class] ? self.postInstallModPlan[@"replacements"] : @[];
    NSError *error = [self.postInstallModStore saveMetadataRecords:records replacingFileNames:replaced replacements:replacements];
    if (error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            showDialog(localize(@"Error", nil), [NSString stringWithFormat:@"Mods installed, but metadata could not be saved: %@", error.localizedDescription]);
        });
        return;
    }
    [NSNotificationCenter.defaultCenter postNotificationName:@"ModManagerModsChanged" object:self.postInstallModStore];
}

#pragma mark - Modpack installation

// NOTE: postInstallModStore is never set anywhere in the CurseForge/Modrinth
// modpack-install path (downloadModpackFromAPI:detail:atIndex: and friends) -
// unlike downloadModsWithPlan:store:, nothing currently threads a
// ModManagerStore through this flow, and ModManagerStore has no default/shared
// instance to fall back on (it requires a specific profileName + profile).
// Until that's wired up, this intentionally no-ops rather than guessing which
// profile a modpack install's records belong to.
- (void)finalizeModpackMetadata {
    if (!self.postInstallModpackMetadataPlan || !self.postInstallModStore) {
        return;
    }

    NSArray *records = [self.postInstallModpackMetadataPlan[@"records"] isKindOfClass:NSArray.class] ? self.postInstallModpackMetadataPlan[@"records"] : @[];
    NSError *error = [self.postInstallModStore saveMetadataRecords:records replacingFileNames:@[] replacements:@[]];
    if (error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            showDialog(localize(@"Error", nil), [NSString stringWithFormat:@"Modpack installed, but mod metadata could not be saved: %@", error.localizedDescription]);
        });
        return;
    }
    [NSNotificationCenter.defaultCenter postNotificationName:@"ModManagerModsChanged" object:self.postInstallModStore];
}

#pragma mark - Utilities

- (void)prepareForDownload {
    // Create a fake progress which is used to update completedUnitCount properly
    // (completedUnitCount does not update unless subprogress completes)
    self.textProgress = [NSProgress new];
    self.textProgress.kind = NSProgressKindFile;
    self.textProgress.fileOperationKind = NSProgressFileOperationKindDownloading;
    self.textProgress.totalUnitCount = -1;

    self.progress = [NSProgress new];
    // Push 1 byte so it won't accidentally finish after downloading assets index
    self.progress.totalUnitCount = 1;
    @synchronized (self) {
        self.pendingDownloadTaskCount = 0;
        self.finishedAddingDownloadTasks = NO;
        self.notifiedAllDownloadTasksFinished = NO;
    }
    [self.fileList removeAllObjects];
    [self.progressList removeAllObjects];
}

- (void)finishDownloadWithErrorString:(NSString *)error {
    [self.progress cancel];
    [self.manager invalidateSessionCancelingTasks:YES resetSession:YES];
    dispatch_async(dispatch_get_main_queue(), ^{
        showDialog(localize(@"Error", nil), error);
    });
    if (self.handleError) {
        self.handleError();
    }
}

- (void)finishDownloadWithError:(NSError *)error file:(NSString *)file {
    NSString *errorStr = [NSString stringWithFormat:localize(@"launcher.mcl.error_download", NULL), file, error.localizedDescription];
    NSLog(@"[MCDL] Error: %@ %@", errorStr, NSThread.callStackSymbols);
    [self finishDownloadWithErrorString:errorStr];
}

// Check if the account has permission to download
- (BOOL)checkAccessWithDialog:(BOOL)show {
    // for now
    BOOL accessible = [BaseAuthenticator.current.authData[@"username"] hasPrefix:@"Demo."] || BaseAuthenticator.current.authData[@"xboxGamertag"] != nil;
    if (!accessible) {
        [self.progress cancel];
        if (show) {
            [self finishDownloadWithErrorString:@"Minecraft can't be legally installed when logged in with a local account. Please switch to an online account to continue."];
        }
    }
    return accessible;
}

// Check SHA of the file
- (BOOL)checkSHAIgnorePref:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName logSuccess:(BOOL)logSuccess {
    if (sha.length == 0) {
        // When sha = skip, only check for file existence
        BOOL existence = [NSFileManager.defaultManager fileExistsAtPath:path];
        if (existence) {
            NSLog(@"[MCDL] Warning: couldn't find SHA for %@, have to assume it's good.", path);
        }
        return existence;
    }

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data == nil) {
        NSLog(@"[MCDL] SHA1 checker: file doesn't exist: %@", altName ? altName : path.lastPathComponent);
        return NO;
    }

    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *localSHA = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for(int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [localSHA appendFormat:@"%02x", digest[i]];
    }

    BOOL check = [sha isEqualToString:localSHA];
    if (!check || (getPrefBool(@"general.debug_logging") && logSuccess)) {
        NSLog(@"[MCDL] SHA1 %@ for %@%@",
          (check ? @"passed" : @"failed"), 
          (altName ? altName : path.lastPathComponent),
          (check ? @"" : [NSString stringWithFormat:@" (expected: %@, got: %@)", sha, localSHA]));
    }
    return check;
}

- (BOOL)checkSHA:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName logSuccess:(BOOL)logSuccess {
    if (getPrefBool(@"general.check_sha")) {
        return [self checkSHAIgnorePref:sha forFile:path altName:altName logSuccess:logSuccess];
    } else {
        return [NSFileManager.defaultManager fileExistsAtPath:path];
    }
}

- (BOOL)checkSHA:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName {
    return [self checkSHA:sha forFile:path altName:altName logSuccess:altName==nil];
}

@end