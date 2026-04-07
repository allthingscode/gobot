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
		{
			name:     "valid cron schedule",
			filename: "cron-job.md",
			content: `---
id: daily-report
name: Daily Report
schedule: cron(0 9 * * *)
specialist: researcher
to: telegram:12345
enabled: true
---
This is the task body.
It can span multiple lines.`,
			wantErr: false,
			validate: func(t *testing.T, j *Job) {
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
			},
		},
		{
			name:     "valid every schedule hours",
			filename: "every-h.md",
			content: `---
id: every-h
schedule: every(2h)
---
Body`,
			wantErr: false,
			validate: func(t *testing.T, j *Job) {
				if j.Schedule.Kind != KindEvery || *j.Schedule.EveryMS != 7200000 {
					t.Errorf("expected EveryMS 7200000, got %v", j.Schedule.EveryMS)
				}
			},
		},
		{
			name:     "valid every schedule days",
			filename: "every-d.md",
			content: `---
id: every-d
schedule: every(1d)
---
Body`,
			wantErr: false,
			validate: func(t *testing.T, j *Job) {
				if j.Schedule.Kind != KindEvery || *j.Schedule.EveryMS != 86400000 {
					t.Errorf("expected EveryMS 86400000, got %v", j.Schedule.EveryMS)
				}
			},
		},
		{
			name:     "valid at schedule",
			filename: "at-job.md",
			content: `---
id: at-job
schedule: at(9999999)
---
Body`,
			wantErr: false,
			validate: func(t *testing.T, j *Job) {
				if j.Schedule.Kind != KindAt || *j.Schedule.AtMS != 9999999 {
					t.Errorf("expected AtMS 9999999, got %v", j.Schedule.AtMS)
				}
			},
		},
		{
			name:     "cron with timezone",
			filename: "cron-tz.md",
			content: `---
id: cron-tz
schedule: cron(0 9 * * 1-5, America/New_York)
---
Body`,
			wantErr: false,
			validate: func(t *testing.T, j *Job) {
				if j.Schedule.Kind != KindCron || j.Schedule.Expr != "0 9 * * 1-5" || j.Schedule.TZ != "America/New_York" {
					t.Errorf("unexpected schedule: %+v", j.Schedule)
				}
			},
		},
		{
			name:     "defaults applied",
			filename: "defaults.md",
			content: `---
id: defaults
schedule: every(100)
---
Body`,
			wantErr: false,
			validate: func(t *testing.T, j *Job) {
				if j.Payload.Channel != "telegram" {
					t.Errorf("expected default channel telegram, got %s", j.Payload.Channel)
				}
				if !j.Enabled {
					t.Errorf("expected default enabled true")
				}
				if j.Payload.To != "" {
					t.Errorf("expected default to empty, got %s", j.Payload.To)
				}
			},
		},
		{
			name:     "missing front-matter",
			filename: "missing-fm.md",
			content:  `No front matter here`,
			wantErr:  true,
		},
		{
			name:     "missing schedule",
			filename: "missing-sched.md",
			content: `---
id: no-sched
---
Body`,
			wantErr: true,
		},
		{
			name:     "id defaults to filename stem",
			filename: "stem-test.md",
			content: `---
schedule: every(100)
---
Body`,
			wantErr: false,
			validate: func(t *testing.T, j *Job) {
				if j.ID != "stem-test" {
					t.Errorf("expected ID stem-test, got %s", j.ID)
				}
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
		t.Parallel()
			path := filepath.Join(tmpDir, tt.filename)
			err := os.WriteFile(path, []byte(tt.content), 0o600)
			if err != nil {
				t.Fatalf("failed to write test file: %v", err)
			}

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
				if got.Kind != tt.want.Kind || got.Expr != tt.want.Expr || got.TZ != tt.want.TZ {
					t.Errorf("got %+v, want %+v", got, tt.want)
				}
				if tt.want.EveryMS != nil {
					if got.EveryMS == nil || *got.EveryMS != *tt.want.EveryMS {
						t.Errorf("got EveryMS %v, want %v", got.EveryMS, tt.want.EveryMS)
					}
				}
				if tt.want.AtMS != nil {
					if got.AtMS == nil || *got.AtMS != *tt.want.AtMS {
						t.Errorf("got AtMS %v, want %v", got.AtMS, tt.want.AtMS)
					}
				}
			}
		})
	}
}
