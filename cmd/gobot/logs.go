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

	"github.com/spf13/cobra"
	"github.com/allthingscode/gobot/internal/config"
)

func cmdLogs() *cobra.Command {
	var lines int
	var filter string
	var since string
	var follow bool

	cmd := &cobra.Command{
		Use:   "logs",
		Short: "View the most recent gobot logs",
		PreRunE: func(cmd *cobra.Command, args []string) error {
			if lines <= 0 {
				return fmt.Errorf("--lines must be greater than 0, got %d", lines)
			}
			return nil
		},
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := config.Load()
			if err != nil {
				return fmt.Errorf("config load failed: %w", err)
			}

			logsDir := cfg.LogsRoot()
			entries, err := os.ReadDir(logsDir)
			if err != nil {
				if os.IsNotExist(err) {
					return fmt.Errorf("log directory not found")
				}
				return fmt.Errorf("failed to read log directory: %w", err)
			}

			var logFiles []os.DirEntry
			for _, entry := range entries {
				if !entry.IsDir() && strings.HasPrefix(entry.Name(), "gobot_") && strings.HasSuffix(entry.Name(), ".log") {
					logFiles = append(logFiles, entry)
				}
			}

			if len(logFiles) == 0 {
				return fmt.Errorf("no log files found")
			}

			// Sort by modification time descending (most recent first)
			sort.Slice(logFiles, func(i, j int) bool {
				iInfo, _ := logFiles[i].Info()
				jInfo, _ := logFiles[j].Info()
				return iInfo.ModTime().After(jInfo.ModTime())
			})
			latestPath := filepath.Join(logsDir, logFiles[0].Name())

			var sinceTime time.Time
			if since != "" {
				d, err := time.ParseDuration(since)
				if err != nil {
					return fmt.Errorf("invalid since duration %q: %w", since, err)
				}
				sinceTime = time.Now().Add(-d)
			}

			filter = strings.ToUpper(filter)

			file, err := os.Open(latestPath)
			if err != nil {
				return fmt.Errorf("failed to open log file: %w", err)
			}
			defer file.Close()

			reader := bufio.NewReader(file)
			var ringBuffer []string
			var pending string

			// Helper to apply filters to a log line
			shouldIncludeLine := func(logLine string) bool {
				if filter != "" && !strings.Contains(logLine, "level="+filter) {
					return false
				}

				if !sinceTime.IsZero() {
					timePrefix := "time="
					idx := strings.Index(logLine, timePrefix)
					if idx != -1 {
						timeStrEnd := strings.IndexByte(logLine[idx+len(timePrefix):], ' ')
						if timeStrEnd != -1 {
							timeStr := logLine[idx+len(timePrefix) : idx+len(timePrefix)+timeStrEnd]
							t, err := time.Parse(time.RFC3339Nano, timeStr)
							// Skip lines with malformed timestamps or timestamps before --since bound
							if err != nil {
								return false
							}
							if t.Before(sinceTime) {
								return false
							}
						}
					}
				}
				return true
			}

			for {
				line, err := reader.ReadString('\n')
				if err != nil {
					if err == io.EOF {
						pending += line
						break
					}
					return fmt.Errorf("error reading log file: %w", err)
				}

				fullLine := pending + line
				pending = ""
				fullLineStr := strings.TrimSuffix(fullLine, "\n")
				fullLineStr = strings.TrimSuffix(fullLineStr, "\r")

				if !shouldIncludeLine(fullLineStr) {
					continue
				}

				ringBuffer = append(ringBuffer, fullLineStr)
				if len(ringBuffer) > lines {
					ringBuffer = ringBuffer[1:]
				}
			}

			for _, l := range ringBuffer {
				cmd.Println(l)
			}

			if follow {
				for {
					select {
					case <-cmd.Context().Done():
						return cmd.Context().Err()
					default:
					}

					line, err := reader.ReadString('\n')
					if err != nil {
						if err == io.EOF {
							pending += line
							select {
							case <-cmd.Context().Done():
								return cmd.Context().Err()
							case <-time.After(500 * time.Millisecond):
							}
							continue
						}
						return fmt.Errorf("error reading log file: %w", err)
					}

					fullLine := pending + line
					pending = ""
					fullLineStr := strings.TrimSuffix(fullLine, "\n")
					fullLineStr = strings.TrimSuffix(fullLineStr, "\r")

					if !shouldIncludeLine(fullLineStr) {
						continue
					}
					cmd.Println(fullLineStr)
				}
			}

			return nil
		},
	}

	cmd.Flags().IntVar(&lines, "lines", 100, "Number of lines to tail")
	cmd.Flags().StringVar(&filter, "filter", "", "Filter by level: ERROR, WARN, INFO, DEBUG")
	cmd.Flags().StringVar(&since, "since", "", "Show logs since duration (e.g., 1h, 30m)")
	cmd.Flags().BoolVar(&follow, "follow", false, "Follow log output")

	return cmd
}
