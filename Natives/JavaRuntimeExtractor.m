#import "JavaRuntimeExtractor.h"

#include <lzma.h>
#include <unistd.h>

// https://www.gnu.org/software/tar/manual/html_node/Standard.html
typedef struct {
    char name[100];
    char mode[8];
    char unused1[8+8];
    char size[12];
    char unused2[12+8];
    char typeflag;
    char linkname[100];
    char unused3[6+2+32+32+8+8+155+12];
} TarHeader;

@implementation JavaRuntimeExtractor

+ (NSString *)lzmaErrorDescriptionForCode:(int)code {
    switch (code) {
        case LZMA_MEM_ERROR:
            return @"Memory allocation failed";
        case LZMA_FORMAT_ERROR:
            return @"The input is not in the .xz format";
        case LZMA_OPTIONS_ERROR:
            return @"Unsupported compression options";
        case LZMA_DATA_ERROR:
            return @"Compressed file is corrupt";
        case LZMA_BUF_ERROR:
            return @"Compressed file is truncated or otherwise corrupt";
        default:
            return @"Unknown error, possibly a bug";
    }
}

// Reference: https://github.com/xz-mirror/xz/blob/master/doc/examples/02_decompress.c
+ (NSString *)extractTarXZ:(NSString *)inPath to:(NSString *)outPath progress:(NSProgress *)progress fileProgress:(NSProgress *)fileProgress fileCallback:(void(^)(NSString* name))fileCallback validate:(NSString * _Nullable (^)(NSString *runtimePath))validate {
    NSString *installingDir = [outPath stringByAppendingPathComponent:@".installing"];
    [NSFileManager.defaultManager createDirectoryAtPath:installingDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSInputStream *inFile = [NSInputStream inputStreamWithFileAtPath:inPath];
    [inFile open];

    NSString *msg = nil;
    lzma_stream strm = LZMA_STREAM_INIT;
    lzma_action action = LZMA_RUN;
    uint8_t inbuf[BUFSIZ], outbuf[512];

    lzma_ret ret = lzma_stream_decoder(&strm, UINT64_MAX, LZMA_CONCATENATED);
    if (ret != LZMA_OK) {
        return [self lzmaErrorDescriptionForCode:ret];
    }

    strm.next_in = NULL;
    strm.avail_in = 0;
    strm.next_out = outbuf;
    strm.avail_out = sizeof(outbuf);

    TarHeader currFileHeader;
    NSString *currFileName;
    NSOutputStream *currFileOut;
    NSUInteger currFileOff, currFileSize;

    while (!progress.cancelled) {
        if (strm.avail_in == 0 && inFile.hasBytesAvailable) {
            strm.next_in = inbuf;
            strm.avail_in = [inFile read:inbuf maxLength:sizeof(inbuf)];

            if (strm.avail_in == -1) {
                msg = inFile.streamError.localizedDescription;
                break;
            }

            if (!inFile.hasBytesAvailable) {
                action = LZMA_FINISH;
            }
        }

        ret = lzma_code(&strm, action);
        if (strm.avail_out == 0 || ret == LZMA_STREAM_END) {
            if (currFileOut) {
                size_t remaining = currFileSize - currFileOff;
                size_t write_size = MIN(sizeof(outbuf), remaining);
                currFileOff += write_size;
                // Avoid overloading the main queue
                if (currFileOff % 102400 == 0) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        fileProgress.completedUnitCount = currFileOff;
                        fileCallback(currFileName);
                    });
                }
                if ([currFileOut write:outbuf maxLength:write_size] != write_size) {
                    msg = [NSString stringWithFormat:@"%s: %@", currFileHeader.name, currFileOut.streamError];
                    break;
                } else if (currFileOff >= currFileSize) {
                    [currFileOut close];
                    currFileOut = nil;
                    if ([currFileName isEqualToString:@"./release"]) {
                        msg = validate(outPath);
                        if (msg) goto cleanup;
                    }
                }
            } else {
                memcpy(&currFileHeader, outbuf, sizeof(outbuf));
                if (currFileHeader.name[0] == '\0') {
                    // EOF
                    break;
                }
                NSString *absPath = [NSString stringWithFormat:@"%@/%s", outPath, currFileHeader.name];
                NSError *error = nil;
                switch (currFileHeader.typeflag) {
                    case '0':
                    case '\0': { // File
                        currFileName = @(currFileHeader.name);
                        currFileOff = fileProgress.completedUnitCount = 0;
                        currFileSize = fileProgress.totalUnitCount = strtol(currFileHeader.size, NULL, 8);
                        NSLog(@"[RuntimeUnpack] Extracting %@", currFileName);
                        dispatch_async(dispatch_get_main_queue(), ^{
                            fileCallback(currFileName);
                        });

                        currFileOut = [NSOutputStream outputStreamToFileAtPath:absPath append:NO];
                        [currFileOut open];
                    } break;
                    case '2': { // Symlink
                        symlink(currFileHeader.linkname, currFileHeader.name);
                        //NSLog(@"%s -> %s", currFileHeader.name, currFileHeader.linkname);
                    } break;
                    case '5': { // Folder
                        [NSFileManager.defaultManager createDirectoryAtPath:absPath withIntermediateDirectories:YES attributes:nil error:&error];
                        if (error) {
                            msg = [NSString stringWithFormat:@"%s: %@", currFileHeader.name, error];
                            goto cleanup;
                        }
                    } break;
                    default: // Ignore everything else
                        if (currFileHeader.typeflag < '0' && currFileHeader.typeflag > '7'
                        && (currFileHeader.typeflag != 'x' && currFileHeader.typeflag != 'g')) {
                            msg = [NSString stringWithFormat:@"Invalid typeflag %c", currFileHeader.typeflag];
                            goto cleanup;
                        }
                        NSLog(@"[RuntimeUnpack] Skipped %s (typeflag %c)", currFileHeader.name, currFileHeader.typeflag);
                        break;
                }
            }

            strm.next_out = outbuf;
            strm.avail_out = sizeof(outbuf);

            progress.completedUnitCount = strm.total_in;
        }

        if (ret == LZMA_STREAM_END) {
            break;
        } else if (ret != LZMA_OK) {
            msg = [self lzmaErrorDescriptionForCode:ret];
            break;
        }
    }

cleanup:
    if (msg || progress.cancelled) {
        [NSFileManager.defaultManager removeItemAtPath:outPath error:nil];
    } else {
        [NSFileManager.defaultManager removeItemAtPath:installingDir error:nil];
    }
    lzma_end(&strm);
    [inFile close];
    [currFileOut close];
    return msg;
}

@end
