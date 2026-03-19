package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestAnalyzeJSONHelperProcess(t *testing.T) {
	if os.Getenv("GO_WANT_ANALYZE_JSON_HELPER") != "1" {
		return
	}
	os.Exit(runJSONAnalyze())
}

func TestRunJSONAnalyzeEmitsLifecycle(t *testing.T) {
	target := t.TempDir()
	if err := os.WriteFile(filepath.Join(target, "file.txt"), []byte("hello"), 0o644); err != nil {
		t.Fatalf("write file: %v", err)
	}
	if err := os.Mkdir(filepath.Join(target, "folder"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	stdout, stderr, err := runAnalyzeJSONHelper(t, target, nil)
	if err != nil {
		t.Fatalf("run analyze json: %v\nstderr:\n%s", err, stderr)
	}

	events := parseAnalyzeJSONEvents(t, stdout)
	if len(events) < 4 {
		t.Fatalf("expected analyze lifecycle events, got %d\nstdout:\n%s", len(events), stdout)
	}
	assertAnalyzeEvent(t, events[0], "operation_start")
	assertAnalyzeEventPresent(t, events, "analyze_start")
	assertAnalyzeEventPresent(t, events, "analyze_entry")
	assertAnalyzeEventPresent(t, events, "analyze_complete")
	assertAnalyzeEvent(t, events[len(events)-1], "operation_complete")
}

func TestRunJSONAnalyzeEmitsCanceledLifecycleOnInterrupt(t *testing.T) {
	target := t.TempDir()
	if err := os.WriteFile(filepath.Join(target, "file.txt"), []byte("hello"), 0o644); err != nil {
		t.Fatalf("write file: %v", err)
	}

	stdout, stderr, err := runAnalyzeJSONHelper(t, target, []string{"MOLE_ANALYZE_TEST_SIGNAL=INT"})
	if err == nil {
		t.Fatalf("expected analyze helper to exit non-zero on interrupt\nstdout:\n%s\nstderr:\n%s", stdout, stderr)
	}

	exitErr, ok := err.(*exec.ExitError)
	if !ok {
		t.Fatalf("expected exit error, got %T: %v", err, err)
	}
	if exitErr.ExitCode() != 130 {
		t.Fatalf("expected exit code 130, got %d\nstdout:\n%s\nstderr:\n%s", exitErr.ExitCode(), stdout, stderr)
	}

	events := parseAnalyzeJSONEvents(t, stdout)
	assertAnalyzeEventPresent(t, events, "error")
	last := events[len(events)-1]
	assertAnalyzeEvent(t, last, "operation_complete")
	data, ok := last.Data.(map[string]any)
	if !ok {
		t.Fatalf("expected operation_complete data object, got %T", last.Data)
	}
	if canceled, _ := data["canceled"].(bool); !canceled {
		t.Fatalf("expected canceled=true in operation_complete: %#v", data)
	}
}

func runAnalyzeJSONHelper(t *testing.T, target string, extraEnv []string) (string, string, error) {
	t.Helper()

	cmd := exec.Command(os.Args[0], "-test.run=TestAnalyzeJSONHelperProcess")
	cmd.Env = append(os.Environ(),
		"GO_WANT_ANALYZE_JSON_HELPER=1",
		"MOLE_OUTPUT=json",
		"MO_ANALYZE_PATH="+target,
	)
	cmd.Env = append(cmd.Env, extraEnv...)

	var stdout, stderr strings.Builder
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	return stdout.String(), stderr.String(), err
}

func parseAnalyzeJSONEvents(t *testing.T, output string) []ndjsonEvent {
	t.Helper()

	lines := strings.Split(strings.TrimSpace(output), "\n")
	events := make([]ndjsonEvent, 0, len(lines))
	for _, line := range lines {
		if strings.TrimSpace(line) == "" {
			continue
		}
		var event ndjsonEvent
		if err := json.Unmarshal([]byte(line), &event); err != nil {
			t.Fatalf("unmarshal analyze event %q: %v", line, err)
		}
		events = append(events, event)
	}
	return events
}

func assertAnalyzeEvent(t *testing.T, event ndjsonEvent, expected string) {
	t.Helper()
	if event.Event != expected {
		t.Fatalf("expected event %q, got %q", expected, event.Event)
	}
}

func assertAnalyzeEventPresent(t *testing.T, events []ndjsonEvent, expected string) {
	t.Helper()
	for _, event := range events {
		if event.Event == expected {
			return
		}
	}
	t.Fatalf("expected event %q in %#v", expected, events)
}
