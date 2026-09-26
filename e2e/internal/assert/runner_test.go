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
		"DocumentDB":         "dbs",
		"Dragonfly":          "dragonflies",
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

func TestMatchServiceBody(t *testing.T) {
	vmBody := []byte(`{"status":"success","data":{"resultType":"vector","result":[{"metric":{"__name__":"otelcol_process_uptime"},"value":[1758750000,"123"]}]}}`)
	if err := matchServiceBody(200, vmBody, `"result":[{`); err != nil {
		t.Errorf("VictoriaMetrics response with series should match: %v", err)
	}
	emptyBody := []byte(`{"status":"success","data":{"resultType":"vector","result":[]}}`)
	if err := matchServiceBody(200, emptyBody, `"result":[{`); err == nil {
		t.Error("empty query result should not match data assertion")
	}
	if err := matchServiceBody(200, emptyBody, ""); err != nil {
		t.Errorf("empty bodyContains should pass on 2xx: %v", err)
	}
	if err := matchServiceBody(500, vmBody, ""); err == nil {
		t.Error("5xx should not match")
	}
	vlBody := []byte("{\"_msg\":\"hello\",\"_stream\":{},\"_time\":\"2026-09-26T00:00:00Z\"}\n")
	if err := matchServiceBody(200, vlBody, "_time"); err != nil {
		t.Errorf("VictoriaLogs response with log line should match: %v", err)
	}
	if err := matchServiceBody(200, []byte(""), "_time"); err == nil {
		t.Error("empty log response should not match data assertion")
	}
}
