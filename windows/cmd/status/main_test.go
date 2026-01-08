//go:build windows

package main

import (
	"testing"
	"time"
)

func TestFormatBytesUint64(t *testing.T) {
	tests := []struct {
		input    uint64
		expected string
	}{
		{0, "0 B"},
		{512, "512 B"},
		{1024, "1.0 KB"},
		{1536, "1.5 KB"},
		{1048576, "1.0 MB"},
		{1073741824, "1.0 GB"},
		{1099511627776, "1.0 TB"},
	}

	for _, test := range tests {
		result := formatBytes(test.input)
		if result != test.expected {
			t.Errorf("formatBytes(%d) = %s, expected %s", test.input, result, test.expected)
		}
	}
}

func TestFormatDuration(t *testing.T) {
	tests := []struct {
		input    time.Duration
		expected string
	}{
		{5 * time.Minute, "5m"},
		{2 * time.Hour, "2h 0m"},
		{25 * time.Hour, "1d 1h 0m"},
		{49*time.Hour + 30*time.Minute, "2d 1h 30m"},
	}

	for _, test := range tests {
		result := formatDuration(test.input)
		if result != test.expected {
			t.Errorf("formatDuration(%v) = %s, expected %s", test.input, result, test.expected)
		}
	}
}

func TestTruncateString(t *testing.T) {
	tests := []struct {
		input    string
		maxLen   int
		expected string
	}{
		{"short", 10, "short"},
		{"this is a long string", 10, "this is..."},
		{"exact", 5, "exact"},
	}

	for _, test := range tests {
		result := truncateString(test.input, test.maxLen)
		if result != test.expected {
			t.Errorf("truncateString(%s, %d) = %s, expected %s", test.input, test.maxLen, result, test.expected)
		}
	}
}

func TestCalculateHealthScore(t *testing.T) {
	tests := []struct {
		name     string
		snapshot MetricsSnapshot
		minScore int
		maxScore int
	}{
		{
			name: "Healthy system",
			snapshot: MetricsSnapshot{
				CPUPercent:  20,
				MemPercent:  40,
				SwapPercent: 10,
				Disks: []DiskInfo{
					{UsedPercent: 50},
				},
			},
			minScore: 90,
			maxScore: 100,
		},
		{
			name: "High CPU",
			snapshot: MetricsSnapshot{
				CPUPercent:  95,
				MemPercent:  40,
				SwapPercent: 10,
				Disks: []DiskInfo{
					{UsedPercent: 50},
				},
			},
			minScore: 50,
			maxScore: 75,
		},
		{
			name: "High Memory",
			snapshot: MetricsSnapshot{
				CPUPercent:  20,
				MemPercent:  95,
				SwapPercent: 10,
				Disks: []DiskInfo{
					{UsedPercent: 50},
				},
			},
			minScore: 60,
			maxScore: 80,
		},
		{
			name: "Critical Disk",
			snapshot: MetricsSnapshot{
				CPUPercent:  20,
				MemPercent:  40,
				SwapPercent: 10,
				Disks: []DiskInfo{
					{Device: "C:", UsedPercent: 98},
				},
			},
			minScore: 60,
			maxScore: 85,
		},
		{
			name: "Multiple issues",
			snapshot: MetricsSnapshot{
				CPUPercent:  95,
				MemPercent:  95,
				SwapPercent: 85,
				Disks: []DiskInfo{
					{Device: "C:", UsedPercent: 98},
				},
			},
			minScore: 0,
			maxScore: 30,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			score, msg := calculateHealthScore(test.snapshot)
			if score < test.minScore || score > test.maxScore {
				t.Errorf("calculateHealthScore() = %d (%s), expected between %d and %d",
					score, msg, test.minScore, test.maxScore)
			}
		})
	}
}

func TestNewCollector(t *testing.T) {
	collector := NewCollector()

	if collector == nil {
		t.Fatal("NewCollector returned nil")
	}

	if collector.prevNet == nil {
		t.Error("prevNet map should be initialized")
	}
}

func TestGetMoleFrame(t *testing.T) {
	// Test visible frames
	for i := 0; i < 8; i++ {
		frame := getMoleFrame(i, false)
		if frame == "" {
			t.Errorf("getMoleFrame(%d, false) returned empty string", i)
		}
	}

	// Test hidden
	frame := getMoleFrame(0, true)
	if frame != "" {
		t.Errorf("getMoleFrame(0, true) = %s, expected empty string", frame)
	}
}

func TestRenderProgressBar(t *testing.T) {
	tests := []struct {
		percent float64
		width   int
	}{
		{0, 20},
		{50, 20},
		{100, 20},
		{75, 30},
	}

	for _, test := range tests {
		result := renderProgressBar(test.percent, test.width)
		if result == "" {
			t.Errorf("renderProgressBar(%.0f, %d) returned empty string", test.percent, test.width)
		}
	}
}

func TestGetPercentColor(t *testing.T) {
	// Just verify it doesn't panic
	_ = getPercentColor(50)
	_ = getPercentColor(75)
	_ = getPercentColor(90)
}

func TestNewModel(t *testing.T) {
	model := newModel()

	if model.collector == nil {
		t.Error("collector should be initialized")
	}

	if model.ready {
		t.Error("ready should be false initially")
	}
}
