//go:build darwin

#include "hid_darwin.h"
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDLib.h>
#include <IOKit/hidsystem/IOHIDLib.h>
#include <mach/mach_time.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

struct KCHandle {
    IOHIDDeviceRef device;
    CFRunLoopRef loop;
    int removed;
};

static uint64_t number(CFDictionaryRef properties, CFStringRef key) {
    CFTypeRef value = CFDictionaryGetValue(properties, key);
    int64_t result = 0;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID())
        CFNumberGetValue(value, kCFNumberSInt64Type, &result);
    return (uint64_t)result;
}

static int string_property(CFDictionaryRef properties, CFStringRef key, char *out, size_t capacity) {
    CFTypeRef value = CFDictionaryGetValue(properties, key);
    out[0] = 0;
    if (!value) return 1;
    if (CFGetTypeID(value) != CFStringGetTypeID()) return 0;
    return CFStringGetCString(value, out, capacity, kCFStringEncodingUTF8);
}

/* Metadata is read from IORegistry without opening or seizing any device. */
static int describe(io_service_t service, KCDevice *out, int *keyboard) {
    CFMutableDictionaryRef properties = NULL;
    IOReturn result = IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0);
    if (result != kIOReturnSuccess) return result;
    memset(out, 0, sizeof(*out));
    *keyboard = 0;
    int pointer = 0, pairs_known = 0;
    uint64_t primary_page = number(properties, CFSTR(kIOHIDPrimaryUsagePageKey));
    uint64_t primary_usage = number(properties, CFSTR(kIOHIDPrimaryUsageKey));
    if (primary_page == 1 && primary_usage == 6) *keyboard = 1;
    CFTypeRef pairs = CFDictionaryGetValue(properties, CFSTR(kIOHIDDeviceUsagePairsKey));
    if (pairs && CFGetTypeID(pairs) == CFArrayGetTypeID()) {
        pairs_known = CFArrayGetCount(pairs) > 0;
        for (CFIndex i = 0; i < CFArrayGetCount(pairs); i++) {
            CFTypeRef pair = CFArrayGetValueAtIndex(pairs, i);
            if (CFGetTypeID(pair) != CFDictionaryGetTypeID()) { pointer = 1; continue; }
            uint64_t page = number(pair, CFSTR(kIOHIDDeviceUsagePageKey));
            uint64_t usage = number(pair, CFSTR(kIOHIDDeviceUsageKey));
            if (page == 1 && usage == 6) *keyboard = 1;
            if (page == 13 || (page == 1 && (usage == 1 || usage == 2))) pointer = 1;
        }
    }
    out->vendor = number(properties, CFSTR(kIOHIDVendorIDKey));
    out->product = number(properties, CFSTR(kIOHIDProductIDKey));
    out->location = number(properties, CFSTR(kIOHIDLocationIDKey));
    int strings_ok = string_property(properties, CFSTR(kIOHIDProductKey), out->name, sizeof(out->name))
        && string_property(properties, CFSTR(kIOHIDSerialNumberKey), out->serial, sizeof(out->serial))
        && string_property(properties, CFSTR(kIOHIDTransportKey), out->transport, sizeof(out->transport));
    /* A built-in USB controller does not make every attached keyboard built-in. */
    CFTypeRef builtin = CFDictionaryGetValue(properties, CFSTR("Built-In"));
    if (builtin) {
        if (CFGetTypeID(builtin) == CFBooleanGetTypeID()) out->built_in = CFBooleanGetValue(builtin);
    }
    out->blockable = *keyboard && pairs_known && !pointer && strings_ok && out->vendor
        && out->product && out->name[0] && strcasecmp(out->transport, "Virtual") != 0
        && strcasestr(out->name, "virtual") == NULL;
    result = IORegistryEntryGetRegistryEntryID(service, &out->entry_id);
    CFRelease(properties);
    if (*keyboard && !strings_ok) return kIOReturnBadArgument; /* Never truncate identity. */
    return result;
}

int kc_list(KCDevice **devices, size_t *count) {
    *devices = NULL; *count = 0;
    io_iterator_t iterator = IO_OBJECT_NULL;
    IOReturn result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator);
    if (result != kIOReturnSuccess) return result;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        KCDevice device; int keyboard = 0;
        result = describe(service, &device, &keyboard);
        IOObjectRelease(service);
        if (result != kIOReturnSuccess) break;
        if (!keyboard) continue;
        if (*count >= 256) { result = kIOReturnNoResources; break; }
        KCDevice *next = realloc(*devices, (*count + 1) * sizeof(KCDevice));
        if (!next) { result = kIOReturnNoMemory; break; }
        *devices = next;
        (*devices)[(*count)++] = device;
    }
    IOObjectRelease(iterator);
    if (result != kIOReturnSuccess) { free(*devices); *devices = NULL; *count = 0; }
    return result;
}

void kc_free(void *pointer) { free(pointer); }

static void input_value(void *context, IOReturn result, void *sender, IOHIDValueRef value) {
    /* Deliberately discard; do not store, log, or synthesize input. */
}
static void removed(void *context, IOReturn result, void *sender) {
    ((KCHandle *)context)->removed = 1;
}

int kc_grab(KCDevice expected, KCHandle **handle) {
    *handle = NULL;
    if (IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted) return kIOReturnNotPermitted;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(expected.entry_id));
    if (!service) return kIOReturnNoDevice;
    KCDevice current; int keyboard = 0;
    IOReturn result = describe(service, &current, &keyboard);
    if (result != kIOReturnSuccess || !current.blockable || current.vendor != expected.vendor
        || current.product != expected.product || current.location != expected.location
        || strcmp(current.name, expected.name) || strcmp(current.serial, expected.serial)
        || strcmp(current.transport, expected.transport)) {
        IOObjectRelease(service); return kIOReturnBadArgument;
    }
    IOHIDDeviceRef device = IOHIDDeviceCreate(kCFAllocatorDefault, service);
    IOObjectRelease(service);
    if (!device) return kIOReturnNoDevice;
    KCHandle *state = calloc(1, sizeof(KCHandle));
    if (!state) { CFRelease(device); return kIOReturnNoMemory; }
    result = IOHIDDeviceOpen(device, kIOHIDOptionsTypeSeizeDevice);
    if (result != kIOReturnSuccess) { free(state); CFRelease(device); return result; }
    state->device = device;
    state->loop = CFRunLoopGetCurrent(); CFRetain(state->loop);
    IOHIDDeviceRegisterInputValueCallback(device, input_value, state);
    IOHIDDeviceRegisterRemovalCallback(device, removed, state);
    IOHIDDeviceScheduleWithRunLoop(device, state->loop, kCFRunLoopDefaultMode);
    *handle = state;
    return kIOReturnSuccess;
}

int kc_release(KCHandle *state) {
    if (!state) return kIOReturnSuccess;
    IOHIDDeviceUnscheduleFromRunLoop(state->device, state->loop, kCFRunLoopDefaultMode);
    IOReturn result = IOHIDDeviceClose(state->device, kIOHIDOptionsTypeNone);
    CFRelease(state->device); CFRelease(state->loop); free(state);
    return result;
}

int kc_pump(KCHandle *state, double seconds) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, true);
    return state->removed ? kIOReturnNoDevice : kIOReturnSuccess;
}

int64_t kc_now_ms(void) {
    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    return (int64_t)(((__uint128_t)mach_continuous_time() * timebase.numer / timebase.denom) / 1000000);
}
int kc_permission(void) { return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent); }
int kc_request_permission(void) { return IOHIDRequestAccess(kIOHIDRequestTypeListenEvent); }
