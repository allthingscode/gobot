package app

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

func (cd *CronDispatcher) verifySearchToolProvenance(sessionKey string) (bool, error) {
	latest, err := cd.latestSessionTranscriptPath(sessionKey)
	if err != nil {
		return false, err
	}
	if latest != "" {
		data, readErr := os.ReadFile(latest)
		if readErr != nil {
			return false, fmt.Errorf("read latest session transcript: %w", readErr)
		}
		text := string(data)
		if hasGoogleAISearchEvidence(text) {
			return true, nil
		}
	}

	return cd.verifySearchToolProvenanceFromLogs(sessionKey)
}

func (cd *CronDispatcher) verifySearchToolProvenanceFromLogs(sessionKey string) (bool, error) {
	logPath := filepath.Join(cd.storageRoot, "logs", "gobot.log")
	f, err := os.Open(logPath)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, fmt.Errorf("open gobot log: %w", err)
	}
	defer func() { _ = f.Close() }()

	const maxTailBytes = 512 * 1024
	if info, statErr := f.Stat(); statErr == nil && info.Size() > maxTailBytes {
		if _, seekErr := f.Seek(-maxTailBytes, io.SeekEnd); seekErr != nil {
			_, _ = f.Seek(0, io.SeekStart)
		}
	}

	data, err := io.ReadAll(f)
	if err != nil {
		return false, fmt.Errorf("read gobot log: %w", err)
	}
	text := string(data)
	parentMarker := `session=` + sessionKey + ` tool=spawn_subagent`
	subSession := `session=agent:researcher:` + sessionKey
	parentHasSpawn := strings.Contains(text, parentMarker)
	subHasSearch := hasLineWithAll(text, subSession, "tool=") && hasGoogleAISearchSessionEvidence(text, subSession)
	return parentHasSpawn && subHasSearch, nil
}

func hasGoogleAISearchEvidence(text string) bool {
	return strings.Contains(text, "search_ai") ||
		strings.Contains(text, "google-ai-search") ||
		strings.Contains(text, "google_ai_search")
}

func hasGoogleAISearchSessionEvidence(text, sessionMarker string) bool {
	for _, line := range strings.Split(text, "\n") {
		if strings.Contains(line, sessionMarker) && hasGoogleAISearchEvidence(line) {
			return true
		}
	}
	return false
}

func hasLineWithAll(text string, needles ...string) bool {
	for _, line := range strings.Split(text, "\n") {
		matched := true
		for _, needle := range needles {
			if !strings.Contains(line, needle) {
				matched = false
				break
			}
		}
		if matched {
			return true
		}
	}
	return false
}

func (cd *CronDispatcher) latestSessionTranscriptPath(sessionKey string) (string, error) {
	sessionRoot := filepath.Join(cd.storageRoot, "workspace", "sessions")
	safeSession := sanitizeSessionKeyForFile(sessionKey)
	dayDirs, err := os.ReadDir(sessionRoot)
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", fmt.Errorf("read sessions dir: %w", err)
	}
	candidates := collectSessionTranscriptCandidates(sessionRoot, dayDirs, safeSession)
	if len(candidates) == 0 {
		return "", nil
	}
	sortSessionTranscriptCandidates(candidates)
	return candidates[0], nil
}

func collectSessionTranscriptCandidates(sessionRoot string, dayDirs []os.DirEntry, safeSession string) []string {
	candidates := make([]string, 0)
	for _, d := range dayDirs {
		if !d.IsDir() {
			continue
		}
		dayPath := filepath.Join(sessionRoot, d.Name())
		matches, globErr := filepath.Glob(filepath.Join(dayPath, safeSession+"_*.md"))
		if globErr != nil {
			continue
		}
		candidates = append(candidates, matches...)
	}
	return candidates
}

func sortSessionTranscriptCandidates(candidates []string) {
	sort.Slice(candidates, func(i, j int) bool {
		ii, iErr := os.Stat(candidates[i])
		jj, jErr := os.Stat(candidates[j])
		if iErr != nil || jErr != nil {
			return candidates[i] > candidates[j]
		}
		return ii.ModTime().After(jj.ModTime())
	})
}

var nonFileCharsRe = regexp.MustCompile(`[^a-zA-Z0-9_\-]`)

func sanitizeSessionKeyForFile(s string) string {
	return nonFileCharsRe.ReplaceAllString(s, "_")
}
