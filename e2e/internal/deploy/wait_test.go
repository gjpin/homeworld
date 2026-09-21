package deploy

import (
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"

	"github.com/gjpin/homeworld/e2e/internal/config"
)

func TestResourceMatchesArgoApplication(t *testing.T) {
	obj := &unstructured.Unstructured{Object: map[string]interface{}{
		"metadata": map[string]interface{}{"name": "forgejo-app"},
		"status": map[string]interface{}{
			"sync":   map[string]interface{}{"status": "Synced"},
			"health": map[string]interface{}{"status": "Healthy"},
		},
	}}
	fields := []config.WaitField{
		{Path: "status.sync.status", Value: "Synced"},
		{Path: "status.health.status", Value: "Healthy"},
	}
	if err := resourceMatches(obj, nil, fields); err != nil {
		t.Fatal(err)
	}
	obj.Object["status"].(map[string]interface{})["health"].(map[string]interface{})["status"] = "Progressing"
	if err := resourceMatches(obj, nil, fields); err == nil {
		t.Fatal("expected health mismatch")
	}
}

func TestResourceMatchesConditions(t *testing.T) {
	obj := &unstructured.Unstructured{Object: map[string]interface{}{
		"status": map[string]interface{}{
			"conditions": []interface{}{
				map[string]interface{}{"type": "Ready", "status": "True"},
			},
		},
	}}
	if err := resourceMatches(obj, []config.WaitCondition{{Type: "Ready", Status: "True"}}, nil); err != nil {
		t.Fatal(err)
	}
}
