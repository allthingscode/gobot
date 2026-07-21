package app

import (
	"context"
	"fmt"
	"strings"
	"sync"
)

type toolMetaKey struct{}

// ToolMeta collects key-value metadata from a tool execution via context.
// Any tool can write metadata by calling toolMetaFromCtx; the runner reads
// it back after Execute() returns and appends a labeled block to the result
// before injecting into the LLM context.
type ToolMeta struct {
	mu   sync.Mutex
	vals map[string]string
}

// Set stores a metadata key-value pair. Safe for concurrent use.
func (m *ToolMeta) Set(k, v string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.vals == nil {
		m.vals = make(map[string]string)
	}
	m.vals[k] = v
}

// withToolMeta injects a fresh ToolMeta into ctx and returns both.
func withToolMeta(ctx context.Context) (context.Context, *ToolMeta) {
	m := &ToolMeta{}
	return context.WithValue(ctx, toolMetaKey{}, m), m
}

// toolMetaFromCtx extracts the ToolMeta from ctx, or nil if absent.
func toolMetaFromCtx(ctx context.Context) *ToolMeta {
	m, _ := ctx.Value(toolMetaKey{}).(*ToolMeta)
	return m
}

// formatToolMetaBlock appends a [tool_meta]...[/tool_meta] block to result
// when metadata has been collected. Returns result unchanged if no metadata.
func formatToolMetaBlock(result string, meta *ToolMeta) string {
	if meta == nil {
		return result
	}
	meta.mu.Lock()
	vals := meta.vals
	meta.mu.Unlock()
	if len(vals) == 0 {
		return result
	}

	var sb strings.Builder
	sb.WriteString(result)
	sb.WriteString("\n\n[tool_meta]\n")
	for _, k := range []string{"agent_type", "fallback_key", "model", "provider", "elapsed_ms", "iterations"} {
		if v, ok := vals[k]; ok {
			fmt.Fprintf(&sb, "%s: %s\n", k, v)
		}
	}
	sb.WriteString("[/tool_meta]")
	return sb.String()
}
