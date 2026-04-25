//nolint:testpackage // requires unexported factory internals for testing
package provider

import (
	"context"
	"testing"
)

func TestFactory_InitAll_Empty(t *testing.T) { //nolint:paralleltest // mutates global registry; must not run in parallel
	t.Cleanup(ResetForTest)
	f := &Factory{}
	err := f.InitAll(context.Background(), nil)
	if err != nil {
		t.Fatalf("expected no error with empty config, got %v", err)
	}
}

func TestRegistry_RegisterGetList(t *testing.T) { //nolint:paralleltest // mutates global registry; must not run in parallel
	t.Cleanup(ResetForTest)

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

	p2, err := Get(providerNameOpenAI)
	if err != nil {
		t.Fatalf("Get failed: %v", err)
	}
	if p2.Name() != providerNameOpenAI {
		t.Errorf("got name %q", p2.Name())
	}

	_, err = Get("not-exists")
	if err == nil {
		t.Error("expected error for non-existent provider")
	}

	list := List()
	if len(list) != 1 || list[0] != providerNameOpenAI {
		t.Errorf("unexpected list: %v", list)
	}
}
