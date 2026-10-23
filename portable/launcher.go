package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

func shellQuote(value string) string { return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'" }
func desktopQuote(value string) string {
	value = strings.NewReplacer("\\", "\\\\", "\"", "\\\"", "$", "\\$", "`", "\\`", "%", "%%").Replace(value)
	// Desktop Entry string unescaping runs before Exec argument unquoting.
	value = strings.ReplaceAll(value, "\\", "\\\\")
	return "\"" + value + "\""
}

func writeLauncher(executable, config, platform, homeDir, dataDir string) (string, error) {
	var err error
	config, err = filepath.Abs(config)
	if err != nil {
		return "", err
	}
	if strings.ContainsAny(executable+config, "\r\n\t") {
		return "", fmt.Errorf("control character in launcher path")
	}
	if platform == "linux" && strings.Contains(executable, "=") {
		return "", fmt.Errorf("Desktop Entry executable path cannot contain '='")
	}
	var path, text string
	mode := os.FileMode(0644)
	switch platform {
	case "darwin":
		path = filepath.Join(homeDir, "Applications", "Keyboard Controller.command")
		text = "#!/bin/sh\nexec sudo " + shellQuote(executable) + " run --config " + shellQuote(config) + "\n"
		mode = 0755
	case "linux":
		if dataDir == "" {
			dataDir = filepath.Join(homeDir, ".local", "share")
		}
		path = filepath.Join(dataDir, "applications", "keyboard-controller.desktop")
		text = "[Desktop Entry]\nType=Application\nName=Keyboard Controller\nComment=Automatic built-in keyboard control\nTerminal=true\nExec=" + desktopQuote(executable) + " run --config " + desktopQuote(config) + "\nCategories=Utility;\n"
	default:
		return "", fmt.Errorf("unsupported launcher platform %s", platform)
	}
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return "", err
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".keyboard-controller-launcher-*")
	if err != nil {
		return "", err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	if err = file.Chmod(mode); err != nil {
		return "", err
	}
	if _, err = file.WriteString(text); err != nil {
		return "", err
	}
	if err = file.Close(); err != nil {
		return "", err
	}
	if err = os.Rename(file.Name(), path); err != nil {
		return "", err
	}
	return path, nil
}
