//nolint:testpackage // intentionally tests internals
package dashboard

import (
	"fmt"
	"testing"
	"time"
)

func TestHub_Broadcast(t *testing.T) {
	t.Parallel()
	h := NewHub(10)
	defer h.Close()

	sub1, _ := h.Subscribe()
	sub2, _ := h.Subscribe()

	entry := &LogEntry{
		Timestamp: time.Now(),
		Level:     "INFO",
		Message:   "Test message",
	}

	h.Emit(entry)

	select {
	case e := <-sub1:
		if e.Message != entry.Message {
			t.Errorf("expected %s, got %s", entry.Message, e.Message)
		}
	case <-time.After(100 * time.Millisecond):
		t.Error("sub1 did not receive message")
	}

	select {
	case e := <-sub2:
		if e.Message != entry.Message {
			t.Errorf("expected %s, got %s", entry.Message, e.Message)
		}
	case <-time.After(100 * time.Millisecond):
		t.Error("sub2 did not receive message")
	}
}

func TestHub_LateJoinerBacklog(t *testing.T) {
	t.Parallel()
	h := NewHub(5)
	defer h.Close()

	entries := []*LogEntry{
		{Message: "1"}, {Message: "2"}, {Message: "3"}, {Message: "4"}, {Message: "5"}, {Message: "6"},
	}

	for _, e := range entries {
		h.Emit(e)
	}

	sub, backlog := h.Subscribe()
	if len(backlog) != 5 {
		t.Errorf("expected 5 entries in backlog, got %d", len(backlog))
	}

	if backlog[0].Message != "2" {
		t.Errorf("expected first backlog message to be '2', got '%s'", backlog[0].Message)
	}

	if backlog[4].Message != "6" {
		t.Errorf("expected last backlog message to be '6', got '%s'", backlog[4].Message)
	}

	h.Unsubscribe(sub)
}

func TestHub_Close(t *testing.T) {
	t.Parallel()
	h := NewHub(10)
	sub, _ := h.Subscribe()

	h.Close()
	h.Close() // Second close should be no-op

	select {
	case _, ok := <-sub:
		if ok {
			t.Error("subscriber channel should be closed")
		}
	case <-time.After(100 * time.Millisecond):
		t.Error("subscriber channel not closed after hub close")
	}

	// Emit after close should not panic
	h.Emit(&LogEntry{Message: "after close"})

	// Subscribe after close should return nil
	s2, b2 := h.Subscribe()
	if s2 != nil || b2 != nil {
		t.Error("expected nil subscribe after close")
	}
}

func TestHub_SlowSubscriber(t *testing.T) {
	t.Parallel()
	h := NewHub(10)
	defer h.Close()

	// Sub with no buffer in channel (not the one we create in Subscribe, but we can't easily change that)
	// Actually, Subscribe creates a buffer of 100.
	sub, _ := h.Subscribe()

	// Fill the sub's channel buffer (100)
	for i := 0; i < 150; i++ {
		h.Emit(&LogEntry{Message: fmt.Sprintf("%d", i)})
	}

	// Sub should still be active and have some messages, but some should have been dropped due to 'default' case in Emit
	count := 0
Loop:
	for {
		select {
		case <-sub:
			count++
		default:
			break Loop
		}
	}

	if count > 100 {
		t.Errorf("expected at most 100 messages (the buffer size), got %d", count)
	}
}

func TestHub_Unsubscribe(t *testing.T) {
	t.Parallel()
	h := NewHub(10)
	defer h.Close()

	sub, _ := h.Subscribe()
	h.Unsubscribe(sub)
	h.Unsubscribe(sub) // Double unsubscribe should be safe

	// Verify it's gone
	h.mu.RLock()
	_, ok := h.subscribers[sub]
	h.mu.RUnlock()
	if ok {
		t.Error("subscriber should have been removed")
	}
}

func TestHub_DefaultBufferSize(t *testing.T) {
	t.Parallel()
	h := NewHub(0)
	if h.bufSize != 1000 {
		t.Errorf("expected default buffer size 1000, got %d", h.bufSize)
	}
}