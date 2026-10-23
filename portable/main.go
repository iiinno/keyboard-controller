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
		return setup(input, out, devices, *configPath, *replace)
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
		result := map[string]any{"platform": runtime.GOOS, "permission": b.PermissionStatus(), "devices": devices,
			"internal": internal, "external": external, "enumeration_error": errorText(listErr), "internal_error": errorText(internalErr), "external_error": errorText(externalErr)}
		if *asJSON {
			return json.NewEncoder(out).Encode(result)
		}
		for _, key := range []string{"platform", "permission", "enumeration_error", "internal_error", "external_error"} {
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
		fmt.Fprintf(out, "%d. %s%s\n   %s\n", i+1, d.Name, hint, d.ID)
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
	fmt.Fprintf(out, "Saved %s\nNext: keyboard-controller permissions --apply\nThen: keyboard-controller test\nFinally: keyboard-controller run\n", path)
	return nil
}

func run(b Backend, cfg Config, input io.Reader, out io.Writer, pass, test bool) (result error) {
	c, err := newController(b, cfg)
	if err != nil {
		return err
	}
	defer func() { result = errors.Join(result, c.Close()) }()
	if pass {
		if err = c.SetMode("FORCED_ON"); err != nil {
			return err
		}
	}
	if test {
		c.settleUntil = b.NowMS()
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if test {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, 8*time.Second)
		defer cancel()
	}
	commands := make(chan string, 1)
	if !test {
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
		fmt.Fprintln(out, "Commands: on | auto | pause 5 | pause 15 | status | quit; Ctrl+C releases and exits")
	}
	previous := ""
	for {
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
				fmt.Fprintln(out, "Unknown command; use on, auto, pause 5, pause 15, status, or quit")
			}
			if err != nil {
				return err
			}
		default:
		}
		if err = c.Tick(); err != nil {
			return err
		}
		status := fmt.Sprintf("%s mode=%s (%s)", c.State, c.Mode, c.Reason)
		if status != previous {
			fmt.Fprintln(out, status)
			previous = status
		}
		if err = b.Pump(10 * time.Millisecond); err != nil {
			return err
		}
	}
}
