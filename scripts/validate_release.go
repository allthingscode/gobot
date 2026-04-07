//go:build ignore

// Command validate_release performs pre-flight checks for GitHub releases.
// It validates:
//  1. Tag format and uniqueness
//  2. File sizes (<2GB per GitHub limits)
//  3. Git token permissions
//  4. Rate limit status
//  5. Asset file existence
//
// Usage: go run scripts/validate_release.go
package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const (
	maxFileSize  = 2 * 1024 * 1024 * 1024 // 2GB GitHub limit
	githubAPIURL = "https://api.github.com"
	tagPattern   = `^v\d+\.\d+\.\d+$`
)

type ReleaseValidation struct {
	Errors   []string
	Warnings []string
}

func (rv *ReleaseValidation) AddError(format string, args ...interface{}) {
	rv.Errors = append(rv.Errors, fmt.Sprintf(format, args...))
}

func (rv *ReleaseValidation) AddWarning(format string, args ...interface{}) {
	rv.Warnings = append(rv.Warnings, fmt.Sprintf(format, args...))
}

func (rv *ReleaseValidation) HasErrors() bool {
	return len(rv.Errors) > 0
}

func main() {
	validation := &ReleaseValidation{}

	// Get environment variables
	tag := os.Getenv("GITHUB_REF")
	token := os.Getenv("GITHUB_TOKEN")
	repo := os.Getenv("GITHUB_REPOSITORY")

	// Extract tag from ref (refs/tags/v1.0.0 -> v1.0.0)
	var trimmed bool
	tag, trimmed = strings.CutPrefix(tag, "refs/tags/")
	_ = trimmed // suppress unused warning

	fmt.Print("=== GitHub Release Pre-Flight Validation ===\n\n")

	// Check 1: Validate tag format
	fmt.Println("1/5: Validating tag format...")
	validateTagFormat(tag, validation)

	// Check 2: Verify GitHub token
	fmt.Println("2/5: Verifying GitHub token...")
	validateToken(token, repo, validation)

	// Check 3: Check rate limit status
	fmt.Println("3/5: Checking rate limit status...")
	checkRateLimit(token, validation)

	// Check 4: Validate release assets
	fmt.Println("4/5: Validating release assets...")
	validateAssets(validation)

	// Check 5: Check tag uniqueness
	fmt.Println("5/5: Checking tag uniqueness...")
	validateTagUniqueness(tag, token, repo, validation)

	// Print results
	fmt.Println("\n=== Validation Results ===")

	if len(validation.Warnings) > 0 {
		fmt.Printf("\n\u26A0\uFE0F  %d warning(s):\n", len(validation.Warnings))
		for _, w := range validation.Warnings {
			fmt.Printf("   - %s\n", w)
		}
	}

	if validation.HasErrors() {
		fmt.Printf("\n\u274C %d error(s) found:\n", len(validation.Errors))
		for _, e := range validation.Errors {
			fmt.Printf("   - %s\n", e)
		}
		fmt.Println("\nRelease validation FAILED")
		os.Exit(1)
	}

	if len(validation.Warnings) == 0 {
		fmt.Println("\n\u2705 All checks passed! Proceeding with release...")
	} else {
		fmt.Println("\n\u2705 Validation passed with warnings")
	}
}

func validateTagFormat(tag string, v *ReleaseValidation) {
	if tag == "" {
		v.AddError("GITHUB_REF environment variable not set or empty")
		return
	}

	tagRe := regexp.MustCompile(tagPattern)
	if !tagRe.MatchString(tag) {
		v.AddError("Tag %q does not match semantic versioning pattern (e.g., v1.0.0)", tag)
		return
	}

	fmt.Printf("   \u2705 Tag format valid: %s\n", tag)
}

func validateToken(token, repo string, v *ReleaseValidation) {
	if token == "" {
		v.AddError("GITHUB_TOKEN environment variable not set")
		return
	}

	// Check token permissions by querying user info
	client := &http.Client{Timeout: 10 * time.Second}
	req, _ := http.NewRequest("GET", githubAPIURL+"/user", nil)
	req.Header.Set("Authorization", "token "+token)

	resp, err := client.Do(req)
	if err != nil {
		v.AddWarning("Could not verify token: %v", err)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		v.AddError("Invalid GitHub token (HTTP %d)", resp.StatusCode)
		return
	}

	var user map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&user); err == nil {
		if login, ok := user["login"].(string); ok {
			fmt.Printf("   \u2705 Token authenticated for user: %s\n", login)
		}
	}

	// Check repo permissions
	if repo != "" {
		parts := strings.Split(repo, "/")
		if len(parts) == 2 {
			owner, repoName := parts[0], parts[1]
			req, _ := http.NewRequest("GET",
				fmt.Sprintf("%s/repos/%s/%s", githubAPIURL, owner, repoName), nil)
			req.Header.Set("Authorization", "token "+token)

			resp, err := client.Do(req)
			if err == nil {
				defer resp.Body.Close()
				if resp.StatusCode == http.StatusOK {
					var repoInfo map[string]interface{}
					if err := json.NewDecoder(resp.Body).Decode(&repoInfo); err == nil {
						if perms, ok := repoInfo["permissions"].(map[string]interface{}); ok {
							if push, ok := perms["push"].(bool); ok && push {
								fmt.Println("   \u2705 Token has push permissions to repository")
							} else {
								v.AddError("Token lacks push permissions to repository %s", repo)
							}
						}
					}
				}
			}
		}
	}
}

func checkRateLimit(token string, v *ReleaseValidation) {
	if token == "" {
		return // Already checked
	}

	client := &http.Client{Timeout: 10 * time.Second}
	req, _ := http.NewRequest("GET", githubAPIURL+"/rate_limit", nil)
	req.Header.Set("Authorization", "token "+token)

	resp, err := client.Do(req)
	if err != nil {
		v.AddWarning("Could not check rate limit: %v", err)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		v.AddWarning("Rate limit check failed (HTTP %d)", resp.StatusCode)
		return
	}

	var limitInfo map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&limitInfo); err != nil {
		v.AddWarning("Failed to parse rate limit response: %v", err)
		return
	}

	if resources, ok := limitInfo["resources"].(map[string]interface{}); ok {
		if core, ok := resources["core"].(map[string]interface{}); ok {
			remaining := core["remaining"].(float64)
			limit := core["limit"].(float64)
			resetTime := time.Unix(int64(core["reset"].(float64)), 0)

			fmt.Printf("   \u2705 API rate limit: %.0f/%.0f remaining (resets in %v)\n",
				remaining, limit, time.Until(resetTime).Truncate(time.Minute))

			if remaining < 10 {
				v.AddWarning("Very few API calls remaining (%.0f). Release might fail.", remaining)
			}
		}
	}
}

func validateAssets(v *ReleaseValidation) {
	assets := []string{
		"gobot-*-windows-amd64.exe",
		"gobot-*-linux-amd64",
	}

	foundCount := 0
	for _, pattern := range assets {
		matches, _ := filepath.Glob(pattern)
		if len(matches) == 0 {
			v.AddWarning("Asset file not found: %s", pattern)
		} else {
			for _, file := range matches {
				info, err := os.Stat(file)
				if err != nil {
					v.AddError("Cannot stat file %s: %v", file, err)
					continue
				}

				if info.Size() == 0 {
					v.AddError("File %s is empty", file)
				} else if info.Size() > maxFileSize {
					v.AddError("File %s exceeds GitHub's 2GB limit (%.2f GB)",
						file, float64(info.Size())/float64(maxFileSize))
				} else {
					fmt.Printf("   \u2705 Asset %s: %.2f MB\n", file, float64(info.Size())/(1024*1024))
					foundCount++
				}
			}
		}
	}

	if foundCount == 0 {
		v.AddError("No valid release assets found")
	} else {
		fmt.Printf("   Found %d asset file(s)\n", foundCount)
	}
}

func validateTagUniqueness(tag, token, repo string, v *ReleaseValidation) {
	if tag == "" || token == "" || repo == "" {
		v.AddWarning("Skipping tag uniqueness check (missing environment variables)")
		return
	}

	client := &http.Client{Timeout: 10 * time.Second}
	url := fmt.Sprintf("%s/repos/%s/git/ref/tags/%s", githubAPIURL, repo, tag)
	req, _ := http.NewRequest("GET", url, nil)
	req.Header.Set("Authorization", "token "+token)

	resp, err := client.Do(req)
	if err != nil {
		v.AddWarning("Could not check tag uniqueness: %v", err)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusOK {
		v.AddError("Tag %s already exists in repository %s", tag, repo)
		return
	} else if resp.StatusCode == http.StatusNotFound {
		fmt.Printf("   \u2705 Tag %s is available\n", tag)
	} else {
		v.AddWarning("Unexpected response checking tag (HTTP %d)", resp.StatusCode)
	}
}
