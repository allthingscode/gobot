package config

import (
	"bytes"
	"testing"
)

func TestDecode_NoBOM(t *testing.T) {
	input := `{"agents":{"defaults":{"model":"gemini-3-flash-preview"}}}`
	cfg, err := decode(bytes.NewReader([]byte(input)))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Agents.Defaults.Model != "gemini-3-flash-preview" {
		t.Errorf("got model %q, want %q", cfg.Agents.Defaults.Model, "gemini-3-flash-preview")
	}
}

func TestDecode_WithBOM(t *testing.T) {
	// UTF-8 BOM prefix followed by valid JSON
	bom := []byte{0xEF, 0xBB, 0xBF}
	json := []byte(`{"providers":{"gemini":{"apiKey":"test-key"}}}`)
	input := append(bom, json...)

	cfg, err := decode(bytes.NewReader(input))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Providers.Gemini.APIKey != "test-key" {
		t.Errorf("got apiKey %q, want %q", cfg.Providers.Gemini.APIKey, "test-key")
	}
}

func TestDecode_MissingField_DoesNotError(t *testing.T) {
	// Partial config — missing fields should zero-value, not error
	cfg, err := decode(bytes.NewReader([]byte(`{}`)))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Agents.Defaults.Model != "" {
		t.Errorf("expected empty model, got %q", cfg.Agents.Defaults.Model)
	}
}

func TestDecode_MalformedJSON(t *testing.T) {
	_, err := decode(bytes.NewReader([]byte(`{not valid json`)))
	if err == nil {
		t.Fatal("expected error for malformed JSON, got nil")
	}
}

func TestStorageRoot_Default(t *testing.T) {
	cfg := &Config{}
	if cfg.StorageRoot() != `D:\Nanobot_Storage` {
		t.Errorf("got %q, want default storage root", cfg.StorageRoot())
	}
}

func TestStorageRoot_Override(t *testing.T) {
	cfg := &Config{Strategic: StrategicConfig{StorageRoot: `E:\CustomStorage`}}
	if cfg.StorageRoot() != `E:\CustomStorage` {
		t.Errorf("got %q, want override storage root", cfg.StorageRoot())
	}
}
