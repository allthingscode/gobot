//nolint:testpackage // requires unexported factory internals for testing
package provider

import (
	"context"
	"testing"
)

func TestFactory_InitAll_Empty(t *testing.T) {
	t.Parallel()
	f := &Factory{}
	err := f.InitAll(context.Background())
	if err != nil {
		t.Fatalf("expected no error with empty config, got %v", err)
	}
}

func TestRegistry_RegisterGetList(t *testing.T) {
	t.Parallel()
	// Clear registry for test
	providersMu.Lock()
	providers = make(map[string]Provider)
	providersMu.Unlock()

	p1 := NewOpenAIProvider("key1", "url1")

	err := Register(p1)
	if err != nil {
		t.Fatalf("Register failed: %v", err)
	}

	// Test Duplicate
	err = Register(p1)
	if err == nil {
		t.Error("expected error when registering duplicate provider")
	}

	p2, err := Get("openai")
	if err != nil {
		t.Fatalf("Get failed: %v", err)
	}
	if p2.Name() != "openai" {
		t.Errorf("got name %q", p2.Name())
	}

	_, err = Get("not-exists")
	if err == nil {
		t.Error("expected error for non-existent provider")
	}

	list := List()
	if len(list) != 1 || list[0] != "openai" {
		t.Errorf("unexpected list: %v", list)
	}
}
