package assert

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/util/sets"

	"github.com/gjpin/homeworld/e2e/internal/config"
	"github.com/gjpin/homeworld/e2e/internal/kube"
	"github.com/gjpin/homeworld/e2e/internal/report"
)

// Runner executes assert checks.
type Runner struct {
	Suite    *config.Suite
	Clients  *kube.Clients
	Report   *report.Report
	Timeout  time.Duration
	FailFast bool
}

// Run executes all assert checks.
func (r *Runner) Run(ctx context.Context) error {
	if r.Suite.Spec.Assert == nil {
		return nil
	}
	timeout, err := config.ParseDuration(r.Suite.Spec.Assert.Timeout, r.Timeout)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	var firstErr error
	for _, check := range r.Suite.Spec.Assert.Checks {
		start := time.Now()
		err := r.runCheck(ctx, check)
		if err != nil {
			r.Report.Add(report.Fail("assert", check.Name, "", time.Since(start), err))
			if firstErr == nil {
				firstErr = err
			}
			if r.FailFast {
				return err
			}
			continue
		}
		r.Report.Add(report.Pass("assert", check.Name, "ok", time.Since(start)))
	}
	return firstErr
}

func (r *Runner) runCheck(ctx context.Context, check config.Check) error {
	interval := 15 * time.Second
	var last error
	start := time.Now()
	var lastLog time.Time
	for {
		last = r.runCheckOnce(ctx, check)
		if last == nil {
			if !lastLog.IsZero() {
				fmt.Fprintf(os.Stderr, "[assert] %s: ok after %s\n", check.Name, time.Since(start).Round(time.Second))
			}
			return nil
		}
		if ctx.Err() != nil {
			return last
		}
		if lastLog.IsZero() || time.Since(lastLog) >= time.Minute {
			fmt.Fprintf(os.Stderr, "[assert] %s: still failing (%s): %v\n", check.Name, time.Since(start).Round(time.Second), last)
			lastLog = time.Now()
		}
		select {
		case <-ctx.Done():
			return last
		case <-time.After(interval):
		}
	}
}

func (r *Runner) runCheckOnce(ctx context.Context, check config.Check) error {
	switch {
	case check.PodsReady != nil:
		return r.podsReady(ctx, check.PodsReady)
	case check.WorkloadsReady != nil:
		return r.workloadsReady(ctx, check.WorkloadsReady)
	case check.ServiceProbe != nil:
		return r.serviceProbe(ctx, check.ServiceProbe)
	case check.ResourceCondition != nil:
		return r.resourceCondition(ctx, check.ResourceCondition)
	case check.GatewayReady != nil:
		return r.gatewayReady(ctx, check.GatewayReady)
	case check.NetworkProbe != nil:
		return r.networkProbe(ctx, check.NetworkProbe)
	default:
		return fmt.Errorf("check %q has no type", check.Name)
	}
}

func (r *Runner) podsReady(ctx context.Context, cfg *config.PodsReady) error {
	nsList, err := r.namespaces(ctx, cfg.Namespaces, cfg.ExcludeNamespaces)
	if err != nil {
		return err
	}
	opts := metav1.ListOptions{}
	if cfg.Selector != "" {
		opts.LabelSelector = cfg.Selector
	}
	var bad []string
	for _, ns := range nsList {
		pods, err := r.Clients.Typed.CoreV1().Pods(ns).List(ctx, opts)
		if err != nil {
			return err
		}
		for _, p := range pods.Items {
			if cfg.IgnoreCompletedJobs && isCompletedJobPod(&p) {
				continue
			}
			if !podReady(&p) {
				bad = append(bad, fmt.Sprintf("%s/%s (%s)", p.Namespace, p.Name, p.Status.Phase))
			}
		}
	}
	if len(bad) > 0 {
		return fmt.Errorf("pods not ready: %s", strings.Join(bad, ", "))
	}
	return nil
}

func isCompletedJobPod(p *corev1.Pod) bool {
	for _, or := range p.OwnerReferences {
		if or.Kind == "Job" {
			return p.Status.Phase == corev1.PodSucceeded || p.Status.Phase == corev1.PodFailed
		}
	}
	return false
}

func podReady(p *corev1.Pod) bool {
	if p.Status.Phase != corev1.PodRunning && p.Status.Phase != corev1.PodSucceeded {
		return false
	}
	if p.Status.Phase == corev1.PodSucceeded {
		return true
	}
	for _, c := range p.Status.Conditions {
		if c.Type == corev1.PodReady {
			return c.Status == corev1.ConditionTrue
		}
	}
	return false
}

func (r *Runner) workloadsReady(ctx context.Context, cfg *config.WorkloadsReady) error {
	nsList, err := r.namespaces(ctx, cfg.Namespaces, nil)
	if err != nil {
		return err
	}
	opts := metav1.ListOptions{}
	if cfg.Selector != "" {
		opts.LabelSelector = cfg.Selector
	}
	var bad []string
	for _, ns := range nsList {
		for _, kind := range cfg.Kinds {
			switch strings.ToLower(kind) {
			case "deployment", "deployments":
				list, err := r.Clients.Typed.AppsV1().Deployments(ns).List(ctx, opts)
				if err != nil {
					return err
				}
				for _, d := range list.Items {
					if !deploymentReady(&d) {
						bad = append(bad, fmt.Sprintf("Deployment/%s/%s", ns, d.Name))
					}
				}
			case "statefulset", "statefulsets":
				list, err := r.Clients.Typed.AppsV1().StatefulSets(ns).List(ctx, opts)
				if err != nil {
					return err
				}
				for _, s := range list.Items {
					if !statefulSetReady(&s) {
						bad = append(bad, fmt.Sprintf("StatefulSet/%s/%s", ns, s.Name))
					}
				}
			case "daemonset", "daemonsets":
				list, err := r.Clients.Typed.AppsV1().DaemonSets(ns).List(ctx, opts)
				if err != nil {
					return err
				}
				for _, d := range list.Items {
					if !daemonSetReady(&d) {
						bad = append(bad, fmt.Sprintf("DaemonSet/%s/%s", ns, d.Name))
					}
				}
			default:
				return fmt.Errorf("unsupported workload kind %q", kind)
			}
		}
	}
	if len(bad) > 0 {
		return fmt.Errorf("workloads not ready: %s", strings.Join(bad, ", "))
	}
	return nil
}

func deploymentReady(d *appsv1.Deployment) bool {
	desired := int32(1)
	if d.Spec.Replicas != nil {
		desired = *d.Spec.Replicas
	}
	return d.Status.ReadyReplicas >= desired && d.Status.UpdatedReplicas >= desired && d.Status.ObservedGeneration >= d.Generation
}

func statefulSetReady(s *appsv1.StatefulSet) bool {
	desired := int32(1)
	if s.Spec.Replicas != nil {
		desired = *s.Spec.Replicas
	}
	return s.Status.ReadyReplicas >= desired && s.Status.UpdatedReplicas >= desired
}

func daemonSetReady(d *appsv1.DaemonSet) bool {
	return d.Status.NumberReady >= d.Status.DesiredNumberScheduled && d.Status.UpdatedNumberScheduled >= d.Status.DesiredNumberScheduled
}

func (r *Runner) serviceProbe(ctx context.Context, cfg *config.ServiceProbe) error {
	timeout, err := config.ParseDuration(cfg.Timeout, 2*time.Minute)
	if err != nil {
		return err
	}
	scheme := cfg.Scheme
	if scheme == "" {
		scheme = "http"
	}
	path := cfg.Path
	if path == "" {
		path = "/"
	}

	deadline := time.Now().Add(timeout)
	var lastErr error
	for {
		localPort, stop, err := kube.PortForward(ctx, r.Clients.Config, r.Clients.Typed, cfg.Namespace, cfg.Service, cfg.Port)
		if err != nil {
			lastErr = err
		} else {
			url := fmt.Sprintf("%s://127.0.0.1:%d%s", scheme, localPort, path)
			code, _, err := kube.HTTPGet(ctx, url, 10*time.Second)
			stop()
			if err == nil && code >= 200 && code < 400 {
				return nil
			}
			if err != nil {
				lastErr = err
			} else {
				lastErr = fmt.Errorf("HTTP %d", code)
			}
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("serviceProbe %s/%s:%d: %v", cfg.Namespace, cfg.Service, cfg.Port, lastErr)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(3 * time.Second):
		}
	}
}

func (r *Runner) resourceCondition(ctx context.Context, cfg *config.ResourceCondition) error {
	group, version, err := kube.ParseAPIVersion(cfg.APIVersion)
	if err != nil {
		return err
	}
	resource := pluralize(cfg.Kind)
	gvr := schema.GroupVersionResource{Group: group, Version: version, Resource: resource}
	return r.resourceConditionOnce(ctx, gvr, cfg)
}

func (r *Runner) resourceConditionOnce(ctx context.Context, gvr schema.GroupVersionResource, cfg *config.ResourceCondition) error {
	var objs []*unstructured.Unstructured
	if cfg.Name != "" {
		var u *unstructured.Unstructured
		var err error
		if cfg.Namespace == "" {
			u, err = r.Clients.Dynamic.Resource(gvr).Get(ctx, cfg.Name, metav1.GetOptions{})
		} else {
			u, err = r.Clients.Dynamic.Resource(gvr).Namespace(cfg.Namespace).Get(ctx, cfg.Name, metav1.GetOptions{})
		}
		if err != nil {
			return err
		}
		objs = []*unstructured.Unstructured{u}
	} else {
		opts := metav1.ListOptions{LabelSelector: cfg.Selector}
		ns := cfg.Namespace
		if ns == "" {
			ns = metav1.NamespaceAll
		}
		list, err := r.Clients.Dynamic.Resource(gvr).Namespace(ns).List(ctx, opts)
		if err != nil {
			return err
		}
		for i := range list.Items {
			objs = append(objs, &list.Items[i])
		}
	}
	if len(objs) == 0 {
		return fmt.Errorf("no %s resources matching criteria", cfg.Kind)
	}
	var bad []string
	for _, obj := range objs {
		if err := matchResource(obj, cfg); err != nil {
			bad = append(bad, fmt.Sprintf("%s/%s: %v", obj.GetNamespace(), obj.GetName(), err))
		}
	}
	if len(bad) > 0 {
		return fmt.Errorf("%s", strings.Join(bad, "; "))
	}
	return nil
}

func matchResource(obj *unstructured.Unstructured, cfg *config.ResourceCondition) error {
	if cfg.Condition != "" {
		got := kube.ConditionStatus(obj, cfg.Condition)
		if got != cfg.Status {
			return fmt.Errorf("condition %s=%s, want %s", cfg.Condition, got, cfg.Status)
		}
	}
	for _, f := range cfg.Fields {
		if err := kube.FieldEquals(obj, f.Path, f.Value); err != nil {
			return err
		}
	}
	return nil
}

func (r *Runner) gatewayReady(ctx context.Context, cfg *config.GatewayReady) error {
	gvr := schema.GroupVersionResource{Group: "gateway.networking.k8s.io", Version: "v1", Resource: "gateways"}
	obj, err := r.Clients.Dynamic.Resource(gvr).Namespace(cfg.Namespace).Get(ctx, cfg.Name, metav1.GetOptions{})
	if err != nil {
		return err
	}
	if kube.ConditionStatus(obj, "Accepted") == "True" && programedOK(obj) {
		return nil
	}
	return fmt.Errorf("gateway not ready (Accepted=%s Programmed=%s)",
		kube.ConditionStatus(obj, "Accepted"), kube.ConditionStatus(obj, "Programmed"))
}

func programedOK(obj *unstructured.Unstructured) bool {
	// Prefer Programmed=True when present; some implementations only set Accepted.
	s := kube.ConditionStatus(obj, "Programmed")
	if s == "" {
		return true
	}
	return s == "True"
}

func (r *Runner) networkProbe(ctx context.Context, cfg *config.NetworkProbe) error {
	timeout, err := config.ParseDuration(cfg.Timeout, 2*time.Minute)
	if err != nil {
		return err
	}
	protocol := strings.ToLower(cfg.Protocol)
	if protocol == "" {
		protocol = "tcp"
	}
	ns := cfg.FromNamespace
	if ns == "" {
		ns = "default"
	}
	opts := metav1.ListOptions{}
	if cfg.FromSelector != "" {
		opts.LabelSelector = cfg.FromSelector
	}
	pods, err := r.Clients.Typed.CoreV1().Pods(ns).List(ctx, opts)
	if err != nil {
		return err
	}
	var pod *corev1.Pod
	for i := range pods.Items {
		if pods.Items[i].Status.Phase == corev1.PodRunning {
			pod = &pods.Items[i]
			break
		}
	}
	if pod == nil {
		return fmt.Errorf("networkProbe: no running pod in %s", ns)
	}
	container := ""
	if len(pod.Spec.Containers) > 0 {
		container = pod.Spec.Containers[0].Name
	}

	addr := cfg.Address
	port := cfg.Port
	var cmd []string
	switch protocol {
	case "tcp":
		if port == 0 {
			return fmt.Errorf("networkProbe tcp requires port")
		}
		cmd = []string{"sh", "-c", fmt.Sprintf("nc -z -w 5 %s %d || (command -v bash >/dev/null && timeout 5 bash -c 'cat < /dev/null > /dev/tcp/%s/%d')", addr, port, addr, port)}
	case "http", "https":
		path := cfg.Path
		if path == "" {
			path = "/"
		}
		url := fmt.Sprintf("%s://%s", protocol, addr)
		if port != 0 {
			url = fmt.Sprintf("%s://%s:%d%s", protocol, addr, port, path)
		} else {
			url = url + path
		}
		cmd = []string{"sh", "-c", fmt.Sprintf("wget -q -O /dev/null --timeout=5 %s || curl -sf --max-time 5 -o /dev/null %s", url, url)}
	default:
		return fmt.Errorf("unsupported networkProbe protocol %q", protocol)
	}

	deadline := time.Now().Add(timeout)
	var lastErr error
	for {
		_, err := kube.ExecInPod(ctx, r.Clients.Config, r.Clients.Typed, pod.Namespace, pod.Name, container, cmd)
		if err == nil {
			return nil
		}
		lastErr = err
		if time.Now().After(deadline) {
			return fmt.Errorf("networkProbe: %v", lastErr)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(3 * time.Second):
		}
	}
}

func (r *Runner) namespaces(ctx context.Context, include, exclude []string) ([]string, error) {
	excl := sets.NewString(exclude...)
	if len(include) > 0 {
		var out []string
		for _, ns := range include {
			if !excl.Has(ns) {
				out = append(out, ns)
			}
		}
		return out, nil
	}
	list, err := r.Clients.Typed.CoreV1().Namespaces().List(ctx, metav1.ListOptions{})
	if err != nil {
		return nil, err
	}
	var out []string
	for _, ns := range list.Items {
		if excl.Has(ns.Name) {
			continue
		}
		out = append(out, ns.Name)
	}
	return out, nil
}

func pluralize(kind string) string {
	k := strings.ToLower(kind)
	switch {
	case strings.HasSuffix(k, "s"):
		return k
	case strings.HasSuffix(k, "y") && len(k) > 1 && !isVowel(k[len(k)-2]):
		return strings.TrimSuffix(k, "y") + "ies"
	default:
		return k + "s"
	}
}

func isVowel(b byte) bool {
	switch b {
	case 'a', 'e', 'i', 'o', 'u':
		return true
	default:
		return false
	}
}
