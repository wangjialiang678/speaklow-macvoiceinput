package main

import (
	"os"
	"path/filepath"

	"github.com/joho/godotenv"
)

// loadEnv loads environment variables from .env files in priority order.
// Environment variables already set take precedence over .env files.
func loadEnv() {
	candidates := []string{
		expandHome("~/.config/speaklow/.env"),
		sameDir(".env"),
		"/Users/michael/projects/组件模块/audio-asr-suite/go/audio-asr-go/.env",
	}

	for _, path := range candidates {
		if path == "" {
			continue
		}
		if _, err := os.Stat(path); err == nil {
			// godotenv.Overload would override existing env; Load does not.
			_ = godotenv.Load(path)
		}
	}
}

func expandHome(path string) string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	if len(path) >= 2 && path[:2] == "~/" {
		return filepath.Join(home, path[2:])
	}
	return path
}

func sameDir(name string) string {
	exe, err := os.Executable()
	if err != nil {
		return ""
	}
	return filepath.Join(filepath.Dir(exe), name)
}
