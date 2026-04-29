#import <Foundation/Foundation.h>
#import "CurseForgeAPI.h"
#import "MinecraftResourceDownloadTask.h"
#import "PLProfiles.h"
#import "config.h"
#import "utils.h"

#define kCurseForgeGameIDMinecraft 432
#define kCurseForgeClassIDModpack 4471
#define kCurseForgeClassIDMod 6
#define kCurseForgePageSize 50

@implementation CurseForgeAPI

+ (BOOL)isConfigured {
    NSString *apiKey = CONFIG_CURSEFORGE_API_KEY;
    return apiKey.length > 0;
}

- (instancetype)init {
    return [super initWithURL:@"https://api.curseforge.com/v1"];
}

- (NSError *)missingAPIKeyError {
    return [NSError errorWithDomain:@"CurseForgeAPI"
        code:401
        userInfo:@{NSLocalizedDescriptionKey:
            @"CurseForge API key is not configured. Set CONFIG_CURSEFORGE_API_KEY when building."}];
}

- (BOOL)validateAPIKey {
    if ([CurseForgeAPI isConfigured]) {
        return YES;
    }
    self.lastError = [self missingAPIKeyError];
    return NO;
}

- (NSDictionary *)requestHeaders {
    NSString *apiKey = CONFIG_CURSEFORGE_API_KEY;
    if (apiKey.length == 0) {
        return nil;
    }
    return @{
        @"Accept": @"application/json",
        @"x-api-key": apiKey
    };
}

- (NSString *)sha1HashForFile:(NSDictionary *)file {
    NSArray *hashes = [file[@"hashes"] isKindOfClass:NSArray.class] ? file[@"hashes"] : @[];
    for (NSDictionary *hash in hashes) {
        if (![hash isKindOfClass:NSDictionary.class]) {
            continue;
        }
        if ([hash[@"algo"] integerValue] == 1 && [hash[@"value"] isKindOfClass:NSString.class]) {
            return hash[@"value"];
        }
    }
    return nil;
}

- (NSString *)minecraftVersionForFile:(NSDictionary *)file {
    NSArray *sortableGameVersions = [file[@"sortableGameVersions"] isKindOfClass:NSArray.class] ? file[@"sortableGameVersions"] : @[];
    for (NSDictionary *version in sortableGameVersions) {
        if (![version isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSString *name = [version[@"gameVersionName"] isKindOfClass:NSString.class] ? version[@"gameVersionName"] : version[@"gameVersion"];
        if ([name isKindOfClass:NSString.class] && name.length > 0) {
            return name;
        }
    }

    NSArray *gameVersions = [file[@"gameVersions"] isKindOfClass:NSArray.class] ? file[@"gameVersions"] : @[];
    for (NSString *version in gameVersions) {
        if (![version isKindOfClass:NSString.class] || version.length == 0) {
            continue;
        }
        unichar first = [version characterAtIndex:0];
        if ([[NSCharacterSet decimalDigitCharacterSet] characterIsMember:first]) {
            return version;
        }
    }

    return @"";
}

- (NSString *)downloadURLForFile:(NSDictionary *)file projectID:(NSNumber *)projectID {
    NSString *url = file[@"downloadUrl"];
    if ([url isKindOfClass:NSString.class] && url.length > 0) {
        return url;
    }

    NSNumber *modID = [file[@"modId"] isKindOfClass:NSNumber.class] ? file[@"modId"] : projectID;
    NSNumber *fileID = [file[@"id"] isKindOfClass:NSNumber.class] ? file[@"id"] : nil;
    if (![modID isKindOfClass:NSNumber.class] || !fileID) {
        return nil;
    }

    NSDictionary *response = [self getEndpoint:[NSString stringWithFormat:@"mods/%@/files/%@/download-url", modID, fileID] params:nil];
    if (![response isKindOfClass:NSDictionary.class]) {
        return nil;
    }
    url = response[@"data"];
    return [url isKindOfClass:NSString.class] && url.length > 0 ? url : nil;
}

- (NSDictionary *)projectInfoForProjectID:(NSNumber *)projectID cache:(NSMutableDictionary *)cache {
    if (![projectID isKindOfClass:NSNumber.class]) {
        return nil;
    }

    id cached = cache[projectID];
    if (cached == NSNull.null) {
        return nil;
    }
    if ([cached isKindOfClass:NSDictionary.class]) {
        return cached;
    }

    NSDictionary *response = [self getEndpoint:[NSString stringWithFormat:@"mods/%@", projectID] params:nil];
    NSDictionary *project = [response[@"data"] isKindOfClass:NSDictionary.class] ? response[@"data"] : nil;
    cache[projectID] = project ?: (id)NSNull.null;
    return project;
}

- (NSString *)manualDownloadPageURLForFile:(NSDictionary *)file projectID:(NSNumber *)projectID cache:(NSMutableDictionary *)cache {
    NSNumber *fileID = [file[@"id"] isKindOfClass:NSNumber.class] ? file[@"id"] : nil;
    if (!fileID) {
        return nil;
    }

    NSDictionary *project = [self projectInfoForProjectID:projectID cache:cache];
    NSDictionary *links = [project[@"links"] isKindOfClass:NSDictionary.class] ? project[@"links"] : nil;
    NSString *websiteURL = links[@"websiteUrl"];
    if ([websiteURL isKindOfClass:NSString.class] && websiteURL.length > 0) {
        while ([websiteURL hasSuffix:@"/"]) {
            websiteURL = [websiteURL substringToIndex:websiteURL.length - 1];
        }
        return [websiteURL stringByAppendingFormat:@"/download/%@", fileID];
    }

    NSString *slug = project[@"slug"];
    if ([slug isKindOfClass:NSString.class] && slug.length > 0) {
        NSInteger classID = [project[@"classId"] respondsToSelector:@selector(integerValue)] ? [project[@"classId"] integerValue] : kCurseForgeClassIDMod;
        NSString *section = classID == kCurseForgeClassIDModpack ? @"modpacks" : @"mc-mods";
        return [NSString stringWithFormat:@"https://www.curseforge.com/minecraft/%@/%@/download/%@", section, slug, fileID];
    }

    return [NSString stringWithFormat:@"https://www.curseforge.com/projects/%@/files/%@", projectID, fileID];
}

- (NSArray *)fileMetadataForFileIDs:(NSArray<NSNumber *> *)fileIDs {
    if (fileIDs.count == 0) {
        return @[];
    }

    NSMutableArray *result = [NSMutableArray new];
    for (NSUInteger i = 0; i < fileIDs.count; i += kCurseForgePageSize) {
        NSUInteger length = MIN(kCurseForgePageSize, fileIDs.count - i);
        NSArray *chunk = [fileIDs subarrayWithRange:NSMakeRange(i, length)];
        NSDictionary *response = [self postEndpoint:@"mods/files" body:@{@"fileIds": chunk}];
        if (!response) {
            return nil;
        }
        if (![response isKindOfClass:NSDictionary.class]) {
            self.lastError = [NSError errorWithDomain:@"CurseForgeAPI"
                code:500
                userInfo:@{NSLocalizedDescriptionKey: @"CurseForge returned invalid file metadata."}];
            return nil;
        }
        NSArray *data = [response[@"data"] isKindOfClass:NSArray.class] ? response[@"data"] : nil;
        if (!data) {
            self.lastError = [NSError errorWithDomain:@"CurseForgeAPI"
                code:500
                userInfo:@{NSLocalizedDescriptionKey: @"CurseForge returned invalid file metadata."}];
            return nil;
        }
        [result addObjectsFromArray:data];
    }
    return result;
}

- (NSArray *)filesForModID:(id)modID {
    NSMutableArray *result = [NSMutableArray new];
    NSUInteger index = 0;
    while (true) {
        NSDictionary *response = [self getEndpoint:[NSString stringWithFormat:@"mods/%@/files", modID]
            params:@{
                @"pageSize": @(kCurseForgePageSize),
                @"index": @(index)
            }];
        if (!response) {
            return nil;
        }
        if (![response isKindOfClass:NSDictionary.class]) {
            self.lastError = [NSError errorWithDomain:@"CurseForgeAPI"
                code:500
                userInfo:@{NSLocalizedDescriptionKey: @"CurseForge returned an invalid file list."}];
            return nil;
        }

        NSArray *data = [response[@"data"] isKindOfClass:NSArray.class] ? response[@"data"] : @[];
        [result addObjectsFromArray:data];

        NSDictionary *pagination = [response[@"pagination"] isKindOfClass:NSDictionary.class] ? response[@"pagination"] : nil;
        NSUInteger resultCount = [pagination[@"resultCount"] unsignedLongValue];
        NSUInteger pageSize = [pagination[@"pageSize"] unsignedLongValue];
        NSUInteger totalCount = [pagination[@"totalCount"] unsignedLongValue];
        if (resultCount == 0 || result.count >= totalCount) {
            break;
        }
        index += pageSize > 0 ? pageSize : resultCount;
    }

    return result;
}

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters previousPageResult:(NSMutableArray *)curseForgeSearchResult {
    if (![self validateAPIKey]) {
        return nil;
    }

    NSString *query = [searchFilters[@"name"] isKindOfClass:NSString.class] ? searchFilters[@"name"] : @"";
    query = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *mcVersion = [searchFilters[@"mcVersion"] isKindOfClass:NSString.class] ? searchFilters[@"mcVersion"] : @"";
    BOOL isModpackFilter = [searchFilters[@"isModpack"] respondsToSelector:@selector(boolValue)] && [searchFilters[@"isModpack"] boolValue];
    NSMutableDictionary *params = @{
        @"gameId": @(kCurseForgeGameIDMinecraft),
        @"classId": isModpackFilter ? @(kCurseForgeClassIDModpack) : @(kCurseForgeClassIDMod),
        @"sortField": @(2),
        @"sortOrder": @"desc",
        @"pageSize": @(kCurseForgePageSize),
        @"index": @(curseForgeSearchResult.count)
    }.mutableCopy;
    if (query.length > 0) {
        params[@"searchFilter"] = query;
    }
    if (mcVersion.length > 0) {
        params[@"gameVersion"] = mcVersion;
    }

    NSDictionary *response = [self getEndpoint:@"mods/search" params:params];
    if (!response) {
        return nil;
    }
    if (![response isKindOfClass:NSDictionary.class]) {
        self.lastError = [NSError errorWithDomain:@"CurseForgeAPI"
            code:500
            userInfo:@{NSLocalizedDescriptionKey: @"CurseForge returned invalid search results."}];
        return nil;
    }
    NSArray *data = [response[@"data"] isKindOfClass:NSArray.class] ? response[@"data"] : @[];

    NSMutableArray *result = curseForgeSearchResult ?: [NSMutableArray new];
    for (NSDictionary *mod in data) {
        if (![mod isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSDictionary *logo = [mod[@"logo"] isKindOfClass:NSDictionary.class] ? mod[@"logo"] : nil;
        NSString *imageUrl = [logo[@"thumbnailUrl"] isKindOfClass:NSString.class] ? logo[@"thumbnailUrl"] : logo[@"url"];
        if (![imageUrl isKindOfClass:NSString.class]) {
            imageUrl = @"";
        }
        NSString *title = [mod[@"name"] isKindOfClass:NSString.class] ? mod[@"name"] : @"";
        NSString *description = [mod[@"summary"] isKindOfClass:NSString.class] ? mod[@"summary"] : @"";
        NSNumber *modID = [mod[@"id"] isKindOfClass:NSNumber.class] ? mod[@"id"] : nil;
        if (!modID) {
            continue;
        }
        NSInteger classID = [mod[@"classId"] respondsToSelector:@selector(integerValue)] ? [mod[@"classId"] integerValue] : 0;
        [result addObject:@{
            @"apiSource": @(0),
            @"isModpack": @(classID == kCurseForgeClassIDModpack),
            @"id": modID,
            @"title": title,
            @"description": description,
            @"imageUrl": imageUrl
        }.mutableCopy];
    }

    NSDictionary *pagination = [response[@"pagination"] isKindOfClass:NSDictionary.class] ? response[@"pagination"] : nil;
    NSUInteger index = [pagination[@"index"] unsignedLongValue];
    NSUInteger pageSize = [pagination[@"pageSize"] unsignedLongValue];
    NSUInteger resultCount = [pagination[@"resultCount"] unsignedLongValue];
    NSUInteger totalCount = [pagination[@"totalCount"] unsignedLongValue];
    self.reachedLastPage = resultCount == 0 || index + pageSize >= totalCount || result.count >= totalCount;
    return result;
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    if (![self validateAPIKey]) {
        return;
    }

    NSArray *files = [self filesForModID:item[@"id"]];
    if (!files) {
        return;
    }

    NSMutableArray<NSString *> *names = [NSMutableArray new];
    NSMutableArray<NSString *> *mcNames = [NSMutableArray new];
    NSMutableArray *urls = [NSMutableArray new];
    NSMutableArray *hashes = [NSMutableArray new];
    NSMutableArray *sizes = [NSMutableArray new];
    NSMutableArray *fileIds = [NSMutableArray new];

    for (NSDictionary *file in files) {
        if (![file isKindOfClass:NSDictionary.class]) {
            continue;
        }
        BOOL isServerPack = [file[@"isServerPack"] respondsToSelector:@selector(boolValue)] && [file[@"isServerPack"] boolValue];
        id available = file[@"isAvailable"];
        BOOL isUnavailable = [available isKindOfClass:NSNumber.class] && ![available boolValue];
        if (isServerPack || isUnavailable) {
            continue;
        }
        NSNumber *fileID = [file[@"id"] isKindOfClass:NSNumber.class] ? file[@"id"] : nil;
        if (!fileID) {
            continue;
        }

        NSString *name = [file[@"displayName"] isKindOfClass:NSString.class] ? file[@"displayName"] : file[@"fileName"];
        if (![name isKindOfClass:NSString.class]) {
            name = nil;
        }
        if (name.length == 0) {
            name = [NSString stringWithFormat:@"File %@", fileID];
        }

        NSString *sha1 = [self sha1HashForFile:file];
        NSString *url = file[@"downloadUrl"];
        NSNumber *size = [file[@"fileLength"] isKindOfClass:NSNumber.class] ? file[@"fileLength"] : file[@"fileSizeOnDisk"];
        if (![size isKindOfClass:NSNumber.class]) {
            size = @0;
        }

        [names addObject:name];
        [mcNames addObject:[self minecraftVersionForFile:file]];
        [urls addObject:([url isKindOfClass:NSString.class] && url.length > 0) ? url : NSNull.null];
        [hashes addObject:sha1 ?: NSNull.null];
        [sizes addObject:size];
        [fileIds addObject:fileID];
    }

    if (names.count == 0) {
        self.lastError = [NSError errorWithDomain:@"CurseForgeAPI"
            code:404
            userInfo:@{NSLocalizedDescriptionKey: @"No downloadable CurseForge files were found for this project."}];
        return;
    }

    item[@"versionNames"] = names;
    item[@"mcVersionNames"] = mcNames;
    item[@"versionSizes"] = sizes;
    item[@"versionUrls"] = urls;
    item[@"versionHashes"] = hashes;
    item[@"versionFileIds"] = fileIds;
    item[@"versionDetailsLoaded"] = @(YES);
}

- (NSString *)downloadURLForModDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    NSString *url = [super downloadURLForModDetail:modDetail atIndex:selectedVersion];
    if (url.length > 0) {
        return url;
    }

    NSArray *fileIds = modDetail[@"versionFileIds"];
    if (![fileIds isKindOfClass:NSArray.class]) {
        return nil;
    }
    if (selectedVersion >= fileIds.count) {
        return nil;
    }

    NSNumber *fileID = [fileIds[selectedVersion] isKindOfClass:NSNumber.class] ? fileIds[selectedVersion] : nil;
    if (!fileID) {
        return nil;
    }
    NSDictionary *response = [self getEndpoint:[NSString stringWithFormat:@"mods/%@/files/%@/download-url", modDetail[@"id"], fileID] params:nil];
    if (![response isKindOfClass:NSDictionary.class]) {
        return nil;
    }
    url = response[@"data"];
    if (![url isKindOfClass:NSString.class] || url.length == 0) {
        return nil;
    }

    NSMutableArray *urls = modDetail[@"versionUrls"];
    if ([urls isKindOfClass:NSMutableArray.class]) {
        urls[selectedVersion] = url;
    }
    return url;
}

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    NSError *error = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to open CurseForge modpack package: %@", error.localizedDescription]];
        return;
    }

    NSData *manifestData = [archive extractDataFromFile:@"manifest.json" error:&error];
    if (!manifestData || error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to read CurseForge manifest.json: %@", error.localizedDescription ?: @"missing manifest.json"]];
        return;
    }

    NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:kNilOptions error:&error];
    if (![manifest isKindOfClass:NSDictionary.class] || error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse CurseForge manifest.json: %@", error.localizedDescription]];
        return;
    }

    NSDictionary *minecraft = [manifest[@"minecraft"] isKindOfClass:NSDictionary.class] ? manifest[@"minecraft"] : nil;
    NSArray *manifestFiles = [manifest[@"files"] isKindOfClass:NSArray.class] ? manifest[@"files"] : nil;
    if (!minecraft || !manifestFiles) {
        [downloader finishDownloadWithErrorString:@"CurseForge manifest.json is missing required minecraft or files sections."];
        return;
    }

    NSMutableArray *requiredManifestFiles = [NSMutableArray new];
    NSMutableArray *fileIDs = [NSMutableArray new];
    for (NSDictionary *manifestFile in manifestFiles) {
        if (![manifestFile isKindOfClass:NSDictionary.class]) {
            [downloader finishDownloadWithErrorString:@"CurseForge manifest.json contains an invalid file entry."];
            return;
        }

        id required = manifestFile[@"required"];
        if ([required respondsToSelector:@selector(boolValue)] && ![required boolValue]) {
            continue;
        }
        NSNumber *fileID = manifestFile[@"fileID"];
        NSNumber *projectID = manifestFile[@"projectID"];
        if (![fileID isKindOfClass:NSNumber.class] || ![projectID isKindOfClass:NSNumber.class]) {
            continue;
        }
        [requiredManifestFiles addObject:manifestFile];
        [fileIDs addObject:fileID];
    }

    NSArray *fileMetadata = [self fileMetadataForFileIDs:fileIDs];
    if (!fileMetadata) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to load CurseForge file metadata: %@", self.lastError.localizedDescription]];
        return;
    }

    NSMutableDictionary *filesByID = [NSMutableDictionary new];
    for (NSDictionary *file in fileMetadata) {
        if (![file isKindOfClass:NSDictionary.class]) {
            continue;
        }
        if (file[@"id"]) {
            filesByID[file[@"id"]] = file;
        }
    }

    BOOL createdDir = [NSFileManager.defaultManager createDirectoryAtPath:destPath
        withIntermediateDirectories:YES
        attributes:nil
        error:&error];
    if (!createdDir) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to create modpack directory: %@", error.localizedDescription]];
        return;
    }

    [NSFileManager.defaultManager removeItemAtPath:[destPath stringByAppendingPathComponent:@"mods"] error:nil];

    NSMutableArray *manualDownloads = [NSMutableArray new];
    NSMutableDictionary *projectCache = [NSMutableDictionary new];
    for (NSDictionary *manifestFile in requiredManifestFiles) {
        NSNumber *fileID = manifestFile[@"fileID"];
        NSNumber *projectID = manifestFile[@"projectID"];
        NSDictionary *file = filesByID[fileID];
        if (!file) {
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"CurseForge file %@ was not returned by the API.", fileID]];
            return;
        }

        NSString *fileName = file[@"fileName"];
        if (![fileName isKindOfClass:NSString.class]) {
            fileName = nil;
        }
        if (fileName.length == 0) {
            fileName = [NSString stringWithFormat:@"%@.jar", fileID];
        }
        if (![ModpackUtils isSafeRelativePath:fileName] || [fileName containsString:@"/"] || [fileName containsString:@"\\"]) {
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Unsafe file name in CurseForge metadata: %@", fileName]];
            return;
        }

        NSString *relativePath = [@"mods" stringByAppendingPathComponent:fileName];
        NSString *path = [destPath stringByAppendingPathComponent:relativePath];
        NSUInteger size = [file[@"fileLength"] respondsToSelector:@selector(unsignedLongLongValue)] ? [file[@"fileLength"] unsignedLongLongValue] : 0;
        if (size == 0) {
            size = [file[@"fileSizeOnDisk"] respondsToSelector:@selector(unsignedLongLongValue)] ? [file[@"fileSizeOnDisk"] unsignedLongLongValue] : 0;
        }
        NSString *sha = [self sha1HashForFile:file];
        NSString *url = [self downloadURLForFile:file projectID:projectID];
        if (url.length == 0) {
            NSString *manualURL = [self manualDownloadPageURLForFile:file projectID:projectID cache:projectCache];
            NSString *title = [file[@"displayName"] isKindOfClass:NSString.class] ? file[@"displayName"] : fileName;
            [manualDownloads addObject:@{
                @"title": title ?: fileName,
                @"fileName": fileName,
                @"url": manualURL ?: @"https://www.curseforge.com",
                @"destinationPath": path,
                @"sha": sha ?: @""
            }];
            NSLog(@"[CurseForge] Queued manual download for %@", fileName);
            continue;
        }

        NSURLSessionDownloadTask *task = [downloader createDownloadTask:url
            size:size
            sha:sha
            altName:relativePath
            toPath:path];
        if (task) {
            [task resume];
        } else if (downloader.progress.cancelled) {
            return;
        }
    }
    downloader.postInstallManualDownloads = manualDownloads.copy;

    NSMutableOrderedSet<NSString *> *overrideDirs = [NSMutableOrderedSet orderedSet];
    NSString *manifestOverrides = manifest[@"overrides"];
    if (![manifestOverrides isKindOfClass:NSString.class]) {
        manifestOverrides = nil;
    }
    if (manifestOverrides.length > 0) {
        [overrideDirs addObject:manifestOverrides];
    } else {
        [overrideDirs addObject:@"overrides"];
    }
    [overrideDirs addObject:@"client-overrides"];

    for (NSString *dir in overrideDirs) {
        [ModpackUtils archive:archive extractDirectory:dir toPath:destPath error:&error];
        if (error) {
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract %@ from CurseForge modpack package: %@", dir, error.localizedDescription]];
            return;
        }
    }

    [NSFileManager.defaultManager removeItemAtPath:packagePath error:nil];

    NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForCurseForgeMinecraft:minecraft];
    NSString *minecraftVersion = minecraft[@"version"];
    if (![minecraftVersion isKindOfClass:NSString.class]) {
        minecraftVersion = @"";
    }
    NSString *versionId = depInfo[@"id"];
    if (![versionId isKindOfClass:NSString.class] || versionId.length == 0) {
        versionId = minecraftVersion;
    }
    if (depInfo[@"json"]) {
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), depInfo[@"id"]];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:depInfo[@"json"] size:1 sha:nil altName:nil toPath:jsonPath];
        if (task) {
            [task resume];
        } else if (downloader.progress.cancelled) {
            return;
        }
    }
    NSString *installerURL = depInfo[@"installer"];
    if ([installerURL isKindOfClass:NSString.class] && installerURL.length > 0 &&
        versionId.length > 0 && ![ModpackUtils isVersionInstalled:versionId]) {
        NSString *installerName = [ModpackUtils isSafeRelativePath:versionId] ? [NSString stringWithFormat:@"%@-installer.jar", versionId] : @"modpack-loader-installer.jar";
        NSString *installerPath = [NSTemporaryDirectory() stringByAppendingPathComponent:installerName];
        [NSFileManager.defaultManager removeItemAtPath:installerPath error:nil];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:installerURL size:0 sha:nil altName:installerName toPath:installerPath];
        if (task) {
            downloader.postInstallInstallerPath = installerPath;
            downloader.postInstallHitEnter = YES;
            [task resume];
        } else if (downloader.progress.cancelled) {
            return;
        }
    }

    NSString *profileName = manifest[@"name"];
    if (![profileName isKindOfClass:NSString.class] || profileName.length == 0) {
        profileName = @"CurseForge Modpack";
    }
    NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
    NSData *iconData = [NSData dataWithContentsOfFile:tmpIconPath];
    NSString *icon = @"";
    if (iconData) {
        icon = [NSString stringWithFormat:@"data:image/png;base64,%@", [iconData base64EncodedStringWithOptions:0]];
    }

    PLProfiles.current.profiles[profileName] = @{
        @"gameDir": [NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent],
        @"name": profileName,
        @"lastVersionId": versionId,
        @"icon": icon
    }.mutableCopy;
    PLProfiles.current.selectedProfileName = profileName;
    [downloader finishAddingDownloadTasks];
}

@end
