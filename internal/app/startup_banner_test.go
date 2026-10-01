//nolint:testpackage // Tests the unexported startup banner formatting seam.
package app

import (
	"bytes"
	"strings"
	"testing"

	"github.com/allthingscode/gobot/internal/config"
)

func TestPrintStartupBannerToDashboardAddress(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name           string
		gateway        config.GatewayConfig
		wantDashboard  string
		mustNotContain string
	}{
		{
			name: "enabled dashboard uses gateway IPv4 address",
			gateway: config.GatewayConfig{
				Enabled: true, DashboardEnabled: true, Host: "127.0.0.1", Port: 18790, WebAddr: "127.0.0.1:7331",
			},
			wantDashboard:  "http://127.0.0.1:18790/dash/",
			mustNotContain: "127.0.0.1:7331",
		},
		{
			name: "enabled dashboard brackets IPv6 gateway host",
			gateway: config.GatewayConfig{
				Enabled: true, DashboardEnabled: true, Host: "[::1]", Port: 18790,
			},
			wantDashboard: "http://[::1]:18790/dash/",
		},
		{
			name: "separate SSE listener does not enable management dashboard",
			gateway: config.GatewayConfig{
				Enabled: true, DashboardEnabled: false, Host: "127.0.0.1", Port: 18790, WebAddr: "127.0.0.1:7331",
			},
			wantDashboard:  "disabled",
			mustNotContain: "127.0.0.1:7331",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()

			cfg := &config.Config{Gateway: tt.gateway}
			var output bytes.Buffer
			printStartupBannerTo(&output, cfg, nil)

			if got := output.String(); !strings.Contains(got, "  Dashboard: "+tt.wantDashboard+"\n") {
				t.Fatalf("banner missing dashboard address %q:\n%s", tt.wantDashboard, got)
			}
			if tt.mustNotContain != "" && strings.Contains(output.String(), tt.mustNotContain) {
				t.Fatalf("banner unexpectedly contains separate SSE address %q:\n%s", tt.mustNotContain, output.String())
			}
		})
	}
}
