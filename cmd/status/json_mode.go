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

			_ = emitStatusSnapshot(emitter, snap)
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

func emitStatusSnapshot(emitter *jsonEmitter, snapshot MetricsSnapshot) error {
	return emitter.emit("status_snapshot", statusSnapshotData(snapshot))
}

func statusSnapshotData(snapshot MetricsSnapshot) map[string]any {
	snapshot = normalizeStatusSnapshot(snapshot)

	return map[string]any{
		"collected_at":      snapshot.CollectedAt.UTC().Format(time.RFC3339Nano),
		"health_score":      snapshot.HealthScore,
		"health_score_msg":  snapshot.HealthScoreMsg,
		"cpu":               snapshot.CPU,
		"gpu":               snapshot.GPU,
		"memory":            snapshot.Memory,
		"disks":             snapshot.Disks,
		"disk_io":           snapshot.DiskIO,
		"network":           snapshot.Network,
		"network_history":   snapshot.NetworkHistory,
		"proxy":             snapshot.Proxy,
		"batteries":         snapshot.Batteries,
		"thermal":           snapshot.Thermal,
		"bluetooth_devices": snapshot.Bluetooth,
		"top_processes":     snapshot.TopProcesses,
	}
}

func normalizeStatusSnapshot(snapshot MetricsSnapshot) MetricsSnapshot {
	snapshot.GPU = normalizedSlice(snapshot.GPU)
	snapshot.Disks = normalizedSlice(snapshot.Disks)
	snapshot.Network = normalizedSlice(snapshot.Network)
	snapshot.NetworkHistory = NetworkHistory{
		RxHistory: normalizedSlice(snapshot.NetworkHistory.RxHistory),
		TxHistory: normalizedSlice(snapshot.NetworkHistory.TxHistory),
	}
	snapshot.Batteries = normalizedSlice(snapshot.Batteries)
	snapshot.Bluetooth = normalizedSlice(snapshot.Bluetooth)
	snapshot.TopProcesses = normalizedSlice(snapshot.TopProcesses)
	return snapshot
}

func normalizedSlice[T any](values []T) []T {
	if values == nil {
		return []T{}
	}
	return values
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
