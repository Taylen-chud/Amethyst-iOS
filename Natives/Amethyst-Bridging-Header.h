#ifndef Amethyst_Bridging_Header_h
#define Amethyst_Bridging_Header_h

// System frameworks
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <MetalKit/MetalKit.h>
#import <GameController/GameController.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <AuthenticationServices/AuthenticationServices.h>

// Third-party code that ships in the tree
#import "external/AFNetworking/AFNetworking/AFNetworking.h"
#import "external/AltKit/ALTServerConnection.h"
#import "external/DBNumberedSlider/Classes/DBNumberedSlider.h"
#import "external/NRFileManager/NSFileManager+NRFileManager.h"

// Core
#import "utils.h"
#import "ios_uikit_bridge.h"
#import "LauncherPreferences.h"
#import "PLPreferences.h"
#import "PLProfiles.h"
#import "JavaLauncher.h"
#import "MinecraftResourceUtils.h"
#import "MinecraftResourceDownloadTask.h"
#import "MinecraftOptionUtils.h"
#import "LauncherVersionLists.h"
#import "SurfaceGlobals.h"
#import "JavaRuntimeExtractor.h"
#import "authenticator/BaseAuthenticator.h"
#import "HostManagerBridge.h"
#import "config.h"
#import "renderer_info.h"
#import "jni.h"
#import "glfw_keycodes.h"
#import "KosmicKrispConfig.h"
#import "LWJGLVersions.h"
#import "MobileGLConfig.h"
#import "MoltenVKConfig.h"
#import "RendererCrashTracker.h"
#import "ZinkConfig.h"
#import "UIKit+hook.h"
#import "sdl3_hook.h"
#import "ctxbridges/vk_bridge.h"
#import "TrackedTextField.h"
#import "AWTInputBridge.h"
#import "ObjCExceptionCatcher.h"

// Input bridge
#import "input/ControllerInput.h"
#import "input/GyroInput.h"
#import "input/KeyboardInput.h"

// Installer / modpack API layer
#import "installer/FabricUtils.h"
#import "installer/modpack/ModpackUtils.h"
#import "installer/modpack/ModpackAPI.h"
#import "installer/modpack/ModrinthAPI.h"
#import "installer/modpack/CurseForgeAPI.h"
#import "installer/modpack/ModrinthSearchFilters.h"
#import "installer/modpack/InstalledModsManager.h"
#import "installer/modpack/ModrinthModInstallation.h"

// Custom controls (views and model, the editor itself is Swift)
#import "customcontrols/ControlButton.h"
#import "customcontrols/ControlDrawer.h"
#import "customcontrols/ControlJoystick.h"
#import "customcontrols/ControlLayout.h"
#import "customcontrols/ControlSubButton.h"
#import "customcontrols/CustomControlsUtils.h"
#import "customcontrols/NSPredicateUtilitiesExternal.h"

#endif /* Amethyst_Bridging_Header_h */
