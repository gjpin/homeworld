package config

import (
	"fmt"
	"strings"
)

// Validate checks the suite schema and required fields.
func (s *Suite) Validate() error {
	var errs []string

	if s.APIVersion != APIVersion {
		errs = append(errs, fmt.Sprintf("apiVersion must be %q, got %q", APIVersion, s.APIVersion))
	}
	if s.Kind != KindSuite {
		errs = append(errs, fmt.Sprintf("kind must be %q, got %q", KindSuite, s.Kind))
	}
	if strings.TrimSpace(s.Metadata.Name) == "" {
		errs = append(errs, "metadata.name is required")
	}

	if err := s.Spec.Cluster.validate(); err != nil {
		errs = append(errs, err.Error())
	}
	if s.Spec.Deps != nil {
		if err := s.Spec.Deps.validate(); err != nil {
			errs = append(errs, err.Error())
		}
	}
	if s.Spec.Prepare != nil {
		if err := s.Spec.Prepare.validate(); err != nil {
			errs = append(errs, err.Error())
		}
	}
	if s.Spec.Deploy != nil {
		if err := s.Spec.Deploy.validate(); err != nil {
			errs = append(errs, err.Error())
		}
	}
	if s.Spec.Assert != nil {
		if err := s.Spec.Assert.validate(); err != nil {
			errs = append(errs, err.Error())
		}
	}

	if len(errs) > 0 {
		return fmt.Errorf("suite validation failed:\n  - %s", strings.Join(errs, "\n  - "))
	}
	return nil
}

func (c Cluster) validate() error {
	var errs []string
	if strings.TrimSpace(c.Name) == "" {
		errs = append(errs, "spec.cluster.name is required")
	}
	if strings.TrimSpace(c.KindConfig) == "" {
		errs = append(errs, "spec.cluster.kindConfig is required")
	}
	if strings.TrimSpace(c.Cilium.ChartVersion) == "" {
		errs = append(errs, "spec.cluster.cilium.chartVersion is required")
	}
	if c.Cilium.WaitTimeout != "" {
		if _, err := ParseDuration(c.Cilium.WaitTimeout, 0); err != nil {
			errs = append(errs, "spec.cluster.cilium.waitTimeout: "+err.Error())
		}
	}
	if len(errs) > 0 {
		return fmt.Errorf("%s", strings.Join(errs, "; "))
	}
	return nil
}

func (d *Deps) validate() error {
	var errs []string
	for i, dc := range d.DockerCompose {
		prefix := fmt.Sprintf("spec.deps.dockerCompose[%d]", i)
		if strings.TrimSpace(dc.Name) == "" {
			errs = append(errs, prefix+".name is required")
		}
		if strings.TrimSpace(dc.File) == "" {
			errs = append(errs, prefix+".file is required")
		}
		if strings.TrimSpace(dc.ProjectName) == "" {
			errs = append(errs, prefix+".projectName is required")
		}
		for j, w := range dc.Wait {
			wprefix := fmt.Sprintf("%s.wait[%d]", prefix, j)
			if strings.TrimSpace(w.URL) == "" {
				errs = append(errs, wprefix+".url is required")
			}
			if w.Timeout != "" {
				if _, err := ParseDuration(w.Timeout, 0); err != nil {
					errs = append(errs, wprefix+".timeout: "+err.Error())
				}
			}
		}
	}
	if len(errs) > 0 {
		return fmt.Errorf("%s", strings.Join(errs, "; "))
	}
	return nil
}

func (p *Prepare) validate() error {
	var errs []string
	for i, h := range p.Hooks {
		prefix := fmt.Sprintf("spec.prepare.hooks[%d]", i)
		if strings.TrimSpace(h.Name) == "" {
			errs = append(errs, prefix+".name is required")
		}
		if len(h.Command) == 0 {
			errs = append(errs, prefix+".command is required")
		}
		if h.Timeout != "" {
			if _, err := ParseDuration(h.Timeout, 0); err != nil {
				errs = append(errs, prefix+".timeout: "+err.Error())
			}
		}
	}
	for i, label := range p.NodeLabels {
		if !strings.Contains(label, "=") {
			errs = append(errs, fmt.Sprintf("spec.prepare.nodeLabels[%d] must be key=value, got %q", i, label))
		}
	}
	if len(errs) > 0 {
		return fmt.Errorf("%s", strings.Join(errs, "; "))
	}
	return nil
}

func (d *Deploy) validate() error {
	var errs []string
	if d.Timeout != "" {
		if _, err := ParseDuration(d.Timeout, 0); err != nil {
			errs = append(errs, "spec.deploy.timeout: "+err.Error())
		}
	}
	if len(d.Steps) == 0 {
		errs = append(errs, "spec.deploy.steps must not be empty when deploy is set")
	}
	for i, step := range d.Steps {
		prefix := fmt.Sprintf("spec.deploy.steps[%d]", i)
		if strings.TrimSpace(step.Name) == "" {
			errs = append(errs, prefix+".name is required")
		}
		kinds := 0
		if step.Apply != nil {
			kinds++
			if len(step.Apply.Paths) == 0 {
				errs = append(errs, prefix+".apply.paths is required")
			}
		}
		if step.Kustomize != nil {
			kinds++
			if strings.TrimSpace(step.Kustomize.Path) == "" {
				errs = append(errs, prefix+".kustomize.path is required")
			}
		}
		if step.Helm != nil {
			kinds++
			if strings.TrimSpace(step.Helm.ReleaseName) == "" {
				errs = append(errs, prefix+".helm.releaseName is required")
			}
			if strings.TrimSpace(step.Helm.Chart) == "" {
				errs = append(errs, prefix+".helm.chart is required")
			}
			if step.Helm.Timeout != "" {
				if _, err := ParseDuration(step.Helm.Timeout, 0); err != nil {
					errs = append(errs, prefix+".helm.timeout: "+err.Error())
				}
			}
		}
		if step.Wait != nil {
			kinds++
			if strings.TrimSpace(step.Wait.Version) == "" {
				errs = append(errs, prefix+".wait.version is required")
			}
			if strings.TrimSpace(step.Wait.Resource) == "" {
				errs = append(errs, prefix+".wait.resource is required")
			}
			if step.Wait.Name == "" && step.Wait.Selector == "" {
				errs = append(errs, prefix+".wait requires name or selector")
			}
			if step.Wait.Timeout != "" {
				if _, err := ParseDuration(step.Wait.Timeout, 0); err != nil {
					errs = append(errs, prefix+".wait.timeout: "+err.Error())
				}
			}
		}
		if step.Hook != nil {
			kinds++
			if strings.TrimSpace(step.Hook.Name) == "" {
				step.Hook.Name = step.Name
			}
			if len(step.Hook.Command) == 0 {
				errs = append(errs, prefix+".hook.command is required")
			}
		}
		if kinds == 0 {
			errs = append(errs, prefix+" must define one of: apply, kustomize, helm, wait, hook")
		}
		if kinds > 1 {
			errs = append(errs, prefix+" must define exactly one of: apply, kustomize, helm, wait, hook")
		}
	}
	if len(errs) > 0 {
		return fmt.Errorf("%s", strings.Join(errs, "; "))
	}
	return nil
}

func (a *Assert) validate() error {
	var errs []string
	if a.Timeout != "" {
		if _, err := ParseDuration(a.Timeout, 0); err != nil {
			errs = append(errs, "spec.assert.timeout: "+err.Error())
		}
	}
	if len(a.Checks) == 0 {
		errs = append(errs, "spec.assert.checks must not be empty when assert is set")
	}
	for i, check := range a.Checks {
		prefix := fmt.Sprintf("spec.assert.checks[%d]", i)
		if strings.TrimSpace(check.Name) == "" {
			errs = append(errs, prefix+".name is required")
		}
		kinds := 0
		if check.PodsReady != nil {
			kinds++
		}
		if check.WorkloadsReady != nil {
			kinds++
			if len(check.WorkloadsReady.Kinds) == 0 {
				errs = append(errs, prefix+".workloadsReady.kinds is required")
			}
		}
		if check.ServiceProbe != nil {
			kinds++
			sp := check.ServiceProbe
			if sp.Namespace == "" || sp.Service == "" || sp.Port == 0 {
				errs = append(errs, prefix+".serviceProbe requires namespace, service, and port")
			}
		}
		if check.ResourceCondition != nil {
			kinds++
			rc := check.ResourceCondition
			if rc.APIVersion == "" || rc.Kind == "" || rc.Name == "" || rc.Condition == "" || rc.Status == "" {
				errs = append(errs, prefix+".resourceCondition requires apiVersion, kind, name, condition, status")
			}
		}
		if check.GatewayReady != nil {
			kinds++
			if check.GatewayReady.Name == "" || check.GatewayReady.Namespace == "" {
				errs = append(errs, prefix+".gatewayReady requires name and namespace")
			}
		}
		if check.NetworkProbe != nil {
			kinds++
			if check.NetworkProbe.Address == "" {
				errs = append(errs, prefix+".networkProbe.address is required")
			}
		}
		if kinds == 0 {
			errs = append(errs, prefix+" must define one check type")
		}
		if kinds > 1 {
			errs = append(errs, prefix+" must define exactly one check type")
		}
	}
	if len(errs) > 0 {
		return fmt.Errorf("%s", strings.Join(errs, "; "))
	}
	return nil
}
