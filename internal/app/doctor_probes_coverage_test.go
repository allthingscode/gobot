//nolint:testpackage // covers package-private probe retry helper
package app

import (
	"strings"
	"testing"
)

func TestLiveProbesListLocalFailurePaths(t *testing.T) {
	t.Parallel()

	probes := LiveProbesList()
	if probes == nil || probes.ProbeTelegram == nil || probes.ProbeGemini == nil || probes.ProbeGmail == nil {
		t.Fatal("expected all live probe functions to be registered")
	}

	tests := []struct {
		name string
		run  func() error
		want string
	}{
		{
			name: "telegram invalid token",
			run: func() error {
				_, err := probes.ProbeTelegram("")
				return err
			},
			want: "new bot",
		},
		{
			name: "gmail missing token",
			run: func() error {
				return probes.ProbeGmail(t.TempDir())
			},
			want: "new google service",
		},
	}
	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			err := tc.run()
			if err == nil {
				t.Fatal("expected local probe failure")
			}
			if !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("expected error containing %q, got %v", tc.want, err)
			}
		})
	}
}

func TestShouldRetryGeminiProbeMessages(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		err  error
		want bool
	}{
		{name: "nil", err: nil, want: false},
		{name: "resource exhausted", err: stringError("RESOURCE_EXHAUSTED quota"), want: true},
		{name: "rate status", err: stringError("request failed with 429"), want: true},
		{name: "other", err: stringError("bad credentials"), want: false},
	}
	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			if got := shouldRetryGeminiProbe(tc.err); got != tc.want {
				t.Fatalf("shouldRetryGeminiProbe(%v) = %v, want %v", tc.err, got, tc.want)
			}
		})
	}
}

type stringError string

func (e stringError) Error() string { return string(e) }
