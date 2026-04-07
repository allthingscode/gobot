package main

import (
	"sync"
	"testing"
	"time"
)

func TestDrainGoroutines(t *testing.T) {
	tests := []struct {
		name          string
		wgCount       int
		blockDuration time.Duration
		timeout       time.Duration
		wantMinTime   time.Duration
		wantMaxTime   time.Duration
	}{
		{
			name:          "DrainCompletesBeforeTimeout",
			wgCount:       1,
			blockDuration: 20 * time.Millisecond,
			timeout:       200 * time.Millisecond,
			wantMinTime:   10 * time.Millisecond,
			wantMaxTime:   100 * time.Millisecond,
		},
		{
			name:          "DrainForcedByTimeout",
			wgCount:       1,
			blockDuration: 500 * time.Millisecond,
			timeout:       50 * time.Millisecond,
			wantMinTime:   40 * time.Millisecond,
			wantMaxTime:   150 * time.Millisecond,
		},
		{
			name:          "ZeroGoroutines",
			wgCount:       0,
			blockDuration: 0,
			timeout:       200 * time.Millisecond,
			wantMinTime:   0,
			wantMaxTime:   20 * time.Millisecond,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var wg sync.WaitGroup
			if tt.wgCount > 0 {
				wg.Add(tt.wgCount)
				go func() {
					time.Sleep(tt.blockDuration)
					// Only call Done if it was actually added
					for i := 0; i < tt.wgCount; i++ {
						wg.Done()
					}
				}()
			}

			start := time.Now()
			drainGoroutines(&wg, tt.timeout)
			elapsed := time.Since(start)

			if elapsed < tt.wantMinTime {
				t.Errorf("drainGoroutines() took %v, want >= %v", elapsed, tt.wantMinTime)
			}
			if elapsed > tt.wantMaxTime {
				t.Errorf("drainGoroutines() took %v, want <= %v", elapsed, tt.wantMaxTime)
			}
		})
	}
}
