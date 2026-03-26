package main

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/santhosh-tekuri/jsonschema/v5"
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
	assertStatusSnapshotContract(t, snapshotData)

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

func TestStatusSnapshotDataEmitsNormalizedJSONForUnavailableMetrics(t *testing.T) {
	snapshotData := statusSnapshotData(MetricsSnapshot{
		CollectedAt:    time.Unix(1_700_000_000, 0).UTC(),
		HealthScore:    88,
		HealthScoreMsg: "Good",
		CPU:            CPUStatus{},
		Memory:         MemoryStatus{},
		DiskIO:         DiskIOStatus{},
		Proxy:          ProxyStatus{},
		Thermal:        ThermalStatus{},
	})

	encoded, err := json.Marshal(snapshotData)
	if err != nil {
		t.Fatalf("marshal status snapshot data: %v", err)
	}

	var decoded map[string]any
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatalf("unmarshal status snapshot data: %v", err)
	}

	assertStatusSnapshotContract(t, decoded)

	for _, field := range []string{"gpu", "disks", "network", "batteries", "bluetooth_devices", "top_processes"} {
		assertEmptyJSONArrayField(t, decoded, field)
	}

	history, ok := decoded["network_history"].(map[string]any)
	if !ok {
		t.Fatalf("expected network_history object, got %T (%#v)", decoded["network_history"], decoded["network_history"])
	}
	assertEmptyJSONArrayField(t, history, "rx_history")
	assertEmptyJSONArrayField(t, history, "tx_history")
}

func TestEmitStatusSnapshotEventMatchesSchemaForUnavailableMetrics(t *testing.T) {
	var output bytes.Buffer
	emitter := newJSONEmitter("status", &output)

	err := emitStatusSnapshot(emitter, MetricsSnapshot{
		CollectedAt:    time.Unix(1_700_000_000, 0).UTC(),
		HealthScore:    88,
		HealthScoreMsg: "Good",
		CPU:            CPUStatus{},
		Memory:         MemoryStatus{},
		DiskIO:         DiskIOStatus{},
		Proxy:          ProxyStatus{},
		Thermal:        ThermalStatus{},
	})
	if err != nil {
		t.Fatalf("emit status snapshot: %v", err)
	}

	event := parseSingleStatusJSONEvent(t, output.String())
	assertStatusEvent(t, event, "status_snapshot")

	eventData, ok := event.Data.(map[string]any)
	if !ok {
		t.Fatalf("expected status_snapshot data object, got %T", event.Data)
	}
	assertStatusSnapshotContract(t, eventData)

	validateStatusEventAgainstSchema(t, strings.TrimSpace(output.String()))
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

func parseSingleStatusJSONEvent(t *testing.T, output string) ndjsonEvent {
	t.Helper()

	events := parseStatusJSONEvents(t, output)
	if len(events) != 1 {
		t.Fatalf("expected exactly one status event, got %d\nstdout:\n%s", len(events), output)
	}
	return events[0]
}

func validateStatusEventAgainstSchema(t *testing.T, eventJSON string) {
	t.Helper()

	schemaPath := filepath.Join(statusPackageDir(t), "..", "..", "docs", "json-events.schema.json")
	compiler := jsonschema.NewCompiler()
	schema, err := compiler.Compile(schemaPath)
	if err != nil {
		t.Fatalf("compile JSON schema %q: %v", schemaPath, err)
	}

	var payload any
	if err := json.Unmarshal([]byte(eventJSON), &payload); err != nil {
		t.Fatalf("unmarshal emitted status event: %v", err)
	}

	if err := schema.Validate(payload); err != nil {
		t.Fatalf("status event does not match schema: %v\njson:\n%s", err, eventJSON)
	}
}

func statusPackageDir(t *testing.T) string {
	t.Helper()

	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("resolve test file path: runtime.Caller failed")
	}
	return filepath.Dir(file)
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

func assertStatusSnapshotContract(t *testing.T, snapshotData map[string]any) {
	t.Helper()

	assertStringField(t, snapshotData, "collected_at")
	assertNumberField(t, snapshotData, "health_score")
	assertStringField(t, snapshotData, "health_score_msg")
	assertJSONObjectField(t, snapshotData, "cpu")
	assertJSONArrayField(t, snapshotData, "gpu")
	assertJSONObjectField(t, snapshotData, "memory")
	assertJSONArrayField(t, snapshotData, "disks")
	assertJSONObjectField(t, snapshotData, "disk_io")
	assertJSONArrayField(t, snapshotData, "network")
	assertJSONObjectField(t, snapshotData, "network_history")
	assertJSONObjectField(t, snapshotData, "proxy")
	assertJSONArrayField(t, snapshotData, "batteries")
	assertJSONObjectField(t, snapshotData, "thermal")
	assertJSONArrayField(t, snapshotData, "bluetooth_devices")
	assertJSONArrayField(t, snapshotData, "top_processes")
}

func assertStringField(t *testing.T, data map[string]any, field string) {
	t.Helper()
	value, ok := data[field]
	if !ok {
		t.Fatalf("expected field %q in %#v", field, data)
	}
	if _, ok := value.(string); !ok {
		t.Fatalf("expected %q to be string, got %T (%#v)", field, value, value)
	}
}

func assertNumberField(t *testing.T, data map[string]any, field string) {
	t.Helper()
	value, ok := data[field]
	if !ok {
		t.Fatalf("expected field %q in %#v", field, data)
	}
	if _, ok := value.(float64); !ok {
		t.Fatalf("expected %q to be number, got %T (%#v)", field, value, value)
	}
}

func assertJSONObjectField(t *testing.T, data map[string]any, field string) {
	t.Helper()
	value, ok := data[field]
	if !ok {
		t.Fatalf("expected field %q in %#v", field, data)
	}
	if _, ok := value.(map[string]any); !ok {
		t.Fatalf("expected %q to be object, got %T (%#v)", field, value, value)
	}
}

func assertJSONArrayField(t *testing.T, data map[string]any, field string) {
	t.Helper()
	value, ok := data[field]
	if !ok {
		t.Fatalf("expected field %q in %#v", field, data)
	}
	if _, ok := value.([]any); !ok {
		t.Fatalf("expected %q to be array, got %T (%#v)", field, value, value)
	}
}

func assertEmptyJSONArrayField(t *testing.T, data map[string]any, field string) {
	t.Helper()
	value, ok := data[field]
	if !ok {
		t.Fatalf("expected field %q in %#v", field, data)
	}
	values, ok := value.([]any)
	if !ok {
		t.Fatalf("expected %q to be array, got %T (%#v)", field, value, value)
	}
	if len(values) != 0 {
		t.Fatalf("expected %q to be empty array, got %#v", field, values)
	}
}
