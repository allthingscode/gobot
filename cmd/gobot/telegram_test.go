package main

import (
	"testing"
	"time"
)

func TestIsDuplicate(t *testing.T) {
	api := &tgAPI{}

	// First call: not a duplicate.
	if api.isDuplicate(1) {
		t.Error("first call should not be a duplicate")
	}

	// Second call with same ID: duplicate.
	if !api.isDuplicate(1) {
		t.Error("second call with same ID should be a duplicate")
	}

	// Different ID: not a duplicate.
	if api.isDuplicate(2) {
		t.Error("different ID should not be a duplicate")
	}

	// Expired entry: should not be a duplicate.
	api.seenMsgs.Store(int64(99), time.Now().Add(-dedupTTL-time.Second))
	if api.isDuplicate(99) {
		t.Error("expired entry should not be treated as duplicate")
	}
}
