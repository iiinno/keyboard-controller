package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode"
)

var version = "dev"

const help = `keyboard-controller — Linux / macOS

  setup [--replace]       Choose the built-in and external keyboard; save config
  devices [--json]        List keyboards without intercepting input
  doctor [--json]         Check configuration, matching, and OS permissions
  permissions [--apply]   Show permission steps; --apply requests/configures access
  run [--pass]            Monitor connection; Ctrl+C releases and exits
  test                   Block for at most 8 seconds, only with the external present
  version                Print version

Every config command accepts --config PATH. During run, enter on, auto,
pause 5, pause 15, status, or quit. No keystroke contents are recorded.
`

func main() {
	if err := entry(os.Args[1:], os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "keyboard-controller:", err)
		os.Exit(1)
	}
}

func entry(args []string, input io.Reader, out io.Writer) error {
	if len(args) == 0 || args[0] == "--help" || args[0] == "help" {
		_, err := io.WriteString(out, help)
		return err
	}
	if args[0] == "version" {
		fmt.Fprintln(out, version)
		return nil
	}
	command := args[0]
	if command != "setup" && command != "devices" && command != "doctor" && command != "permissions" && command != "run" && command != "test" {
		return fmt.Errorf("unknown command %q; use --help", command)
	}
	path, err := defaultConfigPath()
	if err != nil {
		return err
	}
	fs := flag.NewFlagSet(command, flag.ContinueOnError)
	fs.SetOutput(out)
	configPath := fs.String("config", path, "config path")
	asJSON := fs.Bool("json", false, "machine-readable diagnostics")
	replace := fs.Bool("replace", false, "replace existing config")
	apply := fs.Bool("apply", false, "request OS permissions")
	pass := fs.Bool("pass", false, "keep the built-in keyboard usable")
	if err = fs.Parse(args[1:]); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	if fs.NArg() != 0 {
		return errors.New("unexpected arguments")
	}
	runtime.LockOSThread() // IOHID callbacks and their run loop share one OS thread.
	defer runtime.UnlockOSThread()
	b, err := newBackend()
	if err != nil {
		return err
	}
	defer b.Release()
	if command == "devices" || command == "setup" {
		devices, err := b.Devices()
		if err != nil {
			return err
		}
		if command == "devices" {
			if *asJSON {
				return json.NewEncoder(out).Encode(devices)
			}
			printDevices(out, devices)
			return nil
		}
		if err = setup(input, out, devices, *configPath, *replace); err != nil {
			return err
		}
		executable, exeErr := os.Executable()
		homeDir, homeErr := os.UserHomeDir()
		if exeErr == nil && homeErr == nil {
			launcher, launcherErr := writeLauncher(executable, *configPath, runtime.GOOS, homeDir, os.Getenv("XDG_DATA_HOME"))
			if launcherErr == nil {
				fmt.Fprintln(out, "Launcher:", launcher)
			} else {
				fmt.Fprintln(out, "Config saved; launcher could not be created:", launcherErr)
			}
		}
		return nil
	}
	cfg, err := loadConfig(*configPath)
	if err != nil {
		return err
	}
	if command == "permissions" {
		message, err := b.RequestPermission(cfg, *apply)
		fmt.Fprintln(out, message)
		return err
	}
	if command == "doctor" {
		devices, listErr := b.Devices()
		internal, internalErr := uniqueDevice(devices, cfg.InternalID, true)
		external, externalErr := uniqueDevice(devices, cfg.ExternalID, false)
		var permissionErr error
		if internalErr == nil {
			if prober, ok := b.(interface{ Probe(Device) error }); ok {
				permissionErr = prober.Probe(internal)
			}
		}
		result := map[string]any{"platform": runtime.GOOS, "permission": b.PermissionStatus(), "devices": devices,
			"internal": internal, "external": external, "enumeration_error": errorText(listErr), "internal_error": errorText(internalErr), "external_error": errorText(externalErr), "permission_error": errorText(permissionErr)}
		if *asJSON {
			return json.NewEncoder(out).Encode(result)
		}
		for _, key := range []string{"platform", "permission", "enumeration_error", "internal_error", "external_error", "permission_error"} {
			fmt.Fprintf(out, "%s: %v\n", key, result[key])
		}
		return nil
	}
	return run(b, cfg, input, out, *pass, command == "test")
}

func errorText(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

func printDevices(out io.Writer, devices []Device) {
	for i, d := range devices {
		hint := ""
		if d.BuiltIn {
			hint = " [built-in hint]"
		}
		if !d.Blockable {
			hint += " [cannot safely block]"
		}
		name := strings.Map(func(r rune) rune {
			if unicode.IsControl(r) || unicode.Is(unicode.Cf, r) {
				return ' '
			}
			return r
		}, d.Name)
		fmt.Fprintf(out, "%d. %s%s\n   %s\n", i+1, name, hint, d.ID)
	}
}

func setup(input io.Reader, out io.Writer, devices []Device, path string, replace bool) error {
	if len(devices) < 2 {
		return errors.New("connect the external keyboard first; at least two keyboards must be present")
	}
	printDevices(out, devices)
	reader := bufio.NewReader(input)
	choose := func(prompt string) (Device, error) {
		fmt.Fprint(out, prompt)
		text, err := reader.ReadString('\n')
		if err != nil {
			return Device{}, fmt.Errorf("read selection: %w", err)
		}
		n, err := strconv.Atoi(strings.TrimSpace(text))
		if err != nil || n < 1 || n > len(devices) {
			return Device{}, errors.New("choose a number from the list")
		}
		return devices[n-1], nil
	}
	internal, err := choose("Built-in keyboard number / 内蔵の番号: ")
	if err != nil {
		return err
	}
	if _, err = uniqueDevice(devices, internal.ID, true); err != nil {
		return err
	}
	external, err := choose("External keyboard number / 外付けの番号: ")
	if err != nil {
		return err
	}
	if _, err = uniqueDevice(devices, external.ID, false); err != nil {
		return err
	}
	cfg := Config{Version: 1, Platform: runtime.GOOS, InternalID: internal.ID, ExternalID: external.ID, PollMS: 1000, SettleMS: 3000}
	if err = saveConfig(path, cfg, replace); err != nil {
		return err
	}
	fmt.Fprintf(out, "Saved %s\nNext: keyboard-controller permissions --apply\n", path)
	executable, exeErr := os.Executable()
	if exeErr != nil {
		executable = "keyboard-controller"
	}
	if runtime.GOOS == "darwin" {
		fmt.Fprintf(out, "Then: sudo %s test --config %s\nFinally: use the launcher or sudo %s run --config %s\n", shellQuote(executable), shellQuote(path), shellQuote(executable), shellQuote(path))
	} else {
		fmt.Fprintf(out, "Then: %s test\nFinally: use the launcher or %s run\n", shellQuote(executable), shellQuote(executable))
	}
	return nil
}

func run(b Backend, cfg Config, input io.Reader, out io.Writer, pass, test bool) (result error) {
	c, err := newController(b, cfg)
	if err != nil {
		return err
	}
	if pass {
		if err = c.SetMode("FORCED_ON"); err != nil {
			return err
		}
	}
	if test {
		c.settleUntil = b.NowMS()
	}
	testUntil := b.NowMS() + 8000 // Native uptime includes suspend; Go timers may not.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGPIPE)
	defer stop()
	if test {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, 8*time.Second)
		defer cancel()
	}
	// A stalled terminal/pipe must never stall keyboard release or connection checks.
	messages := make(chan string, 16)
	writerDone := make(chan struct{})
	emit := func(text string) {
		select {
		case messages <- text:
		default:
		}
	}
	go func() {
		defer close(writerDone)
		for text := range messages {
			if _, writeErr := fmt.Fprintln(out, text); writeErr != nil {
				stop()
				return
			}
		}
	}()
	defer func() {
		releaseErr := c.Close()
		result = errors.Join(result, releaseErr)
		if releaseErr == nil {
			emit("PASS (controller stopped; input context released)")
		}
		close(messages)
		select {
		case <-writerDone:
		case <-time.After(100 * time.Millisecond):
		}
	}()
	commands := make(chan string, 1)
	if !test {
		emit(fmt.Sprintf("Controller PID: %d", os.Getpid()))
		go func() {
			scanner := bufio.NewScanner(input)
			for scanner.Scan() {
				select {
				case commands <- scanner.Text():
				case <-ctx.Done():
					return
				}
			}
		}()
		emit("Commands: on | auto | pause 5 | pause 15 | status | quit; Ctrl+C releases and exits")
	}
	previous := ""
	testStarted := false
	for {
		if test && b.NowMS() >= testUntil {
			return nil
		}
		select {
		case <-ctx.Done():
			return nil
		case text := <-commands:
			switch strings.TrimSpace(text) {
			case "quit":
				return nil
			case "on":
				err = c.SetMode("FORCED_ON")
			case "auto":
				err = c.SetMode("AUTO")
			case "pause 5":
				err = c.Pause(5 * time.Minute)
			case "pause 15":
				err = c.Pause(15 * time.Minute)
			case "status":
				previous = ""
			default:
				emit("Unknown command; use on, auto, pause 5, pause 15, status, or quit")
			}
			if err != nil {
				return err
			}
		default:
		}
		if err = c.Tick(); err != nil {
			return err
		}
		if test && !testStarted {
			if c.State != "BLOCKED" {
				return fmt.Errorf("8-second test did not start: %s", c.Reason)
			}
			testStarted = true
		}
		status := fmt.Sprintf("%s mode=%s (%s)", c.State, c.Mode, c.Reason)
		if status != previous {
			emit(status)
			previous = status
		}
		if err = b.Pump(10 * time.Millisecond); err != nil {
			return err
		}
	}
}
