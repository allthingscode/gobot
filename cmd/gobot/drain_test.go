//nolint:testpackage // intentionally uses unexported helpers from main package
package main

import (
	"sync"
	"testing"
	"time"

	"github.com/allthingscode/gobot/internal/app"
)

func TestDrainGoroutines(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name          string
		wgCount       int
		blockDuration time.Duration
		timeout       time.Duration
		wantMinTime   time.Duration
		wantMaxTime   time.Duration
	}{
		{
			name:          "completed_immediately",
			wgCount:       0,
			blockDuration: 0,
			timeout:       1 * time.Second,
			wantMinTime:   0,
			wantMaxTime:   100 * time.Millisecond,
		},
		{
			name:          "waits_for_completion",
			wgCount:       1,
			blockDuration: 200 * time.Millisecond,
			timeout:       1 * time.Second,
			wantMinTime:   200 * time.Millisecond,
			wantMaxTime:   500 * time.Millisecond,
		},
		{
			name:          "times_out",
			wgCount:       1,
			blockDuration: 1 * time.Second,
			timeout:       200 * time.Millisecond,
			wantMinTime:   200 * time.Millisecond,
			wantMaxTime:   500 * time.Millisecond,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			var wg sync.WaitGroup
			for i := 0; i < tt.wgCount; i++ {
				wg.Add(1)
				go func() {
					defer wg.Done()
					time.Sleep(tt.blockDuration)
				}()
			}

			start := time.Now()
			app.DrainGoroutines(&wg, tt.timeout)
			elapsed := time.Since(start)

			if elapsed < tt.wantMinTime {
				t.Errorf("DrainGoroutines() took %v, want at least %v", elapsed, tt.wantMinTime)
			}
			if elapsed > tt.wantMaxTime {
				t.Errorf("DrainGoroutines() took %v, want at most %v", elapsed, tt.wantMaxTime)
			}
		})
	}
}
