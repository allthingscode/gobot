//nolint:testpackage // intentionally in same package to test internal recovery logic
package app

import (
	"bytes"
	"log/slog"
	"strings"
	"sync"
	"testing"
)

//nolint:paralleltest // sets global logger
func TestRecoverWithStack(t *testing.T) {
	var buf bytes.Buffer
	h := slog.NewJSONHandler(&buf, nil)
	logger := slog.New(h)
	
	oldLogger := slog.Default()
	slog.SetDefault(logger)
	defer slog.SetDefault(oldLogger)

	t.Run("it recovers from panic and logs stack", func(t *testing.T) {
		buf.Reset()
		
		done := make(chan struct{})
		go func() {
			defer close(done)
			defer RecoverWithStack("test-task")
			
			slog.Info("inside-goroutine")
			panic("test-error")
		}()
		<-done

		logOutput := buf.String()
		if !strings.Contains(logOutput, "inside-goroutine") {
			t.Errorf("inside-goroutine missing; got %q", logOutput)
		}
		if !strings.Contains(logOutput, "panic in background task") {
			t.Errorf("log message missing; got %q", logOutput)
		}
		if !strings.Contains(logOutput, "test-task") {
			t.Errorf("task name missing; got %q", logOutput)
		}
		if !strings.Contains(logOutput, "test-error") {
			t.Errorf("error message missing; got %q", logOutput)
		}
		if !strings.Contains(logOutput, "stack") {
			t.Errorf("stack trace attribute missing; got %q", logOutput)
		}
	})
}

//nolint:paralleltest // sets global logger
func TestBackgroundGoroutinesRecovery(t *testing.T) {
	var buf bytes.Buffer
	h := slog.NewJSONHandler(&buf, nil)
	logger := slog.New(h)
	
	oldLogger := slog.Default()
	slog.SetDefault(logger)
	defer slog.SetDefault(oldLogger)

	t.Run("heartbeat-panic-simulation", func(t *testing.T) {
		buf.Reset()
		var wg sync.WaitGroup
		wg.Add(1)
		
		go func() {
			defer wg.Done()
			defer RecoverWithStack("heartbeat-runner")
			panic("heartbeat-panic")
		}()
		
		wg.Wait()

		logOutput := buf.String()
		if !strings.Contains(logOutput, "heartbeat-runner") || !strings.Contains(logOutput, "heartbeat-panic") {
			t.Errorf("heartbeat panic not recovered correctly; got %q", logOutput)
		}
	})
}
