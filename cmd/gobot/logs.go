package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/allthingscode/gobot/internal/config"
	"github.com/spf13/cobra"
)

func cmdLogs() *cobra.Command {
	var lines int
	var filter string
	var since string
	var follow bool

	cmd := &cobra.Command{
		Use:   "logs",
		Short: "View the most recent gobot logs",
		PreRunE: func(_ *cobra.Command, _ []string) error {
			if lines <= 0 {
				return fmt.Errorf("--lines must be greater than 0, got %d", lines)
			}
			return nil
		},
		RunE: func(cmd *cobra.Command, _ []string) error {
			return runLogs(cmd, lines, filter, since, follow)
		},
	}

	cmd.Flags().IntVar(&lines, "lines", 100, "Number of lines to tail")
	cmd.Flags().StringVar(&filter, "filter", "", "Filter by level: ERROR, WARN, INFO, DEBUG")
	cmd.Flags().StringVar(&since, "since", "", "Show logs since duration (e.g., 1h, 30m)")
	cmd.Flags().BoolVar(&follow, "follow", false, "Follow log output")

	return cmd
}

func runLogs(cmd *cobra.Command, lines int, filter, since string, follow bool) error {
	cfg, err := config.Load()
	if err != nil {
		return fmt.Errorf("config load failed: %w", err)
	}

	latestPath, err := findLatestLogFile(cfg.LogsRoot())
	if err != nil {
		return err
	}

	sinceTime, err := parseSinceDuration(since)
	if err != nil {
		return err
	}

	filter = strings.ToUpper(filter)
	filterFn := makeLogFilter(filter, sinceTime)

	file, err := os.Open(latestPath)
	if err != nil {
		return fmt.Errorf("failed to open log file: %w", err)
	}
	defer func() { _ = file.Close() }()

	reader := bufio.NewReader(file)
	ringBuffer, pending, err := readInitialLogs(reader, lines, filterFn)
	if err != nil {
		return err
	}

	for _, l := range ringBuffer {
		cmd.Println(l)
	}

	if follow {
		return followLogs(cmd, reader, pending, filterFn)
	}

	return nil
}

func findLatestLogFile(logsDir string) (string, error) {
	entries, err := os.ReadDir(logsDir)
	if err != nil {
		if os.IsNotExist(err) {
			return "", fmt.Errorf("log directory not found")
		}
		return "", fmt.Errorf("failed to read log directory: %w", err)
	}

	var logFiles []os.DirEntry
	for _, entry := range entries {
		if !entry.IsDir() && strings.HasPrefix(entry.Name(), "gobot_") && strings.HasSuffix(entry.Name(), ".log") {
			logFiles = append(logFiles, entry)
		}
	}

	if len(logFiles) == 0 {
		return "", fmt.Errorf("no log files found")
	}

	// Sort by modification time descending (most recent first)
	sort.Slice(logFiles, func(i, j int) bool {
		iInfo, _ := logFiles[i].Info()
		jInfo, _ := logFiles[j].Info()
		return iInfo.ModTime().After(jInfo.ModTime())
	})
	return filepath.Join(logsDir, logFiles[0].Name()), nil
}

func parseSinceDuration(since string) (time.Time, error) {
	if since == "" {
		return time.Time{}, nil
	}
	d, err := time.ParseDuration(since)
	if err != nil {
		return time.Time{}, fmt.Errorf("invalid since duration %q: %w", since, err)
	}
	return time.Now().Add(-d), nil
}

func makeLogFilter(filter string, sinceTime time.Time) func(string) bool {
	return func(logLine string) bool {
		if filter != "" && !strings.Contains(logLine, "level="+filter) {
			return false
		}

		if sinceTime.IsZero() {
			return true
		}

		t, ok := parseLogTime(logLine)
		if !ok {
			return false
		}
		return !t.Before(sinceTime)
	}
}

func parseLogTime(logLine string) (time.Time, bool) {
	timePrefix := "time="
	idx := strings.Index(logLine, timePrefix)
	if idx == -1 {
		return time.Time{}, true
	}
	timeStrEnd := strings.IndexByte(logLine[idx+len(timePrefix):], ' ')
	if timeStrEnd == -1 {
		return time.Time{}, true
	}
	timeStr := logLine[idx+len(timePrefix) : idx+len(timePrefix)+timeStrEnd]
	t, err := time.Parse(time.RFC3339Nano, timeStr)
	if err != nil {
		return time.Time{}, false
	}
	return t, true
}

func readInitialLogs(reader *bufio.Reader, lines int, filterFn func(string) bool) (logs []string, pending string, err error) {
	var ringBuffer []string

	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			if err == io.EOF {
				pending += line
				break
			}
			return nil, "", fmt.Errorf("error reading log file: %w", err)
		}

		fullLineStr := cleanLine(pending + line)
		pending = ""

		if !filterFn(fullLineStr) {
			continue
		}

		ringBuffer = append(ringBuffer, fullLineStr)
		if len(ringBuffer) > lines {
			ringBuffer = ringBuffer[1:]
		}
	}
	return ringBuffer, pending, nil
}

func followLogs(cmd *cobra.Command, reader *bufio.Reader, pending string, filterFn func(string) bool) error {
	for {
		select {
		case <-cmd.Context().Done():
			return fmt.Errorf("context done: %w", cmd.Context().Err())
		default:
		}

		line, err := reader.ReadString('\n')
		if err != nil {
			if err == io.EOF {
				pending += line
				select {
				case <-cmd.Context().Done():
					return fmt.Errorf("context done: %w", cmd.Context().Err())
				case <-time.After(500 * time.Millisecond):
				}
				continue
			}
			return fmt.Errorf("error reading log file: %w", err)
		}

		fullLineStr := cleanLine(pending + line)
		pending = ""

		if !filterFn(fullLineStr) {
			continue
		}
		cmd.Println(fullLineStr)
	}
}

func cleanLine(line string) string {
	line = strings.TrimSuffix(line, "\n")
	line = strings.TrimSuffix(line, "\r")
	return line
}
