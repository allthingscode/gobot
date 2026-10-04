//nolint:testpackage // intentionally tests the dashboard handler
package dashboard

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

func TestBranding(t *testing.T) {
	t.Parallel()
	hub := NewHub(10)
	defer hub.Close()
	server := NewServer(hub, "127.0.0.1:0", "")
	response := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/", http.NoBody) //nolint:noctx // test request
	server.handler().ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("serve dashboard: status %d", response.Code)
	}
	html := response.Body.String()
	for _, tc := range []struct {
		name string
		text string
	}{
		{"initial default", `<b id="agent-name">gobot</b>`},
		{"ordinary session fallback", `document.getElementById('agent-name').textContent = "gobot";`},
		{"specialist session branch", `if (sid.startsWith("agent:"))`},
		{"specialist name", `document.getElementById('agent-name').textContent = parts[1];`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			if !strings.Contains(html, tc.text) {
				t.Errorf("served dashboard missing %q", tc.text)
			}
		})
	}
	if strings.Contains(html, "gobot-strategic") {
		t.Error("served dashboard contains stale gobot-strategic label")
	}

	data, err := os.ReadFile("../../versioninfo.json")
	if err != nil {
		t.Fatalf("read Windows resource source: %v", err)
	}
	var resource struct {
		StringFileInfo map[string]string
	}
	if err := json.Unmarshal(data, &resource); err != nil {
		t.Fatalf("parse Windows resource source: %v", err)
	}
	for _, tc := range []struct {
		field string
		want  string
	}{
		{"Comments", "gobot agent runtime"},
		{"FileDescription", "gobot - agent runtime"},
	} {
		t.Run(tc.field, func(t *testing.T) {
			t.Parallel()
			if got := resource.StringFileInfo[tc.field]; got != tc.want {
				t.Errorf("StringFileInfo.%s = %q, want %q", tc.field, got, tc.want)
			}
		})
	}
}
