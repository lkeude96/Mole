package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"strings"
	"testing"
)

func TestStatusJSONHelperProcess(t *testing.T) {
	if os.Getenv("GO_WANT_STATUS_JSON_HELPER") != "1" {
		return
	}
	os.Exit(runJSONStatus())
}

func TestRunJSONStatusEmitsSnapshotAndCanceledLifecycle(t *testing.T) {
	stdout, stderr, err := runStatusJSONHelper(t, []string{"MOLE_STATUS_TEST_SIGNAL=INT"})
	if err == nil {
		t.Fatalf("expected status helper to exit non-zero on interrupt\nstdout:\n%s\nstderr:\n%s", stdout, stderr)
	}

	exitErr, ok := err.(*exec.ExitError)
	if !ok {
		t.Fatalf("expected exit error, got %T: %v", err, err)
	}
	if exitErr.ExitCode() != 130 {
		t.Fatalf("expected exit code 130, got %d\nstdout:\n%s\nstderr:\n%s", exitErr.ExitCode(), stdout, stderr)
	}

	events := parseStatusJSONEvents(t, stdout)
	if len(events) < 4 {
		t.Fatalf("expected status lifecycle events, got %d\nstdout:\n%s", len(events), stdout)
	}

	assertStatusEvent(t, events[0], "operation_start")
	assertStatusEventPresent(t, events, "status_start")
	assertStatusEventPresent(t, events, "status_snapshot")
	assertStatusEventPresent(t, events, "status_complete")
	assertStatusEventPresent(t, events, "error")

	snapshot := findStatusEvent(t, events, "status_snapshot")
	snapshotData, ok := snapshot.Data.(map[string]any)
	if !ok {
		t.Fatalf("expected status_snapshot data object, got %T", snapshot.Data)
	}
	for _, field := range []string{
		"health_score_msg",
		"cpu",
		"gpu",
		"memory",
		"disks",
		"disk_io",
		"network",
		"network_history",
		"proxy",
		"batteries",
		"thermal",
		"bluetooth_devices",
		"top_processes",
	} {
		if _, exists := snapshotData[field]; !exists {
			t.Fatalf("expected status_snapshot field %q in %#v", field, snapshotData)
		}
	}

	last := events[len(events)-1]
	assertStatusEvent(t, last, "operation_complete")
	data, ok := last.Data.(map[string]any)
	if !ok {
		t.Fatalf("expected operation_complete data object, got %T", last.Data)
	}
	if canceled, _ := data["canceled"].(bool); !canceled {
		t.Fatalf("expected canceled=true in operation_complete: %#v", data)
	}
}

func runStatusJSONHelper(t *testing.T, extraEnv []string) (string, string, error) {
	t.Helper()

	cmd := exec.Command(os.Args[0], "-test.run=TestStatusJSONHelperProcess")
	cmd.Env = append(os.Environ(),
		"GO_WANT_STATUS_JSON_HELPER=1",
		"MOLE_OUTPUT=json",
	)
	cmd.Env = append(cmd.Env, extraEnv...)

	var stdout, stderr strings.Builder
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	return stdout.String(), stderr.String(), err
}

func parseStatusJSONEvents(t *testing.T, output string) []ndjsonEvent {
	t.Helper()

	lines := strings.Split(strings.TrimSpace(output), "\n")
	events := make([]ndjsonEvent, 0, len(lines))
	for _, line := range lines {
		if strings.TrimSpace(line) == "" {
			continue
		}
		var event ndjsonEvent
		if err := json.Unmarshal([]byte(line), &event); err != nil {
			t.Fatalf("unmarshal status event %q: %v", line, err)
		}
		events = append(events, event)
	}
	return events
}

func assertStatusEvent(t *testing.T, event ndjsonEvent, expected string) {
	t.Helper()
	if event.Event != expected {
		t.Fatalf("expected event %q, got %q", expected, event.Event)
	}
}

func assertStatusEventPresent(t *testing.T, events []ndjsonEvent, expected string) {
	t.Helper()
	for _, event := range events {
		if event.Event == expected {
			return
		}
	}
	t.Fatalf("expected event %q in %#v", expected, events)
}

func findStatusEvent(t *testing.T, events []ndjsonEvent, expected string) ndjsonEvent {
	t.Helper()
	for _, event := range events {
		if event.Event == expected {
			return event
		}
	}
	t.Fatalf("expected event %q in %#v", expected, events)
	return ndjsonEvent{}
}
