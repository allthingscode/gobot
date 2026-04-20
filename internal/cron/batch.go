package cron

import (
	"bufio"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// ParseModularJobFile parses a Markdown file with YAML-style front-matter into a Job.
func ParseModularJobFile(path string) (*Job, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read file: %w", err)
	}

	data = stripBOM(data)
	frontMatter, body, err := splitModularFile(string(data))
	if err != nil {
		return nil, err
	}

	job := &Job{
		Enabled: true,
		Payload: Payload{
			Channel: "telegram",
		},
	}

	base := filepath.Base(path)
	job.ID = strings.TrimSuffix(base, filepath.Ext(base))

	scheduleStr := parseFrontMatter(frontMatter, job)

	if job.ID == "" {
		return nil, fmt.Errorf("job id is empty")
	}
	if job.Name == "" {
		job.Name = job.ID
	}
	if scheduleStr == "" {
		return nil, fmt.Errorf("missing schedule field")
	}

	sched, err := parseScheduleString(scheduleStr)
	if err != nil {
		return nil, fmt.Errorf("parse schedule: %w", err)
	}
	job.Schedule = sched
	job.Payload.Message = strings.TrimSpace(strings.Join(body, "\n"))

	return job, nil
}

func stripBOM(data []byte) []byte {
	bom := []byte{0xEF, 0xBB, 0xBF}
	if len(data) >= 3 && data[0] == bom[0] && data[1] == bom[1] && data[2] == bom[2] {
		return data[3:]
	}
	return data
}

func splitModularFile(content string) (frontMatter, body []string, err error) {
	scanner := bufio.NewScanner(strings.NewReader(content))
	inFrontMatter := false
	frontMatterCount := 0

	for scanner.Scan() {
		line := scanner.Text()
		if strings.TrimSpace(line) == "---" {
			frontMatterCount++
			if frontMatterCount == 1 {
				inFrontMatter = true
				continue
			} else if frontMatterCount == 2 {
				inFrontMatter = false
				continue
			}
		}

		if inFrontMatter {
			frontMatter = append(frontMatter, line)
		} else if frontMatterCount >= 2 {
			body = append(body, line)
		}
	}

	if frontMatterCount < 2 {
		return nil, nil, fmt.Errorf("missing front-matter delimiters")
	}
	return frontMatter, body, nil
}

func parseFrontMatter(lines []string, job *Job) string {
	var scheduleStr string
	for _, line := range lines {
		key, val := parseFrontMatterLine(line)
		if key == "" || val == "" {
			continue
		}

		if key == "schedule" {
			scheduleStr = val
			continue
		}

		applyFrontMatterField(job, key, val)
	}
	return scheduleStr
}

func parseFrontMatterLine(line string) (key, val string) {
	parts := strings.SplitN(line, ":", 2)
	if len(parts) < 2 {
		return "", ""
	}
	key = strings.ToLower(strings.TrimSpace(parts[0]))
	val = strings.TrimSpace(parts[1])
	return key, val
}

func applyFrontMatterField(job *Job, key, val string) {
	switch key {
	case "id":
		job.ID = val
	case "name":
		job.Name = val
	case "specialist":
		job.Payload.Channel = val
	case "agent":
		job.Payload.Agent = val
	case "to":
		job.Payload.To = val
	case "subject":
		job.Payload.Subject = val
	case "enabled":
		job.Enabled = (strings.ToLower(val) == "true")
	}
}

func parseScheduleString(s string) (Schedule, error) {
	s = strings.TrimSpace(s)
	if strings.HasPrefix(s, "cron(") && strings.HasSuffix(s, ")") {
		inner := s[5 : len(s)-1]
		parts := strings.Split(inner, ",")
		expr := strings.TrimSpace(parts[0])
		tz := ""
		if len(parts) > 1 {
			tz = strings.TrimSpace(parts[1])
		}
		return Schedule{Kind: KindCron, Expr: expr, TZ: tz}, nil
	}

	if strings.HasPrefix(s, "every(") && strings.HasSuffix(s, ")") {
		inner := s[6 : len(s)-1]
		ms, err := parseDurationToMS(inner)
		if err != nil {
			return Schedule{}, err
		}
		return Schedule{Kind: KindEvery, EveryMS: ptr(ms)}, nil
	}

	if strings.HasPrefix(s, "at(") && strings.HasSuffix(s, ")") {
		inner := s[3 : len(s)-1]
		ms, err := strconv.ParseInt(inner, 10, 64)
		if err != nil {
			return Schedule{}, fmt.Errorf("invalid at timestamp: %w", err)
		}
		return Schedule{Kind: KindAt, AtMS: ptr(ms)}, nil
	}

	return Schedule{}, fmt.Errorf("unknown schedule format: %s", s)
}

func parseDurationToMS(s string) (int64, error) {
	if ms, err := strconv.ParseInt(s, 10, 64); err == nil {
		return ms, nil
	}

	if len(s) < 2 {
		return 0, fmt.Errorf("invalid duration: %s", s)
	}

	unit := s[len(s)-1:]
	valStr := s[:len(s)-1]
	val, err := strconv.ParseInt(valStr, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid duration value: %s", valStr)
	}

	switch unit {
	case "s":
		return val * 1000, nil
	case "m":
		return val * 60 * 1000, nil
	case "h":
		return val * 3600 * 1000, nil
	case "d":
		return val * 86400 * 1000, nil
	default:
		return 0, fmt.Errorf("unknown duration unit: %s", unit)
	}
}

func ptr[T any](v T) *T {
	return &v
}

// LoadModularJobs scans itemsDir for .md files and parses each into a Job.
// Files that fail to parse are logged and skipped.
func LoadModularJobs(itemsDir string) ([]Job, error) {
	entries, err := os.ReadDir(itemsDir)
	if err != nil {
		return nil, fmt.Errorf("read items dir: %w", err)
	}
	jobs := make([]Job, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(strings.ToLower(e.Name()), ".md") {
			continue
		}
		path := filepath.Join(itemsDir, e.Name())
		job, err := ParseModularJobFile(path)
		if err != nil {
			slog.Warn("Cron: skipping malformed job file", "file", e.Name(), "err", err)
			continue
		}
		jobs = append(jobs, *job)
	}
	return jobs, nil
}
