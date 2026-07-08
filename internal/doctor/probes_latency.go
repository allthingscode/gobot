package doctor

import (
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/observability"
)

func checkLatency(cfg *config.Config) Result {
	snapshot, err := observability.ReadLatencySnapshot(cfg.StorageRoot())
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return Result{Name: "latency", OK: true, Detail: "not recorded yet"}
		}
		return Result{
			Name:        "latency",
			OK:          false,
			Detail:      err.Error(),
			Remediation: "Restart gobot once to refresh workspace/latency.json.",
		}
	}

	parts := make([]string, 0, len(snapshot.Metrics))
	for _, metric := range snapshot.Metrics {
		if metric.Count == 0 {
			continue
		}
		parts = append(parts, fmt.Sprintf("%s p50 %dms, p99 %dms", latencyLabel(metric.Name), *metric.P50MS, *metric.P99MS))
	}
	if len(parts) == 0 {
		return Result{Name: "latency", OK: true, Detail: "recorded, no samples yet"}
	}
	return Result{Name: "latency", OK: true, Detail: strings.Join(parts, "; ")}
}

func latencyLabel(name string) string {
	switch name {
	case observability.LatencyMetricAgentDispatch:
		return "agent"
	case observability.LatencyMetricTelegramDispatch:
		return "telegram"
	case observability.LatencyMetricToolExecute:
		return "tool"
	default:
		return name
	}
}
