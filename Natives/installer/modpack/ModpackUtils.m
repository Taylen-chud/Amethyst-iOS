#import "installer/FabricUtils.h"
#import "ModpackUtils.h"

@implementation ModpackUtils

+ (BOOL)isSafeRelativePath:(NSString *)path {
    if (![path isKindOfClass:NSString.class] || path.length == 0) {
        return NO;
    }

    NSString *normalizedPath = [path stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    if ([normalizedPath hasPrefix:@"/"] ||
        [normalizedPath containsString:@":"] ||
        [normalizedPath.pathComponents containsObject:@".."] ||
        [normalizedPath.pathComponents containsObject:@"."]) {
        return NO;
    }

    return YES;
}

+ (BOOL)isVersionInstalled:(NSString *)versionId {
    if (![versionId isKindOfClass:NSString.class] || versionId.length == 0) {
        return NO;
    }

    NSString *localPath = [NSString stringWithFormat:@"%s/versions/%@", getenv("POJAV_GAME_DIR"), versionId];
    BOOL isDirectory = NO;
    return [NSFileManager.defaultManager fileExistsAtPath:localPath isDirectory:&isDirectory] && isDirectory;
}

+ (void)archive:(UZKArchive *)archive extractDirectory:(NSString *)dir toPath:(NSString *)path error:(NSError *__autoreleasing*)error {
    NSString *normalizedDir = [dir stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    if (![self isSafeRelativePath:normalizedDir]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModpackUtils"
                code:1
                userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"Unsafe override directory in modpack manifest: %@", dir]}];
        }
        return;
    }

    [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
        NSString *normalizedArchiveName = [fileInfo.filename stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
        NSString *dirPrefix = [normalizedDir stringByAppendingString:@"/"];
        if (![normalizedArchiveName hasPrefix:dirPrefix] ||
            normalizedArchiveName.length <= dirPrefix.length) {
            return;
        }
        NSString *fileName = [normalizedArchiveName substringFromIndex:dirPrefix.length];
        if (![self isSafeRelativePath:fileName]) {
            if (error) {
                *error = [NSError errorWithDomain:@"ModpackUtils"
                    code:1
                    userInfo:@{NSLocalizedDescriptionKey:
                        [NSString stringWithFormat:@"Unsafe path in modpack archive: %@", fileInfo.filename]}];
            }
            *stop = YES;
            return;
        }
        NSString *destItemPath = [path stringByAppendingPathComponent:fileName];
        NSString *destDirPath = fileInfo.isDirectory ? destItemPath : destItemPath.stringByDeletingLastPathComponent;
        BOOL createdDir = [NSFileManager.defaultManager createDirectoryAtPath:destDirPath
            withIntermediateDirectories:YES
            attributes:nil error:error];
        if (!createdDir) {
            *stop = YES;
            return;
        } else if (fileInfo.isDirectory) {
            return;
        }

        NSOutputStream *outputStream = [NSOutputStream outputStreamToFileAtPath:destItemPath append:NO];
        [outputStream open];
        __block NSError *writeError = nil;
        BOOL extracted = [archive extractBufferedDataFromFile:fileInfo.filename error:error action:^(NSData *dataChunk, CGFloat percentDecompressed) {
            if (writeError) {
                return;
            }

            const uint8_t *bytes = dataChunk.bytes;
            NSUInteger bytesLeft = dataChunk.length;
            while (bytesLeft > 0) {
                NSInteger bytesWritten = [outputStream write:bytes maxLength:bytesLeft];
                if (bytesWritten <= 0) {
                    writeError = outputStream.streamError ?: [NSError errorWithDomain:@"ModpackUtils"
                        code:2
                        userInfo:@{NSLocalizedDescriptionKey:
                            [NSString stringWithFormat:@"Failed to write extracted file: %@", destItemPath]}];
                    return;
                }
                bytes += bytesWritten;
                bytesLeft -= bytesWritten;
            }
        }];
        [outputStream close];
        if (writeError && error) {
            *error = writeError;
        }
        if (!extracted || writeError) {
            [NSFileManager.defaultManager removeItemAtPath:destItemPath error:nil];
        }
        *stop = !extracted || writeError;
        if (!*stop) {
            NSLog(@"[ModpackDL] Extracted %@", fileInfo.filename);
        }
    } error:error];
}

+ (NSDictionary *)infoForDependencies:(NSDictionary *)dependency {
    NSMutableDictionary *info = [NSMutableDictionary new];
    if (![dependency isKindOfClass:NSDictionary.class]) {
        return info;
    }
    NSString *minecraftVersion = dependency[@"minecraft"];
    if (![minecraftVersion isKindOfClass:NSString.class] || minecraftVersion.length == 0) {
        return info;
    }
    if (dependency[@"forge"]) {
        NSString *forgeVersion = dependency[@"forge"];
        if (![forgeVersion isKindOfClass:NSString.class] || forgeVersion.length == 0) {
            info[@"id"] = minecraftVersion;
            return info;
        }
        NSString *minecraftPrefix = [minecraftVersion stringByAppendingString:@"-"];
        NSString *installerVersion = [forgeVersion hasPrefix:minecraftPrefix] ? forgeVersion : [NSString stringWithFormat:@"%@-%@", minecraftVersion, forgeVersion];
        if ([forgeVersion hasPrefix:minecraftPrefix]) {
            forgeVersion = [forgeVersion substringFromIndex:minecraftPrefix.length];
        }
        info[@"id"] = [NSString stringWithFormat:@"%@-forge-%@", minecraftVersion, forgeVersion];
        info[@"installer"] = [NSString stringWithFormat:@"https://maven.minecraftforge.net/net/minecraftforge/forge/%1$@/forge-%1$@-installer.jar", installerVersion];
    } else if (dependency[@"fabric-loader"]) {
        NSString *fabricVersion = dependency[@"fabric-loader"];
        if (![fabricVersion isKindOfClass:NSString.class] || fabricVersion.length == 0) {
            info[@"id"] = minecraftVersion;
            return info;
        }
        info[@"id"] = [NSString stringWithFormat:@"fabric-loader-%@-%@", fabricVersion, minecraftVersion];
        info[@"json"] = [NSString stringWithFormat:FabricUtils.endpoints[@"Fabric"][@"json"], minecraftVersion, fabricVersion];
    } else if (dependency[@"quilt-loader"]) {
        NSString *quiltVersion = dependency[@"quilt-loader"];
        if (![quiltVersion isKindOfClass:NSString.class] || quiltVersion.length == 0) {
            info[@"id"] = minecraftVersion;
            return info;
        }
        info[@"id"] = [NSString stringWithFormat:@"quilt-loader-%@-%@", quiltVersion, minecraftVersion];
        info[@"json"] = [NSString stringWithFormat:FabricUtils.endpoints[@"Quilt"][@"json"], minecraftVersion, quiltVersion];
    } else if (dependency[@"neoforge"]) {
        NSString *neoForgeVersion = dependency[@"neoforge"];
        if (![neoForgeVersion isKindOfClass:NSString.class] || neoForgeVersion.length == 0) {
            info[@"id"] = minecraftVersion;
            return info;
        }
        info[@"id"] = [NSString stringWithFormat:@"neoforge-%@", neoForgeVersion];
        info[@"installer"] = [NSString stringWithFormat:@"https://maven.neoforged.net/releases/net/neoforged/neoforge/%1$@/neoforge-%1$@-installer.jar", neoForgeVersion];
    } else {
        info[@"id"] = minecraftVersion;
    }
    return info;
}

+ (NSDictionary *)infoForCurseForgeMinecraft:(NSDictionary *)minecraft {
    NSMutableDictionary *info = [NSMutableDictionary new];
    if (![minecraft isKindOfClass:NSDictionary.class]) {
        return info;
    }

    NSString *minecraftVersion = minecraft[@"version"];
    if (![minecraftVersion isKindOfClass:NSString.class] || minecraftVersion.length == 0) {
        return info;
    }

    NSDictionary *selectedLoader;
    NSArray *modLoaders = [minecraft[@"modLoaders"] isKindOfClass:NSArray.class] ? minecraft[@"modLoaders"] : @[];
    for (NSDictionary *loader in modLoaders) {
        if (![loader isKindOfClass:NSDictionary.class]) {
            continue;
        }
        if ([loader[@"primary"] respondsToSelector:@selector(boolValue)] && [loader[@"primary"] boolValue]) {
            selectedLoader = loader;
            break;
        }
    }
    if (!selectedLoader) {
        for (NSDictionary *loader in modLoaders) {
            if ([loader isKindOfClass:NSDictionary.class]) {
                selectedLoader = loader;
                break;
            }
        }
    }

    NSString *loaderId = selectedLoader[@"id"];
    if (![loaderId isKindOfClass:NSString.class] || loaderId.length == 0) {
        info[@"id"] = minecraftVersion;
        return info;
    }

    NSString *lowerLoaderId = loaderId.lowercaseString;
    if ([lowerLoaderId hasPrefix:@"forge-"]) {
        NSString *forgeVersion = [loaderId substringFromIndex:@"forge-".length];
        NSString *minecraftPrefix = [minecraftVersion stringByAppendingString:@"-"];
        NSString *installerVersion = [forgeVersion hasPrefix:minecraftPrefix] ? forgeVersion : [NSString stringWithFormat:@"%@-%@", minecraftVersion, forgeVersion];
        if ([forgeVersion hasPrefix:minecraftPrefix]) {
            forgeVersion = [forgeVersion substringFromIndex:minecraftPrefix.length];
        }
        info[@"id"] = [NSString stringWithFormat:@"%@-forge-%@", minecraftVersion, forgeVersion];
        info[@"installer"] = [NSString stringWithFormat:@"https://maven.minecraftforge.net/net/minecraftforge/forge/%1$@/forge-%1$@-installer.jar", installerVersion];
    } else if ([lowerLoaderId hasPrefix:@"fabric-"]) {
        NSString *fabricVersion = [loaderId substringFromIndex:@"fabric-".length];
        info[@"id"] = [NSString stringWithFormat:@"fabric-loader-%@-%@", fabricVersion, minecraftVersion];
        info[@"json"] = [NSString stringWithFormat:FabricUtils.endpoints[@"Fabric"][@"json"], minecraftVersion, fabricVersion];
    } else if ([lowerLoaderId hasPrefix:@"quilt-"]) {
        NSString *quiltVersion = [loaderId substringFromIndex:@"quilt-".length];
        info[@"id"] = [NSString stringWithFormat:@"quilt-loader-%@-%@", quiltVersion, minecraftVersion];
        info[@"json"] = [NSString stringWithFormat:FabricUtils.endpoints[@"Quilt"][@"json"], minecraftVersion, quiltVersion];
    } else if ([lowerLoaderId hasPrefix:@"neoforge-"]) {
        NSString *neoForgeVersion = [loaderId substringFromIndex:@"neoforge-".length];
        info[@"id"] = [NSString stringWithFormat:@"neoforge-%@", neoForgeVersion];
        info[@"installer"] = [NSString stringWithFormat:@"https://maven.neoforged.net/releases/net/neoforged/neoforge/%1$@/neoforge-%1$@-installer.jar", neoForgeVersion];
    } else {
        info[@"id"] = minecraftVersion;
    }

    return info;
}

@end
