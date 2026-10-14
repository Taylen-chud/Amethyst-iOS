#import "KosmicKrispConfig.h"
#import "LauncherPreferences.h"

extern char **environ;

// Kosmic Krisp is Mesa code, so its knobs are MESA_* variables. The MVK_CONFIG_* toggles
// in MoltenVKConfig do nothing for this driver, so there is no matching preference here.
@implementation KosmicKrispConfig

+ (void)applyEnvironmentFromPreferences {
    NSString *custom = getPrefObject(@"java.env_variables") ?: @"";

    // Shader cache lives in the app's own support dir so it survives launches and is easy to clear
    NSString *home = [NSString stringWithUTF8String:getenv("AME_HOME") ?: ""];
    if (home.length && ![custom containsString:@"MESA_SHADER_CACHE_DIR="]) {
        NSString *cacheDir = [home stringByAppendingPathComponent:@"mesa_shader_cache"];
        [NSFileManager.defaultManager createDirectoryAtPath:cacheDir withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("MESA_SHADER_CACHE_DIR", cacheDir.UTF8String, 1);
    }

    // Verbose graphics logging also sends Mesa's own log to a file the user can attach to a bug report
    if (getPrefBool(@"debug.debug_verbose_graphics_logging") && home.length
        && ![custom containsString:@"MESA_LOG_FILE="]) {
        NSString *logFile = [home stringByAppendingPathComponent:@"kosmickrisp_mesa.log"];
        setenv("MESA_LOG_FILE", logFile.UTF8String, 1);
    }

    // MESA_VK_ABORT_ON_DEVICE_LOSS is deliberately never set here, it kills the process on
    // device loss and would hide the log we want to read.
}

+ (NSString *)activeConfigSummary {
    NSMutableArray *vars = [NSMutableArray new];
    for (char **e = environ; *e; e++) {
        if (strncmp(*e, "MESA_", 5) == 0) [vars addObject:@(*e)];
    }
    [vars sortUsingSelector:@selector(compare:)];
    return [vars componentsJoinedByString:@" "];
}

@end
