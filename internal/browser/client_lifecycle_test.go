//nolint:testpackage // injects allocator lifecycle functions to stay offline
package browser

import (
	"context"
	"errors"
	"reflect"
	"testing"

	"github.com/allthingscode/gobot/internal/config"
	"github.com/chromedp/chromedp"
	"github.com/chromedp/chromedp/remote"
)

type lifecycleProbe struct {
	calls []string
	url   string
	opts  int
	start error
	alloc context.Context
	ctx   context.Context
}

func (p *lifecycleProbe) runtime(t *testing.T) clientRuntime {
	t.Helper()
	allocate := func(parent context.Context, name string) (context.Context, context.CancelFunc) {
		p.calls = append(p.calls, name)
		var cancel context.CancelFunc
		p.alloc, cancel = context.WithCancel(parent)
		return p.alloc, func() { p.calls = append(p.calls, "allocator close"); cancel() }
	}
	return clientRuntime{
		remote: func(parent context.Context, url string) (context.Context, context.CancelFunc) {
			p.url = url
			return allocate(parent, "remote")
		},
		local: func(parent context.Context, opts ...chromedp.ExecAllocatorOption) (context.Context, context.CancelFunc) {
			p.opts = len(opts)
			return allocate(parent, "local")
		},
		newContext: func(parent context.Context) (context.Context, context.CancelFunc) {
			if parent != p.alloc {
				t.Fatal("browser context has wrong parent")
			}
			p.calls = append(p.calls, "context")
			var cancel context.CancelFunc
			p.ctx, cancel = context.WithCancel(parent)
			return p.ctx, func() { p.calls = append(p.calls, "context close"); cancel() }
		},
		start: func(ctx context.Context) error {
			if ctx != p.ctx {
				t.Fatal("start did not receive browser context")
			}
			p.calls = append(p.calls, "start")
			return p.start
		},
	}
}

func TestClientLifecycle(t *testing.T) {
	t.Parallel()
	for _, tt := range []struct {
		name string
		cfg  config.BrowserConfig
	}{
		{"remote", config.BrowserConfig{DebugPort: 9222}},
		{"remote takes priority", config.BrowserConfig{DebugPort: 9222, Headless: true}},
		{"local", config.BrowserConfig{Headless: true}},
	} {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			for _, fail := range []bool{false, true} {
				checkClientLifecycle(t, tt.cfg, fail)
			}
		})
	}
}

func checkClientLifecycle(t *testing.T, cfg config.BrowserConfig, fail bool) {
	t.Helper()
	p := &lifecycleProbe{}
	if fail {
		p.start = errors.New("startup failed")
	}
	client, err := newClient(cfg, p.runtime(t))
	kind := p.checkAllocation(t, cfg)
	if fail {
		if client != nil || !errors.Is(err, p.start) {
			t.Fatalf("startup failure = %v, %v", client, err)
		}
	} else {
		if err != nil {
			t.Fatal(err)
		}
		if p.ctx.Err() != nil || p.alloc.Err() != nil {
			t.Fatal("client was canceled before Close")
		}
		client.Close()
	}
	p.checkClosed(t, kind)
}

func (p *lifecycleProbe) checkClosed(t *testing.T, kind string) {
	t.Helper()
	want := []string{kind, "context", "start", "context close", "allocator close"}
	if !reflect.DeepEqual(p.calls, want) || p.ctx.Err() == nil || p.alloc.Err() == nil {
		t.Fatalf("lifecycle = %v; want %v and canceled contexts", p.calls, want)
	}
}

func (p *lifecycleProbe) checkAllocation(t *testing.T, cfg config.BrowserConfig) string {
	t.Helper()
	kind := "local"
	if cfg.DebugPort > 0 {
		kind = "remote"
		if p.url != "ws://localhost:9222" {
			t.Fatalf("remote URL = %q", p.url)
		}
	} else if p.opts != len(chromedp.DefaultExecAllocatorOptions)+2 {
		t.Fatalf("local options count = %d", p.opts)
	}
	return kind
}

func TestAllocatorContextsOffline(t *testing.T) {
	t.Parallel()
	for _, name := range []string{"local pipe", "remote websocket"} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			var ctx context.Context
			var cancel context.CancelFunc
			if name == "local pipe" {
				ctx, cancel = chromedp.NewExecAllocator(context.Background(), chromedp.DefaultExecAllocatorOptions[:]...)
				if _, ok := chromedp.FromContext(ctx).Allocator.(*chromedp.ExecAllocator); !ok {
					t.Fatal("wrong local allocator")
				}
			} else {
				ctx, cancel = remote.NewAllocator(context.Background(), "ws://localhost:9222")
				if _, ok := chromedp.FromContext(ctx).Allocator.(*remote.Allocator); !ok {
					t.Fatal("wrong remote allocator")
				}
			}
			cancel()
			if ctx.Err() == nil {
				t.Fatal("allocator context not canceled")
			}
		})
	}
}

func TestPersistentTabCleanup(t *testing.T) {
	t.Parallel()
	ctx, cancel := chromedp.NewContext(context.Background())
	client := NewClientForTest(ctx, cancel)
	tab := client.TabContext()
	if client.TabContext() != tab {
		t.Fatal("tool calls must share a tab")
	}
	client.Close()
	if tab.Err() == nil || ctx.Err() == nil || client.tabCtx != nil || client.tabCancel != nil {
		t.Fatal("Close did not release persistent tab and parent")
	}
}

func TestUnconfiguredClient(t *testing.T) {
	t.Parallel()
	if client, err := NewClient(config.BrowserConfig{}); err == nil || client != nil {
		t.Fatalf("unconfigured client = %v, %v", client, err)
	}
}
