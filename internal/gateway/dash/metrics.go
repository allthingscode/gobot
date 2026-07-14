package dash

import (
	"errors"
	"fmt"
	"net/http"
	"os"
	"sort"
	"time"

	"github.com/allthingscode/gobot/internal/agent"
	"github.com/allthingscode/gobot/internal/doctor"
	"github.com/allthingscode/gobot/internal/observability"
)

type metricPageData struct {
	ActiveNav string
	Panels    []metricPanelView
}

type metricPanelView struct {
	Title   string
	Status  string
	Badge   string
	Primary string
	Detail  string
	Rows    []metricRowView
}

type metricRowView struct {
	Name    string
	Status  string
	Badge   string
	Primary string
	Detail  string
}

type latencyRowsResult struct {
	rows        []metricRowView
	sampleCount int
}

const (
	metricStatusOK          = "ok"
	metricStatusWarn        = "warn"
	metricStatusUnavailable = "unavailable"
	metricStaleAfter        = 24 * time.Hour
)

func (h *Handler) handleMetrics(w http.ResponseWriter, _ *http.Request) {
	data := metricPageData{
		ActiveNav: "metrics",
		Panels: []metricPanelView{
			h.latencyPanel(),
			h.memoryPanel(),
			h.storagePanel(),
			h.startupPanel(),
			h.cronPanel(),
			sessionLocksPanel(agent.GetLockMetrics(), time.Now()),
		},
	}
	h.render(w, "layout.html", "metrics.html", data)
}

func (h *Handler) latencyPanel() metricPanelView {
	snapshot, err := observability.ReadLatencySnapshot(h.storageRoot())
	if err != nil {
		return latencyErrorPanel(err)
	}

	result := latencyRows(snapshot)
	return latencySummaryPanel(snapshot, result.rows, result.sampleCount)
}

func latencyErrorPanel(err error) metricPanelView {
	status := metricStatusWarn
	primary := "Unavailable"
	detail := err.Error()
	if errors.Is(err, os.ErrNotExist) {
		status = metricStatusUnavailable
		primary = "Not recorded yet"
		detail = "workspace/latency.json has not been written."
	}
	return metricPanel("Latency P50/P99", status, primary, detail, nil)
}

func latencyRows(snapshot observability.LatencySnapshot) latencyRowsResult {
	byName := make(map[string]observability.LatencyMetricSnapshot, len(snapshot.Metrics))
	for _, metric := range snapshot.Metrics {
		byName[metric.Name] = metric
	}

	var sampleCount int
	rows := make([]metricRowView, 0, len(fixedLatencyMetrics()))
	for _, name := range fixedLatencyMetrics() {
		metric, ok := byName[name]
		if !ok || metric.Count == 0 {
			rows = append(rows, metricRow(name, metricStatusUnavailable, "No samples", "Recent latency has not been recorded for this path."))
			continue
		}
		if metric.P50MS == nil || metric.P99MS == nil {
			rows = append(rows, metricRow(name, metricStatusWarn, "Invalid snapshot", "Measured metric is missing percentile values."))
			continue
		}
		sampleCount += metric.Count
		rows = append(rows, metricRow(
			name,
			metricStatusOK,
			fmt.Sprintf("p50 %d ms / p99 %d ms", *metric.P50MS, *metric.P99MS),
			fmt.Sprintf("%d samples; updated %s", metric.Count, formatMetricTime(metric.UpdatedAt)),
		))
	}
	return latencyRowsResult{rows: rows, sampleCount: sampleCount}
}

func latencySummaryPanel(snapshot observability.LatencySnapshot, rows []metricRowView, sampleCount int) metricPanelView {
	status := metricStatusOK
	primary := fmt.Sprintf("%d recent samples", sampleCount)
	detail := "Generated " + formatMetricTime(snapshot.GeneratedAt)
	switch {
	case sampleCount == 0:
		status = metricStatusUnavailable
		primary = "No samples yet"
		detail = "Latency snapshot exists but contains no dispatch or tool samples."
	case isStale(snapshot.GeneratedAt):
		status = metricStatusWarn
		primary = "Stale snapshot"
		detail = "Generated " + formatMetricTime(snapshot.GeneratedAt) + "; older than 24h."
	}
	return metricPanel("Latency P50/P99", status, primary, detail, rows)
}

func (h *Handler) memoryPanel() metricPanelView {
	snapshot := observability.ReadMemSnapshot()
	return metricPanel(
		"Process Memory",
		metricStatusOK,
		fmt.Sprintf("heap %.1f MiB", snapshot.HeapAllocMiB()),
		fmt.Sprintf("sys %.1f MiB; current process snapshot", snapshot.SysMiB()),
		nil,
	)
}

func (h *Handler) storagePanel() metricPanelView {
	summary, err := doctor.CollectStorageSizeSummary(h.storageRoot())
	if err != nil {
		return metricPanel("Storage Size", metricStatusWarn, "Unavailable", err.Error(), nil)
	}

	total := summary.TotalBytes()
	status := metricStatusOK
	primary := formatMetricBytes(total)
	detail := fmt.Sprintf("Read-only size snapshot; warning threshold %s per store.", formatMetricBytes(summary.WarnThresholdBytes))
	if total == 0 {
		status = metricStatusUnavailable
		primary = "No storage files found"
		detail = "Database files, session files, and logs are absent or empty."
	}

	rows := make([]metricRowView, 0, len(summary.Stores))
	for _, store := range summary.Stores {
		rowStatus := metricStatusOK
		if store.Warn {
			status = metricStatusWarn
			rowStatus = metricStatusWarn
		}
		rows = append(rows, metricRow(store.Name, rowStatus, storagePrimary(store), storageDetail(store)))
	}
	return metricPanel("Storage Size", status, primary, detail, rows)
}

func (h *Handler) startupPanel() metricPanelView {
	snapshot, err := doctor.ReadStartupSnapshot(h.storageRoot())
	if err != nil {
		status := metricStatusWarn
		primary := "Unavailable"
		detail := err.Error()
		if errors.Is(err, os.ErrNotExist) {
			status = metricStatusUnavailable
			primary = "Not recorded yet"
			detail = "workspace/startup.json has not been written."
		}
		return metricPanel("Startup Time", status, primary, detail, nil)
	}
	return metricPanel(
		"Startup Time",
		metricStatusOK,
		fmt.Sprintf("%d ms", snapshot.DurationMS),
		"Ready at "+snapshot.ReadyAt,
		nil,
	)
}

func (h *Handler) cronPanel() metricPanelView {
	if h.res.Cron != nil {
		return liveCronPanel(h.liveCronTasks())
	}
	summary, err := doctor.ReadCronHealth(h.storageRoot(), time.Now().UnixMilli())
	if err != nil {
		return metricPanel("Cron Health", metricStatusWarn, "Unavailable", err.Error(), nil)
	}
	if summary.JobCount == 0 {
		return metricPanel("Cron Health", metricStatusUnavailable, "No scheduled jobs", "No live scheduler is wired and jobs.json has no jobs.", nil)
	}
	if summary.FailingCount > 0 {
		return metricPanel(
			"Cron Health",
			metricStatusWarn,
			fmt.Sprintf("%d of %d jobs failing", summary.FailingCount, summary.JobCount),
			fmt.Sprintf("Last failure on %q.", summary.LastFailureName),
			nil,
		)
	}
	return metricPanel(
		"Cron Health",
		metricStatusOK,
		fmt.Sprintf("%d persisted jobs healthy", summary.JobCount),
		"Next run "+summary.NextRunSummary+".",
		nil,
	)
}

func liveCronPanel(tasks []cronTaskView) metricPanelView {
	if len(tasks) == 0 {
		return metricPanel("Cron Health", metricStatusUnavailable, "No live jobs", "The live scheduler is wired but has no jobs.", nil)
	}
	status := metricStatusOK
	rows := make([]metricRowView, 0, len(tasks))
	for _, task := range tasks {
		rowStatus := cronMetricStatus(task.Status)
		if rowStatus == metricStatusWarn {
			status = metricStatusWarn
		}
		detail := "schedule " + task.Schedule
		if task.NextRunMS > 0 {
			detail += "; next " + time.UnixMilli(task.NextRunMS).Format("2006-01-02 15:04:05")
		}
		rows = append(rows, metricRow(task.Name, rowStatus, task.Status, detail))
	}
	return metricPanel("Cron Health", status, fmt.Sprintf("%d live jobs", len(tasks)), "Live scheduler state from dashboard resources.", rows)
}

func sessionLocksPanel(metrics map[string]agent.LockStatus, now time.Time) metricPanelView {
	if len(metrics) == 0 {
		return metricPanel("Session Locks", metricStatusUnavailable, "No active locks", "No session lock metrics are currently registered.", nil)
	}

	names := make([]string, 0, len(metrics))
	for name := range metrics {
		names = append(names, name)
	}
	sort.Strings(names)

	status := metricStatusOK
	rows := make([]metricRowView, 0, len(names))
	for _, name := range names {
		lock := metrics[name]
		rowStatus := metricStatusOK
		primary := "unlocked"
		if lock.IsLocked {
			primary = "held " + formatLockHoldAge(lock.CurrentHoldDuration(now))
		}
		if lock.IsStale(now, agent.StaleLockThreshold) {
			status = metricStatusWarn
			rowStatus = metricStatusWarn
			primary = "stale " + primary
		}
		rows = append(rows, metricRow(
			name,
			rowStatus,
			primary,
			fmt.Sprintf("contention %d; max wait %s; total hold %s", lock.ContentionCount, lock.MaxWaitTime.Round(time.Millisecond), lock.TotalHoldTime.Round(time.Millisecond)),
		))
	}

	primary := fmt.Sprintf("%d locks observed", len(metrics))
	detail := fmt.Sprintf("Warns when a held lock exceeds %s.", agent.StaleLockThreshold)
	if status == metricStatusWarn {
		primary = "Stale lock detected"
	}
	return metricPanel("Session Locks", status, primary, detail, rows)
}

func (h *Handler) storageRoot() string {
	if h.res.Config == nil {
		return ""
	}
	return h.res.Config.StorageRoot()
}

func metricPanel(title, status, primary, detail string, rows []metricRowView) metricPanelView {
	return metricPanelView{
		Title:   title,
		Status:  status,
		Badge:   metricBadge(status),
		Primary: primary,
		Detail:  detail,
		Rows:    rows,
	}
}

func metricRow(name, status, primary, detail string) metricRowView {
	return metricRowView{
		Name:    name,
		Status:  status,
		Badge:   metricBadge(status),
		Primary: primary,
		Detail:  detail,
	}
}

func metricBadge(status string) string {
	switch status {
	case metricStatusOK:
		return "bg-success"
	case metricStatusWarn:
		return "bg-warning text-dark"
	default:
		return "bg-secondary"
	}
}

func fixedLatencyMetrics() []string {
	return []string{
		observability.LatencyMetricAgentDispatch,
		observability.LatencyMetricTelegramDispatch,
		observability.LatencyMetricToolExecute,
	}
}

func formatMetricTime(t time.Time) string {
	if t.IsZero() {
		return "unknown"
	}
	return t.UTC().Format(time.RFC3339)
}

func isStale(t time.Time) bool {
	return !t.IsZero() && time.Since(t) > metricStaleAfter
}

func formatLockHoldAge(age time.Duration) string {
	if age <= 0 {
		return "n/a"
	}
	return age.Round(time.Millisecond).String()
}

func formatMetricBytes(n int64) string {
	const mib = int64(1 << 20)
	const kib = int64(1 << 10)
	switch {
	case n >= mib:
		return fmt.Sprintf("%.1f MiB", float64(n)/float64(mib))
	case n >= kib:
		return fmt.Sprintf("%d KiB", n/kib)
	default:
		return fmt.Sprintf("%d B", n)
	}
}

func storagePrimary(store doctor.StorageStoreSize) string {
	if store.TotalBytes() == 0 {
		return "absent"
	}
	return formatMetricBytes(store.TotalBytes())
}

func storageDetail(store doctor.StorageStoreSize) string {
	if store.FileCount > 0 {
		return fmt.Sprintf("%d files", store.FileCount)
	}
	if store.WALBytes > 0 {
		return fmt.Sprintf("main %s; wal %s", formatMetricBytes(store.Bytes), formatMetricBytes(store.WALBytes))
	}
	return "main " + storagePrimary(store)
}

func cronMetricStatus(status string) string {
	switch status {
	case "failed":
		return metricStatusWarn
	case "disabled", "pending", "configured":
		return metricStatusUnavailable
	default:
		return metricStatusOK
	}
}
