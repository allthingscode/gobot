//nolint:testpackage // requires unexported batch internals for testing
package cron

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseModularJobFile(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()

	tests := []struct {
		name     string
		filename string
		content  string
		wantErr  bool
		validate func(*testing.T, *Job)
	}{
		{"valid cron schedule", "cron-job.md", cronJobContent(), false, validateCronJob},
		{"valid every schedule hours", "every-h.md", everyHContent(), false, validateEveryH},
		{"valid every schedule days", "every-d.md", everyDContent(), false, validateEveryD},
		{"valid at schedule", "at-job.md", atJobContent(), false, validateAtJob},
		{"cron with timezone", "cron-tz.md", cronTZContent(), false, validateCronTZ},
		{"defaults applied", "defaults.md", defaultsContent(), false, validateDefaults},
		{"missing front-matter", "missing-fm.md", "No front matter here", true, nil},
		{"missing schedule", "missing-sched.md", missingSchedContent(), true, nil},
		{"id defaults to filename stem", "stem-test.md", stemTestContent(), false, validateStemTest},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			path := filepath.Join(tmpDir, tt.filename)
			_ = os.WriteFile(path, []byte(tt.content), 0o600)

			job, err := ParseModularJobFile(path)
			if (err != nil) != tt.wantErr {
				t.Errorf("ParseModularJobFile() error = %v, wantErr %v", err, tt.wantErr)
				return
			}
			if !tt.wantErr && tt.validate != nil {
				tt.validate(t, job)
			}
		})
	}
}

func cronJobContent() string {
	return `---
id: daily-report
name: Daily Report
schedule: cron(0 9 * * *)
specialist: researcher
to: telegram:12345
enabled: true
---
This is the task body.
It can span multiple lines.`
}

func validateCronJob(t *testing.T, j *Job) {
	t.Helper()
	if j.ID != "daily-report" {
		t.Errorf("expected ID daily-report, got %s", j.ID)
	}
	if j.Name != "Daily Report" {
		t.Errorf("expected Name Daily Report, got %s", j.Name)
	}
	if j.Schedule.Kind != KindCron || j.Schedule.Expr != "0 9 * * *" {
		t.Errorf("unexpected schedule: %+v", j.Schedule)
	}
	if j.Payload.Channel != "researcher" {
		t.Errorf("expected channel researcher, got %s", j.Payload.Channel)
	}
	if j.Payload.To != "telegram:12345" {
		t.Errorf("expected to telegram:12345, got %s", j.Payload.To)
	}
	if !j.Enabled {
		t.Errorf("expected enabled true")
	}
	expectedBody := "This is the task body.\nIt can span multiple lines."
	if j.Payload.Message != expectedBody {
		t.Errorf("expected body %q, got %q", expectedBody, j.Payload.Message)
	}
}

func everyHContent() string {
	return "---\nid: every-h\nschedule: every(2h)\n---\nBody"
}

func validateEveryH(t *testing.T, j *Job) {
	t.Helper()
	if j.Schedule.Kind != KindEvery || *j.Schedule.EveryMS != 7200000 {
		t.Errorf("expected EveryMS 7200000, got %v", j.Schedule.EveryMS)
	}
}

func everyDContent() string {
	return "---\nid: every-d\nschedule: every(1d)\n---\nBody"
}

func validateEveryD(t *testing.T, j *Job) {
	t.Helper()
	if j.Schedule.Kind != KindEvery || *j.Schedule.EveryMS < 80000000 {
		t.Errorf("expected EveryMS ~86400000, got %v", j.Schedule.EveryMS)
	}
}

func atJobContent() string {
	return "---\nid: at-job\nschedule: at(9999999)\n---\nBody"
}

func validateAtJob(t *testing.T, j *Job) {
	t.Helper()
	if j.Schedule.Kind != KindAt || *j.Schedule.AtMS != 9999999 {
		t.Errorf("expected AtMS 9999999, got %v", j.Schedule.AtMS)
	}
}

func cronTZContent() string {
	return "---\nid: cron-tz\nschedule: cron(0 9 * * 1-5, America/New_York)\n---\nBody"
}

func validateCronTZ(t *testing.T, j *Job) {
	t.Helper()
	if j.Schedule.Kind != KindCron || j.Schedule.Expr != "0 9 * * 1-5" || j.Schedule.TZ != "America/New_York" {
		t.Errorf("unexpected schedule: %+v", j.Schedule)
	}
}

func defaultsContent() string {
	return "---\nid: defaults\nschedule: every(100)\n---\nBody"
}

func validateDefaults(t *testing.T, j *Job) {
	t.Helper()
	if j.Payload.Channel != fallbackChannel {
		t.Errorf("expected default channel telegram, got %s", j.Payload.Channel)
	}
	if !j.Enabled {
		t.Errorf("expected default enabled true")
	}
	if j.Payload.To != "" {
		t.Errorf("expected default to empty, got %s", j.Payload.To)
	}
}

func missingSchedContent() string {
	return "---\nid: no-sched\n---\nBody"
}

func stemTestContent() string {
	return "---\nschedule: every(100)\n---\nBody"
}

func validateStemTest(t *testing.T, j *Job) {
	t.Helper()
	if j.ID != "stem-test" {
		t.Errorf("expected ID stem-test, got %s", j.ID)
	}
	if j.Name != "stem-test" {
		t.Errorf("expected Name stem-test, got %s", j.Name)
	}
	if j.Schedule.Kind != KindEvery {
		t.Errorf("expected KindEvery, got %v", j.Schedule.Kind)
	}
	if j.Payload.Channel != fallbackChannel {
		t.Errorf("expected default channel telegram, got %s", j.Payload.Channel)
	}
	if j.Payload.To != "" {
		t.Errorf("expected default to empty, got %s", j.Payload.To)
	}
	if j.Payload.Message != "Body" {
		t.Errorf("expected body %q, got %q", "Body", j.Payload.Message)
	}
}

func TestParseScheduleString(t *testing.T) {
	t.Parallel()
	tests := []struct {
		input   string
		want    Schedule
		wantErr bool
	}{
		{"cron(0 9 * * *)", Schedule{Kind: KindCron, Expr: "0 9 * * *"}, false},
		{"cron(0 9 * * 1-5, UTC)", Schedule{Kind: KindCron, Expr: "0 9 * * 1-5", TZ: "UTC"}, false},
		{"every(1h)", Schedule{Kind: KindEvery, EveryMS: ptr(int64(3600000))}, false},
		{"every(1d)", Schedule{Kind: KindEvery, EveryMS: ptr(int64(86400000))}, false},
		{"every(30m)", Schedule{Kind: KindEvery, EveryMS: ptr(int64(1800000))}, false},
		{"every(1000)", Schedule{Kind: KindEvery, EveryMS: ptr(int64(1000))}, false},
		{"at(123456789)", Schedule{Kind: KindAt, AtMS: ptr(int64(123456789))}, false},
		{"invalid(123)", Schedule{}, true},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			t.Parallel()
			got, err := parseScheduleString(tt.input)
			if (err != nil) != tt.wantErr {
				t.Errorf("parseScheduleString() error = %v, wantErr %v", err, tt.wantErr)
				return
			}
			if !tt.wantErr {
				validateSchedule(t, got, tt.want)
			}
		})
	}
}

func validateSchedule(t *testing.T, got, want Schedule) {
	t.Helper()
	if got.Kind != want.Kind || got.Expr != want.Expr || got.TZ != want.TZ {
		t.Errorf("got %+v, want %+v", got, want)
	}
	if want.EveryMS != nil {
		if got.EveryMS == nil || *got.EveryMS != *want.EveryMS {
			t.Errorf("got EveryMS %v, want %v", got.EveryMS, want.EveryMS)
		}
	}
	if want.AtMS != nil {
		if got.AtMS == nil || *got.AtMS != *want.AtMS {
			t.Errorf("got AtMS %v, want %v", got.AtMS, want.AtMS)
		}
	}
}

func TestParseModularJobFile_AgentField(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	path := filepath.Join(tmpDir, "test_job.md")

	content := `---
id: test-job
name: Test Job
schedule: every(1h)
agent: researcher
specialist: email
to: user@example.com
---
Research the latest Go news.`

	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}

	job, err := ParseModularJobFile(path)
	if err != nil {
		t.Fatalf("ParseModularJobFile failed: %v", err)
	}

	if job.Payload.Agent != "researcher" {
		t.Errorf("expected Agent 'researcher', got %q", job.Payload.Agent)
	}
	if job.Payload.Channel != "email" {
		t.Errorf("expected Channel 'email', got %q", job.Payload.Channel)
	}
	if job.Payload.To != "user@example.com" {
		t.Errorf("expected To 'user@example.com', got %q", job.Payload.To)
	}
	if job.Payload.Message != "Research the latest Go news." {
		t.Errorf("expected Message content mismatch, got %q", job.Payload.Message)
	}
}

func TestParseModularJobFile_LegacySpecialist(t *testing.T) {
	t.Parallel()
	tmpDir := t.TempDir()
	path := filepath.Join(tmpDir, "legacy_job.md")

	// In legacy behavior, 'specialist' maps to Channel
	content := `---
schedule: every(1h)
specialist: telegram
to: 12345
---
Hello`

	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}

	job, err := ParseModularJobFile(path)
	if err != nil {
		t.Fatalf("ParseModularJobFile failed: %v", err)
	}

	if job.Payload.Channel != "telegram" {
		t.Errorf("expected Channel 'telegram', got %q", job.Payload.Channel)
	}
	if job.Payload.Agent != "" {
		t.Errorf("expected empty Agent, got %q", job.Payload.Agent)
	}
}

