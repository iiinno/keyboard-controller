//go:build linux

package main

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

type linuxBackend struct {
	sysRoot, devRoot string
	fd               int
	buffer           [24 * 64]byte
}

func newBackend() (Backend, error) {
	return &linuxBackend{sysRoot: "/sys/class/input", devRoot: "/dev/input", fd: -1}, nil
}

func keyBit(text string, bit int) bool {
	words := strings.Fields(text)
	index := len(words) - 1 - bit/64
	if index < 0 {
		return false
	}
	word, err := strconv.ParseUint(words[index], 16, 64)
	return err == nil && word&(uint64(1)<<uint(bit%64)) != 0
}

func linuxID(name, phys, uniq, vendor, product string) string {
	return deviceID("linux", name, phys, uniq, strings.ToLower(vendor), strings.ToLower(product))
}

func (b *linuxBackend) Devices() ([]Device, error) {
	entries, err := os.ReadDir(b.sysRoot)
	if err != nil {
		return nil, err
	}
	found := []Device{}
	for _, entry := range entries {
		if !regexp.MustCompile(`^event[0-9]+$`).MatchString(entry.Name()) {
			continue
		}
		base := filepath.Join(b.sysRoot, entry.Name(), "device")
		read := func(name string) string {
			data, _ := os.ReadFile(filepath.Join(base, name))
			return strings.TrimSpace(string(data))
		}
		keys, events := read("capabilities/key"), read("capabilities/ev")
		if !keyBit(events, 1) || !keyBit(keys, 28) || !keyBit(keys, 30) || !keyBit(keys, 44) {
			continue
		}
		name, phys, uniq := read("name"), read("phys"), read("uniq")
		vendor, product, bus := read("id/vendor"), read("id/product"), read("id/bustype")
		locator := filepath.Join(b.devRoot, entry.Name())
		safe := name != "" && vendor != "" && product != "" && bus != "0006" && !keyBit(events, 2) && !keyBit(events, 3) && !keyBit(keys, 272) && !keyBit(keys, 330)
		permissionPath := ""
		paths, _ := filepath.Glob(filepath.Join(b.devRoot, "by-path", "*-event-kbd"))
		for _, p := range paths {
			if target, e := filepath.EvalSymlinks(p); e == nil && target == locator {
				permissionPath = strings.TrimSuffix(filepath.Base(p), "-event-kbd")
				break
			}
		}
		found = append(found, Device{ID: linuxID(name, phys, uniq, vendor, product), Name: name, Locator: locator, BuiltIn: bus == "0011" || strings.HasPrefix(phys, "isa"), Blockable: safe, PermissionPath: permissionPath})
	}
	return found, nil
}

func ioctlRead(fd int, nr, size int, pointer unsafe.Pointer) error {
	_, _, err := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), uintptr(2<<30|size<<16|int('E')<<8|nr), uintptr(pointer))
	if err != 0 {
		return err
	}
	return nil
}

func fdString(fd, nr int) (string, error) {
	var buf [256]byte
	if err := ioctlRead(fd, nr, len(buf), unsafe.Pointer(&buf[0])); err != nil {
		return "", err
	}
	if end := bytes.IndexByte(buf[:], 0); end >= 0 {
		return strings.TrimSpace(string(buf[:end])), nil
	}
	return strings.TrimSpace(string(buf[:])), nil
}

func checkedFD(fd int, expected Device) error {
	var id [4]uint16
	if err := ioctlRead(fd, 2, 8, unsafe.Pointer(&id[0])); err != nil {
		return err
	}
	name, err := fdString(fd, 6)
	if err != nil {
		return err
	}
	phys, _ := fdString(fd, 7)
	uniq, _ := fdString(fd, 8)
	if linuxID(name, phys, uniq, fmt.Sprintf("%04x", id[1]), fmt.Sprintf("%04x", id[2])) != expected.ID {
		return errors.New("device identity changed before open; refusing to grab")
	}
	var keys [128]byte
	var events [8]byte
	if err = ioctlRead(fd, 0x21, len(keys), unsafe.Pointer(&keys[0])); err != nil {
		return err
	}
	if err = ioctlRead(fd, 0x20, len(events), unsafe.Pointer(&events[0])); err != nil {
		return err
	}
	bit := func(data []byte, n int) bool { return data[n/8]&(1<<uint(n%8)) != 0 }
	if id[0] == 6 || !bit(keys[:], 28) || !bit(keys[:], 30) || !bit(keys[:], 44) || bit(keys[:], 272) || bit(keys[:], 330) || bit(events[:], 2) || bit(events[:], 3) {
		return errors.New("not a safe keyboard-only device")
	}
	return nil
}

func (b *linuxBackend) Grab(d Device) error {
	if !d.Blockable {
		return errors.New("refusing to grab a pointer/composite device")
	}
	if b.fd >= 0 {
		return errors.New("a keyboard is already grabbed")
	}
	fd, err := syscall.Open(d.Locator, syscall.O_RDONLY|syscall.O_NONBLOCK|syscall.O_CLOEXEC|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return fmt.Errorf("open keyboard (run permissions --apply first): %w", err)
	}
	if err = checkedFD(fd, d); err != nil {
		syscall.Close(fd)
		return err
	}
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), 0x40044590, 1) // EVIOCGRAB
	if errno != 0 {
		syscall.Close(fd)
		return errno
	}
	b.fd = fd
	return nil
}

func (b *linuxBackend) Release() error {
	if b.fd < 0 {
		return nil
	}
	fd := b.fd
	b.fd = -1
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), 0x40044590, 0)
	closeErr := syscall.Close(fd) // Closing the evdev handle also releases its grab.
	if errno != 0 && errno != syscall.ENODEV {
		return errors.Join(errno, closeErr)
	}
	return closeErr
}

func (b *linuxBackend) Pump(delay time.Duration) error {
	if b.fd >= 0 {
		for i := 0; i < 64; i++ {
			n, err := syscall.Read(b.fd, b.buffer[:])
			if err == syscall.EAGAIN || err == syscall.EINTR {
				break
			}
			if err != nil {
				return err
			}
			if n == 0 {
				return errors.New("keyboard disconnected")
			}
		}
	}
	time.Sleep(delay)
	return nil
}

func (b *linuxBackend) NowMS() int64 {
	var ts syscall.Timespec
	_, _, err := syscall.Syscall(syscall.SYS_CLOCK_GETTIME, 7, uintptr(unsafe.Pointer(&ts)), 0) // CLOCK_BOOTTIME includes sleep.
	if err != 0 {
		return time.Now().UnixMilli()
	}
	return ts.Sec*1000 + ts.Nsec/1000000
}

func (b *linuxBackend) PermissionStatus() string {
	return "evdev device access required; permissions --apply grants the active local user access to the selected keyboard"
}

func (b *linuxBackend) Probe(d Device) error {
    fd,err:=syscall.Open(d.Locator,syscall.O_RDONLY|syscall.O_NONBLOCK|syscall.O_CLOEXEC|syscall.O_NOFOLLOW,0)
    if err!=nil{return err};defer syscall.Close(fd)
    return checkedFD(fd,d)
}

func (b *linuxBackend) RequestPermission(cfg Config, apply bool) (string, error) {
	devices, err := b.Devices()
	if err != nil {
		return "", err
	}
	internal, err := uniqueDevice(devices, cfg.InternalID, true)
	if err != nil {
		return "", err
	}
	if !regexp.MustCompile(`^[A-Za-z0-9_.:/-]+$`).MatchString(internal.PermissionPath) {
		return "", errors.New("no safe udev ID_PATH for this keyboard; automatic permission setup is unavailable")
	}
	rule := fmt.Sprintf("SUBSYSTEM==\"input\", KERNEL==\"event[0-9]*\", ENV{ID_INPUT_KEYBOARD}==\"1\", ENV{ID_PATH}==\"%s\", TAG+=\"uaccess\"\n", internal.PermissionPath)
	if !apply {
		return rule + "Run permissions --apply to install this rule (sudo required).", nil
	}
	f, err := os.CreateTemp("", "keyboard-controller-*.rules")
	if err != nil {
		return "", err
	}
	defer os.Remove(f.Name())
	if _, err = f.WriteString(rule); err != nil {
		f.Close()
		return "", err
	}
	if err = f.Close(); err != nil {
		return "", err
	}
	steps := [][]string{{"install", "-o", "root", "-g", "root", "-m", "0644", f.Name(), "/etc/udev/rules.d/70-keyboard-controller.rules"}, {"udevadm", "control", "--reload-rules"}, {"udevadm", "trigger", "--subsystem-match=input", "--action=change"}}
	for _, args := range steps {
		cmd := exec.Command(args[0], args[1:]...)
		if os.Geteuid() != 0 {
			cmd = exec.Command("sudo", args...)
		}
		cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
		if err = cmd.Run(); err != nil {
			return "", err
		}
	}
	if err=b.Probe(internal);err!=nil{return "Rule installed, but current keyboard access was not confirmed. Reconnect/re-login, then run doctor.",err}
	return "Keyboard permission rule installed; access to the selected keyboard was verified without grabbing input.", nil
}
