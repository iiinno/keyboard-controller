//go:build linux

package main

import (
	"encoding/binary"
	"fmt"
	"os"
	"strings"
	"syscall"
	"testing"
	"time"
	"unsafe"
)

func uinputIoctl(fd int, request uintptr, arg uintptr) error {
	_, _, err := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), request, arg)
	if err != 0 {
		return err
	}
	return nil
}

func virtualKeyboard(t *testing.T, label string) (Device, int) {
	t.Helper()
	fd, err := syscall.Open("/dev/uinput", syscall.O_WRONLY|syscall.O_NONBLOCK|syscall.O_CLOEXEC, 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { uinputIoctl(fd, 0x5502, 0); syscall.Close(fd) })
	if err = uinputIoctl(fd, 0x40045564, 1); err != nil {
		t.Fatal(err)
	} // UI_SET_EVBIT(EV_KEY)
	for _, key := range []uintptr{28, 30, 44, 48} {
		if err = uinputIoctl(fd, 0x40045565, key); err != nil {
			t.Fatal(err)
		}
	}
	name := fmt.Sprintf("keyboard-controller-test-%s-%d", label, time.Now().UnixNano())
	phys := append([]byte(name), 0)
	if err = uinputIoctl(fd, 0x4008556c, uintptr(unsafe.Pointer(&phys[0]))); err != nil {
		t.Fatal(err)
	}
	setup := struct {
		ID      [4]uint16
		Name    [80]byte
		Effects uint32
	}{ID: [4]uint16{0x11, 0x1234, 0x5678, 1}}
	copy(setup.Name[:], name)
	if unsafe.Sizeof(setup) != 92 {
		t.Fatal("unexpected uinput ABI")
	}
	if err = uinputIoctl(fd, 0x405c5503, uintptr(unsafe.Pointer(&setup))); err != nil {
		t.Fatal(err)
	}
	if err = uinputIoctl(fd, 0x5501, 0); err != nil {
		t.Fatal(err)
	}
	backend, _ := newBackend()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		devices, err := backend.Devices()
		if err != nil {
			t.Fatal(err)
		}
		for _, d := range devices {
			if d.Name == name {
				if _, err = os.Stat(d.Locator); err == nil {
					return d, fd
				}
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("uinput event device did not appear")
	return Device{}, -1
}

func sendVirtualKey(t *testing.T, fd int, key uint16, value uint32) {
	t.Helper()
	var frame [48]byte // input_event + SYN_REPORT, on the supported 64-bit targets.
	binary.LittleEndian.PutUint16(frame[16:18], 1)
	binary.LittleEndian.PutUint16(frame[18:20], key)
	binary.LittleEndian.PutUint32(frame[20:24], value)
	if n, err := syscall.Write(fd, frame[:]); err != nil || n != len(frame) {
		t.Fatalf("write virtual input: %d %v", n, err)
	}
}

func readVirtualKey(fd int, key uint16, wait time.Duration) bool {
	deadline := time.Now().Add(wait)
	var buf [24 * 64]byte
	for {
		n, err := syscall.Read(fd, buf[:])
		if err == nil {
			for offset := 0; offset+24 <= n; offset += 24 {
				if binary.LittleEndian.Uint16(buf[offset+16:]) == 1 && binary.LittleEndian.Uint16(buf[offset+18:]) == key && binary.LittleEndian.Uint32(buf[offset+20:]) == 1 {
					return true
				}
			}
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(time.Millisecond)
	}
}

func TestLinuxUinputExclusiveAndRelease(t *testing.T) {
	if os.Getenv("KEYBOARD_CONTROLLER_UINPUT") != "1" {
		t.Skip("isolated Linux uinput integration job only")
	}
	internal, writer := virtualKeyboard(t, "internal")
	external, externalWriter := virtualKeyboard(t, "external")
	if !strings.HasPrefix(internal.Name, "keyboard-controller-test-") {
		t.Fatal("not a test device")
	}
	watch, err := syscall.Open(internal.Locator, syscall.O_RDONLY|syscall.O_NONBLOCK|syscall.O_CLOEXEC, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer syscall.Close(watch)
	externalWatch, err := syscall.Open(external.Locator, syscall.O_RDONLY|syscall.O_NONBLOCK|syscall.O_CLOEXEC, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer syscall.Close(externalWatch)
	backend, _ := newBackend()
	defer backend.Release()
	if err = backend.Grab(internal); err != nil {
		t.Fatal(err)
	}
	sendVirtualKey(t, writer, 30, 1)
	sendVirtualKey(t, writer, 30, 0)
	if readVirtualKey(watch, 30, 30*time.Millisecond) {
		t.Fatal("grabbed internal events leaked to another consumer")
	}
	sendVirtualKey(t, externalWriter, 48, 1)
	sendVirtualKey(t, externalWriter, 48, 0)
	if !readVirtualKey(externalWatch, 48, time.Second) {
		t.Fatal("external keyboard was affected")
	}
	if err = backend.Pump(0); err != nil {
		t.Fatal(err)
	}
	if err = backend.Release(); err != nil {
		t.Fatal(err)
	}
	sendVirtualKey(t, writer, 30, 1)
	sendVirtualKey(t, writer, 30, 0)
	if !readVirtualKey(watch, 30, time.Second) {
		t.Fatal("internal events did not return after release")
	}
	t.Log("Verified real EVIOCGRAB, internal event suppression, unaffected external input, and event recovery using two isolated virtual keyboards")
}
