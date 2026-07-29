package config

import (
	"testing"
)

func TestLoadMinimal(t *testing.T) {
	suite, err := Load("../../testdata/suite.minimal.yaml")
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if suite.Metadata.Name != "minimal" {
		t.Errorf("name = %q, want minimal", suite.Metadata.Name)
	}
	if suite.Spec.Cluster.Name != "e2e-minimal" {
		t.Errorf("cluster.name = %q", suite.Spec.Cluster.Name)
	}
	if suite.Spec.Cluster.Cilium.ChartVersion != "1.17.2" {
		t.Errorf("cilium.chartVersion = %q", suite.Spec.Cluster.Cilium.ChartVersion)
	}
}

func TestValidateRejectsMissingFields(t *testing.T) {
	s := &Suite{
		APIVersion: "wrong",
		Kind:       "Suite",
		Metadata:   Metadata{Name: ""},
		Spec: Spec{
			Cluster: Cluster{},
		},
	}
	err := s.Validate()
	if err == nil {
		t.Fatal("expected validation error")
	}
}

func TestValidateDeployStepExclusive(t *testing.T) {
	s := validSuite()
	s.Spec.Deploy = &Deploy{
		Steps: []DeployStep{{
			Name:  "bad",
			Apply: &ApplyStep{Paths: []string{"a.yaml"}},
			Helm:  &HelmStep{ReleaseName: "r", Chart: "c"},
		}},
	}
	if err := s.Validate(); err == nil {
		t.Fatal("expected error for multiple step kinds")
	}
}

func TestValidateDockerCompose(t *testing.T) {
	s := validSuite()
	s.Spec.Deps = &Deps{
		DockerCompose: []DockerCompose{{
			Name:        "infisical",
			File:        "compose.yml",
			ProjectName: "e2e-infisical",
			Wait:        []ComposeWaitProbe{{URL: "http://127.0.0.1:8080/api/status", Timeout: "5m"}},
		}},
	}
	if err := s.Validate(); err != nil {
		t.Fatalf("unexpected: %v", err)
	}
}

func TestValidateAssertChecks(t *testing.T) {
	s := validSuite()
	s.Spec.Assert = &Assert{
		Checks: []Check{{
			Name: "pods",
			PodsReady: &PodsReady{
				ExcludeNamespaces:   []string{"kube-system"},
				IgnoreCompletedJobs: true,
			},
		}},
	}
	if err := s.Validate(); err != nil {
		t.Fatalf("unexpected: %v", err)
	}
}

func validSuite() *Suite {
	return &Suite{
		APIVersion: APIVersion,
		Kind:       KindSuite,
		Metadata:   Metadata{Name: "test"},
		Spec: Spec{
			Cluster: Cluster{
				Name: "e2e",
				KindConfig: `kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
`,
				Cilium: Cilium{ChartVersion: "1.17.2"},
			},
		},
	}
}
