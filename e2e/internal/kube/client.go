package kube

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

// Options configures kube client construction.
type Options struct {
	Kubeconfig string
	Context    string
}

// Clients holds typed and dynamic Kubernetes clients.
type Clients struct {
	Config    *rest.Config
	Typed     kubernetes.Interface
	Dynamic   dynamic.Interface
	RawConfig clientcmd.ClientConfig
}

// NewClients builds Kubernetes clients from kubeconfig/context.
func NewClients(opts Options) (*Clients, error) {
	loadingRules := clientcmd.NewDefaultClientConfigLoadingRules()
	if opts.Kubeconfig != "" {
		loadingRules.ExplicitPath = opts.Kubeconfig
	} else if env := os.Getenv("KUBECONFIG"); env != "" {
		loadingRules.ExplicitPath = env
	} else {
		home, _ := os.UserHomeDir()
		loadingRules.ExplicitPath = filepath.Join(home, ".kube", "config")
	}

	overrides := &clientcmd.ConfigOverrides{}
	if opts.Context != "" {
		overrides.CurrentContext = opts.Context
	}
	raw := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(loadingRules, overrides)
	restCfg, err := raw.ClientConfig()
	if err != nil {
		return nil, fmt.Errorf("build kube rest config: %w", err)
	}
	typed, err := kubernetes.NewForConfig(restCfg)
	if err != nil {
		return nil, fmt.Errorf("create typed client: %w", err)
	}
	dyn, err := dynamic.NewForConfig(restCfg)
	if err != nil {
		return nil, fmt.Errorf("create dynamic client: %w", err)
	}
	return &Clients{Config: restCfg, Typed: typed, Dynamic: dyn, RawConfig: raw}, nil
}

// WaitForCondition polls until the named resource has the given condition status.
func WaitForCondition(ctx context.Context, dyn dynamic.Interface, gvr schema.GroupVersionResource, namespace, name, condType, status string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		var obj *unstructured.Unstructured
		var err error
		if namespace == "" {
			obj, err = dyn.Resource(gvr).Get(ctx, name, metav1.GetOptions{})
		} else {
			obj, err = dyn.Resource(gvr).Namespace(namespace).Get(ctx, name, metav1.GetOptions{})
		}
		if err == nil {
			ok, cur := conditionMatches(obj, condType, status)
			if ok {
				return nil
			}
			_ = cur
		}
		if time.Now().After(deadline) {
			if err != nil {
				return fmt.Errorf("wait for %s/%s %s=%s: %w (last error)", gvr.Resource, name, condType, status, err)
			}
			return fmt.Errorf("timeout waiting for %s/%s condition %s=%s", gvr.Resource, name, condType, status)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(2 * time.Second):
		}
	}
}

func conditionMatches(obj *unstructured.Unstructured, condType, status string) (bool, string) {
	conditions, found, err := unstructured.NestedSlice(obj.Object, "status", "conditions")
	if err != nil || !found {
		return false, ""
	}
	for _, c := range conditions {
		m, ok := c.(map[string]interface{})
		if !ok {
			continue
		}
		t, _, _ := unstructured.NestedString(m, "type")
		s, _, _ := unstructured.NestedString(m, "status")
		if t == condType {
			return s == status, s
		}
	}
	return false, ""
}

// ConditionStatus returns the status string for a condition type, or empty.
func ConditionStatus(obj *unstructured.Unstructured, condType string) string {
	conditions, found, err := unstructured.NestedSlice(obj.Object, "status", "conditions")
	if err != nil || !found {
		return ""
	}
	for _, c := range conditions {
		m, ok := c.(map[string]interface{})
		if !ok {
			continue
		}
		t, _, _ := unstructured.NestedString(m, "type")
		s, _, _ := unstructured.NestedString(m, "status")
		if t == condType {
			return s
		}
	}
	return ""
}

// GVRFromAPIVersion builds a GVR from apiVersion/kind/resource plural guess helpers.
func ParseAPIVersion(apiVersion string) (group, version string, err error) {
	if apiVersion == "" {
		return "", "", fmt.Errorf("apiVersion is empty")
	}
	// core/v1 style vs group/version
	parts := splitAPIVersion(apiVersion)
	if len(parts) == 1 {
		return "", parts[0], nil
	}
	if len(parts) == 2 {
		return parts[0], parts[1], nil
	}
	return "", "", fmt.Errorf("invalid apiVersion %q", apiVersion)
}

func splitAPIVersion(apiVersion string) []string {
	out := make([]string, 0, 2)
	start := 0
	for i := 0; i < len(apiVersion); i++ {
		if apiVersion[i] == '/' {
			out = append(out, apiVersion[start:i])
			start = i + 1
		}
	}
	out = append(out, apiVersion[start:])
	return out
}
