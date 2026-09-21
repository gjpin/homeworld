package kube

import (
	"fmt"
	"strconv"
	"strings"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
)

// NestedString returns the string form of a dotted path (e.g. status.sync.status).
func NestedString(obj *unstructured.Unstructured, dotted string) (string, bool) {
	if obj == nil || dotted == "" {
		return "", false
	}
	parts := strings.Split(dotted, ".")
	v, found, err := unstructured.NestedFieldNoCopy(obj.Object, parts...)
	if err != nil || !found || v == nil {
		return "", false
	}
	switch t := v.(type) {
	case string:
		return t, true
	case bool:
		return strconv.FormatBool(t), true
	case int64:
		return strconv.FormatInt(t, 10), true
	case int32:
		return strconv.FormatInt(int64(t), 10), true
	case float64:
		return strconv.FormatFloat(t, 'f', -1, 64), true
	default:
		return fmt.Sprint(t), true
	}
}

// FieldEquals reports whether the dotted path equals want.
func FieldEquals(obj *unstructured.Unstructured, path, want string) error {
	got, ok := NestedString(obj, path)
	if !ok {
		return fmt.Errorf("%s: not found", path)
	}
	if got != want {
		return fmt.Errorf("%s=%s, want %s", path, got, want)
	}
	return nil
}
