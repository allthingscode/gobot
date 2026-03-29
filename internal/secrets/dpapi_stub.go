//go:build !windows

package secrets

import "errors"

var errNotSupported = errors.New("DPAPI secrets are only supported on Windows")

func protect(_ []byte) ([]byte, error)   { return nil, errNotSupported }
func unprotect(_ []byte) ([]byte, error) { return nil, errNotSupported }
