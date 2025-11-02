#import <Foundation/Foundation.h>
#import "AFNetworking.h"
#import "CurseForgeAPI.h"
#import "MinecraftResourceDownloadTask.h"
#import "ModpackUtils.h"
#import "PLProfiles.h"
#import "UnzipKit.h"
#import "installer/FabricUtils.h"

static NSString * const kCFBaseURL = @"https://api.curseforge.com/v1";
static NSString * const kCFAPIKey  = @"$2a$10$XvHy7mBoebv3rVPWiO.Yge4FfnzphAu6YiiE8Xa7FtydIBVMoWvJ2";

@implementation CurseForgeAPI

- (instancetype)init {
    return [super initWithURL:kCFBaseURL];
}

- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    return [self getEndpoint:endpoint params:params retryCount:3];
}

- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params retryCount:(NSUInteger)retries {
    __block id result = nil;
    __block NSError *lastAttemptError = nil;
    
    for (NSUInteger attempt = 0; attempt < retries; attempt++) {
        if (attempt > 0) {
            NSTimeInterval delay = 0.5 * (1 << (attempt - 1));
            usleep((useconds_t)(delay * 1000000));
        }
        
        dispatch_group_t group = dispatch_group_create();
        dispatch_group_enter(group);
        NSString *url = [self.baseURL stringByAppendingPathComponent:endpoint];
        AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
        manager.requestSerializer.timeoutInterval = 30.0;
        [manager.requestSerializer setValue:kCFAPIKey forHTTPHeaderField:@"x-api-key"];
        manager.responseSerializer = [AFJSONResponseSerializer serializer];
        [manager GET:url parameters:params headers:nil progress:nil
             success:^(NSURLSessionTask *task, id obj) {
                 result = obj;
                 dispatch_group_leave(group);
             } failure:^(NSURLSessionTask *operation, NSError *error) {
                 lastAttemptError = error;
                 self.lastError = error;
                 NSHTTPURLResponse *response = (NSHTTPURLResponse *)operation.response;
                 if (response && response.statusCode == 429) {
                     NSLog(@"[CFAPI] Rate limited on attempt %lu for %@, will retry", (unsigned long)(attempt + 1), endpoint);
                 } else {
                     NSLog(@"[CFAPI] Request failed on attempt %lu for %@: %@", (unsigned long)(attempt + 1), endpoint, error.localizedDescription);
                 }
                 dispatch_group_leave(group);
             }];
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        
        if (result != nil) {
            return result;
        }
        
        NSHTTPURLResponse *response = (NSHTTPURLResponse *)lastAttemptError.userInfo[AFNetworkingOperationFailingURLResponseErrorKey];
        if (response && response.statusCode == 429) {
            NSTimeInterval retryAfter = 2.0 * (1 << attempt);
            NSLog(@"[CFAPI] Rate limited, waiting %.1f seconds before retry", retryAfter);
            usleep((useconds_t)(retryAfter * 1000000));
        }
    }
    
    return nil;
}

 - (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters previousPageResult:(NSMutableArray *)prevResult {
    NSMutableArray *result = prevResult ?: [NSMutableArray new];
    id isModpackObj = searchFilters[@"isModpack"];
    BOOL isModpack = [isModpackObj respondsToSelector:@selector(boolValue)] ? [isModpackObj boolValue] : YES;
    NSMutableDictionary *params = [NSMutableDictionary new];
    params[@"gameId"] = @(432);
    params[@"classId"] = isModpack ? @(4471) : @(6);
    if (searchFilters[@"name"]) {
        params[@"searchFilter"] = searchFilters[@"name"];
    }
    if (searchFilters[@"mcVersion"] && [searchFilters[@"mcVersion"] length] > 0) {
        params[@"gameVersion"] = searchFilters[@"mcVersion"];
    }
    params[@"sortField"] = @(1);
    params[@"sortOrder"] = @"desc";
    params[@"index"] = @(result.count);

    NSDictionary *response = [self getEndpoint:@"mods/search" params:params];
    if (!response) {
        return nil;
    }
    NSArray *data = response[@"data"] ?: @[];
    for (NSDictionary *entry in data) {
        id allow = entry[@"allowModDistribution"];
        if (allow && [allow isKindOfClass:NSNumber.class] && ![allow boolValue]) {
            continue;
        }
        NSDictionary *logo = entry[@"logo"] ?: @{};
        BOOL entryIsModpack = isModpack;
        [result addObject:@{
            @"apiSource": @(0),
            @"isModpack": @(entryIsModpack),
            @"id": [NSString stringWithFormat:@"%@", entry[@"id"]],
            @"title": entry[@"name"] ?: @"",
            @"description": entry[@"summary"] ?: @"",
            @"imageUrl": logo[@"thumbnailUrl"] ?: [NSNull null]
        }.mutableCopy];
    }
    NSDictionary *pagination = response[@"pagination"] ?: @{};
    NSUInteger totalCount = [[pagination objectForKey:@"totalCount"] unsignedIntegerValue];
    self.reachedLastPage = result.count >= totalCount;
    return result;
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    NSMutableArray<NSString *> *mcNames = [NSMutableArray new];
    NSMutableArray<NSString *> *urls = [NSMutableArray new];
    NSMutableArray<NSString *> *hashes = [NSMutableArray new];

    NSUInteger index = 0;
    while (YES) {
        NSDictionary *params = @{ @"pageSize": @(50), @"index": @(index) };
        NSString *endpoint = [NSString stringWithFormat:@"mods/%@/files", item[@"id"]];
        NSDictionary *response = [self getEndpoint:endpoint params:params];
        if (!response) {
            return;
        }
        NSArray *data = response[@"data"] ?: @[];
        for (NSDictionary *file in data) {
            NSNumber *isServerPack = file[@"isServerPack"] ?: @(NO);
            if (isServerPack.boolValue) {
                continue;
            }
            NSString *displayName = file[@"displayName"] ?: @"";
            NSString *downloadUrl = file[@"downloadUrl"] ?: @"";
            NSArray *gameVersions = file[@"gameVersions"] ?: @[];
            NSString *mc = gameVersions.count > 0 ? gameVersions.firstObject : @"";
            NSArray *hashArray = file[@"hashes"] ?: @[];
            NSString *sha1 = nil;
            for (NSDictionary *h in hashArray) {
                if ([[h objectForKey:@"algo"] integerValue] == 1) { sha1 = h[@"value"]; break; }
            }
            [names addObject:displayName ?: @""];
            [urls addObject:downloadUrl ?: @""];
            [mcNames addObject:mc ?: @""];
            [hashes addObject:sha1 ?: (id)[NSNull null]];
        }
        if (data.count < 50) {
            break;
        }
        index += data.count;
    }
    item[@"versionNames"] = names;
    item[@"mcVersionNames"] = mcNames;
    item[@"versionUrls"] = urls;
    item[@"versionHashes"] = hashes;
    item[@"versionDetailsLoaded"] = @(YES);
}

- (NSString *)cfDownloadURLForProject:(NSNumber *)projectID fileId:(NSNumber *)fileID fileData:(NSDictionary *)fileData {
    NSString *downloadUrl = fileData[@"downloadUrl"];
    if (downloadUrl && [downloadUrl isKindOfClass:NSString.class] && downloadUrl.length > 0) {
        NSURL *urlObj = [NSURL URLWithString:downloadUrl];
        if (urlObj && urlObj.scheme && urlObj.host && urlObj.lastPathComponent.length > 0) {
            return downloadUrl;
        }
    }
    
    NSNumber *fid = fileData[@"id"] ?: fileID;
    id fnameObj = fileData[@"fileName"];
    NSString *fname = [fnameObj isKindOfClass:NSString.class] ? (NSString *)fnameObj : @"";
    if (fname.length == 0) {
        return nil;
    }
    long long v1 = fid.longLongValue / 1000;
    long long v2 = fid.longLongValue % 1000;
    NSString *encodedFname = [fname stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    if (!encodedFname) {
        encodedFname = fname;
    }
    return [NSString stringWithFormat:@"https://edge.forgecdn.net/files/%lld/%lld/%@", v1, v2, encodedFname];
}

- (NSString *)cfDownloadSHA1FromFileData:(NSDictionary *)fileData {
    NSArray *hashArray = fileData[@"hashes"] ?: @[];
    for (NSDictionary *h in hashArray) {
        if ([[h objectForKey:@"algo"] integerValue] == 1) {
            return h[@"value"];
        }
    }
    return nil;
}

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    NSError *error;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to open modpack package: %@", error.localizedDescription]];
        return;
    }
    NSData *manifestData = [archive extractDataFromFile:@"manifest.json" error:&error];
    NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:kNilOptions error:&error];
    if (error || !manifest) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse manifest.json: %@", error.localizedDescription]];
        return;
    }
    NSString *manifestType = manifest[@"manifestType"] ?: @"";
    NSNumber *manifestVersion = manifest[@"manifestVersion"] ?: @(0);
    NSDictionary *minecraft = manifest[@"minecraft"] ?: @{};
    NSArray *modLoaders = minecraft[@"modLoaders"] ?: @[];
    if (![manifestType isEqualToString:@"minecraftModpack"] || manifestVersion.integerValue < 1 || modLoaders.count == 0) {
        [downloader finishDownloadWithErrorString:@"Invalid CurseForge manifest.json"];
        return;
    }

    NSArray *files = manifest[@"files"] ?: @[];
    downloader.progress.totalUnitCount = files.count;
    NSString *modsDir = [destPath stringByAppendingPathComponent:@"mods"];
    [NSFileManager.defaultManager createDirectoryAtPath:modsDir withIntermediateDirectories:YES attributes:nil error:nil];

    for (NSDictionary *f in files) {
        NSNumber *projectID = f[@"projectID"];
        NSNumber *fileID = f[@"fileID"];
        NSDictionary *fileResp = [self getEndpoint:[NSString stringWithFormat:@"mods/%@/files/%@", projectID, fileID] params:nil];
        if (!fileResp || ![fileResp isKindOfClass:[NSDictionary class]] || !fileResp[@"data"]) {
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to fetch file metadata for projectID=%@ fileID=%@", projectID, fileID]];
            return;
        }
        NSDictionary *fileData = fileResp[@"data"];
        if (![fileData isKindOfClass:[NSDictionary class]]) {
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Invalid file metadata for projectID=%@ fileID=%@", projectID, fileID]];
            return;
        }
        NSString *url = [self cfDownloadURLForProject:projectID fileId:fileID fileData:fileData];
        if (url.length == 0) {
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to resolve download URL for projectID=%@ fileID=%@", projectID, fileID]];
            return;
        }
        NSString *sha = [self cfDownloadSHA1FromFileData:fileData];
        id fnameObj = fileData[@"fileName"];
        NSString *fname = [fnameObj isKindOfClass:NSString.class] ? (NSString *)fnameObj : @"";
        NSString *resolvedName = fname.length ? fname : [NSURL URLWithString:url].lastPathComponent;
        if (resolvedName.length == 0) {
            resolvedName = [NSString stringWithFormat:@"%@-%@.jar", projectID, fileID];
        } else {
            NSCharacterSet *nonDigitSet = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet];
            NSRange nonDigitRange = [resolvedName rangeOfCharacterFromSet:nonDigitSet];
            if (nonDigitRange.location == NSNotFound && resolvedName.length < 10) {
                resolvedName = [NSString stringWithFormat:@"%@-%@.jar", projectID, fileID];
            }
        }
        NSString *path = [modsDir stringByAppendingPathComponent:resolvedName];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:url size:0 sha:sha altName:nil toPath:path];
        if (task) {
            [downloader.fileList addObject:path.lastPathComponent];
            [task resume];
        } else if (!downloader.progress.cancelled) {
            downloader.progress.completedUnitCount++;
        } else {
            return;
        }
    }

    NSString *overrides = manifest[@"overrides"] ?: @"overrides";
    [ModpackUtils archive:archive extractDirectory:overrides toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract overrides: %@", error.localizedDescription]];
        return;
    }

    [NSFileManager.defaultManager removeItemAtPath:packagePath error:nil];

    NSString *packName = manifest[@"name"] ?: destPath.lastPathComponent;
    NSString *mcVersion = minecraft[@"version"] ?: @"";
    NSDictionary *primaryLoader = [modLoaders firstObject] ?: @{};
    NSString *loaderId = primaryLoader[@"id"] ?: @"";
    NSString *lastVersionId = nil;
    if ([loaderId hasPrefix:@"forge-"]) {
        NSString *forgeVer = [loaderId substringFromIndex:6];
        lastVersionId = [NSString stringWithFormat:@"%@-forge-%@", mcVersion, forgeVer];
    } else if ([loaderId hasPrefix:@"fabric-"]) {
        NSString *fabricVer = [loaderId substringFromIndex:7];
        lastVersionId = [NSString stringWithFormat:@"fabric-loader-%@-%@", fabricVer, mcVersion];
        NSString *jsonURL = [NSString stringWithFormat:FabricUtils.endpoints[@"Fabric"][@"json"], mcVersion, fabricVer];
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), lastVersionId];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:jsonURL size:0 sha:nil altName:nil toPath:jsonPath];
        [task resume];
    } else if ([loaderId hasPrefix:@"quilt-"]) {
        NSString *quiltVer = [loaderId substringFromIndex:6];
        lastVersionId = [NSString stringWithFormat:@"quilt-loader-%@-%@", quiltVer, mcVersion];
        NSString *jsonURL = [NSString stringWithFormat:FabricUtils.endpoints[@"Quilt"][@"json"], mcVersion, quiltVer];
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), lastVersionId];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:jsonURL size:0 sha:nil altName:nil toPath:jsonPath];
        [task resume];
    } else {
        lastVersionId = mcVersion;
    }

    NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
    PLProfiles.current.profiles[packName] = @{
        @"gameDir": [NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent],
        @"name": packName,
        @"lastVersionId": lastVersionId ?: mcVersion,
        @"icon": [NSString stringWithFormat:@"data:image/png;base64,%@",
            [[NSData dataWithContentsOfFile:tmpIconPath] base64EncodedStringWithOptions:0]]
    }.mutableCopy;
    PLProfiles.current.selectedProfileName = packName;
}

@end
