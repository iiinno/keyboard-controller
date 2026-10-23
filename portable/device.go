package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

type Device struct {
	ID             string `json:"id"`
	Name           string `json:"name"`
	Locator        string `json:"locator"`
	BuiltIn        bool   `json:"built_in"`
	Blockable      bool   `json:"blockable"`
	PermissionPath string `json:"permission_path,omitempty"`
}

func deviceID(parts ...string) string {
	sum := sha256.Sum256([]byte(strings.Join(parts, "\x00")))
	return hex.EncodeToString(sum[:16])
}

type Config struct {
	Version    int    `json:"version"`
	Platform   string `json:"platform"`
	InternalID string `json:"internal_id"`
	ExternalID string `json:"external_id"`
	PollMS     int64  `json:"poll_ms"`
	SettleMS   int64  `json:"settle_ms"`
}

func (c Config) Validate() error {
	if c.Version != 1 {
		return errors.New("unsupported config version")
	}
	if c.Platform != runtime.GOOS {
		return fmt.Errorf("config is for %s, this OS is %s; run setup again", c.Platform, runtime.GOOS)
	}
	if c.InternalID == "" || c.ExternalID == "" || c.InternalID == c.ExternalID {
		return errors.New("choose two different keyboard IDs with setup")
	}
	if c.PollMS < 200 || c.PollMS > 10000 || c.SettleMS < 0 || c.SettleMS > 60000 {
		return errors.New("poll_ms must be 200..10000 and settle_ms 0..60000")
	}
	return nil
}

func defaultConfigPath() (string, error) {
	base, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(base, "keyboard-controller", "config.json"), nil
}

func loadConfig(path string) (Config, error) {
	var cfg Config
	f, err := os.Open(path)
	if err != nil {
		return cfg, fmt.Errorf("read config (run setup first): %w", err)
	}
	defer f.Close()
	dec := json.NewDecoder(io.LimitReader(f, 65537))
	dec.DisallowUnknownFields()
	if err = dec.Decode(&cfg); err != nil {
		return cfg, fmt.Errorf("invalid config: %w", err)
	}
	var extra any
	if err = dec.Decode(&extra); err != io.EOF {
		return cfg, errors.New("config must contain one JSON object")
	}
	return cfg, cfg.Validate()
}

func saveConfig(path string, cfg Config, replace bool) error {
	if err := cfg.Validate(); err != nil {
		return err
	}
	if _, err := os.Lstat(path); err == nil && !replace {
		return errors.New("config exists; use setup --replace to replace it")
	} else if err != nil && !os.IsNotExist(err) {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".config-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	defer f.Close()
	enc := json.NewEncoder(f)
	enc.SetIndent("", "  ")
	if err = enc.Encode(cfg); err != nil {
		return err
	}
	if err = f.Sync(); err != nil {
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	if !replace {
		// Hard-link creation fails atomically if the destination appeared meanwhile.
		return os.Link(f.Name(), path)
	}
	return os.Rename(f.Name(), path)
}

type Backend interface {
	Devices() ([]Device, error)
	Grab(Device) error
	Release() error
	Pump(time.Duration) error
	NowMS() int64
	PermissionStatus() string
	RequestPermission(Config, bool) (string, error)
}

func uniqueDevice(devices []Device, id string, internal bool) (Device, error) {
	var found []Device
	for _, d := range devices {
		if d.ID == id {
			found = append(found, d)
		}
	}
	if len(found) != 1 {
		return Device{}, fmt.Errorf("expected one %s keyboard, found %d", map[bool]string{true: "internal", false: "external"}[internal], len(found))
	}
	if internal && !found[0].Blockable {
		return Device{}, errors.New("the selected internal device also controls a pointer or lacks safe keyboard metadata")
	}
	return found[0], nil
}
