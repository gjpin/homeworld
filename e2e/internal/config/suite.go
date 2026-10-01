package config

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"gopkg.in/yaml.v3"
)

const (
	APIVersion = "e2e.testing.dev/v1alpha1"
	KindSuite  = "Suite"
)

// Suite is the portable E2E suite contract.
type Suite struct {
	APIVersion string   `yaml:"apiVersion"`
	Kind       string   `yaml:"kind"`
	Metadata   Metadata `yaml:"metadata"`
	Spec       Spec     `yaml:"spec"`

	// Path is the absolute path to the suite file (set on load).
	Path string `yaml:"-"`
	// Dir is the directory containing the suite file (set on load).
	Dir string `yaml:"-"`
}

type Metadata struct {
	Name string `yaml:"name"`
}

type Spec struct {
	// Workdir overrides the working directory for relative paths and hooks.
	// Defaults to the suite file directory.
	Workdir string   `yaml:"workdir,omitempty"`
	Deps    *Deps    `yaml:"deps,omitempty"`
	Cluster Cluster  `yaml:"cluster"`
	Prepare *Prepare `yaml:"prepare,omitempty"`
	Deploy  *Deploy  `yaml:"deploy,omitempty"`
	Assert  *Assert  `yaml:"assert,omitempty"`
}

type Deps struct {
	DockerCompose []DockerCompose `yaml:"dockerCompose,omitempty"`
}

type DockerCompose struct {
	Name        string             `yaml:"name"`
	File        string             `yaml:"file"`
	EnvFile     string             `yaml:"envFile,omitempty"`
	ProjectName string             `yaml:"projectName"`
	Wait        []ComposeWaitProbe `yaml:"wait,omitempty"`
}

type ComposeWaitProbe struct {
	URL     string `yaml:"url"`
	Timeout string `yaml:"timeout,omitempty"`
}

type Cluster struct {
	Name        string `yaml:"name"`
	KindConfig  string `yaml:"kindConfig"`
	Cilium      Cilium `yaml:"cilium"`
	KubeVersion string `yaml:"kubeVersion,omitempty"`
}

type Cilium struct {
	ChartVersion string            `yaml:"chartVersion"`
	Namespace    string            `yaml:"namespace,omitempty"`
	Values       map[string]string `yaml:"values,omitempty"`
	WaitTimeout  string            `yaml:"waitTimeout,omitempty"`
}

type Prepare struct {
	NodeLabels []string `yaml:"nodeLabels,omitempty"`
	Hooks      []Hook   `yaml:"hooks,omitempty"`
}

type Hook struct {
	Name    string            `yaml:"name"`
	Command []string          `yaml:"command"`
	Env     map[string]string `yaml:"env,omitempty"`
	Timeout string            `yaml:"timeout,omitempty"`
}

type Deploy struct {
	Timeout string       `yaml:"timeout,omitempty"`
	Steps   []DeployStep `yaml:"steps"`
}

type DeployStep struct {
	Name      string         `yaml:"name"`
	Apply     *ApplyStep     `yaml:"apply,omitempty"`
	Kustomize *KustomizeStep `yaml:"kustomize,omitempty"`
	Helm      *HelmStep      `yaml:"helm,omitempty"`
	Wait      *WaitStep      `yaml:"wait,omitempty"`
	Hook      *Hook          `yaml:"hook,omitempty"`
}

type ApplyStep struct {
	Paths []string `yaml:"paths"`
}

type KustomizeStep struct {
	Path string `yaml:"path"`
}

type HelmStep struct {
	ReleaseName string            `yaml:"releaseName"`
	Chart       string            `yaml:"chart"`
	RepoURL     string            `yaml:"repoURL,omitempty"`
	Version     string            `yaml:"version,omitempty"`
	Namespace   string            `yaml:"namespace,omitempty"`
	CreateNS    bool              `yaml:"createNamespace,omitempty"`
	Values      map[string]string `yaml:"values,omitempty"`
	ValuesFiles []string          `yaml:"valuesFiles,omitempty"`
	Wait        bool              `yaml:"wait,omitempty"`
	Timeout     string            `yaml:"timeout,omitempty"`
	// SkipIfPresent skips helm upgrade --install when the release already
	// exists (any status). Used with --keep-cluster so a failed/pending
	// bootstrap does not block reuse while workloads are already running.
	SkipIfPresent bool `yaml:"skipIfPresent,omitempty"`
}

type WaitStep struct {
	Group      string          `yaml:"group,omitempty"`
	Version    string          `yaml:"version"`
	Resource   string          `yaml:"resource"`
	Namespace  string          `yaml:"namespace,omitempty"`
	Name       string          `yaml:"name,omitempty"`
	Selector   string          `yaml:"selector,omitempty"`
	Conditions []WaitCondition `yaml:"conditions,omitempty"`
	Fields     []WaitField     `yaml:"fields,omitempty"`
	Timeout    string          `yaml:"timeout,omitempty"`
	// Interval between wait polls. Defaults to 15s. Each poll uses a
	// short per-attempt timeout so a hung apiserver cannot stall the loop.
	Interval string `yaml:"interval,omitempty"`
	// ResyncInterval re-triggers syncs on Applications matching the wait's
	// selector that sit OutOfSync with no operation running. Argo CD gives
	// up on an app after five failed sync attempts and self-heal never
	// re-fires after a failed sync, so a first-boot transient (an operator
	// reconciling an instance that is still starting) can leave an app
	// stuck OutOfSync forever even though the underlying condition cleared
	// minutes later. Empty disables the rescue.
	ResyncInterval string `yaml:"resyncInterval,omitempty"`
}

type WaitCondition struct {
	Type   string `yaml:"type"`
	Status string `yaml:"status"`
}

// WaitField matches a dotted path under an object (e.g. status.sync.status).
type WaitField struct {
	Path  string `yaml:"path"`
	Value string `yaml:"value"`
}

type Assert struct {
	Timeout string  `yaml:"timeout,omitempty"`
	Checks  []Check `yaml:"checks"`
}

type Check struct {
	Name              string             `yaml:"name"`
	PodsReady         *PodsReady         `yaml:"podsReady,omitempty"`
	WorkloadsReady    *WorkloadsReady    `yaml:"workloadsReady,omitempty"`
	ServiceProbe      *ServiceProbe      `yaml:"serviceProbe,omitempty"`
	ResourceCondition *ResourceCondition `yaml:"resourceCondition,omitempty"`
	GatewayReady      *GatewayReady      `yaml:"gatewayReady,omitempty"`
	NetworkProbe      *NetworkProbe      `yaml:"networkProbe,omitempty"`
}

type PodsReady struct {
	Namespaces          []string `yaml:"namespaces,omitempty"`
	ExcludeNamespaces   []string `yaml:"excludeNamespaces,omitempty"`
	IgnoreCompletedJobs bool     `yaml:"ignoreCompletedJobs,omitempty"`
	Selector            string   `yaml:"selector,omitempty"`
}

type WorkloadsReady struct {
	Namespaces []string `yaml:"namespaces,omitempty"`
	Kinds      []string `yaml:"kinds,omitempty"` // Deployment, StatefulSet, DaemonSet
	Selector   string   `yaml:"selector,omitempty"`
}

type ServiceProbe struct {
	Namespace string `yaml:"namespace"`
	Service   string `yaml:"service"`
	Port      int    `yaml:"port"`
	Path      string `yaml:"path,omitempty"`
	Scheme    string `yaml:"scheme,omitempty"`
	Timeout   string `yaml:"timeout,omitempty"`
	// Username/Password add HTTP basic auth to the probe request.
	Username string `yaml:"username,omitempty"`
	Password string `yaml:"password,omitempty"`
	// Host overrides the request's Host header. The port-forward dials the
	// pod directly, so virtual-host-validated endpoints (Authelia's OIDC
	// discovery, Homepage's host allowlist, Grafana behind its root_url)
	// would otherwise reject the probe with 400/401.
	Host string `yaml:"host,omitempty"`
	// Headers adds arbitrary request headers: Authelia derives its endpoint
	// URLs from X-Forwarded-Proto and rejects requests that skip the proxy
	// chain without it.
	Headers map[string]string `yaml:"headers,omitempty"`
	// BodyContains requires the response body to contain the substring.
	// The probe keeps retrying until the deadline when it is absent,
	// which proves data actually arrived (not just HTTP 200).
	BodyContains string `yaml:"bodyContains,omitempty"`
}

type ResourceCondition struct {
	APIVersion string      `yaml:"apiVersion"`
	Kind       string      `yaml:"kind"`
	Name       string      `yaml:"name,omitempty"`
	Namespace  string      `yaml:"namespace,omitempty"`
	Selector   string      `yaml:"selector,omitempty"`
	Condition  string      `yaml:"condition,omitempty"`
	Status     string      `yaml:"status,omitempty"`
	Fields     []WaitField `yaml:"fields,omitempty"`
	Timeout    string      `yaml:"timeout,omitempty"`
}

type GatewayReady struct {
	Name      string `yaml:"name"`
	Namespace string `yaml:"namespace"`
	Timeout   string `yaml:"timeout,omitempty"`
}

type NetworkProbe struct {
	FromNamespace string `yaml:"fromNamespace,omitempty"`
	FromSelector  string `yaml:"fromSelector,omitempty"`
	Address       string `yaml:"address"`
	Port          int    `yaml:"port,omitempty"`
	Protocol      string `yaml:"protocol,omitempty"` // tcp (default), http
	Path          string `yaml:"path,omitempty"`
	Timeout       string `yaml:"timeout,omitempty"`
}

// Load reads and validates a suite YAML file.
func Load(path string) (*Suite, error) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return nil, fmt.Errorf("resolve suite path: %w", err)
	}
	data, err := os.ReadFile(abs)
	if err != nil {
		return nil, fmt.Errorf("read suite: %w", err)
	}
	var suite Suite
	// KnownFields: a typo'd field (e.g. `resyncinterval` instead of
	// `resyncInterval`) must fail loudly instead of being silently ignored.
	dec := yaml.NewDecoder(bytes.NewReader(data))
	dec.KnownFields(true)
	if err := dec.Decode(&suite); err != nil {
		return nil, fmt.Errorf("parse suite YAML: %w", err)
	}
	suite.Path = abs
	suite.Dir = filepath.Dir(abs)
	if err := suite.Validate(); err != nil {
		return nil, err
	}
	return &suite, nil
}

// WorkDir returns the effective working directory for relative paths.
func (s *Suite) WorkDir() string {
	if s.Spec.Workdir != "" {
		if filepath.IsAbs(s.Spec.Workdir) {
			return s.Spec.Workdir
		}
		return filepath.Join(s.Dir, s.Spec.Workdir)
	}
	return s.Dir
}

// ResolvePath resolves a path relative to the suite workdir.
func (s *Suite) ResolvePath(p string) string {
	if filepath.IsAbs(p) {
		return p
	}
	return filepath.Join(s.WorkDir(), p)
}

// ParseDuration parses a duration string with a default when empty.
func ParseDuration(value string, def time.Duration) (time.Duration, error) {
	if value == "" {
		return def, nil
	}
	d, err := time.ParseDuration(value)
	if err != nil {
		return 0, fmt.Errorf("invalid duration %q: %w", value, err)
	}
	return d, nil
}
