//nolint:testpackage // exercises the package-level Roundtripper contract
package secrets

import (
	"errors"
	"runtime"
	"strings"
	"testing"
)

// fakeRoundtripper is an in-memory Roundtripper used to drive RoundtripTest
// through its success and failure branches without touching real DPAPI/AES
// storage.
type fakeRoundtripper struct {
	data      map[string]string
	setErr    error
	getErr    error
	overrideR string // if non-empty, Get returns this instead of the stored value
	deleted   int
}

func newFakeRoundtripper() *fakeRoundtripper {
	return &fakeRoundtripper{data: map[string]string{}}
}

func (f *fakeRoundtripper) Set(key, value string) error {
	if f.setErr != nil {
		return f.setErr
	}
	f.data[key] = value
	return nil
}

func (f *fakeRoundtripper) Get(key string) (string, error) {
	if f.getErr != nil {
		return "", f.getErr
	}
	if f.overrideR != "" {
		return f.overrideR, nil
	}
	return f.data[key], nil
}

func (f *fakeRoundtripper) Delete(_ string) error {
	f.deleted++
	return nil
}

func TestRoundtripTest_Success(t *testing.T) {
	t.Parallel()
	store := newFakeRoundtripper()
	if err := RoundtripTest(store); err != nil {
		t.Fatalf("expected success, got: %v", err)
	}
	// One best-effort pre-clean plus one deferred cleanup.
	if store.deleted < 2 {
		t.Errorf("expected the test key to be cleaned up, got %d deletes", store.deleted)
	}
}

func TestRoundtripTest_WriteFail(t *testing.T) {
	t.Parallel()
	store := newFakeRoundtripper()
	store.setErr = errors.New("protect failed")
	err := RoundtripTest(store)
	if err == nil {
		t.Fatal("expected error on write failure")
	}
	if !strings.Contains(err.Error(), "write failed") {
		t.Errorf("expected 'write failed', got: %v", err)
	}
	if !strings.Contains(err.Error(), runtime.GOOS) {
		t.Errorf("expected OS %q in error, got: %v", runtime.GOOS, err)
	}
}

func TestRoundtripTest_ReadFail(t *testing.T) {
	t.Parallel()
	store := newFakeRoundtripper()
	store.getErr = errors.New("unprotect failed")
	err := RoundtripTest(store)
	if err == nil {
		t.Fatal("expected error on read failure")
	}
	if !strings.Contains(err.Error(), "read failed") {
		t.Errorf("expected 'read failed', got: %v", err)
	}
	if !strings.Contains(err.Error(), "Task Scheduler") {
		t.Errorf("expected account-mismatch hint, got: %v", err)
	}
}

func TestRoundtripTest_Mismatch(t *testing.T) {
	t.Parallel()
	store := newFakeRoundtripper()
	store.overrideR = "tampered"
	err := RoundtripTest(store)
	if err == nil {
		t.Fatal("expected error on readback mismatch")
	}
	if !strings.Contains(err.Error(), "mismatch") {
		t.Errorf("expected 'mismatch', got: %v", err)
	}
}

func TestCurrentUsername(t *testing.T) {
	t.Parallel()
	if CurrentUsername() == "" {
		t.Error("CurrentUsername must never return an empty string")
	}
}
