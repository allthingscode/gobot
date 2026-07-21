//nolint:testpackage,paralleltest // tests unexported command wiring and package-level hooks
package main

import (
	"errors"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/config"
	"github.com/allthingscode/gobot/internal/doctor"
)

func TestCmdDoctorNoInteractiveUsesLocalOnlyProbes(t *testing.T) {
	restoreDoctorCommandDeps(t)

	cfg := &config.Config{}
	var gotProbes *doctor.Probes
	doctorCommandDeps.loadConfig = func() (*config.Config, error) {
		return cfg, nil
	}
	doctorCommandDeps.liveProbes = func() *doctor.Probes {
		t.Fatal("live probes must not be created in no-interactive mode")
		return nil
	}
	doctorCommandDeps.runDoctorDiagnostics = func(gotCfg *config.Config, probes *doctor.Probes) error {
		if gotCfg != cfg {
			t.Fatal("doctor received unexpected config")
		}
		gotProbes = probes
		return nil
	}

	cmd := cmdDoctor()
	cmd.SetArgs([]string{"--no-interactive"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("doctor --no-interactive returned error: %v", err)
	}
	if gotProbes != nil {
		t.Fatal("doctor --no-interactive should pass nil probes")
	}
}

func TestCmdDoctorDefaultUsesLiveProbes(t *testing.T) {
	restoreDoctorCommandDeps(t)

	liveProbes := &doctor.Probes{}
	var gotProbes *doctor.Probes
	doctorCommandDeps.loadConfig = func() (*config.Config, error) {
		return &config.Config{}, nil
	}
	doctorCommandDeps.liveProbes = func() *doctor.Probes {
		return liveProbes
	}
	doctorCommandDeps.runDoctorDiagnostics = func(_ *config.Config, probes *doctor.Probes) error {
		gotProbes = probes
		return nil
	}

	cmd := cmdDoctor()
	if err := cmd.Execute(); err != nil {
		t.Fatalf("doctor returned error: %v", err)
	}
	if gotProbes != liveProbes {
		t.Fatal("doctor without --no-interactive should pass live probes")
	}
}

func TestCmdDoctorWrapsRunnerError(t *testing.T) {
	restoreDoctorCommandDeps(t)

	doctorCommandDeps.loadConfig = func() (*config.Config, error) {
		return &config.Config{}, nil
	}
	doctorCommandDeps.liveProbes = func() *doctor.Probes {
		return nil
	}
	doctorCommandDeps.runDoctorDiagnostics = func(_ *config.Config, _ *doctor.Probes) error {
		return errors.New("boom")
	}

	cmd := cmdDoctor()
	err := cmd.Execute()
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !strings.Contains(err.Error(), "run doctor: boom") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func restoreDoctorCommandDeps(t *testing.T) {
	t.Helper()

	original := doctorCommandDeps
	t.Cleanup(func() {
		doctorCommandDeps = original
	})
}
