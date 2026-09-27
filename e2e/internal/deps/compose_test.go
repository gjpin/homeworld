package deps

import (
	"strings"
	"testing"

	"github.com/gjpin/homeworld/e2e/internal/config"
)

func TestComposeArgs(t *testing.T) {
	suite := &config.Suite{
		Dir: "/suite",
		Spec: config.Spec{
			Cluster: config.Cluster{Name: "e2e", KindConfig: "x", Cilium: config.Cilium{ChartVersion: "1.20.2"}},
		},
	}
	dc := config.DockerCompose{
		Name:        "infisical",
		File:        "examples/infisical/docker-compose.yml",
		EnvFile:     "examples/infisical/.env.e2e",
		ProjectName: "e2e-infisical",
	}
	args := ComposeArgs(suite, dc, "up", "-d")
	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "compose -p e2e-infisical") {
		t.Fatalf("missing project: %s", joined)
	}
	if !strings.Contains(joined, "-f /suite/examples/infisical/docker-compose.yml") {
		t.Fatalf("missing file: %s", joined)
	}
	if !strings.Contains(joined, "--env-file /suite/examples/infisical/.env.e2e") {
		t.Fatalf("missing env: %s", joined)
	}
	if !strings.HasSuffix(joined, "up -d") {
		t.Fatalf("missing action: %s", joined)
	}
}

func TestComposeArgsDown(t *testing.T) {
	suite := &config.Suite{Dir: "/suite"}
	dc := config.DockerCompose{
		File:        "compose.yml",
		ProjectName: "proj",
	}
	args := ComposeArgs(suite, dc, "down", "-v", "--remove-orphans")
	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "down -v --remove-orphans") {
		t.Fatalf("unexpected: %s", joined)
	}
}
