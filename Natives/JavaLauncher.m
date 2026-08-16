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

#include "utils.h"

#import "ios_uikit_bridge.h"
#import "JavaLauncher.h"
#import "LauncherPreferences.h"
#import "MinecraftOptionUtils.h"
#import "PLLogOutputView.h"
#import "PLProfiles.h"

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

// Some builds of libMobileGL.dylib reference __ZNSt3__113__hash_memoryEPKvm
// (std::__1::__hash_memory) as a two-level-namespace symbol expected to live
// in /usr/lib/libc++.1.dylib. On devices where the system libc++ doesn't
// export that symbol, dyld refuses to load libMobileGL.dylib at all with
// "Symbol not found: __ZNSt3__113__hash_memoryEPKvm", which surfaces to us
// as an UnsatisfiedLinkError when LWJGL tries to load OpenGL.
//
// We can't edit libMobileGL itself, so instead we:
//   1. dlopen() a small shim dylib (libcxx_hash_shim.dylib, bundled in
//      Frameworks/) with RTLD_GLOBAL, which exports that exact symbol.
//   2. Set DYLD_FORCE_FLAT_NAMESPACE=1 so dyld resolves the unresolved
//      reference against any loaded image (our shim) instead of insisting
//      on libc++.1.dylib specifically.
//
// This must run before anything dlopen()s libMobileGL.dylib - in practice
// that happens later, inside LWJGL's native library loader once the JVM is
// running - so doing it here, before JLI_Launch, is early enough.
static void init_libcxxHashShim() {
    setenv("DYLD_FORCE_FLAT_NAMESPACE", "1", 1);

    NSString *shimPath = [NSString stringWithFormat:@"%@/Frameworks/libcxx_hash_shim.dylib", NSBundle.mainBundle.bundlePath];
    if (![fm fileExistsAtPath:shimPath]) {
        NSLog(@"[JavaLauncher] libcxx_hash_shim.dylib not found at %@, skipping (MobileGL may fail to load on this device)", shimPath);
        return;
    }

    void *shim = dlopen(shimPath.UTF8String, RTLD_GLOBAL | RTLD_NOW);
    if (!shim) {
        NSLog(@"[JavaLauncher] Failed to load libcxx_hash_shim.dylib: %s", dlerror());
        return;
    }
    NSLog(@"[JavaLauncher] Loaded libcxx_hash_shim.dylib for MobileGL libc++ symbol compatibility");
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
    init_libcxxHashShim();

    DeviceGetJITFlags(YES); // refresh JIT flags right after loading env
    BOOL requiresTXMWorkaround = DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM);
    BOOL jit26AlwaysAttached = getPrefBool(@"debug.debug_always_attached_jit");
    if (requiresTXMWorkaround) {
        static void *result;
        if(!result) result = JIT26CreateRegionLegacy(getpagesize());
        if ((uint32_t)result != 0x690000E0) {
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
            [NSFileManager.defaultManager copyItemAtPath:inBundleScriptPath toPath:[NSString stringWithFormat:@"%s/UniversalJIT26.js", getenv("POJAV_HOME")] error:nil];
            showDialog(localize(@"Error", nil), @"Support for legacy script has been removed. Please switch to Universal JIT script. To import it, long-press on Amethyst when enabling JIT in StikDebug and tap \"Assign Script\", then go to Amethyst's Documents directory and pick it. (on sideloaded StikDebug, the builtin script is named Amethyst-MeloNX.js)");
            [PLLogOutputView handleExitCode:1];
            return 1;
        }
        JIT26SendJITScript([NSString stringWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"UniversalJIT26Extension" ofType:@"js"]]);
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
    NSString *lwjglFolder = @"lwjgl-3.3.3";
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

        // Determine LWJGL version based on explicitly recorded lwjglVersion or fallback rules
        NSString *lwjglVersionStr = launchTarget[@"lwjglVersion"];
        if ([lwjglVersionStr isKindOfClass:NSString.class] && lwjglVersionStr.length > 0) {
            NSArray<NSString *> *lwjglVersion = [lwjglVersionStr componentsSeparatedByString:@"."];
            int lwjglMajor = lwjglVersion.count > 0 ? [lwjglVersion[0] intValue] : 0;
            int lwjglMinor = lwjglVersion.count > 1 ? [lwjglVersion[1] intValue] : 0;
            if (lwjglMajor > 3 || (lwjglMajor == 3 && lwjglMinor >= 4)) {
                lwjglFolder = @"lwjgl-3.4.1";
            } else {
                lwjglFolder = @"lwjgl-3.3.3";
            }
        } else {
            // Fallback: Parse Minecraft version ID cleanly (e.g. "1.21.11" or "26.1")
            NSString *versionId = launchTarget[@"id"];
            lwjglFolder = @"lwjgl-3.3.3"; // Default safety net for 1.x versions

            if ([versionId isKindOfClass:NSString.class]) {
                NSArray<NSString *> *components = [versionId componentsSeparatedByString:@"."];
                if (components.count > 0) {
                    int major = [components[0] intValue];
                    // If major version is >= 26 force 3.4.1
                    if (major >= 26) {
                        lwjglFolder = @"lwjgl-3.4.1";
                    }
                }
            }
        }
        NSLog(@"[JavaLauncher] Using LWJGL from %@", lwjglFolder);

        // Setup POJAV_RENDERER
        NSString *renderer = [PLProfiles resolveKeyForCurrentProfile:@"renderer"];
        NSLog(@"[JavaLauncher] RENDERER is set to %@\n", renderer);
        setenv("POJAV_RENDERER", renderer.UTF8String, 1);
        if (isMobileGLRenderer(renderer.UTF8String)) {
            setenv("MOBILEGL_BACKEND_TYPE",
                [renderer isEqualToString:@ RENDERER_NAME_MOBILEGL_GLES] ? "DirectGLES" : "DirectVulkan",
                1);
            const char *pojavHome = getenv("POJAV_HOME");
            if (pojavHome && *pojavHome) {
                NSString *mobileGLLogPath = [NSString stringWithFormat:@"%s/mobilegl.log", pojavHome];
                setenv("MOBILEGL_LOG_FILE_PATH", mobileGLLogPath.UTF8String, 1);
            }
        } else {
            unsetenv("MOBILEGL_BACKEND_TYPE");
            unsetenv("MOBILEGL_LOG_FILE_PATH");
        }
        // Setup gameDir
        gameDir = [NSString stringWithFormat:@"%s/instances/%@/%@",
            getenv("POJAV_HOME"), getPrefObject(@"general.game_directory"),
            [PLProfiles resolveKeyForCurrentProfile:@"gameDir"]]
            .stringByStandardizingPath;

        [MinecraftOptionUtils setupOptionsAtGameDir:gameDir];
    } else {
        defaultJRETag = @"execute_jar";
        gameDir = @(getenv("POJAV_GAME_DIR"));
        launchJar = YES;
    }
    NSLog(@"[JavaLauncher] Looking for Java %d or later", minVersion);
    NSString *javaHome = getSelectedJavaHome(defaultJRETag, minVersion);

    if (javaHome == nil) {
        UIKit_returnToSplitView();
        BOOL isExecuteJar = [defaultJRETag isEqualToString:@"execute_jar"];
        showDialog(localize(@"Error", nil), [NSString stringWithFormat:localize(@"java.error.missing_runtime", nil),
            isExecuteJar ? [launchTarget lastPathComponent] : PLProfiles.current.selectedProfile[@"lastVersionId"], minVersion]);
        return 1;
    } else if ([javaHome hasPrefix:@(getenv("POJAV_HOME"))]) {
        // Symlink libawt_xawt.dylib
        NSString *dest = [NSString stringWithFormat:@"%@/lib/libawt_xawt.dylib", javaHome];
        NSString *source = [NSString stringWithFormat:@"%@/Frameworks/libawt_xawt.dylib", NSBundle.mainBundle.bundlePath];
        NSError *error;
        [fm createSymbolicLinkAtPath:dest withDestinationPath:source error:&error];
        if (error) {
            NSLog(@"[JavaLauncher] Symlink libawt_xawt.dylib failed: %@", error.localizedDescription);
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

    int margc = -1;
    const char *margv[1000];

    margv[++margc] = [NSString stringWithFormat:@"%@/bin/java", javaHome].UTF8String;
    margv[++margc] = "-XstartOnFirstThread";
    if (!launchJar) {
        margv[++margc] = "-Djava.system.class.loader=net.kdt.pojavlaunch.PojavClassLoader";
    }
    margv[++margc] = "-Xms128M";
    margv[++margc] = [NSString stringWithFormat:@"-Xmx%dM", allocmem].UTF8String;
    NSString *lwjglNativesFolder = [lwjglFolder isEqualToString:@"lwjgl-3.4.1"] ? @"lwjgl34" : @"lwjgl33";
    margv[++margc] = [NSString stringWithFormat:@"-Djava.library.path=%@/Frameworks:%@/Frameworks/%@", NSBundle.mainBundle.bundlePath, NSBundle.mainBundle.bundlePath, lwjglNativesFolder].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Duser.dir=%@", gameDir].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Duser.home=%s", getenv("POJAV_HOME")].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-Duser.timezone=%@", NSTimeZone.localTimeZone.name].UTF8String;
    margv[++margc] = [NSString stringWithFormat:@"-DUIScreen.maximumFramesPerSecond=%d", (int)UIScreen.mainScreen.maximumFramesPerSecond].UTF8String;
    margv[++margc] = "-Dorg.lwjgl.glfw.checkThread0=false";
    margv[++margc] = "-Dorg.lwjgl.system.allocator=system";
    margv[++margc] = "-Dorg.lwjgl.spvc.libname=spirv-cross-c-shared.0.68.0";
    margv[++margc] = "-Dorg.lwjgl.util.NoChecks=true";
    margv[++margc] = "-Dlog4j2.formatMsgNoLookups=true";
    // Preset OpenGL libname. NOTE: this is only the initial value - GLFW's
    // native init (pojavInitOpenGL/pojavSetWindowHint in egl_bridge.m) calls
    // JNI_LWJGL_changeRenderer() later, on the render thread, which
    // overwrites this same system property via a direct JNI
    // System.setProperty() call. That's the one GL.create() actually ends up
    // seeing in practice, so the equivalent absolute-path fix needs to stay
    // in sync in both places - see the comment on JNI_LWJGL_changeRenderer.
    const char *glLibName = getenv("POJAV_RENDERER");
    if (glLibName) {
        if (!strcmp(glLibName, "auto")) {
            // workaround only applies to 1.20.2+
            glLibName = RENDERER_NAME_MTL_ANGLE;
        }

        // Pass the FULL ABSOLUTE PATH to the renderer dylib rather than a bare
        // name. LWJGL's Library.loadNative() has an isAbsolute() fast path
        // that, when it matches, loads the file directly with zero name
        // decoration - completely skipping Platform.mapLibraryName() /
        // System.mapLibraryName(). That matters here because on this custom
        // iOS OpenJDK build, System.mapLibraryName() has been observed to
        // double-decorate an already-bare name (e.g. "MobileGL-gles" comes
        // back as "liblibMobileGL-gles.dylib.dylib" instead of
        // "libMobileGL-gles.dylib"), which is a bug in the JDK build itself,
        // not something fixable from this side - so instead of feeding it a
        // name for it to decorate (correctly or not), we skip that whole
        // codepath. glLibName here (e.g. "libMobileGL-gles.dylib") is always
        // exactly the filename the Makefile copies into Frameworks/, so we
        // can point straight at it.
        NSString *glLibPath = [NSString stringWithFormat:@"%@/Frameworks/%s", NSBundle.mainBundle.bundlePath, glLibName];
        NSLog(@"[JavaLauncher] POJAV_RENDERER=%s -> org.lwjgl.opengl.libname=%@", glLibName, glLibPath);
        // NOTE: .UTF8String on a temporary/autoreleased NSString returns a
        // pointer into THAT OBJECT'S OWN internal buffer - valid only as
        // long as the object itself stays alive. margv is read much later,
        // at the very bottom of this function, after dozens more NSString
        // allocations happen in between (Caciocavallo classpath, custom JVM
        // flags, etc). If this particular autoreleased string's backing
        // memory gets reclaimed/reused before then, margv ends up pointing
        // at stale data instead of what we just logged above. strdup() onto
        // the heap so this entry can't be invalidated by anything that
        // happens later in this function - it's a small permanent
        // allocation, intentionally never freed, same lifetime as the
        // process.
        margv[++margc] = strdup([NSString stringWithFormat:@"-Dorg.lwjgl.opengl.libname=%@", glLibPath].UTF8String);
    }

    NSString *librariesPath = [NSString stringWithFormat:@"%@/libs", NSBundle.mainBundle.bundlePath];
    margv[++margc] = [NSString stringWithFormat:@"-javaagent:%@/patchjna_agent.jar=", librariesPath].UTF8String;
    if(getPrefBool(@"general.cosmetica")) {
        margv[++margc] = [NSString stringWithFormat:@"-javaagent:%@/arc_dns_injector.jar=23.95.137.176", librariesPath].UTF8String;
    }
if (getPrefBool(@"video.fix_simple_voice_chat_mod")) {
        margv[++margc] = [NSString stringWithFormat:@"-javaagent:%@/patchsvc.jar=", librariesPath].UTF8String;
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
        // LWJGL's MemoryUtil prefers Unsafe, then reflection into java.nio.DirectByteBuffer,
        // and only falls back to a native JNI call (JNINativeInterface.nNewDirectByteBuffer)
        // as a last resort - which isn't implemented in our vendored liblwjgl.dylib. Without
        // this add-opens, the reflection fallback is blocked by module encapsulation, so
        // MemoryUtil falls through to that broken native path and crashes on LWJGL 3.4.1.
        margv[++margc] = "--add-opens=java.base/java.nio=ALL-UNNAMED";
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

    NSMutableString *classpath = [NSMutableString string];
    NSArray *libJars = [fm contentsOfDirectoryAtPath:librariesPath error:nil];
    for (NSString *jarFile in libJars) {
        if (![jarFile hasSuffix:@".jar"]) continue;
        if ([jarFile hasPrefix:@"lwjgl-3."]) continue; // skip both versioned lwjgl jars here
        [classpath appendFormat:@"%@/%@:", librariesPath, jarFile];
    }
    [classpath appendFormat:@"%@/%@/*", librariesPath, lwjglFolder];
    if (launchJar) {
        [classpath appendFormat:@":%@", launchTarget];
    }

    // DEBUG: dump the resolved classpath, and what's actually sitting in the
    // top-level libs
    NSLog(@"[JavaLauncher][DEBUG] classpath = %@", classpath);
    NSLog(@"[JavaLauncher][DEBUG] librariesPath = %@", librariesPath);
    NSArray *topLevelJars = [fm contentsOfDirectoryAtPath:librariesPath error:nil];
    NSLog(@"[JavaLauncher][DEBUG] top-level libs/ contents: %@", topLevelJars);
    NSString *lwjglSubPath = [NSString stringWithFormat:@"%@/%@", librariesPath, lwjglFolder];
    NSArray *lwjglJars = [fm contentsOfDirectoryAtPath:lwjglSubPath error:nil];
    NSLog(@"[JavaLauncher][DEBUG] %@ contents: %@", lwjglFolder, lwjglJars);

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

    
    if (getPrefBool(@"video.sodium_compatibility")) {
        const char *currentRenderer = getenv("POJAV_RENDERER");
        char *savedRenderer = currentRenderer ? strdup(currentRenderer) : NULL;
        unsetenv("POJAV_RENDERER");
        if (savedRenderer) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                setenv("POJAV_RENDERER", savedRenderer, 1);
                free(savedRenderer);
            });
        }
    }

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
