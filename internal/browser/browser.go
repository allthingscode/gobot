package browser

import (
	"context"
	"fmt"
	"sync"

	"github.com/chromedp/chromedp"

	"github.com/allthingscode/gobot/internal/config"
)

// Client wraps a chromedp browser context and its allocator.
type Client struct {
	ctx    context.Context
	cancel context.CancelFunc

	mu        sync.Mutex
	tabCtx    context.Context
	tabCancel context.CancelFunc
}

// NewClient creates a new browser client based on the configuration.
func NewClient(cfg config.BrowserConfig) (*Client, error) {
	var allocCtx context.Context
	var allocCancel context.CancelFunc

	switch {
	case cfg.DebugPort > 0:
		url := fmt.Sprintf("ws://localhost:%d", cfg.DebugPort)
		allocCtx, allocCancel = chromedp.NewRemoteAllocator(context.Background(), url)
	case cfg.Headless:
		opts := append(chromedp.DefaultExecAllocatorOptions[:],
			chromedp.Flag("headless", true),
			chromedp.Flag("disable-gpu", true),
		)
		allocCtx, allocCancel = chromedp.NewExecAllocator(context.Background(), opts...)
	default:
		return nil, fmt.Errorf("browser not configured (headless=false, debug_port=0)")
	}

	// Create an initial context to start the browser.
	ctx, cancel := chromedp.NewContext(allocCtx)

	// Ensure the browser is started.
	if err := chromedp.Run(ctx); err != nil {
		cancel()
		allocCancel()
		return nil, fmt.Errorf("failed to start browser: %w", err)
	}

	return &Client{
		ctx: ctx,
		cancel: func() {
			cancel()
			allocCancel()
		},
	}, nil
}

// NewClientForTest creates a client without initializing a real browser for unit testing.
func NewClientForTest(ctx context.Context, cancel context.CancelFunc) *Client {
	return &Client{ctx: ctx, cancel: cancel}
}

// TabContext returns a persistent tab context shared across browser tool calls.
func (c *Client) TabContext() context.Context {
	c.mu.Lock()
	defer c.mu.Unlock()

	if c.tabCtx == nil {
		c.tabCtx, c.tabCancel = chromedp.NewContext(c.ctx)
	}
	return c.tabCtx
}

// Close cancels the browser context and allocator.
func (c *Client) Close() {
	c.mu.Lock()
	tabCancel := c.tabCancel
	c.tabCancel = nil
	c.tabCtx = nil
	c.mu.Unlock()

	if tabCancel != nil {
		tabCancel()
	}
	if c.cancel != nil {
		c.cancel()
	}
}
