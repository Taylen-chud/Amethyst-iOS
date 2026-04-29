#import "LauncherPreferences.h"
#import "ModManagerStore.h"
#import "utils.h"

static NSString * const kModManagerMetadataFileName = @"amethyst_mods.json";

@interface ModManagerStore ()
@property(nonatomic) NSString *profileName;
@property(nonatomic) NSMutableDictionary *profile;
@property(nonatomic) NSString *profileGameDir;
@property(nonatomic) NSString *modsDir;
@property(nonatomic) NSString *metadataPath;
@property(nonatomic) NSDictionary *profileInfo;
@end

@implementation ModManagerStore

- (instancetype)initWithProfileName:(NSString *)profileName profile:(NSMutableDictionary *)profile {
    self = [super init];
    self.profileName = profileName;
    self.profile = profile;
    NSString *gameDir = [self resolvedProfileValue:@"gameDir"];
    self.profileGameDir = [[NSString stringWithFormat:@"%s/instances/%@/%@",
        getenv("POJAV_HOME"),
        getPrefObject(@"general.game_directory"),
        gameDir ?: @"."]
        stringByStandardizingPath];
    self.modsDir = [self.profileGameDir stringByAppendingPathComponent:@"mods"];
    self.metadataPath = [self.profileGameDir stringByAppendingPathComponent:kModManagerMetadataFileName];
    self.profileInfo = [self resolvedProfileInfoForVersionId:[self resolvedProfileValue:@"lastVersionId"]];
    return self;
}

- (NSString *)resolvedProfileValue:(NSString *)key {
    NSString *value = self.profile[key];
    if ([value isKindOfClass:NSString.class] && value.length > 0) {
        return value;
    }
    if ([key isEqualToString:@"gameDir"]) {
        return @".";
    }
    return nil;
}

+ (NSDictionary *)profileInfoForVersionId:(NSString *)versionId {
    if (![versionId isKindOfClass:NSString.class]) {
        versionId = @"";
    }

    NSString *lower = versionId.lowercaseString;
    NSString *loader = @"vanilla";
    NSString *minecraftVersion = versionId;

    NSRegularExpression *fabric = [NSRegularExpression regularExpressionWithPattern:@"^fabric-loader-[^-]+-(.+)$" options:0 error:nil];
    NSTextCheckingResult *fabricMatch = [fabric firstMatchInString:versionId options:0 range:NSMakeRange(0, versionId.length)];
    if (fabricMatch.numberOfRanges == 2) {
        loader = @"fabric";
        minecraftVersion = [versionId substringWithRange:[fabricMatch rangeAtIndex:1]];
    } else {
        NSRegularExpression *quilt = [NSRegularExpression regularExpressionWithPattern:@"^quilt-loader-[^-]+-(.+)$" options:0 error:nil];
        NSTextCheckingResult *quiltMatch = [quilt firstMatchInString:versionId options:0 range:NSMakeRange(0, versionId.length)];
        if (quiltMatch.numberOfRanges == 2) {
            loader = @"quilt";
            minecraftVersion = [versionId substringWithRange:[quiltMatch rangeAtIndex:1]];
        } else if ([lower containsString:@"neoforge"]) {
            loader = @"neoforge";
            NSRegularExpression *neo = [NSRegularExpression regularExpressionWithPattern:@"(\\d+\\.\\d+(?:\\.\\d+)*)" options:0 error:nil];
            NSTextCheckingResult *neoMatch = [neo firstMatchInString:versionId options:0 range:NSMakeRange(0, versionId.length)];
            if (neoMatch.numberOfRanges > 1) {
                minecraftVersion = [versionId substringWithRange:[neoMatch rangeAtIndex:1]];
            }
        } else if ([lower containsString:@"forge"]) {
            loader = @"forge";
            NSRegularExpression *forge = [NSRegularExpression regularExpressionWithPattern:@"^(\\d+\\.\\d+(?:\\.\\d+)?)-forge-" options:0 error:nil];
            NSTextCheckingResult *forgeMatch = [forge firstMatchInString:versionId options:0 range:NSMakeRange(0, versionId.length)];
            if (forgeMatch.numberOfRanges == 2) {
                minecraftVersion = [versionId substringWithRange:[forgeMatch rangeAtIndex:1]];
            }
        }
    }

    return @{
        @"versionId": versionId ?: @"",
        @"minecraftVersion": minecraftVersion ?: @"",
        @"loader": loader
    };
}

- (NSDictionary *)resolvedProfileInfoForVersionId:(NSString *)versionId {
    NSMutableDictionary *info = [[ModManagerStore profileInfoForVersionId:versionId] mutableCopy];
    NSString *jsonPath = [NSString stringWithFormat:@"%s/versions/%@/%@.json", getenv("POJAV_GAME_DIR"), versionId, versionId];
    if ([NSFileManager.defaultManager fileExistsAtPath:jsonPath]) {
        NSDictionary *json = parseJSONFromFile(jsonPath);
        NSString *inheritsFrom = [json[@"inheritsFrom"] isKindOfClass:NSString.class] ? json[@"inheritsFrom"] : nil;
        if (inheritsFrom.length > 0) {
            info[@"minecraftVersion"] = inheritsFrom;
        }
        NSString *lowerId = [versionId lowercaseString];
        if ([lowerId containsString:@"fabric"]) {
            info[@"loader"] = @"fabric";
        } else if ([lowerId containsString:@"quilt"]) {
            info[@"loader"] = @"quilt";
        } else if ([lowerId containsString:@"neoforge"]) {
            info[@"loader"] = @"neoforge";
        } else if ([lowerId containsString:@"forge"]) {
            info[@"loader"] = @"forge";
        }
    }
    return info;
}

+ (BOOL)profileInfoSupportsModInstall:(NSDictionary *)profileInfo {
    NSString *loader = profileInfo[@"loader"];
    return [@[@"fabric", @"quilt", @"forge", @"neoforge"] containsObject:loader];
}

+ (NSString *)displayNameForLoader:(NSString *)loader {
    if ([loader isEqualToString:@"fabric"]) return @"Fabric";
    if ([loader isEqualToString:@"quilt"]) return @"Quilt";
    if ([loader isEqualToString:@"forge"]) return @"Forge";
    if ([loader isEqualToString:@"neoforge"]) return @"NeoForge";
    return @"Vanilla";
}

- (NSMutableDictionary *)metadataCreatingIfNeeded:(BOOL)create {
    if (![NSFileManager.defaultManager fileExistsAtPath:self.metadataPath]) {
        return @{@"version": @1, @"mods": [NSMutableDictionary new]}.mutableCopy;
    }
    NSMutableDictionary *metadata = parseJSONFromFile(self.metadataPath);
    if ([metadata[@"NSErrorObject"] isKindOfClass:NSError.class]) {
        if (!create) {
            return @{@"version": @1, @"mods": @{}}.mutableCopy;
        }
        metadata = @{@"version": @1, @"mods": @{}}.mutableCopy;
    }
    if (![metadata[@"mods"] isKindOfClass:NSMutableDictionary.class]) {
        NSDictionary *mods = [metadata[@"mods"] isKindOfClass:NSDictionary.class] ? metadata[@"mods"] : @{};
        metadata[@"mods"] = mods.mutableCopy;
    }
    return metadata;
}

- (BOOL)isSafeModFileName:(NSString *)fileName {
    if (![fileName isKindOfClass:NSString.class] || fileName.length == 0) {
        return NO;
    }
    if ([fileName containsString:@"/"] || [fileName containsString:@"\\"] || [fileName containsString:@":"]) {
        return NO;
    }
    NSString *lower = fileName.lowercaseString;
    return [lower hasSuffix:@".jar"];
}

- (NSArray<NSString *> *)modFileNames {
    NSArray *contents = [NSFileManager.defaultManager contentsOfDirectoryAtPath:self.modsDir error:nil] ?: @[];
    NSMutableArray *files = [NSMutableArray new];
    for (NSString *fileName in contents) {
        NSString *lower = fileName.lowercaseString;
        if ([lower hasSuffix:@".jar"] || [lower hasSuffix:@".jar.disabled"]) {
            [files addObject:fileName];
        }
    }
    return files;
}

- (NSArray<NSMutableDictionary *> *)installedMods {
    NSMutableDictionary *metadata = [self metadataCreatingIfNeeded:NO];
    NSDictionary *records = [metadata[@"mods"] isKindOfClass:NSDictionary.class] ? metadata[@"mods"] : @{};
    NSMutableArray *installed = [NSMutableArray new];
    NSMutableSet *seen = [NSMutableSet new];

    for (NSString *actualFileName in [self modFileNames]) {
        BOOL enabled = [actualFileName.lowercaseString hasSuffix:@".jar"];
        NSString *fileName = enabled ? actualFileName : [actualFileName substringToIndex:actualFileName.length - @".disabled".length];
        NSDictionary *record = [records[fileName] isKindOfClass:NSDictionary.class] ? records[fileName] : nil;
        NSMutableDictionary *mod = record ? record.mutableCopy : [NSMutableDictionary new];
        if (mod[@"title"] == nil) {
            mod[@"title"] = fileName.stringByDeletingPathExtension;
        }
        if (mod[@"source"] == nil) {
            mod[@"source"] = @"manual";
        }
        mod[@"fileName"] = fileName;
        mod[@"actualFileName"] = actualFileName;
        mod[@"path"] = [self.modsDir stringByAppendingPathComponent:actualFileName];
        mod[@"enabled"] = @(enabled);
        [installed addObject:mod];
        [seen addObject:fileName];
    }

    for (NSString *fileName in records) {
        if ([seen containsObject:fileName]) {
            continue;
        }
        NSMutableDictionary *record = [records[fileName] mutableCopy];
        record[@"fileName"] = fileName;
        record[@"missing"] = @YES;
        record[@"enabled"] = @NO;
        [installed addObject:record];
    }

    [installed sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSString *aTitle = a[@"title"] ?: a[@"fileName"] ?: @"";
        NSString *bTitle = b[@"title"] ?: b[@"fileName"] ?: @"";
        return [aTitle localizedCaseInsensitiveCompare:bTitle];
    }];
    return installed;
}

- (NSArray<NSMutableDictionary *> *)installedModsMatchingQuery:(NSString *)query {
    NSArray *mods = [self installedMods];
    query = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
    if (query.length == 0) {
        return mods;
    }

    NSMutableArray *result = [NSMutableArray new];
    for (NSMutableDictionary *mod in mods) {
        NSString *title = [mod[@"title"] isKindOfClass:NSString.class] ? mod[@"title"] : @"";
        NSString *fileName = [mod[@"fileName"] isKindOfClass:NSString.class] ? mod[@"fileName"] : @"";
        if ([title.lowercaseString containsString:query] || [fileName.lowercaseString containsString:query]) {
            [result addObject:mod];
        }
    }
    return result;
}

- (BOOL)dependency:(NSDictionary *)dependency matchesMod:(NSDictionary *)mod {
    NSString *dependencySource = dependency[@"source"];
    NSString *modSource = mod[@"source"];
    if (![dependencySource isKindOfClass:NSString.class] ||
        ![modSource isKindOfClass:NSString.class] ||
        ![dependencySource isEqualToString:modSource]) {
        return NO;
    }

    id dependencyProjectId = dependency[@"projectId"];
    id modProjectId = mod[@"projectId"];
    if (dependencyProjectId && modProjectId &&
        [[[dependencyProjectId description] lowercaseString] isEqualToString:[[modProjectId description] lowercaseString]]) {
        return YES;
    }

    id dependencyVersionId = dependency[@"versionId"];
    id modVersionId = mod[@"versionId"];
    if (dependencyVersionId && modVersionId &&
        [[[dependencyVersionId description] lowercaseString] isEqualToString:[[modVersionId description] lowercaseString]]) {
        return YES;
    }
    return NO;
}

- (BOOL)mod:(NSDictionary *)candidate dependsOnAnyModInArray:(NSArray<NSDictionary *> *)mods {
    NSArray *dependencies = [candidate[@"dependencies"] isKindOfClass:NSArray.class] ? candidate[@"dependencies"] : @[];
    for (NSDictionary *dependency in dependencies) {
        if (![dependency isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSString *type = dependency[@"type"];
        if ([type isKindOfClass:NSString.class] &&
            ![type isEqualToString:@"required"] &&
            ![type isEqualToString:@"dependency"]) {
            continue;
        }
        for (NSDictionary *mod in mods) {
            if ([self dependency:dependency matchesMod:mod]) {
                return YES;
            }
        }
    }
    return NO;
}

- (NSString *)identityForInstalledMod:(NSDictionary *)mod {
    NSString *fileName = mod[@"fileName"];
    if ([fileName isKindOfClass:NSString.class] && fileName.length > 0) {
        return [@"file:" stringByAppendingString:fileName.lowercaseString];
    }
    NSString *source = mod[@"source"];
    id projectId = mod[@"projectId"];
    if ([source isKindOfClass:NSString.class] && projectId) {
        return [NSString stringWithFormat:@"%@:%@", source, [[projectId description] lowercaseString]];
    }
    return [NSString stringWithFormat:@"object:%p", mod];
}

- (NSArray<NSDictionary *> *)dependentModsForMod:(NSDictionary *)mod includeDisabled:(BOOL)includeDisabled {
    if (![mod isKindOfClass:NSDictionary.class]) {
        return @[];
    }

    NSMutableArray<NSDictionary *> *affected = [NSMutableArray arrayWithObject:mod];
    NSMutableArray<NSDictionary *> *dependents = [NSMutableArray new];
    NSMutableSet<NSString *> *seen = [NSMutableSet setWithObject:[self identityForInstalledMod:mod]];
    BOOL added = YES;

    while (added) {
        added = NO;
        for (NSDictionary *candidate in [self installedMods]) {
            if ([candidate[@"missing"] boolValue]) {
                continue;
            }
            if (!includeDisabled && ![candidate[@"enabled"] boolValue]) {
                continue;
            }
            NSString *identity = [self identityForInstalledMod:candidate];
            if ([seen containsObject:identity]) {
                continue;
            }
            if ([self mod:candidate dependsOnAnyModInArray:affected]) {
                [seen addObject:identity];
                [affected addObject:candidate];
                [dependents addObject:candidate];
                added = YES;
            }
        }
    }

    return dependents;
}

- (BOOL)moveMod:(NSDictionary *)mod toEnabled:(BOOL)enabled error:(NSError **)error {
    NSString *actualFileName = mod[@"actualFileName"];
    NSString *fileName = mod[@"fileName"];
    if (![self isSafeModFileName:fileName] || ![actualFileName isKindOfClass:NSString.class]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModManagerStore" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid mod file name."}];
        }
        return NO;
    }

    NSString *sourcePath = [self.modsDir stringByAppendingPathComponent:actualFileName];
    NSString *targetName = enabled ? fileName : [fileName stringByAppendingString:@".disabled"];
    NSString *targetPath = [self.modsDir stringByAppendingPathComponent:targetName];
    if ([sourcePath isEqualToString:targetPath]) {
        return YES;
    }

    [NSFileManager.defaultManager removeItemAtPath:targetPath error:nil];
    return [NSFileManager.defaultManager moveItemAtPath:sourcePath toPath:targetPath error:error];
}

- (BOOL)enableMod:(NSDictionary *)mod error:(NSError **)error {
    return [self moveMod:mod toEnabled:YES error:error];
}

- (BOOL)disableMod:(NSDictionary *)mod error:(NSError **)error {
    return [self moveMod:mod toEnabled:NO error:error];
}

- (BOOL)removeMod:(NSDictionary *)mod error:(NSError **)error {
    NSString *actualFileName = mod[@"actualFileName"];
    NSString *fileName = mod[@"fileName"];
    if (![actualFileName isKindOfClass:NSString.class] || ![self isSafeModFileName:fileName]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModManagerStore" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Invalid mod file name."}];
        }
        return NO;
    }

    NSString *path = [self.modsDir stringByAppendingPathComponent:actualFileName];
    BOOL removed = ![NSFileManager.defaultManager fileExistsAtPath:path] ||
        [NSFileManager.defaultManager removeItemAtPath:path error:error];
    if (!removed) {
        return NO;
    }

    NSMutableDictionary *metadata = [self metadataCreatingIfNeeded:YES];
    [metadata[@"mods"] removeObjectForKey:fileName];
    [NSFileManager.defaultManager createDirectoryAtPath:self.profileGameDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSError *saveError = saveJSONToFile(metadata, self.metadataPath);
    if (saveError && error) {
        *error = saveError;
    }
    return saveError == nil;
}

- (BOOL)containsInstalledProjectWithSource:(NSString *)source projectId:(id)projectId {
    if (![source isKindOfClass:NSString.class] || !projectId) {
        return NO;
    }
    NSString *needle = [[projectId description] lowercaseString];
    for (NSDictionary *mod in [self installedMods]) {
        NSString *modSource = mod[@"source"];
        NSString *modProjectId = [mod[@"projectId"] description];
        if ([modSource isEqualToString:source] && [modProjectId.lowercaseString isEqualToString:needle]) {
            return YES;
        }
    }
    return NO;
}

- (NSString *)existingFileNameForSource:(NSString *)source projectId:(id)projectId {
    if (![source isKindOfClass:NSString.class] || !projectId) {
        return nil;
    }
    NSString *needle = [[projectId description] lowercaseString];
    for (NSDictionary *mod in [self installedMods]) {
        NSString *modProjectId = [mod[@"projectId"] description];
        if ([mod[@"source"] isEqualToString:source] && [modProjectId.lowercaseString isEqualToString:needle]) {
            return mod[@"fileName"];
        }
    }
    return nil;
}

- (NSString *)isoTimestamp {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZZZZZ";
    return [formatter stringFromDate:NSDate.date];
}

- (NSDictionary *)installPlanForFiles:(NSArray<NSDictionary *> *)files error:(NSError **)error {
    if (files.count == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModManagerStore" code:3 userInfo:@{NSLocalizedDescriptionKey: @"No mods were selected for installation."}];
        }
        return nil;
    }

    NSMutableArray *downloads = [NSMutableArray new];
    NSMutableArray *manualDownloads = [NSMutableArray new];
    NSMutableArray *records = [NSMutableArray new];
    NSMutableOrderedSet *replaced = [NSMutableOrderedSet orderedSet];
    NSMutableArray *replacements = [NSMutableArray new];
    NSString *installedAt = [self isoTimestamp];

    for (NSDictionary *file in files) {
        NSString *fileName = file[@"fileName"];
        if (![self isSafeModFileName:fileName]) {
            if (error) {
                *error = [NSError errorWithDomain:@"ModManagerStore"
                    code:4
                    userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Invalid mod file name: %@", fileName ?: @""]}];
            }
            return nil;
        }

        NSString *destination = [self.modsDir stringByAppendingPathComponent:fileName];
        NSString *source = file[@"source"] ?: @"manual";
        id projectId = file[@"projectId"];
        NSString *existingFileName = [self existingFileNameForSource:source projectId:projectId];
        if (existingFileName.length > 0 && ![existingFileName isEqualToString:fileName]) {
            [replaced addObject:existingFileName];
            [replacements addObject:@{
                @"oldFileName": existingFileName,
                @"newFileName": fileName
            }];
        }

        NSString *downloadURL = file[@"downloadUrl"];
        NSString *manualURL = file[@"manualUrl"];
        NSString *sha = [file[@"sha1"] isKindOfClass:NSString.class] ? file[@"sha1"] : @"";
        NSNumber *size = [file[@"size"] isKindOfClass:NSNumber.class] ? file[@"size"] : @0;
        NSString *title = [file[@"title"] isKindOfClass:NSString.class] ? file[@"title"] : fileName;

        NSMutableDictionary *record = [NSMutableDictionary new];
        NSArray *recordKeys = @[@"source", @"projectId", @"versionId", @"fileId", @"title", @"versionName", @"summary", @"iconUrl", @"fileName", @"sha1", @"size", @"gameVersion", @"loaders", @"dependencies", @"datePublished"];
        for (NSString *key in recordKeys) {
            id value = file[key];
            if (value && value != NSNull.null) {
                record[key] = value;
            }
        }
        record[@"installedAt"] = installedAt;
        record[@"enabled"] = @YES;
        [records addObject:record];

        if ([downloadURL isKindOfClass:NSString.class] && downloadURL.length > 0) {
            [downloads addObject:@{
                @"title": title,
                @"fileName": fileName,
                @"url": downloadURL,
                @"destinationPath": destination,
                @"sha": sha,
                @"size": size
            }];
        } else if ([manualURL isKindOfClass:NSString.class] && manualURL.length > 0) {
            NSString *temporaryDestination = [destination stringByAppendingString:@".download"];
            [manualDownloads addObject:@{
                @"title": title,
                @"fileName": fileName,
                @"url": manualURL,
                @"destinationPath": temporaryDestination,
                @"finalDestinationPath": destination,
                @"sha": sha
            }];
        } else {
            if (error) {
                *error = [NSError errorWithDomain:@"ModManagerStore"
                    code:5
                    userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"No download URL was available for %@.", title]}];
            }
            return nil;
        }
    }

    return @{
        @"profileName": self.profileName ?: @"",
        @"profileGameDir": self.profileGameDir,
        @"modsDir": self.modsDir,
        @"metadataPath": self.metadataPath,
        @"downloads": downloads,
        @"manualDownloads": manualDownloads,
        @"records": records,
        @"replacedFileNames": replaced.array,
        @"replacements": replacements
    };
}

- (NSError *)saveMetadataRecords:(NSArray<NSDictionary *> *)records
               replacingFileNames:(NSArray<NSString *> *)replacedFileNames
                     replacements:(NSArray<NSDictionary *> *)replacements {
    NSError *error = nil;
    [NSFileManager.defaultManager createDirectoryAtPath:self.modsDir withIntermediateDirectories:YES attributes:nil error:&error];
    if (error) {
        return error;
    }

    NSMutableDictionary *metadata = [self metadataCreatingIfNeeded:YES];
    NSMutableDictionary *mods = metadata[@"mods"];

    NSMutableSet *savedFileNames = [NSMutableSet new];
    for (NSDictionary *record in records) {
        NSString *fileName = record[@"fileName"];
        if (![self isSafeModFileName:fileName]) {
            continue;
        }
        NSString *enabledPath = [self.modsDir stringByAppendingPathComponent:fileName];
        NSString *disabledPath = [enabledPath stringByAppendingString:@".disabled"];
        if (![NSFileManager.defaultManager fileExistsAtPath:enabledPath] &&
            ![NSFileManager.defaultManager fileExistsAtPath:disabledPath]) {
            continue;
        }
        mods[fileName] = record;
        [savedFileNames addObject:fileName];
    }

    if (replacements.count > 0) {
        for (NSDictionary *replacement in replacements) {
            NSString *oldFileName = replacement[@"oldFileName"];
            NSString *newFileName = replacement[@"newFileName"];
            if (![self isSafeModFileName:oldFileName] ||
                ![self isSafeModFileName:newFileName] ||
                ![savedFileNames containsObject:newFileName]) {
                continue;
            }
            NSString *enabledPath = [self.modsDir stringByAppendingPathComponent:oldFileName];
            NSString *disabledPath = [enabledPath stringByAppendingString:@".disabled"];
            [NSFileManager.defaultManager removeItemAtPath:enabledPath error:nil];
            [NSFileManager.defaultManager removeItemAtPath:disabledPath error:nil];
            [mods removeObjectForKey:oldFileName];
        }
    } else if (savedFileNames.count > 0) {
        for (NSString *fileName in replacedFileNames) {
            if (![self isSafeModFileName:fileName]) {
                continue;
            }
            NSString *enabledPath = [self.modsDir stringByAppendingPathComponent:fileName];
            NSString *disabledPath = [enabledPath stringByAppendingString:@".disabled"];
            [NSFileManager.defaultManager removeItemAtPath:enabledPath error:nil];
            [NSFileManager.defaultManager removeItemAtPath:disabledPath error:nil];
            [mods removeObjectForKey:fileName];
        }
    }

    [NSFileManager.defaultManager createDirectoryAtPath:self.profileGameDir withIntermediateDirectories:YES attributes:nil error:&error];
    if (error) {
        return error;
    }
    return saveJSONToFile(metadata, self.metadataPath);
}

@end
