package app

import (
	"log/slog"
	"runtime"
)

// RecoverWithStack handles panic recovery by logging the error and full stack trace.
// It is intended to be used as a deferred function at the entry point of
// background goroutines: defer RecoverWithStack("task-name").
func RecoverWithStack(taskName string) {
	if r := recover(); r != nil {
		const stackSize = 4096
		stack := make([]byte, stackSize)
		n := runtime.Stack(stack, false)
		slog.Error("panic in background task",
			"task", taskName,
			"error", r,
			"stack", string(stack[:n]),
		)
	}
}
