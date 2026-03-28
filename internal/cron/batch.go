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
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("open file: %w", err)
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	var frontMatter []string
	var body []string
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
		return nil, fmt.Errorf("missing front-matter delimiters")
	}

	job := &Job{
		Enabled: true,
		Payload: Payload{
			Channel: "telegram",
		},
	}

	// Default ID from filename
	base := filepath.Base(path)
	ext := filepath.Ext(base)
	job.ID = strings.TrimSuffix(base, ext)

	var scheduleStr string
	for _, line := range frontMatter {
		parts := strings.SplitN(line, ":", 2)
		if len(parts) < 2 {
			continue
		}
		key := strings.ToLower(strings.TrimSpace(parts[0]))
		val := strings.TrimSpace(parts[1])
		if val == "" {
			continue
		}

		switch key {
		case "id":
			job.ID = val
		case "name":
			job.Name = val
		case "schedule":
			scheduleStr = val
		case "specialist":
			job.Payload.Channel = val
		case "to":
			job.Payload.To = val
		case "enabled":
			job.Enabled = (strings.ToLower(val) == "true")
		}
	}

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
	var jobs []Job
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
