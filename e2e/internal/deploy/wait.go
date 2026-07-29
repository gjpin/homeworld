package deploy

import (
	"context"
	"fmt"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"

	"github.com/gjpin/homeworld/e2e/internal/config"
	"github.com/gjpin/homeworld/e2e/internal/kube"
)

func getResource(ctx context.Context, c *kube.Clients, gvr schema.GroupVersionResource, namespace, name string) (*unstructured.Unstructured, error) {
	if namespace == "" {
		return c.Dynamic.Resource(gvr).Get(ctx, name, metav1.GetOptions{})
	}
	return c.Dynamic.Resource(gvr).Namespace(namespace).Get(ctx, name, metav1.GetOptions{})
}

func listResources(ctx context.Context, c *kube.Clients, gvr schema.GroupVersionResource, namespace string, opts metav1.ListOptions) ([]*unstructured.Unstructured, error) {
	var list *unstructured.UnstructuredList
	var err error
	if namespace == "" {
		list, err = c.Dynamic.Resource(gvr).List(ctx, opts)
	} else {
		list, err = c.Dynamic.Resource(gvr).Namespace(namespace).List(ctx, opts)
	}
	if err != nil {
		return nil, err
	}
	out := make([]*unstructured.Unstructured, 0, len(list.Items))
	for i := range list.Items {
		out = append(out, &list.Items[i])
	}
	return out, nil
}

func conditionsOK(obj *unstructured.Unstructured, want []config.WaitCondition) error {
	if len(want) == 0 {
		return nil
	}
	for _, c := range want {
		status := kube.ConditionStatus(obj, c.Type)
		if status != c.Status {
			return fmt.Errorf("condition %s=%s, want %s", c.Type, status, c.Status)
		}
	}
	return nil
}
