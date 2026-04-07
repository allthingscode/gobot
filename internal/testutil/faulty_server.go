package testutil

import (
	"errors"
	"math/rand"
	"net"
	"net/http"
	"net/http/httptest"
	"sync"
	"time"
)

// FaultyServer is a test HTTP server that can be configured to fail in various ways.
type FaultyServer struct {
	*httptest.Server
	mu sync.Mutex

	// FailureRate is the probability (0.0 to 1.0) that a request will fail.
	FailureRate float64

	// FailureCodes is a list of HTTP status codes to return on failure.
	// If empty, 500 Internal Server Error is used.
	FailureCodes []int

	// Delay is the duration to sleep before responding.
	Delay time.Duration

	// DropConnection, if true, will close the connection without sending a response.
	DropConnection bool

	// Sequence allows programming a specific sequence of responses.
	// If not empty, it overrides FailureRate.
	Sequence []ResponseAction

	// current index in the Sequence.
	current int

	// count of requests received.
	RequestCount int
}

// ResponseAction defines how the server should respond to a single request.
type ResponseAction struct {
	StatusCode int
	Delay      time.Duration
	Drop       bool
}

// NewFaultyServer creates a new FaultyServer.
func NewFaultyServer() *FaultyServer {
	fs := &FaultyServer{
		FailureCodes: []int{http.StatusInternalServerError},
	}
	fs.Server = httptest.NewServer(http.HandlerFunc(fs.handle))
	return fs
}

func (fs *FaultyServer) handle(w http.ResponseWriter, _ *http.Request) {
	fs.mu.Lock()
	fs.RequestCount++

	var action ResponseAction
	switch {
	case len(fs.Sequence) > 0:
		if fs.current < len(fs.Sequence) {
			action = fs.Sequence[fs.current]
			fs.current++
		} else {
			// Default to success after sequence is exhausted
			action = ResponseAction{StatusCode: http.StatusOK}
		}
	case fs.FailureRate > 0 && rand.Float64() < fs.FailureRate: //nolint:gosec // test-only RNG, not security-sensitive
		code := http.StatusInternalServerError
		if len(fs.FailureCodes) > 0 {
			code = fs.FailureCodes[rand.Intn(len(fs.FailureCodes))] // #nosec G404
		}
		action = ResponseAction{
			StatusCode: code,
			Delay:      fs.Delay,
			Drop:       fs.DropConnection,
		}
	default:
		action = ResponseAction{
			StatusCode: http.StatusOK,
			Delay:      fs.Delay,
		}
	}
	fs.mu.Unlock()

	if action.Delay > 0 {
		time.Sleep(action.Delay)
	}

	if action.Drop {
		hj, ok := w.(http.Hijacker)
		if !ok {
			// Fallback if hijacking is not supported
			http.Error(w, "webserver doesn't support hijacking", http.StatusInternalServerError)
			return
		}
		conn, _, err := hj.Hijack()
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		_ = conn.Close()
		return
	}

	if action.StatusCode >= 400 {
		w.WriteHeader(action.StatusCode)
		_, _ = w.Write([]byte("error injected by faulty server"))
		return
	}

	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

// Reset resets the request count and sequence index.
func (fs *FaultyServer) Reset() {
	fs.mu.Lock()
	defer fs.mu.Unlock()
	fs.RequestCount = 0
	fs.current = 0
}

// Update safely updates fields of the server.
func (fs *FaultyServer) Update(fn func(fs *FaultyServer)) {
	fs.mu.Lock()
	defer fs.mu.Unlock()
	fn(fs)
}

// Close closes the underlying httptest.Server.
func (fs *FaultyServer) Close() {
	fs.Server.Close()
}

// IsNetworkError returns true if the error is likely a network-level error
// (e.g. connection refused, timeout, EOF).
func IsNetworkError(err error) bool {
	if err == nil {
		return false
	}
	var netErr net.Error
	if errors.As(err, &netErr) {
		return true
	}
	// Add more checks if needed (e.g. strings.Contains(err.Error(), "EOF"))
	return false
}
