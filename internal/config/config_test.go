package config

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// errReader is an io.Reader that always returns an error.
type errReader struct{}

func (errReader) Read(_ []byte) (int, error) { return 0, errors.New("read error") }

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

func TestGeminiAPIKey(t *testing.T) {
	cfg := &Config{Providers: ProvidersConfig{Gemini: GeminiConfig{APIKey: "my-key"}}}
	if cfg.GeminiAPIKey() != "my-key" {
		t.Errorf("got %q, want %q", cfg.GeminiAPIKey(), "my-key")
	}
}

func TestGeminiAPIKey_Empty(t *testing.T) {
	cfg := &Config{}
	if cfg.GeminiAPIKey() != "" {
		t.Errorf("expected empty key, got %q", cfg.GeminiAPIKey())
	}
}

func TestDefaultConfigPath(t *testing.T) {
	got := DefaultConfigPath()
	if !strings.HasSuffix(got, filepath.Join(".nanobot", "config.json")) {
		t.Errorf("DefaultConfigPath() = %q, want suffix .nanobot/config.json", got)
	}
}

func TestLoadFrom_ValidFile(t *testing.T) {
	content := `{"providers":{"gemini":{"apiKey":"file-key"}}}`
	f, err := os.CreateTemp(t.TempDir(), "config-*.json")
	if err != nil {
		t.Fatal(err)
	}
	f.WriteString(content)
	f.Close()

	cfg, err := LoadFrom(f.Name())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Providers.Gemini.APIKey != "file-key" {
		t.Errorf("got %q, want %q", cfg.Providers.Gemini.APIKey, "file-key")
	}
}

func TestLoadFrom_MissingFile(t *testing.T) {
	_, err := LoadFrom(filepath.Join(t.TempDir(), "nonexistent.json"))
	if err == nil {
		t.Fatal("expected error for missing file, got nil")
	}
}

func TestDecode_ReadError(t *testing.T) {
	_, err := decode(errReader{})
	if err == nil {
		t.Fatal("expected error from failing reader, got nil")
	}
}

func TestDecode_OnlyBOM(t *testing.T) {
	// BOM with no subsequent JSON — should fail JSON parsing, not panic.
	bom := []byte{0xEF, 0xBB, 0xBF}
	_, err := decode(bytes.NewReader(bom))
	if err == nil {
		t.Fatal("expected parse error for BOM-only input, got nil")
	}
}

// Ensure Load() wires to DefaultConfigPath without panicking.
// We don't assert a specific value since the real config may or may not exist.
func TestLoad_DoesNotPanic(t *testing.T) {
	// Swallow both success and "file not found" — just must not panic.
	_, _ = Load()
}

// Satisfy the io import so errReader compiles cleanly.
var _ io.Reader = errReader{}
