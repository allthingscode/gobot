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
			data, err := os.ReadFile(args[0])
			if err != nil {
				return fmt.Errorf("reading file: %w", err)
			}

			data = stripBOM(data)
			// First, try to unmarshal as the legacy structure
			var legacy map[string]interface{}
			if err := json.Unmarshal(data, &legacy); err != nil {
				return fmt.Errorf("reading legacy state: %w", err)
			}

			newState := factory.SessionState{
				Version:   "2.0",
				Timestamp: time.Now().UTC(),
				Tasks:     make(map[string]*factory.TaskState),
			}

			// Handle "tasks" key if it exists
			if tasksRaw, ok := legacy["tasks"]; ok {
				tasks, ok := tasksRaw.(map[string]interface{})
				if ok {
					for taskID, taskDataRaw := range tasks {
						taskData, ok := taskDataRaw.(map[string]interface{})
						if !ok {
							continue
						}

						tState := &factory.TaskState{
							TaskID: taskID,
						}

						// Map specialists
						for role, roleDataRaw := range taskData {
							roleData, ok := roleDataRaw.(map[string]interface{})
							if !ok {
								continue
							}

							// Helper to map generic specialist fields
							mapSpecialist := func(target interface{}) {
								b, _ := json.Marshal(roleData)
								_ = json.Unmarshal(b, target)
							}

							switch role {
							case "groomer":
								tState.Specialists.Groomer = &factory.GroomerState{}
								mapSpecialist(tState.Specialists.Groomer)
							case "architect":
								tState.Specialists.Architect = &factory.ArchitectState{}
								mapSpecialist(tState.Specialists.Architect)
							case "reviewer":
								tState.Specialists.Reviewer = &factory.ReviewerState{}
								mapSpecialist(tState.Specialists.Reviewer)
							case "operator":
								tState.Specialists.Operator = &factory.OperatorState{}
								mapSpecialist(tState.Specialists.Operator)
							case "researcher":
								tState.Specialists.Researcher = &factory.ResearcherState{}
								mapSpecialist(tState.Specialists.Researcher)
							}
						}
						newState.Tasks[taskID] = tState
					}
				}
			}

			// Handle "_legacy" key
			if legacyRaw, ok := legacy["_legacy"]; ok {
				legacyMap, ok := legacyRaw.(map[string]interface{})
				if ok {
					if specsRaw, ok := legacyMap["specialists"]; ok {
						specs, ok := specsRaw.(map[string]interface{})
						if ok {
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
					}
				}
			}

			output, err := json.MarshalIndent(newState, "", "    ")
			if err != nil {
				return fmt.Errorf("marshaling new state: %w", err)
			}

			if err := os.WriteFile(args[0], output, 0o600); err != nil {
				return fmt.Errorf("writing migrated file: %w", err)
			}

			fmt.Printf("Successfully migrated %s to version 2.0\n", args[0])
			return nil
		},
	}
}
