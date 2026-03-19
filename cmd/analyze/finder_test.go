package main

import (
	"io"
	"os"
	"os/exec"
	"runtime"
	"testing"
)

func finderAvailable() bool {
	if runtime.GOOS != "darwin" {
		return false
	}
	// Keep the existing CI behavior (many CI agents are headless).
	if os.Getenv("CI") != "" {
		return false
	}

	cmd := exec.Command("osascript", "-e", `tell application "Finder" to get name of startup disk`)
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	return cmd.Run() == nil
}

func requireFinder(t *testing.T) {
	t.Helper()
	if !finderAvailable() {
		t.Skip("Skipping Finder-dependent test (Finder unavailable in this environment)")
	}
}

