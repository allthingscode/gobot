//nolint:testpackage // intentionally uses the main package
package main

import (
	"sync"
	"testing"
	"testing/synctest"
	"time"

	"github.com/allthingscode/gobot/internal/app"
)

func TestDrainGoroutines(t *testing.T) {
	t.Parallel()
	for _, scenario := range []string{"completed", "held worker", "timeout"} {
		t.Run(scenario, func(t *testing.T) {
			t.Parallel()
			synctest.Test(t, func(t *testing.T) { checkDrainScenario(t, scenario) })
		})
	}
}

func checkDrainScenario(t *testing.T, scenario string) {
	t.Helper()
	var wg sync.WaitGroup
	release := make(chan struct{})
	var once sync.Once
	unblock := func() { once.Do(func() { close(release) }) }
	defer func() { unblock(); wg.Wait(); synctest.Wait() }()
	if scenario != "completed" {
		wg.Add(1)
		go func() { defer wg.Done(); <-release }()
	}
	done := make(chan struct{})
	go func() { app.DrainGoroutines(&wg, time.Hour); close(done) }()
	synctest.Wait()
	if scenario == "completed" {
		if !drainSignalClosed(done) {
			t.Fatal("completed work did not drain")
		}
		return
	}
	if drainSignalClosed(done) {
		t.Fatal("drain returned while worker held")
	}
	if scenario == "timeout" {
		time.Sleep(time.Hour)
	} else {
		unblock()
	}
	synctest.Wait()
	if !drainSignalClosed(done) {
		t.Fatal("drain did not finish")
	}
	if scenario == "timeout" && drainSignalClosed(release) {
		t.Fatal("timeout released worker")
	}
}

func drainSignalClosed(signal <-chan struct{}) bool {
	select {
	case <-signal:
		return true
	default:
		return false
	}
}
