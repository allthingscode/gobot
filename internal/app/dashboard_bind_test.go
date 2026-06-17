//nolint:testpackage // tests the unexported dashboardBindAddr helper
package app

import "testing"

func TestDashboardBindAddr(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name  string
		addr  string
		token string
		want  string
	}{
		{"token set leaves addr untouched", "0.0.0.0:8080", "secret", "0.0.0.0:8080"},
		{"no token forces all-interfaces to loopback", "0.0.0.0:8080", "", "127.0.0.1:8080"},
		{"no token forces empty host to loopback", ":8080", "", "127.0.0.1:8080"},
		{"no token leaves loopback ip untouched", "127.0.0.1:8080", "", "127.0.0.1:8080"},
		{"no token leaves localhost untouched", "localhost:9000", "", "localhost:9000"},
		{"no token forces lan ip to loopback", "192.168.1.5:8080", "", "127.0.0.1:8080"},
		{"unparseable addr returned as-is", "not-an-addr", "", "not-an-addr"},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			if got := dashboardBindAddr(tc.addr, tc.token); got != tc.want {
				t.Errorf("dashboardBindAddr(%q, %q) = %q, want %q", tc.addr, tc.token, got, tc.want)
			}
		})
	}
}
