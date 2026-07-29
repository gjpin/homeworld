package assert

import "testing"

func TestPluralize(t *testing.T) {
	cases := map[string]string{
		"ClusterSecretStore": "clustersecretstores",
		"Gateway":            "gateways",
		"Application":        "applications",
		"Policy":             "policies",
	}
	for in, want := range cases {
		if got := pluralize(in); got != want {
			t.Errorf("pluralize(%q)=%q want %q", in, got, want)
		}
	}
}
