//nolint:testpackage // intentionally uses unexported helpers from main package
package main

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/spf13/cobra"
)

type lockedLogOutput struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (o *lockedLogOutput) Write(p []byte) (int, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.buf.Write(p)
}

func (o *lockedLogOutput) String() string {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.buf.String()
}

func TestFollowLogsStreamsAppendedLineAndCancels(t *testing.T) {
	t.Parallel()

	h := startFollowLogsTest(t, "", func(string) bool { return true })

	appended := `time=2026-07-20T12:00:00Z level=INFO msg="appended after start"`
	h.append(t, appended+"\n")
	h.waitFor(t, "appended after start")

	h.cancel()
	err := h.waitDone(t)
	if !isContextDoneError(err) {
		t.Fatalf("expected context done error after streamed line, got %v", err)
	}
}

func TestFollowLogsFiltersAppendedLines(t *testing.T) {
	t.Parallel()

	h := startFollowLogsTest(t, "", makeLogFilter("error", time.Time{}))

	h.append(t, strings.Join([]string{
		`time=2026-07-20T12:00:00Z level=INFO msg="ignore me"`,
		`time=2026-07-20T12:00:01Z level=ERROR msg="keep me"`,
		"",
	}, "\n"))
	h.waitFor(t, "keep me")

	got := h.output.String()
	if strings.Contains(got, "ignore me") {
		t.Fatalf("non-matching appended line reached output: %q", got)
	}
	if !strings.Contains(got, "keep me") {
		t.Fatalf("matching appended line missing from output: %q", got)
	}

	h.cancel()
	if err := h.waitDone(t); !isContextDoneError(err) {
		t.Fatalf("expected context done error, got %v", err)
	}
}

func TestFollowLogsCompletesPendingPartialLine(t *testing.T) {
	t.Parallel()

	pending := `time=2026-07-20T12:00:00Z level=INFO msg="partial`
	h := startFollowLogsTest(t, pending, func(string) bool { return true })

	h.waitWithout(t, "partial", 100*time.Millisecond)
	h.append(t, ` line"`+"\n")
	h.waitFor(t, `msg="partial line"`)

	got := h.output.String()
	if strings.Contains(got, "\n line") {
		t.Fatalf("partial suffix was printed as a separate line: %q", got)
	}

	h.cancel()
	if err := h.waitDone(t); !isContextDoneError(err) {
		t.Fatalf("expected context done error, got %v", err)
	}
}

type followLogsHarness struct {
	path   string
	output *lockedLogOutput
	cancel context.CancelFunc
	done   chan error
}

func startFollowLogsTest(t *testing.T, pending string, filterFn func(string) bool) *followLogsHarness {
	t.Helper()

	path := filepath.Join(t.TempDir(), "gobot.log")
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	file, err := os.Open(path)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { _ = file.Close() })

	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)

	cmd := &cobra.Command{}
	cmd.SetContext(ctx)
	output := &lockedLogOutput{}
	cmd.SetOut(output)

	done := make(chan error, 1)
	go func() {
		done <- followLogs(cmd, bufio.NewReader(file), pending, filterFn)
	}()

	return &followLogsHarness{
		path:   path,
		output: output,
		cancel: cancel,
		done:   done,
	}
}

func (h *followLogsHarness) append(t *testing.T, content string) {
	t.Helper()

	file, err := os.OpenFile(h.path, os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		t.Fatalf("OpenFile append: %v", err)
	}
	defer func() { _ = file.Close() }()

	if _, err := file.WriteString(content); err != nil {
		t.Fatalf("WriteString append: %v", err)
	}
}

func (h *followLogsHarness) waitFor(t *testing.T, want string) {
	t.Helper()

	deadline := time.After(2 * time.Second)
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()

	for {
		if strings.Contains(h.output.String(), want) {
			return
		}
		select {
		case err := <-h.done:
			t.Fatalf("followLogs returned before output %q: %v", want, err)
		case <-deadline:
			t.Fatalf("timed out waiting for %q in output %q", want, h.output.String())
		case <-ticker.C:
		}
	}
}

func (h *followLogsHarness) waitWithout(t *testing.T, unwanted string, duration time.Duration) {
	t.Helper()

	timer := time.NewTimer(duration)
	defer timer.Stop()
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()

	for {
		if strings.Contains(h.output.String(), unwanted) {
			t.Fatalf("output unexpectedly contained %q: %q", unwanted, h.output.String())
		}
		select {
		case err := <-h.done:
			t.Fatalf("followLogs returned while checking absence of %q: %v", unwanted, err)
		case <-timer.C:
			return
		case <-ticker.C:
		}
	}
}

func (h *followLogsHarness) waitDone(t *testing.T) error {
	t.Helper()

	select {
	case err := <-h.done:
		return err
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for followLogs to return after cancellation")
		return nil
	}
}

func isContextDoneError(err error) bool {
	return err != nil && strings.Contains(err.Error(), "context done") && errors.Is(err, context.Canceled)
}
