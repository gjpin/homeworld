package kube

import (
	"testing"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

func TestConditionStatusTopLevel(t *testing.T) {
	obj := &unstructured.Unstructured{Object: map[string]interface{}{
		"status": map[string]interface{}{
			"conditions": []interface{}{
				map[string]interface{}{"type": "Ready", "status": "True"},
			},
		},
	}}
	if got := ConditionStatus(obj, "Ready"); got != "True" {
		t.Fatalf("Ready = %q, want True", got)
	}
}

func TestConditionStatusRouteParents(t *testing.T) {
	parent := func(status string) interface{} {
		return map[string]interface{}{
			"conditions": []interface{}{
				map[string]interface{}{"type": "Accepted", "status": status},
			},
		}
	}
	route := func(parents ...interface{}) *unstructured.Unstructured {
		return &unstructured.Unstructured{Object: map[string]interface{}{
			"status": map[string]interface{}{"parents": parents},
		}}
	}
	if got := ConditionStatus(route(parent("True"), parent("True")), "Accepted"); got != "True" {
		t.Fatalf("all parents accepted: got %q, want True", got)
	}
	if got := ConditionStatus(route(parent("True"), parent("False")), "Accepted"); got != "False" {
		t.Fatalf("one parent rejected: got %q, want False", got)
	}
	if got := ConditionStatus(route(), "Accepted"); got != "" {
		t.Fatalf("no parents: got %q, want empty", got)
	}
}
