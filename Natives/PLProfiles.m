#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "utils.h"

static PLProfiles* current;
static NSString * const kPLProfilesSchemaVersionKey = @"amethystProfilesSchemaVersion";
static NSInteger const kPLProfilesSchemaVersion = 2;
static NSString * const kPLProfilesDirectoryPrefix = @"./profiles/";
static NSString * const kPLProfilesLegacyDirectoryPrefix = @"./profile_gamedirs/";

@interface PLProfiles()
@end

@implementation PLProfiles

+ (id)defaultProfiles {
    NSMutableDictionary *defaultProfile = @{
        @"name": @"(Default)",
        @"lastVersionId": @"latest-release"
    }.mutableCopy;
    NSMutableDictionary *profiles = @{
        @"(Default)": defaultProfile
    }.mutableCopy;
    NSMutableDictionary *result = @{
        @"profiles": profiles,
        @"selectedProfile": @"(Default)"
    }.mutableCopy;
    return result;
}

+ (PLProfiles *)current {
    if (!current) {
        [self updateCurrent];
    }
    return current;
}

+ (void)updateCurrent {
    current = [[PLProfiles alloc] initWithCurrentInstance];
}

+ (id)profile:(NSMutableDictionary *)profile resolveKey:(id)key {
   NSString *value = [profile[key] isKindOfClass:NSString.class] ? profile[key] : nil;
    if (value.length > 0) {
        //NSDebugLog(@"[PLProfiles] Applying %@: \"%@\"", key, value);
        return value;
    }

    NSDictionary *valueDefaults = @{
        @"javaVersion": @"0",
        @"gameDir": @"."
    };
    if (valueDefaults[key]) {
        return valueDefaults[key];
    }

    NSDictionary *prefDefaults = @{
        @"defaultTouchCtrl": @"control.default_ctrl",
        @"defaultGamepadCtrl": @"control.default_gamepad_ctrl",
        @"javaArgs": @"java.java_args",
        @"renderer": @"video.renderer"
    };
    return getPrefObject(prefDefaults[key]);
}

+ (id)resolveKeyForCurrentProfile:(id)key {
    return [self profile:self.current.selectedProfile resolveKey:key];
}

- (id)initWithCurrentInstance {
    self = [super init];
    self.profilePath = [@(getenv("POJAV_GAME_DIR")) stringByAppendingPathComponent:@"launcher_profiles.json"];
    self.profileDict = parseJSONFromFile(self.profilePath);
    if (self.profileDict[@"NSErrorObject"]) {
        self.profileDict = PLProfiles.defaultProfiles;
         }
    BOOL legacyMigration = [self.profileDict[kPLProfilesSchemaVersionKey] intValue] < kPLProfilesSchemaVersion;
    BOOL changed = [self normalizeProfilesMigratingLegacySharedRoot:legacyMigration];
    if (changed) {
        NSError *error = saveJSONToFile(self.profileDict, self.profilePath);
        if (error) {
            NSLog(@"[PLProfiles] Failed to save migrated launcher_profiles.json: %@", error.localizedDescription);
        }
    }

    return self;
}

- (NSString *)instanceRootPath {
    return self.profilePath.stringByDeletingLastPathComponent;
}

- (BOOL)isSafeProfileDirectoryIdentifier:(NSString *)identifier {
    if (![identifier isKindOfClass:NSString.class] || identifier.length == 0) {
        return NO;
    }
    return ![identifier containsString:@"/"] &&
        ![identifier containsString:@"\\"] &&
        ![identifier containsString:@":"];
}

- (NSString *)profileIdentifierFromGameDir:(NSString *)gameDir prefix:(NSString *)prefix {
    if (![gameDir isKindOfClass:NSString.class] || ![gameDir hasPrefix:prefix]) {
        return nil;
    }
    NSString *identifier = [gameDir substringFromIndex:prefix.length];
    return [self isSafeProfileDirectoryIdentifier:identifier] ? identifier : nil;
}

- (NSString *)uniqueProfileIdentifierFromCandidate:(NSString *)candidate usedIdentifiers:(NSMutableSet<NSString *> *)usedIdentifiers {
    NSString *identifier = [self isSafeProfileDirectoryIdentifier:candidate] ? candidate : nil;
    if (identifier.length == 0 || [usedIdentifiers containsObject:identifier]) {
        do {
            identifier = NSUUID.UUID.UUIDString.lowercaseString;
        } while ([usedIdentifiers containsObject:identifier]);
    }
    [usedIdentifiers addObject:identifier];
    return identifier;
}

- (NSString *)absolutePathForGameDir:(NSString *)gameDir {
    if (![gameDir isKindOfClass:NSString.class] || gameDir.length == 0) {
        gameDir = @".";
    }
    if ([gameDir hasPrefix:@"/"]) {
        return gameDir.stringByStandardizingPath;
    }
    return [[self.instanceRootPath stringByAppendingPathComponent:gameDir] stringByStandardizingPath];
}

- (NSSet<NSString *> *)sharedRootMigrationExcludedNames {
    return [NSSet setWithArray:@[
        @"launcher_profiles.json",
        @"launcher_preferences.plist",
        @"versions",
        @"libraries",
        @"assets",
        @"indexes",
        @"objects",
        @"custom_gamedir",
        @"profile_gamedirs",
        @"profiles"
    ]];
}

- (BOOL)copyContentsFromDirectory:(NSString *)sourcePath toDirectory:(NSString *)destinationPath excludingNames:(NSSet<NSString *> *)excludedNames {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:sourcePath isDirectory:&isDirectory] || !isDirectory) {
        return NO;
    }

    NSError *error = nil;
    if (![fm createDirectoryAtPath:destinationPath withIntermediateDirectories:YES attributes:nil error:&error]) {
        NSLog(@"[PLProfiles] Failed to create profile directory %@: %@", destinationPath, error.localizedDescription);
        return NO;
    }

    NSArray<NSString *> *contents = [fm contentsOfDirectoryAtPath:sourcePath error:&error];
    if (!contents) {
        NSLog(@"[PLProfiles] Failed to list %@ for profile migration: %@", sourcePath, error.localizedDescription);
        return NO;
    }

    BOOL copiedAny = NO;
    for (NSString *name in contents) {
        if ([excludedNames containsObject:name]) {
            continue;
        }

        NSString *destinationItem = [destinationPath stringByAppendingPathComponent:name];
        if ([fm fileExistsAtPath:destinationItem]) {
            BOOL sourceIsDirectory = NO;
            BOOL destinationIsDirectory = NO;
            NSString *sourceItem = [sourcePath stringByAppendingPathComponent:name];
            [fm fileExistsAtPath:sourceItem isDirectory:&sourceIsDirectory];
            [fm fileExistsAtPath:destinationItem isDirectory:&destinationIsDirectory];
            if (sourceIsDirectory && destinationIsDirectory) {
                copiedAny = [self copyContentsFromDirectory:sourceItem toDirectory:destinationItem excludingNames:nil] || copiedAny;
            }
            continue;
        }

        NSString *sourceItem = [sourcePath stringByAppendingPathComponent:name];
        error = nil;
        if (![fm copyItemAtPath:sourceItem toPath:destinationItem error:&error]) {
            NSLog(@"[PLProfiles] Failed to copy %@ to %@ during profile migration: %@", sourceItem, destinationItem, error.localizedDescription);
            continue;
        }
        copiedAny = YES;
    }
    return copiedAny;
}

- (BOOL)normalizeProfilesMigratingLegacySharedRoot:(BOOL)migrateSharedRoot {
    BOOL changed = NO;
    NSMutableDictionary *profiles = [self.profiles isKindOfClass:NSMutableDictionary.class] ? self.profiles : nil;
    if (!profiles) {
        self.profileDict[@"profiles"] = [NSMutableDictionary new];
        profiles = self.profileDict[@"profiles"];
        changed = YES;
    }

    NSMutableSet<NSString *> *usedIdentifiers = [NSMutableSet new];
    for (NSString *profileKey in profiles.allKeys.copy) {
        id profileObject = profiles[profileKey];
        NSMutableDictionary *profile = [profileObject isKindOfClass:NSMutableDictionary.class] ? profileObject : nil;
        if (!profile && [profileObject isKindOfClass:NSDictionary.class]) {
            profile = [profileObject mutableCopy];
            profiles[profileKey] = profile;
            changed = YES;
        }
        if (!profile) {
            continue;
        }

        NSString *gameDir = [profile[@"gameDir"] isKindOfClass:NSString.class] ? profile[@"gameDir"] : nil;
        NSString *profilesDirIdentifier = [self profileIdentifierFromGameDir:gameDir prefix:kPLProfilesDirectoryPrefix];
        NSString *currentProfileID = [profile[@"amethystProfileId"] isKindOfClass:NSString.class] ? profile[@"amethystProfileId"] : nil;
        NSString *profileID = [self uniqueProfileIdentifierFromCandidate:profilesDirIdentifier ?: currentProfileID usedIdentifiers:usedIdentifiers];
        if (![currentProfileID isEqualToString:profileID]) {
            profile[@"amethystProfileId"] = profileID;
            changed = YES;
        }

        if (![profile[@"name"] isKindOfClass:NSString.class] || [profile[@"name"] length] == 0) {
            profile[@"name"] = profileKey;
            changed = YES;
        }

        NSString *targetGameDir = [kPLProfilesDirectoryPrefix stringByAppendingString:profileID];
        NSString *targetPath = [self absolutePathForGameDir:targetGameDir];

        if (gameDir.length == 0 || [gameDir isEqualToString:@"."]) {
            profile[@"gameDir"] = targetGameDir;
            changed = YES;
            if (migrateSharedRoot) {
                BOOL copied = [self copyContentsFromDirectory:self.instanceRootPath
                                                  toDirectory:targetPath
                                               excludingNames:self.sharedRootMigrationExcludedNames];
                NSLog(@"[PLProfiles] Migrated shared-root profile %@ to %@%@", profileKey, targetGameDir, copied ? @" with copied data" : @"");
            }
            continue;
        }

        if ([gameDir hasPrefix:kPLProfilesLegacyDirectoryPrefix]) {
            NSString *legacyPath = [self absolutePathForGameDir:gameDir];
            profile[@"gameDir"] = targetGameDir;
            changed = YES;
            BOOL copied = [self copyContentsFromDirectory:legacyPath toDirectory:targetPath excludingNames:nil];
            NSLog(@"[PLProfiles] Migrated legacy profile directory %@ for %@ to %@%@", gameDir, profileKey, targetGameDir, copied ? @" with copied data" : @"");
            continue;
        }

        if ([gameDir hasPrefix:kPLProfilesDirectoryPrefix]) {
            if (![gameDir isEqualToString:targetGameDir]) {
                NSString *oldPath = [self absolutePathForGameDir:gameDir];
                profile[@"gameDir"] = targetGameDir;
                changed = YES;
                BOOL copied = [self copyContentsFromDirectory:oldPath toDirectory:targetPath excludingNames:nil];
                NSLog(@"[PLProfiles] Normalized profile directory %@ for %@ to %@%@", gameDir, profileKey, targetGameDir, copied ? @" with copied data" : @"");
            }
            continue;
        }
    }

    if ([self.profileDict[kPLProfilesSchemaVersionKey] intValue] != kPLProfilesSchemaVersion) {
        self.profileDict[kPLProfilesSchemaVersionKey] = @(kPLProfilesSchemaVersion);
        changed = YES;
    }
    return changed;
}

- (id)profiles {
    return self.profileDict[@"profiles"];
}

- (id)selectedProfile {
    return self.profiles[self.selectedProfileName];
}

- (NSString *)selectedProfileName {
    return (id)self.profileDict[@"selectedProfile"];
}

- (void)setSelectedProfileName:(NSString *)name {
    self.profileDict[@"selectedProfile"] = (id)name;
    [self save];
}

- (void)save {
    [self normalizeProfilesMigratingLegacySharedRoot:NO];
    NSError *error = saveJSONToFile(self.profileDict, self.profilePath);
    if (error) {
        NSLog(@"[PLProfiles] Failed to save launcher_profiles.json: %@", error.localizedDescription);
    }
}

@end
