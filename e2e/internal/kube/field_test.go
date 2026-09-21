package kube

import (
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

func TestNestedStringArgoStatus(t *testing.T) {
	obj := &unstructured.Unstructured{Object: map[string]interface{}{
		"status": map[string]interface{}{
			"sync":   map[string]interface{}{"status": "Synced"},
			"health": map[string]interface{}{"status": "Healthy"},
		},
	}}
	got, ok := NestedString(obj, "status.sync.status")
	if !ok || got != "Synced" {
		t.Fatalf("sync=%q ok=%v", got, ok)
	}
	got, ok = NestedString(obj, "status.health.status")
	if !ok || got != "Healthy" {
		t.Fatalf("health=%q ok=%v", got, ok)
	}
}

func TestFieldEqualsDragonflyPhase(t *testing.T) {
	obj := &unstructured.Unstructured{Object: map[string]interface{}{
		"status": map[string]interface{}{"phase": "ready"},
	}}
	if err := FieldEquals(obj, "status.phase", "ready"); err != nil {
		t.Fatal(err)
	}
	if err := FieldEquals(obj, "status.phase", "Ready"); err == nil {
		t.Fatal("expected mismatch")
	}
	if err := FieldEquals(obj, "status.missing", "ready"); err == nil {
		t.Fatal("expected missing path")
	}
}
