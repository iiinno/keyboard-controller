#ifndef KEYBOARD_CONTROLLER_HID_H
#define KEYBOARD_CONTROLLER_HID_H
#include <stdint.h>
#include <stddef.h>
typedef struct {
    uint64_t entry_id, vendor, product, location;
    char name[512], serial[512], transport[128];
    int built_in, blockable;
} KCDevice;
typedef struct KCHandle KCHandle;
int kc_list(KCDevice **devices, size_t *count);
void kc_free(void *pointer);
int kc_grab(KCDevice expected, KCHandle **handle);
int kc_release(KCHandle *handle);
int kc_pump(KCHandle *handle, double seconds);
int64_t kc_now_ms(void);
int kc_permission(void);
int kc_request_permission(void);
#endif
