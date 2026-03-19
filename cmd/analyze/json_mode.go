//go:build darwin

package main

import (
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

func runJSONAnalyze() int {
	emitter := newJSONEmitter("analyze", os.Stdout)
	start := time.Now()

	target := os.Getenv("MO_ANALYZE_PATH")
	if target == "" && len(os.Args) > 1 {
		target = os.Args[1]
	}

	var abs string
	if target == "" {
		abs = "/"
	} else {
		var err error
		abs, err = filepath.Abs(target)
		if err != nil {
			_ = emitter.emit("operation_start", map[string]any{
				"mode":    "scan",
				"argv":    os.Args,
				"dry_run": true,
			})
			_ = emitter.emit("error", map[string]any{
				"code":    "unknown",
				"message": err.Error(),
			})
			_ = emitter.emit("operation_complete", map[string]any{
				"success":     false,
				"canceled":    false,
				"exit_code":   1,
				"duration_ms": time.Since(start).Milliseconds(),
			})
			return 1
		}
	}

	_ = emitter.emit("operation_start", map[string]any{
		"mode":    "scan",
		"argv":    os.Args,
		"dry_run": true,
	})
	_ = emitter.emit("analyze_start", map[string]any{
		"target_path": abs,
	})

	var cancelOnce sync.Once
	cancelDone := make(chan struct{})
	emitCanceled := func(exitCode int) {
		cancelOnce.Do(func() {
			_ = emitter.emit("error", map[string]any{
				"code":    "canceled",
				"message": "Operation canceled",
			})
			_ = emitter.emit("operation_complete", map[string]any{
				"success":     false,
				"canceled":    true,
				"exit_code":   exitCode,
				"duration_ms": time.Since(start).Milliseconds(),
			})
			os.Exit(exitCode)
		})
	}

	sigCh := make(chan os.Signal, 2)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(sigCh)

	go func() {
		select {
		case sig := <-sigCh:
			exitCode := 130
			if sig == syscall.SIGTERM {
				exitCode = 143
			}
			emitCanceled(exitCode)
		case <-cancelDone:
			return
		}
	}()

	maybeTriggerAnalyzeJSONTestSignal()

	var filesScanned, dirsScanned, bytesScanned int64
	currentPath := &atomic.Value{}
	currentPath.Store("")

	done := make(chan struct{})
	go func() {
		ticker := time.NewTicker(350 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-done:
				return
			case <-ticker.C:
				select {
				case <-done:
					return
				default:
				}
				cur := ""
				if v := currentPath.Load(); v != nil {
					if s, ok := v.(string); ok {
						cur = s
					}
				}
				_ = emitter.emit("analyze_progress", map[string]any{
					"files_scanned": atomic.LoadInt64(&filesScanned),
					"dirs_scanned":  atomic.LoadInt64(&dirsScanned),
					"bytes_scanned": atomic.LoadInt64(&bytesScanned),
					"current_path":  cur,
				})
			}
		}
	}()

	result, err := scanPathConcurrent(abs, &filesScanned, &dirsScanned, &bytesScanned, currentPath)
	close(done)
	close(cancelDone)

	if err != nil {
		_ = emitter.emit("error", map[string]any{
			"code":    "permission_denied",
			"message": err.Error(),
		})
		_ = emitter.emit("operation_complete", map[string]any{
			"success":     false,
			"canceled":    false,
			"exit_code":   1,
			"duration_ms": time.Since(start).Milliseconds(),
		})
		return 1
	}

	for _, entry := range result.Entries {
		_ = emitter.emit("analyze_entry", map[string]any{
			"parent_path": abs,
			"name":        entry.Name,
			"path":        entry.Path,
			"is_dir":      entry.IsDir,
			"size_bytes":  entry.Size,
		})
	}
	for _, f := range result.LargeFiles {
		_ = emitter.emit("analyze_large_file", map[string]any{
			"parent_path": abs,
			"name":        f.Name,
			"path":        f.Path,
			"size_bytes":  f.Size,
		})
	}

	_ = emitter.emit("analyze_complete", map[string]any{
		"target_path":      abs,
		"total_size_bytes": result.TotalSize,
		"entry_count":      len(result.Entries),
		"large_file_count": len(result.LargeFiles),
	})

	_ = emitter.emit("operation_complete", map[string]any{
		"success":     true,
		"canceled":    false,
		"exit_code":   0,
		"duration_ms": time.Since(start).Milliseconds(),
	})
	return 0
}

func maybeTriggerAnalyzeJSONTestSignal() {
	signalName := os.Getenv("MOLE_ANALYZE_TEST_SIGNAL")
	if signalName == "" {
		return
	}

	var sig syscall.Signal
	switch signalName {
	case "TERM":
		sig = syscall.SIGTERM
	default:
		sig = syscall.SIGINT
	}

	process, err := os.FindProcess(os.Getpid())
	if err != nil {
		return
	}
	_ = process.Signal(sig)
}
