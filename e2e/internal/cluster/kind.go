package cluster

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/gjpin/homeworld/e2e/internal/config"
)

const ciliumHelmRepo = "https://helm.cilium.io/"

// Manager creates and deletes kind clusters with Cilium.
type Manager struct {
	Suite       *config.Suite
	Timeout     time.Duration
	KeepCluster bool
}

// Exists reports whether a kind cluster with the suite name already exists.
func (m *Manager) Exists(ctx context.Context) (bool, error) {
	out, err := runOutput(ctx, "kind", "get", "clusters")
	if err != nil {
		return false, fmt.Errorf("kind get clusters: %w", err)
	}
	name := m.Suite.Spec.Cluster.Name
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		if strings.TrimSpace(line) == name {
			return true, nil
		}
	}
	return false, nil
}

// Up creates the kind cluster and installs Cilium.
func (m *Manager) Up(ctx context.Context) error {
	exists, err := m.Exists(ctx)
	if err != nil {
		return err
	}
	if exists {
		if m.KeepCluster {
			fmt.Fprintf(os.Stderr, "reusing kind cluster %q (--keep-cluster)\n", m.Suite.Spec.Cluster.Name)
			// Cilium (often CRDs-only) is already installed. A helm upgrade
			// against a saturated kind apiserver fails the suite before
			// wait-argo. Prepare hooks re-apply policy CRDs.
			return m.waitForAPI(ctx)
		}
		return fmt.Errorf("kind cluster %q already exists; run 'e2e cluster down -f ...' first", m.Suite.Spec.Cluster.Name)
	}

	cfg := m.Suite.Spec.Cluster
	tmp, err := os.MkdirTemp("", "e2e-kind-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)

	kindFile := filepath.Join(tmp, "kind.yaml")
	if err := os.WriteFile(kindFile, []byte(cfg.KindConfig), 0o644); err != nil {
		return fmt.Errorf("write kind config: %w", err)
	}

	args := []string{"create", "cluster", "--name", cfg.Name, "--config", kindFile}
	if cfg.KubeVersion != "" {
		args = append(args, "--image", "kindest/node:"+cfg.KubeVersion)
	}
	if err := run(ctx, "kind", args...); err != nil {
		return fmt.Errorf("kind create cluster: %w", err)
	}

	if err := m.installCilium(ctx); err != nil {
		return err
	}
	return nil
}

// Down deletes the kind cluster.
func (m *Manager) Down(ctx context.Context) error {
	exists, err := m.Exists(ctx)
	if err != nil {
		return err
	}
	if !exists {
		return nil
	}
	if err := run(ctx, "kind", "delete", "cluster", "--name", m.Suite.Spec.Cluster.Name); err != nil {
		return fmt.Errorf("kind delete cluster: %w", err)
	}
	return nil
}

func (m *Manager) waitForAPI(ctx context.Context) error {
	deadline := time.Now().Add(2 * time.Minute)
	var last error
	for time.Now().Before(deadline) {
		if err := ctx.Err(); err != nil {
			return err
		}
		err := run(ctx, "kubectl", "--request-timeout=10s", "get", "--raw=/readyz")
		if err == nil {
			return nil
		}
		last = err
		fmt.Fprintf(os.Stderr, "waiting for apiserver: %v\n", err)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(5 * time.Second):
		}
	}
	if last == nil {
		last = fmt.Errorf("timeout")
	}
	return fmt.Errorf("apiserver not ready: %w", last)
}

func (m *Manager) installCilium(ctx context.Context) error {
	cilium := m.Suite.Spec.Cluster.Cilium
	ns := cilium.Namespace
	if ns == "" {
		ns = "kube-system"
	}
	waitTimeout, err := config.ParseDuration(cilium.WaitTimeout, 10*time.Minute)
	if err != nil {
		return err
	}

	if err := run(ctx, "helm", "repo", "add", "cilium", ciliumHelmRepo, "--force-update"); err != nil {
		return fmt.Errorf("helm repo add cilium: %w", err)
	}
	if err := run(ctx, "helm", "repo", "update", "cilium"); err != nil {
		return fmt.Errorf("helm repo update: %w", err)
	}

	args := []string{
		"upgrade", "--install", "cilium", "cilium/cilium",
		"--version", cilium.ChartVersion,
		"--namespace", ns,
		"--wait",
		"--timeout", waitTimeout.String(),
	}
	for k, v := range cilium.Values {
		args = append(args, "--set", fmt.Sprintf("%s=%s", k, v))
	}
	// Kind-friendly defaults when not overridden.
	if _, ok := cilium.Values["operator.replicas"]; !ok {
		args = append(args, "--set", "operator.replicas=1")
	}
	if _, ok := cilium.Values["kubeProxyReplacement"]; !ok {
		args = append(args, "--set", "kubeProxyReplacement=false")
	}

	if err := run(ctx, "helm", args...); err != nil {
		return fmt.Errorf("helm install cilium: %w", err)
	}

	// Cilium 1.17 helm chart does not include CRDs (no crds/ dir and no
	// templates gated on crds.install). Apply policy CRDs from the matching
	// Git tag so CiliumNetworkPolicy objects can be admitted.
	if err := applyCiliumPolicyCRDs(ctx, cilium.ChartVersion); err != nil {
		return err
	}

	// Wait only for workloads the chart actually created. Suites may install
	// CRDs only (agent=false) when the host cannot mount bpffs (Docker Desktop
	// rootless).
	ctxWait, cancel := context.WithTimeout(ctx, waitTimeout)
	defer cancel()
	if err := waitIfPresent(ctxWait, "daemonset", "cilium", ns, waitTimeout); err != nil {
		return fmt.Errorf("wait for cilium daemonset: %w", err)
	}
	if err := waitIfPresent(ctxWait, "deployment", "cilium-operator", ns, waitTimeout); err != nil {
		return fmt.Errorf("wait for cilium-operator: %w", err)
	}
	return nil
}

func applyCiliumPolicyCRDs(ctx context.Context, version string) error {
	base := fmt.Sprintf("https://raw.githubusercontent.com/cilium/cilium/v%s/pkg/k8s/apis/cilium.io/client/crds/v2", version)
	args := []string{
		"apply", "--server-side", "--force-conflicts",
		"-f", base + "/ciliumnetworkpolicies.yaml",
		"-f", base + "/ciliumclusterwidenetworkpolicies.yaml",
	}
	if err := run(ctx, "kubectl", args...); err != nil {
		return fmt.Errorf("apply cilium policy CRDs (v%s): %w", version, err)
	}
	return nil
}

func waitIfPresent(ctx context.Context, kind, name, ns string, timeout time.Duration) error {
	out, err := runOutput(ctx, "kubectl", "get", kind, name, "-n", ns, "-o", "name")
	if err != nil || strings.TrimSpace(out) == "" {
		return nil
	}
	return run(ctx, "kubectl", "rollout", "status", kind+"/"+name, "-n", ns, "--timeout="+timeout.String())
}

func run(ctx context.Context, name string, args ...string) error {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func runOutput(ctx context.Context, name string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	out, err := cmd.CombinedOutput()
	return string(out), err
}
