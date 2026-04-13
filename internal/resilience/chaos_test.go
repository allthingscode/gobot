//nolint:testpackage // requires unexported internals for testing
package resilience

import (
	"context"
	"math/rand"
	"net/http"
	"sync"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/testutil"
)

func chaosWorker(start time.Time, duration time.Duration, cb *Breaker, cfg RetryConfig, fsURL string, wg *sync.WaitGroup) {
	defer wg.Done()
	for time.Since(start) < duration {
		_ = cb.Execute(func() error {
			return Do(context.Background(), cfg, IsRetryable, func() error {
				req, _ := http.NewRequestWithContext(context.Background(), "GET", fsURL, http.NoBody)
				resp, err := http.DefaultClient.Do(req)
				if err != nil {
					return err
				}
				defer func() { _ = resp.Body.Close() }()
				if resp.StatusCode >= 500 {
					return &HTTPStatusError{StatusCode: resp.StatusCode}
				}
				return nil
			})
		})
		// Small sleep to prevent tight loop
		// #nosec G404
		time.Sleep(time.Duration(rand.Intn(10)) * time.Millisecond)
	}
}

func TestChaos_RandomFailures(t *testing.T) {
	t.Parallel()
	if testing.Short() {
		t.Skip("skipping chaos test in short mode")
	}

	fs := testutil.NewFaultyServer()
	defer fs.Close()

	// 30% failure rate with various error modes
	fs.FailureRate = 0.3
	fs.FailureCodes = []int{http.StatusInternalServerError, http.StatusBadGateway, http.StatusServiceUnavailable, http.StatusGatewayTimeout}
	fs.Delay = 10 * time.Millisecond
	fs.DropConnection = true // some failures will be connection drops

	cb := New("chaos-breaker", 5, 1*time.Second, 100*time.Millisecond)
	defer cb.Stop()

	cfg := RetryConfig{
		MaxAttempts:  3,
		InitialDelay: 5 * time.Millisecond,
		Multiplier:   1.5,
		JitterFactor: 0.2,
	}

	// Run for 10 seconds
	duration := 10 * time.Second
	start := time.Now()

	var wg sync.WaitGroup
	concurrency := 5
	wg.Add(concurrency)

	for i := 0; i < concurrency; i++ {
		go chaosWorker(start, duration, cb, cfg, fs.URL, &wg)
	}

	wg.Wait()

	t.Logf("Chaos test completed: %d total requests", fs.RequestCount)
}
