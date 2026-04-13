//nolint:testpackage // requires unexported vector internals for testing
package vector

import (
	"testing"

	"google.golang.org/genai"
)

func TestNewGeminiProvider_StoresModel(t *testing.T) {
	t.Parallel()
	tests := []struct {
		name  string
		model string
	}{
		{
			name:  "standard embedding model",
			model: "text-embedding-004",
		},
		{
			name:  "custom embedding model",
			model: "my-custom-embedding-model",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			p := NewGeminiProvider(&genai.Client{}, tc.model)
			if p.model != tc.model {
				t.Errorf("NewGeminiProvider model = %q, want %q", p.model, tc.model)
			}
		})
	}
}
