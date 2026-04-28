#import "MinecraftResourceDownloadTask.h"
#import "ModrinthAPI.h"
#import "ModpackUtils.h"
#import "PLProfiles.h"

@implementation ModrinthAPI

- (instancetype)init {
    return [super initWithURL:@"https://api.modrinth.com/v2"];
}

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters previousPageResult:(NSMutableArray *)modrinthSearchResult {
    int limit = 50;

    NSMutableString *facetString = [NSMutableString new];
    [facetString appendString:@"["];
    BOOL isModpackFilter = [searchFilters[@"isModpack"] respondsToSelector:@selector(boolValue)] && [searchFilters[@"isModpack"] boolValue];
    [facetString appendFormat:@"[\"project_type:%@\"]", isModpackFilter ? @"modpack" : @"mod"];
    NSString *mcVersion = [searchFilters[@"mcVersion"] isKindOfClass:NSString.class] ? searchFilters[@"mcVersion"] : @"";
    if (mcVersion.length > 0) {
        [facetString appendFormat:@",[\"versions:%@\"]", mcVersion];
    }
    [facetString appendString:@"]"];

    NSString *query = [searchFilters[@"name"] isKindOfClass:NSString.class] ? searchFilters[@"name"] : @"";
    NSDictionary *params = @{
        @"facets": facetString,
        @"query": [query stringByReplacingOccurrencesOfString:@" " withString:@"+"],
        @"limit": @(limit),
        @"index": @"relevance",
        @"offset": @(modrinthSearchResult.count)
    };
    NSDictionary *response = [self getEndpoint:@"search" params:params];
    if (!response) {
        return nil;
    }
    if (![response isKindOfClass:NSDictionary.class]) {
        self.lastError = [NSError errorWithDomain:@"ModrinthAPI"
            code:500
            userInfo:@{NSLocalizedDescriptionKey: @"Modrinth returned invalid search results."}];
        return nil;
    }
    NSArray *hits = [response[@"hits"] isKindOfClass:NSArray.class] ? response[@"hits"] : @[];

    NSMutableArray *result = modrinthSearchResult ?: [NSMutableArray new];
    for (NSDictionary *hit in hits) {
        if (![hit isKindOfClass:NSDictionary.class]) {
            continue;
        }
        BOOL isModpack = [hit[@"project_type"] isEqualToString:@"modpack"];
        NSString *projectID = [hit[@"project_id"] isKindOfClass:NSString.class] ? hit[@"project_id"] : @"";
        NSString *title = [hit[@"title"] isKindOfClass:NSString.class] ? hit[@"title"] : @"";
        NSString *description = [hit[@"description"] isKindOfClass:NSString.class] ? hit[@"description"] : @"";
        NSString *imageUrl = [hit[@"icon_url"] isKindOfClass:NSString.class] ? hit[@"icon_url"] : @"";
        [result addObject:@{
            @"apiSource": @(1), // Constant MODRINTH
            @"isModpack": @(isModpack),
            @"id": projectID,
            @"title": title,
            @"description": description,
            @"imageUrl": imageUrl
        }.mutableCopy];
    }
    NSUInteger totalHits = [response[@"total_hits"] respondsToSelector:@selector(unsignedLongValue)] ? [response[@"total_hits"] unsignedLongValue] : result.count;
    self.reachedLastPage = result.count >= totalHits;
    return result;
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    NSArray *response = [self getEndpoint:[NSString stringWithFormat:@"project/%@/version", item[@"id"]] params:nil];
    if (!response) {
        return;
    }
    if (![response isKindOfClass:NSArray.class]) {
        self.lastError = [NSError errorWithDomain:@"ModrinthAPI"
            code:500
            userInfo:@{NSLocalizedDescriptionKey: @"Modrinth returned an invalid version list."}];
        return;
    }
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    NSMutableArray<NSString *> *mcNames = [NSMutableArray new];
    NSMutableArray<NSString *> *urls = [NSMutableArray new];
    NSMutableArray *hashes = [NSMutableArray new];
    NSMutableArray *sizes = [NSMutableArray new];
    [response enumerateObjectsUsingBlock:
  ^(NSDictionary *version, NSUInteger i, BOOL *stop) {
        if (![version isKindOfClass:NSDictionary.class]) {
            return;
        }
        NSArray *files = [version[@"files"] isKindOfClass:NSArray.class] ? version[@"files"] : @[];
        NSDictionary *file = [files.firstObject isKindOfClass:NSDictionary.class] ? files.firstObject : nil;
        if (!file) {
            return;
        }

        NSString *versionName = [version[@"name"] isKindOfClass:NSString.class] ? version[@"name"] : @"";
        [names addObject:versionName];
        NSArray *gameVersions = [version[@"game_versions"] isKindOfClass:NSArray.class] ? version[@"game_versions"] : @[];
        [mcNames addObject:[gameVersions.firstObject isKindOfClass:NSString.class] ? gameVersions.firstObject : @""];
        [sizes addObject:[file[@"size"] isKindOfClass:NSNumber.class] ? file[@"size"] : @0];
        NSString *url = [file[@"url"] isKindOfClass:NSString.class] ? file[@"url"] : @"";
        [urls addObject:url];
        NSDictionary *hashesMap = [file[@"hashes"] isKindOfClass:NSDictionary.class] ? file[@"hashes"] : nil;
        [hashes addObject:hashesMap[@"sha1"] ?: NSNull.null];
    }];
    if (names.count == 0) {
        self.lastError = [NSError errorWithDomain:@"ModrinthAPI"
            code:404
            userInfo:@{NSLocalizedDescriptionKey: @"No downloadable Modrinth files were found for this project."}];
        return;
    }
    item[@"versionNames"] = names;
    item[@"mcVersionNames"] = mcNames;
    item[@"versionSizes"] = sizes;
    item[@"versionUrls"] = urls;
    item[@"versionHashes"] = hashes;
    item[@"versionDetailsLoaded"] = @(YES);
}

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    NSError *error = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to open modpack package: %@", error.localizedDescription]];
        return;
    }

    NSData *indexData = [archive extractDataFromFile:@"modrinth.index.json" error:&error];
    if (!indexData || error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to read modrinth.index.json: %@", error.localizedDescription ?: @"missing modrinth.index.json"]];
        return;
    }
    NSDictionary* indexDict = [NSJSONSerialization JSONObjectWithData:indexData options:kNilOptions error:&error];
    if (![indexDict isKindOfClass:NSDictionary.class] || error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse modrinth.index.json: %@", error.localizedDescription]];
        return;
    }
    NSArray *indexFiles = [indexDict[@"files"] isKindOfClass:NSArray.class] ? indexDict[@"files"] : nil;
    if (!indexFiles) {
        [downloader finishDownloadWithErrorString:@"modrinth.index.json is missing a valid files section."];
        return;
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

    for (NSDictionary *indexFile in indexFiles) {
        if (![indexFile isKindOfClass:NSDictionary.class]) {
            [downloader finishDownloadWithErrorString:@"modrinth.index.json contains an invalid file entry."];
            return;
        }
/*
        if ([indexFile[@"downloads"] count] > 1) {
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Unhandled multiple files download %@", indexFile[@"downloads"]]];
            return;
        }
*/
        NSString *relativePath = indexFile[@"path"];
        if (![ModpackUtils isSafeRelativePath:relativePath]) {
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Unsafe path in modrinth.index.json: %@", relativePath]];
            return;
        }
        NSArray *downloads = [indexFile[@"downloads"] isKindOfClass:NSArray.class] ? indexFile[@"downloads"] : @[];
        NSString *url = [downloads.firstObject isKindOfClass:NSString.class] ? downloads.firstObject : nil;
        if (url.length == 0) {
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Missing download URL for %@", relativePath]];
            return;
        }
        NSDictionary *hashesMap = [indexFile[@"hashes"] isKindOfClass:NSDictionary.class] ? indexFile[@"hashes"] : nil;
        NSString *sha = hashesMap[@"sha1"];
        if (![sha isKindOfClass:NSString.class]) {
            sha = nil;
        }
        NSString *path = [destPath stringByAppendingPathComponent:relativePath];
        NSUInteger size = [indexFile[@"fileSize"] respondsToSelector:@selector(unsignedLongLongValue)] ? [indexFile[@"fileSize"] unsignedLongLongValue] : 0;
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:url size:size sha:sha altName:relativePath toPath:path];
        if (task) {
            [task resume];
        } else if (downloader.progress.cancelled) {
            return; // cancelled
        }
    }

    [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract overrides from modpack package: %@", error.localizedDescription]];
        return;
    }

    [ModpackUtils archive:archive extractDirectory:@"client-overrides" toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract client-overrides from modpack package: %@", error.localizedDescription]];
        return;
    }

    // Delete package cache
    [NSFileManager.defaultManager removeItemAtPath:packagePath error:nil];

    // Download dependency client json (if available)
    NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:indexDict[@"dependencies"]];
    NSDictionary *dependencies = [indexDict[@"dependencies"] isKindOfClass:NSDictionary.class] ? indexDict[@"dependencies"] : nil;
    NSString *minecraftVersion = dependencies[@"minecraft"];
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
    // Create profile
    NSString *profileName = indexDict[@"name"];
    if (![profileName isKindOfClass:NSString.class] || profileName.length == 0) {
        profileName = @"Modrinth Modpack";
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
