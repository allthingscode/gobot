package main

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/resilience"
)

func TestIsDuplicate(t *testing.T) {
	api := &tgAPI{}

	// First call: not a duplicate.
	if api.isDuplicate("1:1") {
		t.Error("first call should not be a duplicate")
	}

	// Second call with same key: duplicate.
	if !api.isDuplicate("1:1") {
		t.Error("second call with same key should be a duplicate")
	}

	// Different chat ID with same message ID: not a duplicate.
	if api.isDuplicate("2:1") {
		t.Error("different chat ID with same message ID should not be a duplicate")
	}

	// Same chat ID with different message ID: not a duplicate.
	if api.isDuplicate("1:2") {
		t.Error("same chat ID with different message ID should not be a duplicate")
	}

	// Expired entry: should not be a duplicate.
	api.seenMsgs.Store("99:99", time.Now().Add(-dedupTTL-time.Second))
	if api.isDuplicate("99:99") {
		t.Error("expired entry should not be treated as duplicate")
	}
}

func TestIsDuplicate_CrossChatNoFalsePositive(t *testing.T) {
	api := &tgAPI{}

	// Same messageID, different chats — must NOT deduplicate.
	if api.isDuplicate("100:42") {
		t.Error("first call should return false")
	}
	if api.isDuplicate("200:42") {
		t.Error("different chat with same msgID should not be a duplicate")
	}

	// Same composite key — must deduplicate.
	if !api.isDuplicate("100:42") {
		t.Error("same key second call should return true")
	}
}

func TestUpdates_CircuitOpen(t *testing.T) {
	// Initialize a breaker that is already open.
	breaker := resilience.New("test_telegram_circuit", 1, time.Minute, time.Hour)
	_ = breaker.Execute(func() error { return errors.New("fail") })

	api := &tgAPI{
		breaker: breaker,
	}

	_, err := api.Updates(context.Background(), 30)
	if err == nil {
		t.Error("expected error when circuit is open, got nil")
	}
}
