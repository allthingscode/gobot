//nolint:testpackage // requires unexported config internals for testing
package config

import (
	"testing"
	"time"
)

func TestVectorIndexInterval(t *testing.T) {
	t.Parallel()
	const def = 24 * time.Hour

	tests := []struct {
		name string
		raw  string
		want time.Duration
	}{
		{"empty defaults to 24h", "", def},
		{"valid duration", "6h", 6 * time.Hour},
		{"valid minutes", "30m", 30 * time.Minute},
		{"invalid falls back", "not-a-duration", def},
		{"zero falls back", "0s", def},
		{"negative falls back", "-5m", def},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			cfg := &Config{}
			cfg.Runtime.VectorIndexInterval = tt.raw
			if got := cfg.VectorIndexInterval(); got != tt.want {
				t.Errorf("VectorIndexInterval(%q) = %v, want %v", tt.raw, got, tt.want)
			}
		})
	}
}
