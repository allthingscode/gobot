//go:build !windows

package sandbox

import (
	"context"
	"errors"
)

// ErrNotSupported is returned on non-Windows platforms.
var ErrNotSupported = errors.New("sandbox: Windows Job Objects not supported on this platform")

// New returns a stub Executor that always returns ErrNotSupported.
func New(_ Config) Executor {
	return &stubExecutor{}
}

type stubExecutor struct{}

func (s *stubExecutor) Run(_ context.Context, _ string, _ []string) (string, error) {
	return "", ErrNotSupported
}
