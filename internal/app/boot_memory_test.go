package app_test

import (
	"bytes"
	"log/slog"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/app"
)

func TestLogBootMemory_EmitsDebugRecordWithFields(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelDebug}))

	app.LogBootMemory(logger)

	out := buf.String()
	if !strings.Contains(out, "level=DEBUG") {
		t.Errorf("boot memory line not at DEBUG level: %q", out)
	}
	if !strings.Contains(out, "gobot: boot memory") {
		t.Errorf("missing boot memory message: %q", out)
	}
	for _, key := range []string{"heap_alloc_mib=", "sys_mib="} {
		if !strings.Contains(out, key) {
			t.Errorf("missing field %q in boot memory line: %q", key, out)
		}
	}
}

func TestLogBootMemory_SilentAtInfoLevel(t *testing.T) {
	t.Parallel()
	var buf bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelInfo}))

	app.LogBootMemory(logger)

	if buf.Len() != 0 {
		t.Errorf("boot memory should be silent at INFO level, got: %q", buf.String())
	}
}

func TestLogBootMemory_NilLoggerDoesNotPanic(t *testing.T) {
	t.Parallel()
	app.LogBootMemory(nil)
}
