package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"sync"
	"time"
)

type ndjsonEvent struct {
	SchemaVersion int         `json:"schema_version"`
	Operation     string      `json:"operation"`
	Event         string      `json:"event"`
	Timestamp     string      `json:"timestamp"`
	Seq           int64       `json:"seq"`
	RunID         string      `json:"run_id"`
	Data          interface{} `json:"data"`
}

type jsonEmitter struct {
	operation string
	runID     string
	seq       int64
	enc       *json.Encoder
	mu        sync.Mutex
}

func newJSONEmitter(operation string, w io.Writer) *jsonEmitter {
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	return &jsonEmitter{
		operation: operation,
		runID:     newUUIDv4(),
		seq:       0,
		enc:       enc,
	}
}

func (e *jsonEmitter) emit(event string, data interface{}) error {
	e.mu.Lock()
	defer e.mu.Unlock()

	e.seq++
	return e.enc.Encode(ndjsonEvent{
		SchemaVersion: 1,
		Operation:     e.operation,
		Event:         event,
		Timestamp:     time.Now().UTC().Format(time.RFC3339Nano),
		Seq:           e.seq,
		RunID:         e.runID,
		Data:          data,
	})
}

func newUUIDv4() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		now := time.Now().UnixNano()
		return fmt.Sprintf("00000000-0000-0000-0000-%012x", now&0xffffffffffff)
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80

	hexStr := hex.EncodeToString(b[:])
	return fmt.Sprintf("%s-%s-%s-%s-%s",
		hexStr[0:8],
		hexStr[8:12],
		hexStr[12:16],
		hexStr[16:20],
		hexStr[20:32],
	)
}
