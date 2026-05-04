package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"golang.org/x/mod/semver"
)

// Module represents the output of 'go list -m -json all'.
type Module struct {
	Path      string `json:"Path"`
	Main      bool   `json:"Main"`
	GoVersion string `json:"GoVersion"`
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	fmt.Println("Checking Go version alignment...")
	ctx := context.Background()

	mainMod, err := getMainModule(ctx)
	if err != nil {
		return err
	}

	currentVersion := ensureVPrefix(mainMod.GoVersion)
	fmt.Printf("Current Go version (go.mod): %s\n", mainMod.GoVersion)

	maxRequired, bottleneckMod, err := getHighestDependencyVersion(ctx)
	if err != nil {
		return err
	}

	fmt.Printf("Highest required Go version by dependencies: %s (from %s)\n", strings.TrimPrefix(maxRequired, "v"), bottleneckMod)

	return compareVersions(currentVersion, mainMod.GoVersion, maxRequired)
}

func getMainModule(ctx context.Context) (Module, error) {
	cmd := exec.CommandContext(ctx, "go", "list", "-mod=readonly", "-m", "-json")
	output, err := cmd.Output()
	if err != nil {
		return Module{}, fmt.Errorf("error running 'go list': %w", err)
	}

	var mainMod Module
	if err := json.Unmarshal(output, &mainMod); err != nil {
		return Module{}, fmt.Errorf("error parsing main module JSON: %w", err)
	}
	return mainMod, nil
}

func getHighestDependencyVersion(ctx context.Context) (maxRequired, bottleneckMod string, err error) {
	cmd := exec.CommandContext(ctx, "go", "list", "-mod=readonly", "-m", "-json", "all")
	output, err := cmd.Output()
	if err != nil {
		return "", "", fmt.Errorf("error running 'go list all': %w", err)
	}

	dec := json.NewDecoder(strings.NewReader(string(output)))
	maxRequired = "v1.0"

	for dec.More() {
		var mod Module
		if err := dec.Decode(&mod); err != nil {
			return "", "", fmt.Errorf("error decoding module JSON: %w", err)
		}

		if mod.Main || mod.GoVersion == "" {
			continue
		}

		ver := ensureVPrefix(mod.GoVersion)
		if semver.Compare(ver, maxRequired) > 0 {
			maxRequired = ver
			bottleneckMod = mod.Path
		}
	}
	return maxRequired, bottleneckMod, nil
}

func ensureVPrefix(v string) string {
	if !strings.HasPrefix(v, "v") {
		return "v" + v
	}
	return v
}

func compareVersions(currentVersion, currentVersionRaw, maxRequired string) error {
	cmp := semver.Compare(currentVersion, maxRequired)
	switch {
	case cmp < 0:
		return fmt.Errorf("go.mod version (%s) is LESS than required version (%s)",
			currentVersionRaw, strings.TrimPrefix(maxRequired, "v"))
	case cmp > 0:
		fmt.Printf("WARNING: go.mod version (%s) is HIGHER than strictly required (%s). Downgrade may be possible but deferred.\n",
			currentVersionRaw, strings.TrimPrefix(maxRequired, "v"))
		return nil
	default:
		fmt.Println("SUCCESS: Go version is perfectly aligned with dependencies.")
		return nil
	}
}
