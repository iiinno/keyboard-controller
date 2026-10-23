//go:build darwin

package main

/*
#cgo CFLAGS: -mmacosx-version-min=13.0
#cgo LDFLAGS: -mmacosx-version-min=13.0 -framework IOKit -framework CoreFoundation
#include "hid_darwin.h"
*/
import "C"

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"time"
	"unsafe"
)

type darwinBackend struct {
	handle  *C.KCHandle
	devices map[string]C.KCDevice
}

func newBackend() (Backend, error) { return &darwinBackend{devices: map[string]C.KCDevice{}}, nil }

func macDevice(raw C.KCDevice) Device {
	name, serial, transport := C.GoString(&raw.name[0]), C.GoString(&raw.serial[0]), C.GoString(&raw.transport[0])
	return Device{ID: deviceID("darwin", name, serial, transport, fmt.Sprint(uint64(raw.vendor)), fmt.Sprint(uint64(raw.product)), fmt.Sprint(uint64(raw.location))), Name: name,
		Locator: strconv.FormatUint(uint64(raw.entry_id), 10), BuiltIn: raw.built_in != 0, Blockable: raw.blockable != 0}
}

func (b *darwinBackend) Devices() ([]Device, error) {
	var raw *C.KCDevice
	var count C.size_t
	result := C.kc_list(&raw, &count)
	if result != 0 {
		return nil, fmt.Errorf("IORegistry enumeration failed: 0x%08x", uint32(result))
	}
	defer C.kc_free(unsafe.Pointer(raw))
	found := make([]Device, 0, int(count))
	b.devices = map[string]C.KCDevice{}
	if count > 0 {
		for _, record := range unsafe.Slice(raw, int(count)) {
			d := macDevice(record)
			found = append(found, d)
			b.devices[d.Locator] = record
		}
	}
	return found, nil
}

func (b *darwinBackend) Grab(d Device) error {
	if b.handle != nil {
		return errors.New("a keyboard is already seized")
	}
	raw, ok := b.devices[d.Locator]
	if !ok || !d.Blockable || macDevice(raw).ID != d.ID {
		return errors.New("keyboard identity changed; refusing to seize")
	}
	if os.Geteuid() != 0 {
		return errors.New("macOS requires administrator privileges to seize a keyboard; run with sudo and an explicit --config path")
	}
	result := C.kc_grab(raw, &b.handle)
	if result != 0 {
		return fmt.Errorf("IOHIDDeviceOpen failed: 0x%08x; check Input Monitoring permission or another keyboard utility", uint32(result))
	}
	return nil
}

func (b *darwinBackend) Release() error {
	if b.handle == nil {
		return nil
	}
	handle := b.handle
	b.handle = nil
	result := C.kc_release(handle)
	if result != 0 {
		return fmt.Errorf("IOHIDDeviceClose failed: 0x%08x", uint32(result))
	}
	return nil
}
func (b *darwinBackend) Pump(delay time.Duration) error {
	if b.handle == nil {
		time.Sleep(delay)
		return nil
	}
	result := C.kc_pump(b.handle, C.double(delay.Seconds()))
	if result != 0 {
		return fmt.Errorf("IOHID keyboard disconnected: 0x%08x", uint32(result))
	}
	return nil
}
func (b *darwinBackend) NowMS() int64 { return int64(C.kc_now_ms()) }
func (b *darwinBackend) PermissionStatus() string {
	switch C.kc_permission() {
	case 0:
		return "Input Monitoring granted"
	case 1:
		return "Input Monitoring denied; run permissions --apply"
	default:
		return "Input Monitoring not yet granted; run permissions --apply"
	}
}
func (b *darwinBackend) Probe(_ Device) error {
    if C.kc_permission()!=0{return errors.New(b.PermissionStatus())}
    if os.Geteuid()!=0{return errors.New("blocking requires administrator privileges; use the generated launcher")}
    return nil
}
func (b *darwinBackend) RequestPermission(_ Config, apply bool) (string, error) {
	if apply {
		C.kc_request_permission()
	}
	return b.PermissionStatus() + ". Enable this program (or its terminal) in System Settings > Privacy & Security > Input Monitoring, then restart the program. No Accessibility permission or extra driver is requested.", nil
}
