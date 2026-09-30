package deploy

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"

	"github.com/gjpin/homeworld/e2e/internal/config"
	"github.com/gjpin/homeworld/e2e/internal/kube"
	"github.com/gjpin/homeworld/e2e/internal/report"
)

// Runner executes prepare + deploy steps.
type Runner struct {
	Suite   *config.Suite
	Clients *kube.Clients
	Report  *report.Report
	Timeout time.Duration
}

// Prepare applies node labels and runs prepare hooks.
func (r *Runner) Prepare(ctx context.Context) error {
	if r.Suite.Spec.Prepare == nil {
		return nil
	}
	prep := r.Suite.Spec.Prepare

	if len(prep.NodeLabels) > 0 {
		start := time.Now()
		if err := r.applyNodeLabels(ctx, prep.NodeLabels); err != nil {
			r.Report.Add(report.Fail("prepare", "nodeLabels", "", time.Since(start), err))
			return err
		}
		r.Report.Add(report.Pass("prepare", "nodeLabels", strings.Join(prep.NodeLabels, ","), time.Since(start)))
	}

	for _, h := range prep.Hooks {
		start := time.Now()
		if err := r.runHook(ctx, h); err != nil {
			r.Report.Add(report.Fail("prepare", h.Name, "", time.Since(start), err))
			return err
		}
		r.Report.Add(report.Pass("prepare", h.Name, "hook completed", time.Since(start)))
	}
	return nil
}

// Deploy runs ordered deploy steps.
func (r *Runner) Deploy(ctx context.Context) error {
	if r.Suite.Spec.Deploy == nil {
		return nil
	}
	timeout, err := config.ParseDuration(r.Suite.Spec.Deploy.Timeout, r.Timeout)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	for _, step := range r.Suite.Spec.Deploy.Steps {
		start := time.Now()
		if err := r.runStep(ctx, step); err != nil {
			r.Report.Add(report.Fail("deploy", step.Name, "", time.Since(start), err))
			return err
		}
		r.Report.Add(report.Pass("deploy", step.Name, "ok", time.Since(start)))
	}
	return nil
}

func (r *Runner) applyNodeLabels(ctx context.Context, labels []string) error {
	nodes, err := r.Clients.Typed.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
	if err != nil {
		return fmt.Errorf("list nodes: %w", err)
	}
	for _, node := range nodes.Items {
		args := []string{"label", "node", node.Name, "--overwrite"}
		args = append(args, labels...)
		if err := runCmd(ctx, r.Suite.WorkDir(), nil, "kubectl", args...); err != nil {
			return fmt.Errorf("label node %s: %w", node.Name, err)
		}
	}
	return nil
}

func (r *Runner) runHook(ctx context.Context, h config.Hook) error {
	timeout, err := config.ParseDuration(h.Timeout, 15*time.Minute)
	if err != nil {
		return err
	}
	hctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	if len(h.Command) == 0 {
		return fmt.Errorf("empty hook command")
	}
	env := os.Environ()
	for k, v := range h.Env {
		env = append(env, fmt.Sprintf("%s=%s", k, v))
	}
	return runCmd(hctx, r.Suite.WorkDir(), env, h.Command[0], h.Command[1:]...)
}

func (r *Runner) runStep(ctx context.Context, step config.DeployStep) error {
	switch {
	case step.Apply != nil:
		return r.applyPaths(ctx, step.Apply.Paths)
	case step.Kustomize != nil:
		path := r.Suite.ResolvePath(step.Kustomize.Path)
		return runCmd(ctx, r.Suite.WorkDir(), nil, "kubectl", "apply", "-k", path)
	case step.Helm != nil:
		return r.helmInstall(ctx, step.Helm)
	case step.Wait != nil:
		return r.waitStep(ctx, step.Name, step.Wait)
	case step.Hook != nil:
		return r.runHook(ctx, *step.Hook)
	default:
		return fmt.Errorf("step %q has no action", step.Name)
	}
}

func (r *Runner) applyPaths(ctx context.Context, paths []string) error {
	for _, p := range paths {
		abs := r.Suite.ResolvePath(p)
		if err := retryCmd(ctx, func() error {
			return runCmd(ctx, r.Suite.WorkDir(), nil, "kubectl", "apply", "-f", abs)
		}); err != nil {
			return fmt.Errorf("apply %s: %w", p, err)
		}
	}
	return nil
}

func (r *Runner) helmInstall(ctx context.Context, h *config.HelmStep) error {
	timeout, err := config.ParseDuration(h.Timeout, 10*time.Minute)
	if err != nil {
		return err
	}
	if shouldSkipHelm(h.SkipIfPresent, helmReleaseExists(ctx, r.Suite.WorkDir(), h)) {
		fmt.Fprintf(os.Stderr, "[helm] %s already present; skipping upgrade\n", h.ReleaseName)
		return nil
	}
	chart := h.Chart
	if !strings.Contains(chart, "/") && !strings.HasPrefix(chart, ".") && h.RepoURL == "" {
		// local path
		chart = r.Suite.ResolvePath(chart)
	} else if strings.HasPrefix(chart, ".") || strings.HasPrefix(chart, "/") {
		chart = r.Suite.ResolvePath(chart)
	}

	if h.RepoURL != "" {
		repoName := h.ReleaseName + "-repo"
		if err := runCmd(ctx, r.Suite.WorkDir(), nil, "helm", "repo", "add", repoName, h.RepoURL, "--force-update"); err != nil {
			return err
		}
		if !strings.Contains(chart, "/") {
			chart = repoName + "/" + chart
		}
	}

	args := []string{"upgrade", "--install", h.ReleaseName, chart}
	if h.Version != "" {
		args = append(args, "--version", h.Version)
	}
	if h.Namespace != "" {
		args = append(args, "--namespace", h.Namespace)
	}
	if h.CreateNS {
		args = append(args, "--create-namespace")
	}
	if h.Wait {
		args = append(args, "--wait", "--timeout", timeout.String())
	}
	for k, v := range h.Values {
		args = append(args, "--set", fmt.Sprintf("%s=%s", k, v))
	}
	for _, vf := range h.ValuesFiles {
		args = append(args, "-f", r.Suite.ResolvePath(vf))
	}
	return retryCmd(ctx, func() error {
		return runCmd(ctx, r.Suite.WorkDir(), nil, "helm", args...)
	})
}

// retryCmd runs fn with up to three attempts and a short fixed backoff,
// absorbing transient kind-apiserver stalls (connection refused, HTTP 5xx)
// during apply/helm steps. Wait and assert steps already poll and are
// unaffected.
func retryCmd(ctx context.Context, fn func() error) error {
	var err error
	for attempt := 1; attempt <= 3; attempt++ {
		if err = fn(); err == nil {
			return nil
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if attempt < 3 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(5 * time.Second):
			}
		}
	}
	return err
}

func shouldSkipHelm(skipIfPresent, exists bool) bool {
	return skipIfPresent && exists
}

func helmReleaseExists(ctx context.Context, dir string, h *config.HelmStep) bool {
	args := []string{"status", h.ReleaseName, "-o", "json"}
	if h.Namespace != "" {
		args = append(args, "--namespace", h.Namespace)
	}
	var out bytes.Buffer
	if helmStatus(ctx, dir, args, &out) != nil {
		return false
	}
	// A release is only "present" when its last install/upgrade completed:
	// failed or pending-upgrade releases are left behind on --keep-cluster
	// and must be reinstalled, not skipped.
	var status struct {
		Info struct {
			Status string `json:"status"`
		} `json:"info"`
	}
	if err := json.Unmarshal(out.Bytes(), &status); err != nil {
		return false
	}
	return status.Info.Status == "deployed"
}

func helmStatus(ctx context.Context, dir string, args []string, out *bytes.Buffer) error {
	cmd := exec.CommandContext(ctx, "helm", args...)
	cmd.Dir = dir
	cmd.Stdout = out
	cmd.Stderr = io.Discard
	return cmd.Run()
}

func (r *Runner) waitStep(ctx context.Context, name string, w *config.WaitStep) error {
	timeout, err := config.ParseDuration(w.Timeout, 15*time.Minute)
	if err != nil {
		return err
	}
	interval, err := config.ParseDuration(w.Interval, 15*time.Second)
	if err != nil {
		return err
	}
	if interval < time.Second {
		interval = time.Second
	}
	gvr := schema.GroupVersionResource{
		Group:    w.Group,
		Version:  w.Version,
		Resource: w.Resource,
	}

	fmt.Fprintf(os.Stderr, "[wait] %s: polling timeout=%s interval=%s\n", name, timeout, interval)
	var resyncEvery time.Duration
	if w.ResyncInterval != "" && gvr.Group == "argoproj.io" && gVRResource(gvr) == "applications" {
		resyncEvery, err = config.ParseDuration(w.ResyncInterval, 0)
		if err != nil {
			return err
		}
		fmt.Fprintf(os.Stderr, "[wait] %s: out-of-sync application rescue every %s\n", name, resyncEvery)
	}
	deadline := time.Now().Add(timeout)
	var lastLog time.Time
	var lastResync time.Time
	for {
		actx, cancel := context.WithTimeout(ctx, 30*time.Second)
		err := r.checkWait(actx, gvr, w)
		cancel()
		if err == nil {
			fmt.Fprintf(os.Stderr, "[wait] %s: ok\n", name)
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("wait timeout: %w", err)
		}
		if lastLog.IsZero() || time.Since(lastLog) >= time.Minute {
			fmt.Fprintf(os.Stderr, "[wait] %s: still waiting (%s left): %v\n", name, time.Until(deadline).Round(time.Second), err)
			lastLog = time.Now()
		}
		if resyncEvery > 0 && (lastResync.IsZero() || time.Since(lastResync) >= resyncEvery) {
			rctx, rcancel := context.WithTimeout(ctx, 60*time.Second)
			r.resyncOutOfSyncApps(rctx, w)
			rcancel()
			lastResync = time.Now()
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(interval):
		}
	}
}

func gVRResource(gvr schema.GroupVersionResource) string {
	return gvr.Resource
}

// resyncOutOfSyncApps force-syncs Applications that are stuck OutOfSync with
// no operation running. Argo CD exhausts its five sync retries on transient
// first-boot failures and self-heal never re-fires after a failed sync, so a
// short-lived condition (for example the grafana operator pinging its
// instance before the pod is ready) can leave an application permanently
// OutOfSync even after the underlying resource turns healthy. Re-triggering
// the operation is the documented recovery; patching operation.sync on many
// applications at once overloads the application-controller, so the sweep
// is rate limited.
func (r *Runner) resyncOutOfSyncApps(ctx context.Context, w *config.WaitStep) {
	gvr := schema.GroupVersionResource{Group: "argoproj.io", Version: "v1alpha1", Resource: "applications"}
	var listOpts metav1.ListOptions
	if w.Selector != "" {
		listOpts.LabelSelector = w.Selector
	}
	list, err := listResources(ctx, r.Clients, gvr, w.Namespace, listOpts)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[wait] resync: list applications: %v\n", err)
		return
	}
	rescued := 0
	for _, u := range list {
		syncStatus, _, _ := unstructured.NestedString(u.Object, "status", "sync", "status")
		if syncStatus != "OutOfSync" {
			continue
		}
		if _, opExists, _ := unstructured.NestedMap(u.Object, "operation"); opExists {
			continue
		}
		revision, _, _ := unstructured.NestedString(u.Object, "spec", "source", "targetRevision")
		if revision == "" {
			revision = "HEAD"
		}
		operation := map[string]interface{}{
			"initiatedBy": map[string]interface{}{"username": "e2e-resync"},
			"sync": map[string]interface{}{
				"revision": revision,
				"prune":    true,
			},
		}
		if syncOptions, ok, _ := unstructured.NestedStringSlice(u.Object, "spec", "syncPolicy", "syncOptions"); ok {
			operation["sync"].(map[string]interface{})["syncOptions"] = syncOptions
		}
		patch, err := json.Marshal(map[string]interface{}{"operation": operation})
		if err != nil {
			continue
		}
		rctx, cancel := context.WithTimeout(ctx, 20*time.Second)
		_, err = r.Clients.Dynamic.Resource(gvr).Namespace(w.Namespace).Patch(
			rctx, u.GetName(), types.MergePatchType, patch, metav1.PatchOptions{})
		cancel()
		if err != nil {
			fmt.Fprintf(os.Stderr, "[wait] resync: %s: %v\n", u.GetName(), err)
		} else {
			fmt.Fprintf(os.Stderr, "[wait] resync: re-triggered sync on %s\n", u.GetName())
			rescued++
		}
		if rescued >= 4 {
			break
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(time.Second):
		}
	}
}

func (r *Runner) checkWait(ctx context.Context, gvr schema.GroupVersionResource, w *config.WaitStep) error {
	var listOpts metav1.ListOptions
	if w.Selector != "" {
		listOpts.LabelSelector = w.Selector
	}

	if w.Name != "" {
		u, err := getResource(ctx, r.Clients, gvr, w.Namespace, w.Name)
		if err != nil {
			return err
		}
		return resourceMatches(u, w.Conditions, w.Fields)
	}

	list, err := listResources(ctx, r.Clients, gvr, w.Namespace, listOpts)
	if err != nil {
		return err
	}
	if len(list) == 0 {
		return fmt.Errorf("no resources matching wait criteria")
	}
	for _, u := range list {
		if err := resourceMatches(u, w.Conditions, w.Fields); err != nil {
			return fmt.Errorf("%s: %w", u.GetName(), err)
		}
	}
	return nil
}

func resourceMatches(obj *unstructured.Unstructured, conditions []config.WaitCondition, fields []config.WaitField) error {
	if err := conditionsOK(obj, conditions); err != nil {
		return err
	}
	return fieldsOK(obj, fields)
}

func runCmd(ctx context.Context, dir string, env []string, name string, args ...string) error {
	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = dir
	if env != nil {
		cmd.Env = env
	}
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}
