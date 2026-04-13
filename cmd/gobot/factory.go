package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"time"

	"github.com/spf13/cobra"

	"github.com/allthingscode/gobot/internal/factory"
)

// stripBOM removes the UTF-8 Byte Order Mark (BOM) if present.
func stripBOM(data []byte) []byte {
	return bytes.TrimPrefix(data, []byte("\xef\xbb\xbf"))
}

func cmdFactory() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "factory",
		Short: "Dev Factory management commands",
		Long:  `Internal commands for managing the Dev Factory pipeline and state.`,
	}

	cmd.AddCommand(
		cmdFactoryState(),
	)

	return cmd
}

func cmdFactoryState() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "state",
		Short: "Manage Dev Factory session state",
	}

	cmd.AddCommand(
		cmdFactoryStateValidate(),
		cmdFactoryStateMigrate(),
	)

	return cmd
}

func cmdFactoryStateValidate() *cobra.Command {
	return &cobra.Command{
		Use:   "validate [file]",
		Short: "Validate a session state file against the formalized schema",
		Args:  cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			data, err := os.ReadFile(args[0])
			if err != nil {
				return fmt.Errorf("reading file: %w", err)
			}

			data = stripBOM(data)
			var state factory.SessionState
			if err := json.Unmarshal(data, &state); err != nil {
				return fmt.Errorf("invalid schema: %w", err)
			}

			fmt.Printf("Successfully validated %s (Version: %s)\n", args[0], state.Version)
			return nil
		},
	}
}

func cmdFactoryStateMigrate() *cobra.Command {
	return &cobra.Command{
		Use:   "migrate [file]",
		Short: "Migrate legacy session state to the formalized schema",
		Args:  cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			return runMigrate(args[0])
		},
	}
}

func runMigrate(filePath string) error {
	data, err := os.ReadFile(filePath)
	if err != nil {
		return fmt.Errorf("reading file: %w", err)
	}

	data = stripBOM(data)
	var legacy map[string]interface{}
	if err := json.Unmarshal(data, &legacy); err != nil {
		return fmt.Errorf("reading legacy state: %w", err)
	}

	newState := factory.SessionState{
		Version:   "2.0",
		Timestamp: time.Now().UTC(),
		Tasks:     make(map[string]*factory.TaskState),
	}

	migrateTasks(legacy, newState.Tasks)
	migrateLegacySpecialists(legacy, &newState)

	output, err := json.MarshalIndent(newState, "", "    ")
	if err != nil {
		return fmt.Errorf("marshaling new state: %w", err)
	}

	if err := os.WriteFile(filePath, output, 0o600); err != nil {
		return fmt.Errorf("writing migrated file: %w", err)
	}

	fmt.Printf("Successfully migrated %s to version 2.0\n", filePath)
	return nil
}

func migrateTasks(legacy map[string]interface{}, target map[string]*factory.TaskState) {
	tasksRaw, ok := legacy["tasks"]
	if !ok {
		return
	}
	tasks, ok := tasksRaw.(map[string]interface{})
	if !ok {
		return
	}

	for taskID, taskDataRaw := range tasks {
		taskData, ok := taskDataRaw.(map[string]interface{})
		if !ok {
			continue
		}

		tState := &factory.TaskState{
			TaskID: taskID,
		}

		for role, roleDataRaw := range taskData {
			roleData, ok := roleDataRaw.(map[string]interface{})
			if !ok {
				continue
			}
			mapSpecialistRole(role, roleData, tState)
		}
		target[taskID] = tState
	}
}

func mapSpecialistRole(role string, roleData map[string]interface{}, tState *factory.TaskState) {
	mapFn := func(target interface{}) {
		b, _ := json.Marshal(roleData)
		_ = json.Unmarshal(b, target)
	}

	switch role {
	case roleGroomer:
		tState.Specialists.Groomer = &factory.GroomerState{}
		mapFn(tState.Specialists.Groomer)
	case roleArchitect:
		tState.Specialists.Architect = &factory.ArchitectState{}
		mapFn(tState.Specialists.Architect)
	case roleReviewer:
		tState.Specialists.Reviewer = &factory.ReviewerState{}
		mapFn(tState.Specialists.Reviewer)
	case roleOperator:
		tState.Specialists.Operator = &factory.OperatorState{}
		mapFn(tState.Specialists.Operator)
	case roleResearcher:
		tState.Specialists.Researcher = &factory.ResearcherState{}
		mapFn(tState.Specialists.Researcher)
	}
}

func migrateLegacySpecialists(legacy map[string]interface{}, newState *factory.SessionState) {
	legacyRaw, ok := legacy["_legacy"]
	if !ok {
		return
	}
	legacyMap, ok := legacyRaw.(map[string]interface{})
	if !ok {
		return
	}
	specsRaw, ok := legacyMap["specialists"]
	if !ok {
		return
	}
	specs, ok := specsRaw.(map[string]interface{})
	if !ok {
		return
	}

	newState.LegacySpecialists = make(map[string]*factory.SpecialistState)
	for role, roleDataRaw := range specs {
		roleData, ok := roleDataRaw.(map[string]interface{})
		if !ok {
			continue
		}
		sState := &factory.SpecialistState{}
		b, _ := json.Marshal(roleData)
		_ = json.Unmarshal(b, sState)
		newState.LegacySpecialists[role] = sState
	}
}
