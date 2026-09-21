package deploy

import (
	"testing"

	"github.com/gjpin/homeworld/e2e/internal/config"
)

func TestShouldSkipHelm(t *testing.T) {
	if !shouldSkipHelm(true, true) {
		t.Fatal("skipIfPresent with existing release should skip")
	}
	if shouldSkipHelm(true, false) {
		t.Fatal("skipIfPresent without a release should install")
	}
	if shouldSkipHelm(false, true) {
		t.Fatal("existing release without skipIfPresent should upgrade")
	}
}

func TestHelmStepSkipIfPresentDefault(t *testing.T) {
	h := config.HelmStep{ReleaseName: "argocd", Chart: "argo-cd"}
	if h.SkipIfPresent {
		t.Fatal("skipIfPresent must default false")
	}
}
