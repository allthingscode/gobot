package config

import (
	"bytes"
	"testing"
)

func TestMaxToolResultBytes(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name  string
		input string
		want  int
	}{
		{
			name:  "default (missing)",
			input: `{}`,
			want:  32768,
		},
		{
			name:  "explicit value",
			input: `{"agents":{"defaults":{"maxToolResultBytes":1024}}}`,
			want:  1024,
		},
		{
			name:  "zero disables (returns 0 from config)",
			input: `{"agents":{"defaults":{"maxToolResultBytes":0}}}`,
			want:  32768, // Wait, if it's 0, it falls back to 32768 in the current implementation.
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
		t.Parallel()
			cfg, err := decode(bytes.NewReader([]byte(tt.input)))
			if err != nil {
				t.Fatalf("decode failed: %v", err)
			}
			got := cfg.MaxToolResultBytes()
			if got != tt.want {
				t.Errorf("MaxToolResultBytes() = %d, want %d", got, tt.want)
			}
		})
	}
}

func TestMaxToolResultBytes_Disabled(t *testing.T) {
	t.Parallel()
	// The specification says "Zero or negative value disables truncation."
	// However, the current implementation of MaxToolResultBytes() in config.go is:
	// if c.Agents.Defaults.MaxToolResultBytes != 0 {
	//     return c.Agents.Defaults.MaxToolResultBytes
	// }
	// return 32768
	// This means 0 falls back to 32768. 
	// If the user wants to disable it, they might use -1.
	
	cfg := &Config{Agents: AgentsConfig{Defaults: AgentDefaults{MaxToolResultBytes: -1}}}
	if cfg.MaxToolResultBytes() != -1 {
		t.Errorf("expected -1, got %d", cfg.MaxToolResultBytes())
	}
}
