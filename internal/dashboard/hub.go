package dashboard

import (
	"sync"
	"time"
)

// LogEntry represents a single log line to be broadcast to dashboard clients.
type LogEntry struct {
	Timestamp time.Time      `json:"timestamp"`
	Level     string         `json:"level"`
	Message   string         `json:"message"`
	Fields    map[string]any `json:"fields,omitempty"`
}

// Hub manages the broadcast of log entries to multiple SSE clients.
// It maintains a ring buffer of recent logs for late-joining clients.
type Hub struct {
	mu          sync.RWMutex
	subscribers map[chan *LogEntry]struct{}
	buffer      []*LogEntry
	bufSize     int
	closed      bool
}

// NewHub creates a new Hub with the specified ring buffer size.
func NewHub(bufferSize int) *Hub {
	if bufferSize <= 0 {
		bufferSize = 1000
	}
	return &Hub{
		subscribers: make(map[chan *LogEntry]struct{}),
		buffer:      make([]*LogEntry, 0, bufferSize),
		bufSize:     bufferSize,
	}
}

// Emit broadcasts a log entry to all active subscribers and adds it to the ring buffer.
func (h *Hub) Emit(entry *LogEntry) {
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		return
	}

	// Add to ring buffer
	if len(h.buffer) >= h.bufSize {
		h.buffer = h.buffer[1:]
	}
	h.buffer = append(h.buffer, entry)

	// Broadcast to subscribers
	for sub := range h.subscribers {
		select {
		case sub <- entry:
		default:
			// Subscriber is too slow, skip it or we could close it
		}
	}
	h.mu.Unlock()
}

// Subscribe adds a new subscriber and returns a channel for receiving log entries.
// It also returns the current backlog of entries from the ring buffer.
func (h *Hub) Subscribe() (chan *LogEntry, []*LogEntry) {
	h.mu.Lock()
	defer h.mu.Unlock()

	if h.closed {
		return nil, nil
	}

	sub := make(chan *LogEntry, 100)
	h.subscribers[sub] = struct{}{}

	// Copy buffer for the new subscriber
	backlog := make([]*LogEntry, len(h.buffer))
	copy(backlog, h.buffer)

	return sub, backlog
}

// Unsubscribe removes a subscriber and closes its channel.
func (h *Hub) Unsubscribe(sub chan *LogEntry) {
	h.mu.Lock()
	defer h.mu.Unlock()

	if _, ok := h.subscribers[sub]; ok {
		delete(h.subscribers, sub)
		close(sub)
	}
}

// Close closes the hub and all subscriber channels.
func (h *Hub) Close() {
	h.mu.Lock()
	defer h.mu.Unlock()

	if h.closed {
		return
	}

	h.closed = true
	for sub := range h.subscribers {
		close(sub)
	}
	h.subscribers = nil
	h.buffer = nil
}
