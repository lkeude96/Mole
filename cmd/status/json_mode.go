package main

import (
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"
)

func runJSONStatus() int {
	emitter := newJSONEmitter("status", os.Stdout)
	start := time.Now()

	_ = emitter.emit("operation_start", map[string]any{
		"mode":    "scan",
		"argv":    os.Args,
		"dry_run": false,
	})

	collector := NewCollector()

	// First snapshot for status_start metadata.
	snap, err := collector.Collect()
	if err != nil {
		_ = emitter.emit("warning", map[string]any{
			"code":    "unknown",
			"message": err.Error(),
		})
	}

	_ = emitter.emit("status_start", map[string]any{
		"interval_ms": int(refreshInterval / time.Millisecond),
		"host":        snap.Host,
		"platform":    snap.Platform,
		"hardware":    snap.Hardware,
	})

	// Signal handling for graceful stop.
	sigCh := make(chan os.Signal, 2)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(sigCh)
	maybeTriggerStatusJSONTestSignal()

	ticker := time.NewTicker(refreshInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ticker.C:
			snap, err := collector.Collect()
			if err != nil {
				_ = emitter.emit("warning", map[string]any{
					"code":    "unknown",
					"message": err.Error(),
				})
			}

			_ = emitter.emit("status_snapshot", map[string]any{
				"collected_at":      snap.CollectedAt.UTC().Format(time.RFC3339Nano),
				"health_score":      snap.HealthScore,
				"health_score_msg":  snap.HealthScoreMsg,
				"cpu":               snap.CPU,
				"gpu":               snap.GPU,
				"memory":            snap.Memory,
				"disks":             snap.Disks,
				"disk_io":           snap.DiskIO,
				"network":           snap.Network,
				"network_history":   snap.NetworkHistory,
				"proxy":             snap.Proxy,
				"batteries":         snap.Batteries,
				"thermal":           snap.Thermal,
				"bluetooth_devices": snap.Bluetooth,
				"top_processes":     snap.TopProcesses,
			})
		case sig := <-sigCh:
			exitCode := 130
			if sig == syscall.SIGTERM {
				exitCode = 143
			}
			_ = emitter.emit("error", map[string]any{
				"code":    "canceled",
				"message": "Operation canceled",
			})
			_ = emitter.emit("status_complete", map[string]any{})
			_ = emitter.emit("operation_complete", map[string]any{
				"success":     false,
				"canceled":    true,
				"exit_code":   exitCode,
				"duration_ms": time.Since(start).Milliseconds(),
			})
			return exitCode
		}
	}
}

func maybeTriggerStatusJSONTestSignal() {
	signalName := os.Getenv("MOLE_STATUS_TEST_SIGNAL")
	if signalName == "" {
		return
	}

	delay := refreshInterval + 100*time.Millisecond
	if rawDelay := os.Getenv("MOLE_STATUS_TEST_SIGNAL_DELAY_MS"); rawDelay != "" {
		if ms, err := strconv.Atoi(rawDelay); err == nil && ms >= 0 {
			delay = time.Duration(ms) * time.Millisecond
		}
	}

	var sig syscall.Signal
	switch signalName {
	case "TERM":
		sig = syscall.SIGTERM
	default:
		sig = syscall.SIGINT
	}

	go func() {
		time.Sleep(delay)
		process, err := os.FindProcess(os.Getpid())
		if err != nil {
			return
		}
		_ = process.Signal(sig)
	}()
}
