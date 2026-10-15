#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define VK_EXPORT __attribute__((visibility("default")))
#define VK_SUCCESS 0
#define VK_ERROR_INITIALIZATION_FAILED (-3)

typedef int32_t VkResult;
typedef void (*PFN_voidFunction)(void);
typedef VkResult (*PFN_createInstance)(const void *, const void *, void **);
typedef VkResult (*PFN_enumerateVersion)(uint32_t *);
typedef VkResult (*PFN_enumerateExtensions)(const char *, uint32_t *, void *);
typedef PFN_voidFunction (*PFN_getInstanceProcAddr)(void *, const char *);

static pthread_once_t driverOnce = PTHREAD_ONCE_INIT;
static void *driverLib;
static PFN_createInstance realCreateInstance;
static PFN_enumerateVersion realEnumerateVersion;
static PFN_enumerateExtensions realEnumerateExtensions;
static PFN_getInstanceProcAddr realGetInstanceProcAddr;

static void *driverSymbol(const char *name) {
    return driverLib ? dlsym(driverLib, name) : NULL;
}

static char loaderAnchor;

static void loadDriver(void) {
    const char *path = getenv("AME_VULKAN_DRIVER");
    char buf[1024];

    if (!path || !*path) {
        Dl_info info;
        if (!dladdr(&loaderAnchor, &info) || !info.dli_fname) return;
        const char *slash = strrchr(info.dli_fname, '/');
        size_t dirLen = slash ? (size_t)(slash - info.dli_fname) + 1 : 0;
        const char *name = "libvulkan.dylib";
        if (dirLen + strlen(name) + 1 > sizeof(buf)) return;
        memcpy(buf, info.dli_fname, dirLen);
        strcpy(buf + dirLen, name);
        path = buf;
    }

    driverLib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!driverLib) return;

    realCreateInstance = (PFN_createInstance)(uintptr_t)driverSymbol("vkCreateInstance");
    realEnumerateVersion = (PFN_enumerateVersion)(uintptr_t)driverSymbol("vkEnumerateInstanceVersion");
    realEnumerateExtensions = (PFN_enumerateExtensions)(uintptr_t)driverSymbol("vkEnumerateInstanceExtensionProperties");
    realGetInstanceProcAddr = (PFN_getInstanceProcAddr)(uintptr_t)driverSymbol("vkGetInstanceProcAddr");
}

static void ensureDriver(void) {
    pthread_once(&driverOnce, loadDriver);
}

VK_EXPORT VkResult vkCreateInstance(const void *createInfo, const void *allocator, void **instance) {
    ensureDriver();
    if (!realCreateInstance) return VK_ERROR_INITIALIZATION_FAILED;
    return realCreateInstance(createInfo, allocator, instance);
}

VK_EXPORT VkResult vkEnumerateInstanceVersion(uint32_t *apiVersion) {
    ensureDriver();
    if (!realEnumerateVersion) return VK_ERROR_INITIALIZATION_FAILED;
    return realEnumerateVersion(apiVersion);
}

VK_EXPORT VkResult vkEnumerateInstanceExtensionProperties(const char *layerName, uint32_t *count, void *properties) {
    ensureDriver();
    if (!realEnumerateExtensions) return VK_ERROR_INITIALIZATION_FAILED;
    return realEnumerateExtensions(layerName, count, properties);
}

// No layers exist on iOS. Reporting zero is what a loader with no layer manifests does.
VK_EXPORT VkResult vkEnumerateInstanceLayerProperties(uint32_t *count, void *properties) {
    (void)properties;
    if (!count) return VK_ERROR_INITIALIZATION_FAILED;
    *count = 0;
    return VK_SUCCESS;
}

VK_EXPORT VkResult vkEnumerateDeviceLayerProperties(void *physicalDevice, uint32_t *count, void *properties) {
    (void)physicalDevice;
    (void)properties;
    if (!count) return VK_ERROR_INITIALIZATION_FAILED;
    *count = 0;
    return VK_SUCCESS;
}

VK_EXPORT PFN_voidFunction vkGetInstanceProcAddr(void *instance, const char *name) {
    ensureDriver();
    if (!name) return NULL;
    if (!strcmp(name, "vkEnumerateInstanceLayerProperties"))
        return (PFN_voidFunction)vkEnumerateInstanceLayerProperties;
    if (!strcmp(name, "vkEnumerateDeviceLayerProperties"))
        return (PFN_voidFunction)vkEnumerateDeviceLayerProperties;
    if (!realGetInstanceProcAddr) return NULL;
    return realGetInstanceProcAddr(instance, name);
}
