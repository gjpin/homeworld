package assert

import (
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"

	"github.com/gjpin/homeworld/e2e/internal/config"
)

func TestPluralize(t *testing.T) {
	cases := map[string]string{
		"ClusterSecretStore": "clustersecretstores",
		"Gateway":            "gateways",
		"Application":        "applications",
		"Policy":             "policies",
		"ExternalSecret":     "externalsecrets",
	}
	for in, want := range cases {
		if got := pluralize(in); got != want {
			t.Errorf("pluralize(%q)=%q want %q", in, got, want)
		}
	}
}

func TestMatchResourceExternalSecret(t *testing.T) {
	obj := &unstructured.Unstructured{Object: map[string]interface{}{
		"metadata": map[string]interface{}{"name": "postgres-credentials", "namespace": "authelia"},
		"status": map[string]interface{}{
			"conditions": []interface{}{
				map[string]interface{}{"type": "Ready", "status": "True"},
			},
		},
	}}
	cfg := &config.ResourceCondition{Condition: "Ready", Status: "True"}
	if err := matchResource(obj, cfg); err != nil {
		t.Fatal(err)
	}
}

func TestMatchResourceDragonflyPhase(t *testing.T) {
	obj := &unstructured.Unstructured{Object: map[string]interface{}{
		"status": map[string]interface{}{"phase": "ready"},
	}}
	cfg := &config.ResourceCondition{Fields: []config.WaitField{{Path: "status.phase", Value: "ready"}}}
	if err := matchResource(obj, cfg); err != nil {
		t.Fatal(err)
	}
}
