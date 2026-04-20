package browser_test

import (
	"context"
	"testing"

	"github.com/allthingscode/gobot/internal/browser"
	"github.com/allthingscode/gobot/internal/config"
)

func TestNewClient_InvalidConfig(t *testing.T) {
	t.Parallel()
	_, err := browser.NewClient(config.BrowserConfig{
		Headless:  false,
		DebugPort: 0,
	})
	if err == nil {
		t.Error("expected error for unconfigured browser, got nil")
	}
}

func TestClient_Close(t *testing.T) {
	t.Parallel()
	ctx, cancel := context.WithCancel(context.Background())
	c := browser.NewClientForTest(ctx, cancel)
	c.Close()

	select {
	case <-ctx.Done():
		// Expected, context should be canceled
	default:
		t.Error("expected context to be canceled by Close")
	}
}
