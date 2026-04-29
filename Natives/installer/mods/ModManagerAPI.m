#import "installer/modpack/CurseForgeAPI.h"
#import "installer/modpack/ModrinthAPI.h"
#import "ModManagerAPI.h"
#import "ModManagerStore.h"

static NSString * const kModSourceModrinth = @"modrinth";
static NSString * const kModSourceCurseForge = @"curseforge";

@interface ModManagerAPI ()
@property(nonatomic) ModrinthAPI *modrinth;
@property(nonatomic) CurseForgeAPI *curseforge;
@property(nonatomic) NSMutableDictionary *curseForgeProjectCache;
@property(nonatomic) NSMutableDictionary *modrinthProjectCache;
@end

@implementation ModManagerAPI

- (instancetype)init {
    self = [super init];
    self.modrinth = [ModrinthAPI new];
    self.curseforge = [CurseForgeAPI new];
    self.curseForgeProjectCache = [NSMutableDictionary new];
    self.modrinthProjectCache = [NSMutableDictionary new];
    return self;
}

- (NSError *)errorWithDescription:(NSString *)description {
    return [NSError errorWithDomain:@"ModManagerAPI"
        code:1
        userInfo:@{NSLocalizedDescriptionKey: description ?: @"Unknown mod manager error."}];
}

- (NSDictionary *)filtersForQuery:(NSString *)query profileInfo:(NSDictionary *)profileInfo {
    NSMutableDictionary *filters = @{
        @"isModpack": @NO,
        @"name": query ?: @""
    }.mutableCopy;
    NSString *mcVersion = profileInfo[@"minecraftVersion"];
    NSString *loader = profileInfo[@"loader"];
    if ([mcVersion isKindOfClass:NSString.class] && mcVersion.length > 0) {
        filters[@"mcVersion"] = mcVersion;
    }
    if ([loader isKindOfClass:NSString.class] && loader.length > 0 && ![loader isEqualToString:@"vanilla"]) {
        filters[@"loader"] = loader;
    }
    return filters;
}

- (NSMutableDictionary *)normalizedProjectFromSearchItem:(NSDictionary *)item source:(NSString *)source {
    NSMutableDictionary *project = [NSMutableDictionary new];
    project[@"source"] = source;
    project[@"projectId"] = item[@"id"] ?: @"";
    project[@"title"] = item[@"title"] ?: @"";
    project[@"summary"] = item[@"description"] ?: @"";
    project[@"iconUrl"] = item[@"imageUrl"] ?: @"";
    return project;
}

- (NSArray<NSMutableDictionary *> *)searchModsWithQuery:(NSString *)query source:(NSString *)source profileInfo:(NSDictionary *)profileInfo {
    self.lastError = nil;
    NSMutableArray *results = [NSMutableArray new];
    NSDictionary *filters = [self filtersForQuery:query profileInfo:profileInfo];

    BOOL includeModrinth = ![source isEqualToString:kModSourceCurseForge];
    BOOL includeCurseForge = ![source isEqualToString:kModSourceModrinth];

    if (includeModrinth) {
        NSMutableArray *items = [self.modrinth searchModWithFilters:filters previousPageResult:nil];
        if (items) {
            for (NSDictionary *item in items) {
                [results addObject:[self normalizedProjectFromSearchItem:item source:kModSourceModrinth]];
            }
        } else if (![source isEqualToString:@"all"]) {
            self.lastError = self.modrinth.lastError;
            return nil;
        }
    }

    if (includeCurseForge) {
        if (![CurseForgeAPI isConfigured]) {
            if ([source isEqualToString:kModSourceCurseForge]) {
                self.lastError = [self errorWithDescription:@"CurseForge API key is not configured for this build."];
                return nil;
            }
        } else {
            NSMutableArray *items = [self.curseforge searchModWithFilters:filters previousPageResult:nil];
            if (items) {
                for (NSDictionary *item in items) {
                    [results addObject:[self normalizedProjectFromSearchItem:item source:kModSourceCurseForge]];
                }
            } else if (![source isEqualToString:@"all"]) {
                self.lastError = self.curseforge.lastError;
                return nil;
            }
        }
    }

    [results sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSString *aTitle = a[@"title"] ?: @"";
        NSString *bTitle = b[@"title"] ?: @"";
        return [aTitle localizedCaseInsensitiveCompare:bTitle];
    }];
    return results;
}

- (BOOL)array:(NSArray *)array containsString:(NSString *)needle caseInsensitive:(BOOL)caseInsensitive {
    if (![array isKindOfClass:NSArray.class] || ![needle isKindOfClass:NSString.class] || needle.length == 0) {
        return NO;
    }
    for (id item in array) {
        if (![item isKindOfClass:NSString.class]) {
            continue;
        }
        if (caseInsensitive ? [item caseInsensitiveCompare:needle] == NSOrderedSame : [item isEqualToString:needle]) {
            return YES;
        }
    }
    return NO;
}

- (NSDictionary *)modrinthProjectInfoForID:(NSString *)projectID {
    if (![projectID isKindOfClass:NSString.class] || projectID.length == 0) {
        return nil;
    }
    id cached = self.modrinthProjectCache[projectID];
    if (cached == NSNull.null) return nil;
    if ([cached isKindOfClass:NSDictionary.class]) return cached;

    NSDictionary *project = [self.modrinth getEndpoint:[NSString stringWithFormat:@"project/%@", projectID] params:nil];
    if (![project isKindOfClass:NSDictionary.class]) {
        self.modrinthProjectCache[projectID] = NSNull.null;
        return nil;
    }
    self.modrinthProjectCache[projectID] = project;
    return project;
}

- (NSDictionary *)modrinthVersionForID:(NSString *)versionID {
    if (![versionID isKindOfClass:NSString.class] || versionID.length == 0) {
        return nil;
    }
    NSDictionary *version = [self.modrinth getEndpoint:[NSString stringWithFormat:@"version/%@", versionID] params:nil];
    return [version isKindOfClass:NSDictionary.class] ? version : nil;
}

- (NSDictionary *)primaryModrinthFileForVersion:(NSDictionary *)version {
    NSArray *files = [version[@"files"] isKindOfClass:NSArray.class] ? version[@"files"] : @[];
    NSDictionary *fallback = nil;
    for (NSDictionary *file in files) {
        if (![file isKindOfClass:NSDictionary.class]) continue;
        NSString *fileName = file[@"filename"];
        if (![fileName isKindOfClass:NSString.class] || ![fileName.lowercaseString hasSuffix:@".jar"]) {
            continue;
        }
        if (!fallback) fallback = file;
        if ([file[@"primary"] respondsToSelector:@selector(boolValue)] && [file[@"primary"] boolValue]) {
            return file;
        }
    }
    return fallback;
}

- (NSDictionary *)normalizedModrinthVersion:(NSDictionary *)version project:(NSDictionary *)project profileInfo:(NSDictionary *)profileInfo {
    NSArray *gameVersions = [version[@"game_versions"] isKindOfClass:NSArray.class] ? version[@"game_versions"] : @[];
    NSArray *loaders = [version[@"loaders"] isKindOfClass:NSArray.class] ? version[@"loaders"] : @[];
    NSString *mcVersion = profileInfo[@"minecraftVersion"];
    NSString *loader = profileInfo[@"loader"];
    if (mcVersion.length > 0 && ![self array:gameVersions containsString:mcVersion caseInsensitive:NO]) {
        return nil;
    }
    if (loader.length > 0 && ![loader isEqualToString:@"vanilla"] && ![self array:loaders containsString:loader caseInsensitive:YES]) {
        return nil;
    }

    NSDictionary *file = [self primaryModrinthFileForVersion:version];
    if (!file) {
        return nil;
    }

    NSDictionary *hashes = [file[@"hashes"] isKindOfClass:NSDictionary.class] ? file[@"hashes"] : nil;
    NSMutableArray *dependencies = [NSMutableArray new];
    NSArray *versionDependencies = [version[@"dependencies"] isKindOfClass:NSArray.class] ? version[@"dependencies"] : @[];
    for (NSDictionary *dependency in versionDependencies) {
        if (![dependency isKindOfClass:NSDictionary.class]) continue;
        NSString *type = dependency[@"dependency_type"];
        if (![type isKindOfClass:NSString.class] || type.length == 0) {
            type = @"required";
        }
        NSMutableDictionary *normalized = @{
            @"source": kModSourceModrinth,
            @"type": type
        }.mutableCopy;
        if (dependency[@"project_id"]) normalized[@"projectId"] = dependency[@"project_id"];
        if (dependency[@"version_id"]) normalized[@"versionId"] = dependency[@"version_id"];
        [dependencies addObject:normalized];
    }

    NSString *projectID = project[@"project_id"] ?: project[@"id"] ?: version[@"project_id"];
    NSString *title = project[@"title"] ?: project[@"name"] ?: version[@"name"] ?: file[@"filename"];
    return @{
        @"source": kModSourceModrinth,
        @"projectId": projectID ?: @"",
        @"versionId": version[@"id"] ?: @"",
        @"title": title ?: @"",
        @"versionName": version[@"name"] ?: @"",
        @"summary": project[@"description"] ?: project[@"summary"] ?: @"",
        @"iconUrl": project[@"icon_url"] ?: @"",
        @"fileName": file[@"filename"] ?: @"",
        @"downloadUrl": file[@"url"] ?: @"",
        @"sha1": hashes[@"sha1"] ?: @"",
        @"size": file[@"size"] ?: @0,
        @"gameVersion": gameVersions.firstObject ?: @"",
        @"loaders": loaders ?: @[],
        @"datePublished": version[@"date_published"] ?: @"",
        @"dependencies": dependencies
    };
}

- (NSArray<NSDictionary *> *)modrinthVersionsForProject:(NSDictionary *)project profileInfo:(NSDictionary *)profileInfo {
    NSString *projectID = [project[@"projectId"] description];
    NSArray *versions = [self.modrinth getEndpoint:[NSString stringWithFormat:@"project/%@/version", projectID] params:nil];
    if (![versions isKindOfClass:NSArray.class]) {
        self.lastError = self.modrinth.lastError ?: [self errorWithDescription:@"Modrinth returned an invalid version list."];
        return nil;
    }

    NSMutableArray *result = [NSMutableArray new];
    for (NSDictionary *version in versions) {
        if (![version isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *normalized = [self normalizedModrinthVersion:version project:project profileInfo:profileInfo];
        if (normalized) {
            [result addObject:normalized];
        }
    }
    return result;
}

- (BOOL)curseForgeFile:(NSDictionary *)file matchesProfileInfo:(NSDictionary *)profileInfo {
    BOOL isServerPack = [file[@"isServerPack"] respondsToSelector:@selector(boolValue)] && [file[@"isServerPack"] boolValue];
    id available = file[@"isAvailable"];
    BOOL isUnavailable = [available isKindOfClass:NSNumber.class] && ![available boolValue];
    NSString *fileName = file[@"fileName"];
    if (isServerPack || isUnavailable || ![fileName isKindOfClass:NSString.class] || ![fileName.lowercaseString hasSuffix:@".jar"]) {
        return NO;
    }

    NSArray *gameVersions = [file[@"gameVersions"] isKindOfClass:NSArray.class] ? file[@"gameVersions"] : @[];
    NSString *mcVersion = profileInfo[@"minecraftVersion"];
    NSString *loader = profileInfo[@"loader"];
    if (mcVersion.length > 0 && ![self array:gameVersions containsString:mcVersion caseInsensitive:NO]) {
        return NO;
    }

    if (loader.length == 0 || [loader isEqualToString:@"vanilla"]) {
        return YES;
    }

    BOOL mentionsAnyLoader = NO;
    NSArray *knownLoaders = @[@"forge", @"fabric", @"quilt", @"neoforge", @"neo forge"];
    for (NSString *gameVersion in gameVersions) {
        if (![gameVersion isKindOfClass:NSString.class]) continue;
        NSString *lower = gameVersion.lowercaseString;
        for (NSString *known in knownLoaders) {
            if ([lower isEqualToString:known]) {
                mentionsAnyLoader = YES;
            }
        }
    }
    if (!mentionsAnyLoader) {
        return YES;
    }
    if ([loader isEqualToString:@"neoforge"]) {
        return [self array:gameVersions containsString:@"NeoForge" caseInsensitive:YES] ||
            [self array:gameVersions containsString:@"Neo Forge" caseInsensitive:YES];
    }
    return [self array:gameVersions containsString:[ModManagerStore displayNameForLoader:loader] caseInsensitive:YES];
}

- (NSString *)curseForgeMinecraftVersionForFile:(NSDictionary *)file {
    NSArray *gameVersions = [file[@"gameVersions"] isKindOfClass:NSArray.class] ? file[@"gameVersions"] : @[];
    for (NSString *version in gameVersions) {
        if (![version isKindOfClass:NSString.class] || version.length == 0) continue;
        unichar first = [version characterAtIndex:0];
        if ([[NSCharacterSet decimalDigitCharacterSet] characterIsMember:first]) {
            return version;
        }
    }
    return @"";
}

- (NSArray *)normalizedCurseForgeDependencies:(NSArray *)dependencies {
    NSMutableArray *result = [NSMutableArray new];
    for (NSDictionary *dependency in dependencies) {
        if (![dependency isKindOfClass:NSDictionary.class]) continue;
        NSNumber *modID = [dependency[@"modId"] isKindOfClass:NSNumber.class] ? dependency[@"modId"] : nil;
        if (!modID) continue;
        NSInteger relationType = [dependency[@"relationType"] respondsToSelector:@selector(integerValue)] ? [dependency[@"relationType"] integerValue] : 3;
        NSString *type = @"required";
        if (relationType == 1) type = @"embedded";
        else if (relationType == 2 || relationType == 4) type = @"optional";
        else if (relationType == 5) type = @"incompatible";
        else if (relationType == 3 || relationType == 6) type = @"required";
        [result addObject:@{
            @"source": kModSourceCurseForge,
            @"type": type,
            @"projectId": modID
        }];
    }
    return result;
}

- (NSDictionary *)normalizedCurseForgeFile:(NSDictionary *)file project:(NSDictionary *)project profileInfo:(NSDictionary *)profileInfo {
    NSNumber *projectID = [file[@"modId"] isKindOfClass:NSNumber.class] ? file[@"modId"] : project[@"projectId"];
    if (![projectID isKindOfClass:NSNumber.class]) {
        projectID = @([[project[@"projectId"] description] integerValue]);
    }
    NSString *fileName = file[@"fileName"];
    if (![fileName isKindOfClass:NSString.class] || fileName.length == 0) {
        fileName = [NSString stringWithFormat:@"%@.jar", file[@"id"] ?: projectID];
    }

    NSString *downloadURL = [self.curseforge downloadURLForFile:file projectID:projectID];
    NSString *manualURL = [self.curseforge manualDownloadPageURLForFile:file projectID:projectID cache:self.curseForgeProjectCache];
    NSString *title = project[@"title"] ?: project[@"name"] ?: file[@"displayName"] ?: fileName;
    NSNumber *size = [file[@"fileLength"] isKindOfClass:NSNumber.class] ? file[@"fileLength"] : file[@"fileSizeOnDisk"];
    if (![size isKindOfClass:NSNumber.class]) size = @0;

    return @{
        @"source": kModSourceCurseForge,
        @"projectId": projectID ?: @0,
        @"fileId": file[@"id"] ?: @0,
        @"title": title ?: @"",
        @"versionName": file[@"displayName"] ?: fileName,
        @"summary": project[@"summary"] ?: @"",
        @"iconUrl": project[@"iconUrl"] ?: @"",
        @"fileName": fileName,
        @"downloadUrl": downloadURL ?: @"",
        @"manualUrl": manualURL ?: @"",
        @"sha1": [self.curseforge sha1HashForFile:file] ?: @"",
        @"size": size,
        @"gameVersion": [self curseForgeMinecraftVersionForFile:file],
        @"loaders": @[profileInfo[@"loader"] ?: @""],
        @"datePublished": file[@"fileDate"] ?: @"",
        @"dependencies": [self normalizedCurseForgeDependencies:([file[@"dependencies"] isKindOfClass:NSArray.class] ? file[@"dependencies"] : @[])]
    };
}

- (NSDictionary *)curseForgeProjectInfoForID:(NSNumber *)projectID fallback:(NSDictionary *)fallback {
    NSDictionary *project = [self.curseforge projectInfoForProjectID:projectID cache:self.curseForgeProjectCache];
    if (![project isKindOfClass:NSDictionary.class]) {
        return fallback;
    }
    NSDictionary *logo = [project[@"logo"] isKindOfClass:NSDictionary.class] ? project[@"logo"] : nil;
    NSString *imageUrl = [logo[@"thumbnailUrl"] isKindOfClass:NSString.class] ? logo[@"thumbnailUrl"] : logo[@"url"];
    return @{
        @"source": kModSourceCurseForge,
        @"projectId": projectID ?: @0,
        @"title": project[@"name"] ?: fallback[@"title"] ?: @"",
        @"summary": project[@"summary"] ?: fallback[@"summary"] ?: @"",
        @"iconUrl": imageUrl ?: fallback[@"iconUrl"] ?: @""
    };
}

- (NSArray<NSDictionary *> *)curseForgeVersionsForProject:(NSDictionary *)project profileInfo:(NSDictionary *)profileInfo {
    if (![CurseForgeAPI isConfigured]) {
        self.lastError = [self errorWithDescription:@"CurseForge API key is not configured for this build."];
        return nil;
    }
    NSNumber *projectID = [project[@"projectId"] isKindOfClass:NSNumber.class] ? project[@"projectId"] : @([[project[@"projectId"] description] integerValue]);
    NSArray *files = [self.curseforge filesForModID:projectID];
    if (![files isKindOfClass:NSArray.class]) {
        self.lastError = self.curseforge.lastError ?: [self errorWithDescription:@"CurseForge returned an invalid file list."];
        return nil;
    }

    NSDictionary *projectInfo = [self curseForgeProjectInfoForID:projectID fallback:project];
    NSMutableArray *result = [NSMutableArray new];
    for (NSDictionary *file in files) {
        if (![file isKindOfClass:NSDictionary.class] || ![self curseForgeFile:file matchesProfileInfo:profileInfo]) {
            continue;
        }
        [result addObject:[self normalizedCurseForgeFile:file project:projectInfo profileInfo:profileInfo]];
        if (result.count >= 30) {
            break;
        }
    }
    return result;
}

- (NSArray<NSDictionary *> *)versionsForProject:(NSDictionary *)project profileInfo:(NSDictionary *)profileInfo {
    self.lastError = nil;
    NSString *source = project[@"source"];
    NSArray *versions = nil;
    if ([source isEqualToString:kModSourceModrinth]) {
        versions = [self modrinthVersionsForProject:project profileInfo:profileInfo];
    } else if ([source isEqualToString:kModSourceCurseForge]) {
        versions = [self curseForgeVersionsForProject:project profileInfo:profileInfo];
    } else {
        self.lastError = [self errorWithDescription:@"Unknown mod source."];
        return nil;
    }
    if (versions.count == 0 && !self.lastError) {
        NSString *mcVersion = profileInfo[@"minecraftVersion"] ?: @"this Minecraft version";
        NSString *loader = [ModManagerStore displayNameForLoader:profileInfo[@"loader"]];
        self.lastError = [self errorWithDescription:[NSString stringWithFormat:@"No compatible %@ files were found for %@.", loader, mcVersion]];
    }
    return versions;
}

- (NSDictionary *)projectForDependency:(NSDictionary *)dependency {
    NSString *source = dependency[@"source"];
    id projectID = dependency[@"projectId"];
    if ([source isEqualToString:kModSourceModrinth]) {
        NSDictionary *project = [self modrinthProjectInfoForID:[projectID description]];
        return @{
            @"source": kModSourceModrinth,
            @"projectId": projectID ?: @"",
            @"title": project[@"title"] ?: @"Dependency",
            @"summary": project[@"description"] ?: @"",
            @"iconUrl": project[@"icon_url"] ?: @""
        };
    } else if ([source isEqualToString:kModSourceCurseForge]) {
        NSNumber *modID = [projectID isKindOfClass:NSNumber.class] ? projectID : @([[projectID description] integerValue]);
        NSDictionary *project = [self curseForgeProjectInfoForID:modID fallback:nil];
        return project ?: @{
            @"source": kModSourceCurseForge,
            @"projectId": modID ?: @0,
            @"title": @"Dependency",
            @"summary": @"",
            @"iconUrl": @""
        };
    }
    return nil;
}

- (NSDictionary *)versionForDependency:(NSDictionary *)dependency profileInfo:(NSDictionary *)profileInfo {
    NSString *source = dependency[@"source"];
    if ([source isEqualToString:kModSourceModrinth] && [dependency[@"versionId"] isKindOfClass:NSString.class]) {
        NSDictionary *version = [self modrinthVersionForID:dependency[@"versionId"]];
        NSDictionary *project = [self modrinthProjectInfoForID:dependency[@"projectId"]];
        NSDictionary *normalized = [self normalizedModrinthVersion:version project:project profileInfo:profileInfo];
        if (normalized) {
            return normalized;
        }
    }

    NSDictionary *project = [self projectForDependency:dependency];
    NSArray *versions = [self versionsForProject:project profileInfo:profileInfo];
    return versions.firstObject;
}

- (void)collectDependenciesForVersion:(NSDictionary *)version
                           profileInfo:(NSDictionary *)profileInfo
                                 store:(ModManagerStore *)store
                                  seen:(NSMutableSet *)seen
                              required:(NSMutableArray *)required
                              optional:(NSMutableArray *)optional
                                 error:(NSError **)error {
    NSArray *dependencies = [version[@"dependencies"] isKindOfClass:NSArray.class] ? version[@"dependencies"] : @[];
    for (NSDictionary *dependency in dependencies) {
        if (![dependency isKindOfClass:NSDictionary.class]) continue;
        NSString *source = dependency[@"source"];
        id projectID = dependency[@"projectId"] ?: dependency[@"versionId"];
        NSString *type = dependency[@"type"];
        if (![source isKindOfClass:NSString.class] || !projectID) {
            continue;
        }
        NSString *key = [NSString stringWithFormat:@"%@:%@", source, projectID];
        if ([type isEqualToString:@"embedded"]) {
            continue;
        }
        if ([type isEqualToString:@"incompatible"]) {
            if ([store containsInstalledProjectWithSource:source projectId:projectID] && error) {
                *error = [self errorWithDescription:@"An installed mod is marked incompatible with this selection."];
            }
            continue;
        }
        if ([seen containsObject:key] ||
            (dependency[@"projectId"] && [store containsInstalledProjectWithSource:source projectId:dependency[@"projectId"]])) {
            continue;
        }
        [seen addObject:key];

        NSDictionary *resolved = [self versionForDependency:dependency profileInfo:profileInfo];
        if (!resolved) {
            if ([type isEqualToString:@"required"] && error) {
                *error = self.lastError ?: [self errorWithDescription:@"A required dependency could not be resolved."];
            }
            continue;
        }

        if ([type isEqualToString:@"optional"]) {
            [optional addObject:resolved];
        } else {
            [required addObject:resolved];
            [self collectDependenciesForVersion:resolved
                                    profileInfo:profileInfo
                                          store:store
                                           seen:seen
                                       required:required
                                       optional:optional
                                          error:error];
            if (error && *error) {
                return;
            }
        }
    }
}

- (BOOL)resolveDependenciesForVersion:(NSDictionary *)version
                           profileInfo:(NSDictionary *)profileInfo
                                 store:(ModManagerStore *)store
                              required:(NSArray<NSDictionary *> *__autoreleasing *)required
                              optional:(NSArray<NSDictionary *> *__autoreleasing *)optional
                                 error:(NSError *__autoreleasing *)error {
    NSMutableArray *requiredResult = [NSMutableArray new];
    NSMutableArray *optionalResult = [NSMutableArray new];
    NSMutableSet *seen = [NSMutableSet setWithObject:[NSString stringWithFormat:@"%@:%@", version[@"source"], version[@"projectId"]]];
    [self collectDependenciesForVersion:version
                            profileInfo:profileInfo
                                  store:store
                                   seen:seen
                               required:requiredResult
                               optional:optionalResult
                                  error:error];
    if (error && *error) {
        return NO;
    }
    if (required) *required = requiredResult;
    if (optional) *optional = optionalResult;
    return YES;
}

- (NSDictionary *)latestVersionForInstalledMod:(NSDictionary *)mod profileInfo:(NSDictionary *)profileInfo error:(NSError **)error {
    NSString *source = mod[@"source"];
    id projectID = mod[@"projectId"];
    if (![source isKindOfClass:NSString.class] || !projectID || [source isEqualToString:@"manual"]) {
        return nil;
    }

    NSDictionary *project = @{
        @"source": source,
        @"projectId": projectID,
        @"title": mod[@"title"] ?: @"",
        @"summary": mod[@"summary"] ?: @"",
        @"iconUrl": mod[@"iconUrl"] ?: @""
    };
    NSArray *versions = [self versionsForProject:project profileInfo:profileInfo];
    NSDictionary *latest = versions.firstObject;
    if (!latest) {
        if (error) *error = self.lastError;
        return nil;
    }

    NSString *installedVersion = [mod[@"versionId"] description];
    NSString *latestVersion = [latest[@"versionId"] description];
    NSString *installedFile = [mod[@"fileId"] description];
    NSString *latestFile = [latest[@"fileId"] description];
    if (latestVersion.length > 0 && ![latestVersion isEqualToString:installedVersion]) {
        return latest;
    }
    if (latestFile.length > 0 && ![latestFile isEqualToString:installedFile]) {
        return latest;
    }
    return nil;
}

@end
