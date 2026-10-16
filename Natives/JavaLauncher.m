#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <libgen.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <mach/mach.h>
#include <mach/task.h>
#include <mach/thread_status.h>
#include <mach/exception_types.h>

#include "renderer_info.h"
#include "utils.h"
#include "ctxbridges/vk_preflight.h"

#import "ios_uikit_bridge.h"
#import "JavaLauncher.h"
#import "LauncherPreferences.h"
#import "LWJGLVersions.h"
#import "MinecraftOptionUtils.h"
#import "MobileGLConfig.h"
#import "MoltenVKConfig.h"
#import "KosmicKrispConfig.h"
#import "PLLogOutputView.h"
#import "PLProfiles.h"
#import "ZinkConfig.h"

#define fm NSFileManager.defaultManager

extern char **environ;

BOOL validateVirtualMemorySpace(size_t size) {
    size <<= 20; // convert to MB
    void *map = mmap(0, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    // check if process successfully maps and unmaps a contiguous range
    if(map == MAP_FAILED || munmap(map, size) != 0)
        return NO;
    return YES;
}


void init_loadDefaultEnv() {
    /* Define default env */

    // Silent Caciocavallo NPE error in locating Android-only lib
    setenv("LD_LIBRARY_PATH", "", 1);

    // Ignore mipmap for performance(?) seems does not affect iOS
    //setenv("LIBGL_MIPMAP", "3", 1);

    // Disable overloaded functions hack for Minecraft 1.17+
    setenv("LIBGL_NOINTOVLHACK", "1", 1);

    // Fix white color on banner and sheep, since GL4ES 1.1.5
    setenv("LIBGL_NORMALIZE", "1", 1);

    // Override OpenGL version to 4.1 for Zink
    setenv("MESA_GL_VERSION_OVERRIDE", "4.1", 1);

    // MoltenVK 1.4.3 performance defaults for Apple GPUs.
    // Use setenv(..., 0) so per-profile/user Java environment overrides win.
    setenv("MVK_CONFIG_FAST_MATH_ENABLED", "2", 0);
    setenv("MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS", "1", 0);
    setenv("MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS", "0", 0);
    setenv("MVK_CONFIG_USE_COMMAND_POOLING", "1", 0);
    setenv("MVK_CONFIG_USE_MTLHEAP", "1", 0);
    setenv("MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS", "1", 0);
    setenv("MVK_CONFIG_VK_SEMAPHORE_SUPPORT_STYLE", "1", 0);
    setenv("MVK_CONFIG_RESUME_LOST_DEVICE", "1", 0);
    // errors only, the default info level dumps ~160 lines of extensions on every instance (the verbose graphics pref below raises it)
    setenv("MVK_CONFIG_LOG_LEVEL", "1", 0);

    // Runs JVM in a separate thread
    setenv("HACK_IGNORE_START_ON_FIRST_THREAD", "1", 1);
}

void init_loadCustomEnv() {
    NSString *envvars = getPrefObject(@"java.env_variables");
    if (envvars == nil) return;
    NSLog(@"[JavaLauncher] Reading custom environment variables");
    for (NSString *line in [envvars componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        if (![line containsString:@"="]) {
            NSLog(@"[JavaLauncher] Warning: skipped empty value custom env variable: %@", line);
            continue;
        }
        NSRange range = [line rangeOfString:@"="];
        NSString *key = [line substringToIndex:range.location];
        NSString *value = [line substringFromIndex:range.location+range.length];
        setenv(key.UTF8String, value.UTF8String, 1);
        NSLog(@"[JavaLauncher] Added custom env variable: %@", line);
    }
}

void init_loadCustomJvmFlags(int* argc, const char** argv) {
    NSString *jvmargs = [PLProfiles resolveKeyForCurrentProfile:@"javaArgs"];
    if (jvmargs == nil) return;
    // Make the separator happy
    jvmargs = [jvmargs stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    jvmargs = [@" " stringByAppendingString:jvmargs];

    NSLog(@"[JavaLauncher] Reading custom JVM flags");
    NSArray *argsToPurge = @[@"Xms", @"Xmx", @"d32", @"d64"];
    for (NSString *arg in [jvmargs componentsSeparatedByString:@" -"]) {
        NSString *jvmarg = [arg stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (jvmarg.length == 0) continue;
        BOOL ignore = NO;
        for (NSString *argToPurge in argsToPurge) {
            if ([jvmarg hasPrefix:argToPurge]) {
                NSLog(@"[JavaLauncher] Ignored JVM flag: -%@", jvmarg);
                ignore = YES;
                break;
            }
        }
        if (ignore) continue;

        ++*argc;
        argv[*argc] = [@"-" stringByAppendingString:jvmarg].UTF8String;

        NSLog(@"[JavaLauncher] Added custom JVM flag: %s", argv[*argc]);
    }
}

int launchJVM(NSString *username, id launchTarget, int width, int height, int minVersion) {
    NSLog(@"[JavaLauncher] Beginning JVM launch");

    init_loadDefaultEnv();
    init_loadCustomEnv();

    DeviceGetJITFlags(YES); // refresh JIT flags right after loading env
    BOOL requiresTXMWorkaround = DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM);
    BOOL jit26AlwaysAttached = getPrefBool(@"debug.debug_always_attached_jit");
    if (requiresTXMWorkaround) {
        static void *result;
        if(!result) result = JIT26CreateRegionLegacy(getpagesize());
        if ((uint32_t)(uintptr_t)result != 0x690000E0) {
            munmap(result, getpagesize());
            // we can't continue since legacy script only allows calling breakpoint once
            NSString *inBundleScriptPath = [NSBundle.mainBundle pathForResource:@"UniversalJIT26" ofType:@"js"];
            NSString *lcAppInfoPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"LCAppInfo.plist"];
            NSMutableDictionary *lcAppInfo = [NSMutableDictionary dictionaryWithContentsOfFile:lcAppInfoPath];
            if(lcAppInfo) {
                // if this is inside LiveContainer, we assign script ourselves and prompt user to restart Amethyst
                lcAppInfo[@"jitLaunchScriptJs"] = [[NSData dataWithContentsOfFile:inBundleScriptPath] base64EncodedStringWithOptions:0];
                if([lcAppInfo writeToFile:lcAppInfoPath atomically:YES]) {
                    showDialog(localize(@"Error", nil), @"Amethyst was launched with a legacy script. We have updated the script to Universal, please restart LiveContainer to continue.");
                    [PLLogOutputView handleExitCode:1];
                    return 1;
                }
            }
            [NSFileManager.defaultManager copyItemAtPath:inBundleScriptPath toPath:[NSString stringWithFormat:@"%s/UniversalJIT26.js", getenv("AME_HOME")] error:nil];
            showDialog(localize(@"Error", nil), @"Support for legacy script has been removed. Please switch to Universal JIT script. To import it, long-press on Amethyst when enabling JIT in StikDebug and tap \"Assign Script\", then go to Amethyst's Documents directory and pick it. (on sideloaded StikDebug, the builtin script is named Amethyst-MeloNX.js)");
            [PLLogOutputView handleExitCode:1];
            return 1;
        }
        JIT26SendJITScript([NSString stringWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"UniversalJIT26Extension" ofType:@"js"] encoding:NSUTF8StringEncoding error:nil]);
        JIT26SetDetachAfterFirstBr(!jit26AlwaysAttached);
        // make sure we don't get stuck in EXC_BAD_ACCESS
        task_set_exception_ports(mach_task_self(), EXC_MASK_BAD_ACCESS, 0, EXCEPTION_DEFAULT, MACHINE_THREAD_STATE);
    }
    if (!requiresTXMWorkaround || jit26AlwaysAttached) {
        if (jit26AlwaysAttached) {
            // Only allow StikDebug to catch our breakpoints to prevent any stutters
            task_set_exception_ports(mach_task_self(), EXC_MASK_ALL & ~EXC_MASK_BREAKPOINT, 0,
                EXCEPTION_DEFAULT, THREAD_STATE_NONE);
        }
        // Activate Library Validation bypass for external runtime and dylibs (JNA, etc)
        init_bypassDyldLibValidation();
    } else {
        NSLog(@"[DyldLVBypass] Hook disabled! Loading unsigned dylib will cause code signature error.");
    }

    BOOL launchJar = NO;
    NSString *gameDir;
    NSString *defaultJRETag;
    AMLWJGLVersion *lwjgl = nil;
    BOOL vulkanUnavailable = NO;
    NSCAssert(launchTarget, @"Unexpected nil launchTarget");
    if ([launchTarget isKindOfClass:NSDictionary.class]) {
        // Get preferred Java version from current profile
        int preferredJavaVersion = [PLProfiles resolveKeyForCurrentProfile:@"javaVersion"].intValue;
        if (preferredJavaVersion > 0) {
            if (minVersion > preferredJavaVersion) {
                NSLog(@"[JavaLauncher] Profile's preferred Java version (%d) does not meet the minimum version (%d), dropping request", preferredJavaVersion, minVersion);
            } else {
                NSDebugLog(@"[PLProfiles] Applying javaVersion");
                minVersion = preferredJavaVersion;
            }
        }
        if (minVersion <= 8) {
            defaultJRETag = @"1_16_5_older";
        } else {
            defaultJRETag = @"1_17_newer";
        }


        AMLWJGLSelection *lwjglPick = [AMLWJGLVersions selectForRequiredVersion:launchTarget[@"lwjglVersion"]
                                                                       versionId:launchTarget[@"id"]];
        lwjgl = lwjglPick.version;
        if (lwjglPick.warning) {
            NSLog(@"[LWJGL] %@", lwjglPick.warning);
        }

        // Setup AME_RENDERER
        NSString *renderer = [PLProfiles resolveKeyForCurrentProfile:@"renderer"];
        NSLog(@"[JavaLauncher] RENDERER is set to %@\n", renderer);
        setenv("AME_RENDERER", renderer.UTF8String, 1);

        // Apply Zink-specific environment variables if Zink renderer is selected
        if ([renderer hasPrefix:@"libOSMesa"]) {
            [ZinkConfig applyZinkEnvironmentFromPreferences];
            NSString *configSummary = [ZinkConfig activeConfigSummary];
            NSLog(@"[ZinkConfig] ========== Zink Renderer Active (Mesa 25) ==========");
            NSLog(@"[ZinkConfig] %@", configSummary);
            setenv("ZINK_ACTIVE_CONFIG", configSummary.UTF8String, 1);
        }

       
        if (isMobileGLRenderer(renderer.UTF8String)) {
            [MobileGLConfig applyEnvironmentFromPreferences];
            NSLog(@"[MobileGLConfig] %@", [MobileGLConfig activeConfigSummary]);
        } else {
            unsetenv("MOBILEGL_BACKEND_TYPE");
            unsetenv("MOBILEGL_LOG_FILE_PATH");
        }

        ame_renderer_t vulkanKind = ame_renderer_from_name(renderer.UTF8String);
        if (ame_renderer_is_vulkan_native(vulkanKind)) {
            // env first, the driver reads its config once when it is loaded
            const char *vulkanFile = ame_vulkan_library_file(vulkanKind);
            NSString *vulkanPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:
                                    [@"Frameworks/" stringByAppendingString:[NSString stringWithUTF8String:vulkanFile]]];
            if (vulkanKind == AME_RENDERER_KOSMICKRISP) {
                [KosmicKrispConfig applyEnvironmentFromPreferences];
            } else {
                [MoltenVKConfig applyEnvironmentFromPreferences];
            }

            ame_vk_preflight_t pf = ame_vk_preflight(vulkanPath.UTF8String);
            if (pf.ok) {
                NSLog(@"[Vulkan] %s Vulkan %u.%u.%u, %@", vulkanFile, pf.apiVersion >> 22, (pf.apiVersion >> 12) & 0x3ff, pf.apiVersion & 0xfff,
                      vulkanKind == AME_RENDERER_KOSMICKRISP ? [KosmicKrispConfig activeConfigSummary]
                                                             : [MoltenVKConfig activeConfigSummary]);
            } else {
                NSLog(@"[Vulkan] %s preflight failed: %s", vulkanFile, pf.error);
                vulkanUnavailable = YES;
                renderer = @"auto";
                setenv("AME_RENDERER", "auto", 1);
            }
        }

        // MobileGlues wants a writable dir for its log/cache, the default one is android's /sdcard
        if (!strcmp(renderer.UTF8String, "libmobileglues.dylib") && getenv("AME_HOME")) {
            NSString *mgDir = [NSString stringWithFormat:@"%s/mobileglues", getenv("AME_HOME")];
            [NSFileManager.defaultManager createDirectoryAtPath:mgDir withIntermediateDirectories:YES attributes:nil error:nil];
            setenv("MG_DIR_PATH", mgDir.UTF8String, 1);
        }

        // Setup gameDir
        gameDir = [NSString stringWithFormat:@"%s/instances/%@/%@",
            getenv("AME_HOME"), getPrefObject(@"general.game_directory"),
            [PLProfiles resolveKeyForCurrentProfile:@"gameDir"]]
            .stringByStandardizingPath;
    } else {
        defaultJRETag = @"execute_jar";
        gameDir = @(getenv("GAME_DIR"));
        launchJar = YES;
        // same default a game without lwjglVersion gets
        lwjgl = [AMLWJGLVersions selectForRequiredVersion:nil versionId:nil].version;
    }
    if (!lwjgl) {
        UIKit_returnToSplitView();
        showDialog(localize(@"Error", nil), @"No LWJGL versions are listed in lwjgl_versions.txt, the app bundle is incomplete.");
        return 1;
    }
    NSLog(@"[JavaLauncher] Using LWJGL from %@", lwjgl.folder);
    NSLog(@"[JavaLauncher] Looking for Java %d or later", minVersion);
    NSString *javaHome = getSelectedJavaHome(defaultJRETag, minVersion);

    if (javaHome == nil) {
        UIKit_returnToSplitView();
        BOOL isExecuteJar = [defaultJRETag isEqualToString:@"execute_jar"];
        showDialog(localize(@"Error", nil), [NSString stringWithFormat:localize(@"java.error.missing_runtime", nil),
            isExecuteJar ? [launchTarget lastPathComponent] : PLProfiles.current.selectedProfile[@"lastVersionId"], minVersion]);
        return 1;
    } else if ([javaHome hasPrefix:@(getenv("AME_HOME"))]) {
        // Copy libawt_xawt.dylib
        NSString *dest = [NSString stringWithFormat:@"%@/lib/libawt_xawt.dylib", javaHome];
        NSString *source = [NSString stringWithFormat:@"%@/Frameworks/libawt_xawt.dylib", NSBundle.mainBundle.bundlePath];
        NSError *error;
        [fm removeItemAtPath:dest error:nil];
        [fm copyItemAtPath:source toPath:dest error:&error];
        if (error) {
            NSLog(@"[JavaLauncher] Copy libawt_xawt.dylib failed: %@", error.localizedDescription);
        }
    }

    setenv("JAVA_HOME", javaHome.UTF8String, 1);
    NSLog(@"[JavaLauncher] JAVA_HOME has been set to %@", javaHome);

    int allocmem;
    if (getPrefBool(@"java.auto_ram")) {
        CGFloat autoRatio = getEntitlementValue(@"com.apple.private.memorystatus") ? 0.4 : 0.25;
        allocmem = roundf((NSProcessInfo.processInfo.physicalMemory >> 20) * autoRatio);
    } else {
        allocmem = getPrefInt(@"java.allocated_memory");
    }
    NSLog(@"[JavaLauncher] Max RAM allocation is set to %d MB", allocmem);
    if (!validateVirtualMemorySpace(allocmem)) {
        UIKit_returnToSplitView();
        if (getEntitlementValue(@"com.apple.developer.kernel.increased-memory-limit")) {
            showDialog(localize(@"Error", nil), @"Insufficient contiguous virtual memory space. Lower memory allocation and try again.");
        } else {
            showDialog(localize(@"Error", nil), @"Insufficient contiguous virtual memory space. Increased Memory Limit entitlement is missing, please add it via GetMoreRam app.");
        }
        return 1;
    }

    // Setup options.txt
    [MinecraftOptionUtils setupOptionsAtGameDir:gameDir];
    
    int margc = -1;
    const char *margv[1000];

    margv[++margc] = [NSString stringWithFormat:@"%@/bin/java", javaHome].UTF8String;
    margv[++margc] = "-XstartOnFirstThread";
    if (!launchJar) {
        margv[++margc] = "-Djava.system.class.loader=net.kdt.pojavlaunch.PojavClassLoader";
    }
    margv[++margc] = "-Xms128M";
    margv[++margc] = [NSString stringWithFormat:@"-Xmx%dM", allocmem].UTF8String;
    
    NSString *frameworksPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks"];
    NSString *lwjglNativeSubfolder = lwjgl.nativeSubfolder;
    NSString *javaLibraryPath = frameworksPath;
    if (lwjglNativeSubfolder) {
        javaLibraryPath = [NSString stringWithFormat:@"%@:%@",
                            [frameworksPath stringByAppendingPathComponent:lwjglNativeSubfolder],
                            frameworksPath];
        // sdl3_hook finds libSDL3 through this
        setenv("AME_LWJGL_NATIVE_SUBFOLDER", lwjglNativeSubfolder.UTF8String, 1);
    }
    margv[++margc] = [NSString stringWithFormat:@"-Djava.library.path=%@", javaLibraryPath].UTF8String;

    // video.resolution (percent) for the SDL path, java shrinks the pixel size it reports to minecraft
    margv[++margc] = [NSString stringWithFormat:@"-Damethyst.resolutionScale=%.3f", getPrefFloat(@"video.resolution") / 100.0].UTF8String;

    margv[++margc] = "-Damethyst.noUpcalls=true";

    if (lwjglNativeSubfolder) {
        NSString *sdlDylibPath = [[frameworksPath stringByAppendingPathComponent:lwjglNativeSubfolder] stringByAppendingPathComponent:@"libSDL3_controlify.dylib"];
        if ([fm fileExistsAtPath:sdlDylibPath]) {
            margv[++margc] = [NSString stringWithFormat:@"-Ddev.isxander.sdl.library=%@", sdlDylibPath].UTF8String;
        }
    }
    margv[++margc] = [NSString stringWithFormat:@"-Dpojav.lwjglVersion=%@", lwjgl.folder].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Duser.dir=%@", gameDir].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Duser.home=%s", getenv("AME_HOME")].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Duser.timezone=%@", NSTimeZone.localTimeZone.name].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-DUIScreen.maximumFramesPerSecond=%d", (int)UIScreen.mainScreen.maximumFramesPerSecond].UTF8String;
    margv[++margc] = "-Dorg.lwjgl.glfw.checkThread0=false";
    margv[++margc] = "-Dorg.lwjgl.system.allocator=system";
    //margv[++margc] = "-Dorg.lwjgl.util.NoChecks=true";
    margv[++margc] = "-Dlog4j2.formatMsgNoLookups=true";

    // minecraft runs with no log4j config here so everything under ERROR vanishes, give it a plain console one
    {
        NSString *logCfg = [NSString stringWithFormat:@"%s/log4j2-ame.xml", getenv("AME_HOME")];
        NSString *xml = @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            "<Configuration status=\"WARN\">\n"
            "<Appenders><Console name=\"Console\" target=\"SYSTEM_OUT\" direct=\"true\">\n"
            "<PatternLayout pattern=\"[%d{HH:mm:ss}] [%t/%level] (%logger{1}) %msg{nolookups}%n\"/>\n"
            "</Console></Appenders>\n"
            "<Loggers><Root level=\"info\"><AppenderRef ref=\"Console\"/></Root></Loggers>\n"
            "</Configuration>\n";
        if ([xml writeToFile:logCfg atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
            margv[++margc] = [NSString stringWithFormat:@"-Dlog4j.configurationFile=%@", logCfg].UTF8String;
            margv[++margc] = [NSString stringWithFormat:@"-Damethyst.log4jConfig=%@", logCfg].UTF8String;
        }
    }

    // Preset OpenGL libname
    const char *glLibName = getenv("AME_RENDERER");
    if (glLibName) {
        if (!strcmp(glLibName, "auto") || ame_renderer_is_vulkan_native(ame_renderer_from_name(glLibName))) {
            // workaround only applies to 1.20.2+, MoltenVK games that ask for GL land here too
            glLibName = RENDERER_NAME_MTL_ANGLE;
        }
        margv[++margc] = [NSString stringWithFormat:@"-Dorg.lwjgl.opengl.libname=%s", glLibName].UTF8String;
    }

    // read by GLFWVulkan.glfwVulkanSupported, absent means yes
    if (vulkanUnavailable) margv[++margc] = "-Dame.vulkan.available=false";

    // LWJGL's bare dylib lookup does not search Frameworks, so give it the bundled path of the selected driver
    ame_renderer_t lwjglVulkanKind = ame_renderer_from_name(getenv("AME_RENDERER"));
    NSString *bundledVulkan = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:
                               [@"Frameworks/" stringByAppendingString:[NSString stringWithUTF8String:ame_vulkan_library_file(lwjglVulkanKind)]]];
    if ([fm fileExistsAtPath:bundledVulkan]) {
        margv[++margc] = [NSString stringWithFormat:@"-Dame.vulkan.libpath=%@", bundledVulkan].UTF8String;
    }

    NSString *librariesPath = [NSString stringWithFormat:@"%@/libs", NSBundle.mainBundle.bundlePath];
    margv[++margc] = [NSString stringWithFormat:@"-javaagent:%@/patchjna_agent.jar=", librariesPath].UTF8String;
    if(getPrefBool(@"general.cosmetica")) {
        margv[++margc] = [NSString stringWithFormat:@"-javaagent:%@/arc_dns_injector.jar=23.95.137.176", librariesPath].UTF8String;
    }

    // Workaround random stack guard allocation crashes
    margv[++margc] = "-XX:+UnlockExperimentalVMOptions";
    margv[++margc] = "-XX:+DisablePrimordialThreadGuardPages";

    // On iOS 26, use mirror mapped JIT by default
    if (@available(iOS 26.0, *)) {
        margv[++margc] = "-XX:+MirrorMappedCodeCache";
    }

    // Disable Forge 1.16.x early progress window
    margv[++margc] = "-Dfml.earlyprogresswindow=false";

    // Load java
    NSString *libjlipath8 = [NSString stringWithFormat:@"%@/lib/jli/libjli.dylib", javaHome]; // java 8
    NSString *libjlipath11 = [NSString stringWithFormat:@"%@/lib/libjli.dylib", javaHome]; // java 11+
    BOOL isJava8 = [fm fileExistsAtPath:libjlipath8];
    setenv("INTERNAL_JLI_PATH", (isJava8 ? libjlipath8 : libjlipath11).UTF8String, 1);
    void* libjli = dlopen(getenv("INTERNAL_JLI_PATH"), RTLD_GLOBAL);

    if (!libjli) {
        const char *error = dlerror();
        NSLog(@"[Init] JLI lib = NULL: %s", error);
        UIKit_returnToSplitView();
        showDialog(localize(@"Error", nil), @(error));
        return 1;
    }

    // Setup Caciocavallo
    margv[++margc] = "-Djava.awt.headless=false";
    margv[++margc] = "-Dcacio.font.fontmanager=sun.awt.X11FontManager";
    margv[++margc] = "-Dcacio.font.fontscaler=sun.font.FreetypeFontScaler";
    margv[++margc] = [NSString stringWithFormat:@"-Dcacio.managed.screensize=%dx%d", width, height].UTF8String;
    margv[++margc] = "-Dswing.defaultlaf=javax.swing.plaf.metal.MetalLookAndFeel";
    if (isJava8) {
        // Setup Caciocavallo
        margv[++margc] = "-Dawt.toolkit=net.java.openjdk.cacio.ctc.CTCToolkit";
        margv[++margc] = "-Djava.awt.graphicsenv=net.java.openjdk.cacio.ctc.CTCGraphicsEnvironment";
    } else {
        // Required by Cosmetica to inject DNS
        margv[++margc] = "--add-opens=java.base/java.net=ALL-UNNAMED";

        // Setup Caciocavallo
        margv[++margc] = "-Dawt.toolkit=com.github.caciocavallosilano.cacio.ctc.CTCToolkit";
        margv[++margc] = "-Djava.awt.graphicsenv=com.github.caciocavallosilano.cacio.ctc.CTCGraphicsEnvironment";

        // Required by Caciocavallo17 to access internal API
        margv[++margc] = "--add-exports=java.desktop/java.awt=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.desktop/java.awt.peer=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.desktop/sun.awt.image=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.desktop/sun.java2d=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.desktop/java.awt.dnd.peer=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.desktop/sun.awt=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.desktop/sun.awt.event=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.desktop/sun.awt.datatransfer=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.desktop/sun.font=ALL-UNNAMED";
        margv[++margc] = "--add-exports=java.base/sun.security.action=ALL-UNNAMED";
        margv[++margc] = "--add-opens=java.base/java.util=ALL-UNNAMED";
        margv[++margc] = "--add-opens=java.desktop/java.awt=ALL-UNNAMED";
        margv[++margc] = "--add-opens=java.desktop/sun.font=ALL-UNNAMED";
        margv[++margc] = "--add-opens=java.desktop/sun.java2d=ALL-UNNAMED";
        margv[++margc] = "--add-opens=java.base/java.lang.reflect=ALL-UNNAMED";

        // TODO: workaround, will be removed once the startup part works without PLaunchApp
        margv[++margc] = "--add-exports=cpw.mods.bootstraplauncher/cpw.mods.bootstraplauncher=ALL-UNNAMED";
    }

    // Add Caciocavallo bootclasspath
    NSString *cacio_classpath = [NSString stringWithFormat:@"-Xbootclasspath/%s", isJava8 ? "p" : "a"];
    NSString *cacio_libs_path = [NSString stringWithFormat:@"%@/libs_caciocavallo%s", NSBundle.mainBundle.bundlePath, isJava8 ? "" : "17"];
    NSArray *files = [fm contentsOfDirectoryAtPath:cacio_libs_path error:nil];
    for(NSString *file in files) {
        if ([file hasSuffix:@".jar"]) {
            cacio_classpath = [NSString stringWithFormat:@"%@:%@/%@", cacio_classpath, cacio_libs_path, file];
        }
    }
    margv[++margc] = cacio_classpath.UTF8String;

    // FIXME: the JVM arg is deprecated; and it is currently broken for Java 25
    if (!getenv("JVM_KEEP_UseCompressedClassPointers") || !getEntitlementValue(@"com.apple.developer.kernel.extended-virtual-addressing")) {
        // In jailed environment, where extended virtual addressing entitlement isn't
        // present (for free dev account), allocating compressed space fails.
        // FIXME: does extended VA allow allocating compressed class space?
        margv[++margc] = "-XX:-UseCompressedClassPointers";
    }

    if ([launchTarget isKindOfClass:NSDictionary.class]) {
        for (NSString *arg in launchTarget[@"arguments"][@"jvm_processed"]) {
            margv[++margc] = arg.UTF8String;
        }
    }

    init_loadCustomJvmFlags(&margc, (const char **)margv);
    NSLog(@"[Init] Found JLI lib");

    NSString *classpath;
    if (lwjglNativeSubfolder) {
        classpath = [NSString stringWithFormat:@"%@/%@/*:%@/*",
                     librariesPath, lwjglNativeSubfolder, librariesPath];
    } else {
        classpath = [NSString stringWithFormat:@"%@/*", librariesPath];
    }
    if (launchJar) {
        classpath = [classpath stringByAppendingFormat:@":%@", launchTarget];
    }
    margv[++margc] = "-cp";
    margv[++margc] = classpath.UTF8String;
    margv[++margc] = "net.kdt.pojavlaunch.PojavLauncher";

    if (launchJar) {
        margv[++margc] = "-jar";
    } else {
        margv[++margc] = username.UTF8String;
    }

    if ([launchTarget isKindOfClass:NSDictionary.class]) {
        margv[++margc] = [launchTarget[@"id"] UTF8String];
    } else {
        margv[++margc] = [launchTarget UTF8String];
    }
    //margv[++margc] = "ghidra.GhidraRun";

    pJLI_Launch = (JLI_Launch_func *)dlsym(libjli, "JLI_Launch");

    if (NULL == pJLI_Launch) {
        NSLog(@"[Init] JLI_Launch = NULL");
        return -2;
    }

    NSLog(@"[Init] Calling JLI_Launch");

    // Cr4shed known issue: exit after crash dump,
    // reset signal handler so that JVM can catch them
    signal(SIGSEGV, SIG_DFL);
    signal(SIGPIPE, SIG_DFL);
    signal(SIGBUS, SIG_DFL);
    signal(SIGILL, SIG_DFL);
    signal(SIGFPE, SIG_DFL);

    // Free split VC
    tmpRootVC = nil;

    return pJLI_Launch(++margc, margv,
                   0, NULL, // sizeof(const_jargs) / sizeof(char *), const_jargs,
                   0, NULL, // sizeof(const_appclasspath) / sizeof(char *), const_appclasspath,
                   // These values are ignored in Java 17, so keep it anyways
                   "1.8.0-internal",
                   "1.8",

                   "java", "openjdk",
                   /* (const_jargs != NULL) ? JNI_TRUE : */ JNI_FALSE,
                   JNI_TRUE, JNI_FALSE, JNI_TRUE);
}
