#import "MobileGLConfig.h"
#import "LauncherPreferences.h"

extern char **environ;

// pref, env var, value it gets when the pref is on
static NSArray<NSArray<NSString *> *> *envTable(void) {
    return @[
        @[@"video.mobilegl_fast_shader_load", @"MOBILEGL_ASYNC_OPTIMISTIC_SHADER_STATUS", @"1"],
        @[@"video.mobilegl_buffer_compat", @"MOBILEGL_COHERENT_AS_FLUSH", @"1"],
        @[@"video.mobilegl_relaxed", @"MOBILEGL_RELAXED_SEMANTICS", @"1"],
    ];
}

@implementation MobileGLConfig

+ (void)applyEnvironmentFromPreferences {
    setenv("MOBILEGL_BACKEND_TYPE", "DirectVulkan", 1);

    const char *home = getenv("AME_HOME");
    if (home && *home) {
        NSString *log = [NSString stringWithFormat:@"%s/mobilegl.log", home];
        setenv("MOBILEGL_LOG_FILE_PATH", log.UTF8String, 1);
    }

    // overwrite = 0, whatever's in the java env vars field wins
    for (NSArray<NSString *> *row in envTable()) {
        if (getPrefBool(row[0])) setenv(row[1].UTF8String, row[2].UTF8String, 0);
    }
}

+ (NSString *)activeConfigSummary {
    NSMutableArray *vars = [NSMutableArray new];
    for (char **e = environ; *e; e++) {
        if (strncmp(*e, "MOBILEGL_", 9) == 0) [vars addObject:@(*e)];
    }
    [vars sortUsingSelector:@selector(compare:)];
    return [vars componentsJoinedByString:@" "];
}

@end
