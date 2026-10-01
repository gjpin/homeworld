package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"syscall"
	"time"

	"github.com/spf13/cobra"

	"github.com/gjpin/homeworld/e2e/internal/assert"
	"github.com/gjpin/homeworld/e2e/internal/cluster"
	"github.com/gjpin/homeworld/e2e/internal/config"
	"github.com/gjpin/homeworld/e2e/internal/deploy"
	"github.com/gjpin/homeworld/e2e/internal/deps"
	"github.com/gjpin/homeworld/e2e/internal/kube"
	"github.com/gjpin/homeworld/e2e/internal/report"
)

type globalFlags struct {
	suiteFile   string
	kubeconfig  string
	context     string
	timeout     time.Duration
	failFast    bool
	output      string
	keepCluster bool
	keepDeps    bool
}

// exitError carries a specific process exit code through cobra's error
// return path. Returning errors instead of calling os.Exit lets the run
// command's deferred cleanup execute — os.Exit skips defers, which used to
// leak the kind cluster and compose dependencies on every pipeline
// failure (and made --keep-cluster/--keep-deps meaningless).
type exitError struct {
	code int
	err  error
}

func (e *exitError) Error() string { return e.err.Error() }
func (e *exitError) Unwrap() error { return e.err }

func main() {
	g := &globalFlags{
		timeout: 60 * time.Minute,
		output:  "text",
	}

	root := &cobra.Command{
		Use:           "e2e",
		Short:         "Portable kind+Cilium E2E suite runner",
		SilenceUsage:  true,
		SilenceErrors: true,
	}

	root.PersistentFlags().StringVarP(&g.suiteFile, "file", "f", "", "path to suite YAML (required)")
	root.PersistentFlags().StringVar(&g.kubeconfig, "kubeconfig", "", "kubeconfig path")
	root.PersistentFlags().StringVar(&g.context, "context", "", "kube context")
	root.PersistentFlags().DurationVar(&g.timeout, "timeout", g.timeout, "default operation timeout")
	root.PersistentFlags().BoolVar(&g.failFast, "fail-fast", false, "stop on first assert failure")
	root.PersistentFlags().StringVarP(&g.output, "output", "o", g.output, "report output: text|json")

	root.AddCommand(
		newRunCmd(g),
		newValidateCmd(g),
		newDepsCmd(g),
		newClusterCmd(g),
		newDeployCmd(g),
		newAssertCmd(g),
	)

	if err := root.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		var ec *exitError
		if errors.As(err, &ec) {
			os.Exit(ec.code)
		}
		os.Exit(report.ExitPipelineError)
	}
}

func requireSuite(g *globalFlags) (*config.Suite, error) {
	if g.suiteFile == "" {
		return nil, fmt.Errorf("--file/-f is required")
	}
	return config.Load(g.suiteFile)
}

func withSignalContext(parent context.Context) (context.Context, context.CancelFunc) {
	ctx, cancel := signal.NotifyContext(parent, os.Interrupt, syscall.SIGTERM)
	return ctx, cancel
}

func newRunCmd(g *globalFlags) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "run",
		Short: "Full pipeline: deps → cluster up → prepare → deploy → assert",
		RunE: func(cmd *cobra.Command, args []string) error {
			suite, err := requireSuite(g)
			if err != nil {
				return err
			}
			rep := report.New(suite.Metadata.Name)
			ctx, cancel := withSignalContext(cmd.Context())
			defer cancel()

			depsMgr := &deps.Manager{Suite: suite}
			clusterMgr := &cluster.Manager{Suite: suite, Timeout: g.timeout, KeepCluster: g.keepCluster}

			cleanup := func(failed bool) {
				if failed && g.keepCluster {
					fmt.Fprintln(os.Stderr, "keeping cluster (--keep-cluster)")
				} else if !g.keepCluster || !failed {
					_ = clusterMgr.Down(context.Background())
				}
				if failed && g.keepDeps {
					fmt.Fprintln(os.Stderr, "keeping deps (--keep-deps)")
				} else if !g.keepDeps || !failed {
					_ = depsMgr.Down(context.Background())
				}
			}

			failed := true
			defer func() {
				if failed {
					cleanup(true)
				}
			}()

			start := time.Now()
			if err := depsMgr.Up(ctx); err != nil {
				rep.Add(report.Fail("deps", "up", "", time.Since(start), err))
				_ = rep.WriteToStdout(g.output)
				return &exitError{report.ExitPipelineError, err}
			}
			rep.Add(report.Pass("deps", "up", "compose ready", time.Since(start)))

			start = time.Now()
			if err := clusterMgr.Up(ctx); err != nil {
				rep.Add(report.Fail("cluster", "up", "", time.Since(start), err))
				_ = rep.WriteToStdout(g.output)
				return &exitError{report.ExitPipelineError, err}
			}
			rep.Add(report.Pass("cluster", "up", "kind+cilium ready", time.Since(start)))

			clients, err := kube.NewClients(kube.Options{Kubeconfig: g.kubeconfig, Context: g.context})
			if err != nil {
				rep.Add(report.Fail("kube", "client", "", 0, err))
				_ = rep.WriteToStdout(g.output)
				return &exitError{report.ExitPipelineError, err}
			}

			deployer := &deploy.Runner{Suite: suite, Clients: clients, Report: rep, Timeout: g.timeout}
			if err := deployer.Prepare(ctx); err != nil {
				_ = rep.WriteToStdout(g.output)
				return &exitError{report.ExitPipelineError, err}
			}
			if err := deployer.Deploy(ctx); err != nil {
				_ = rep.WriteToStdout(g.output)
				return &exitError{report.ExitPipelineError, err}
			}

			asserter := &assert.Runner{Suite: suite, Clients: clients, Report: rep, Timeout: g.timeout, FailFast: g.failFast}
			assertErr := asserter.Run(ctx)
			_ = rep.WriteToStdout(g.output)
			if assertErr != nil {
				return &exitError{report.ExitAssertFailed, assertErr}
			}

			failed = false
			cleanup(false)
			return nil
		},
	}
	cmd.Flags().BoolVar(&g.keepCluster, "keep-cluster", false, "reuse an existing kind cluster and keep it on failure")
	cmd.Flags().BoolVar(&g.keepDeps, "keep-deps", false, "keep compose deps on failure")
	return cmd
}

func newValidateCmd(g *globalFlags) *cobra.Command {
	return &cobra.Command{
		Use:   "validate",
		Short: "Validate suite schema and host prerequisites (no cluster)",
		RunE: func(cmd *cobra.Command, args []string) error {
			suite, err := requireSuite(g)
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				return &exitError{report.ExitUsageError, err}
			}
			fmt.Printf("suite %q OK (%s)\n", suite.Metadata.Name, suite.Path)

			missing := checkPrereqs()
			if len(missing) > 0 {
				fmt.Fprintln(os.Stderr, "warning: missing prerequisites (required for run/cluster/deps):")
				for _, m := range missing {
					fmt.Fprintf(os.Stderr, "  - %s\n", m)
				}
				return nil
			}
			fmt.Println("prerequisites: docker, docker compose, kind, kubectl, helm, rsync, envsubst, python3, git, openssl, jq, curl — OK")
			return nil
		},
	}
}

func checkPrereqs() []string {
	var missing []string
	// The run pipeline's own tools, plus every host binary the suite hooks
	// invoke (seed-infisical.sh, stage-local-repo.sh, rewrite-staging.py, and
	// the examples/manifests helpers): `validate` passing must mean the full
	// run can proceed.
	for _, bin := range []string{
		"docker", "kind", "kubectl", "helm",
		"rsync", "envsubst", "python3", "git", "openssl", "jq", "curl",
	} {
		if _, err := exec.LookPath(bin); err != nil {
			missing = append(missing, bin)
		}
	}
	// docker compose plugin
	if _, err := exec.LookPath("docker"); err == nil {
		cmd := exec.Command("docker", "compose", "version")
		if err := cmd.Run(); err != nil {
			missing = append(missing, "docker compose")
		}
	}
	return missing
}

func newDepsCmd(g *globalFlags) *cobra.Command {
	cmd := &cobra.Command{Use: "deps", Short: "Manage suite Docker Compose dependencies"}
	cmd.AddCommand(
		&cobra.Command{
			Use:   "up",
			Short: "Start Docker Compose projects from the suite",
			RunE: func(cmd *cobra.Command, args []string) error {
				suite, err := requireSuite(g)
				if err != nil {
					return err
				}
				ctx, cancel := withSignalContext(cmd.Context())
				defer cancel()
				return (&deps.Manager{Suite: suite}).Up(ctx)
			},
		},
		&cobra.Command{
			Use:   "down",
			Short: "Stop Docker Compose projects from the suite",
			RunE: func(cmd *cobra.Command, args []string) error {
				suite, err := requireSuite(g)
				if err != nil {
					return err
				}
				ctx, cancel := withSignalContext(cmd.Context())
				defer cancel()
				return (&deps.Manager{Suite: suite}).Down(ctx)
			},
		},
	)
	return cmd
}

func newClusterCmd(g *globalFlags) *cobra.Command {
	var keepDeps bool
	cmd := &cobra.Command{Use: "cluster", Short: "Manage kind+Cilium cluster"}
	up := &cobra.Command{
		Use:   "up",
		Short: "Create kind cluster and install Cilium",
		RunE: func(cmd *cobra.Command, args []string) error {
			suite, err := requireSuite(g)
			if err != nil {
				return err
			}
			ctx, cancel := withSignalContext(cmd.Context())
			defer cancel()
			return (&cluster.Manager{Suite: suite, Timeout: g.timeout}).Up(ctx)
		},
	}
	down := &cobra.Command{
		Use:   "down",
		Short: "Delete kind cluster (and Compose deps unless --keep-deps)",
		RunE: func(cmd *cobra.Command, args []string) error {
			suite, err := requireSuite(g)
			if err != nil {
				return err
			}
			ctx, cancel := withSignalContext(cmd.Context())
			defer cancel()
			if err := (&cluster.Manager{Suite: suite, Timeout: g.timeout}).Down(ctx); err != nil {
				return err
			}
			if !keepDeps {
				return (&deps.Manager{Suite: suite}).Down(ctx)
			}
			return nil
		},
	}
	down.Flags().BoolVar(&keepDeps, "keep-deps", false, "do not tear down Compose deps")
	cmd.AddCommand(up, down)
	return cmd
}

func newDeployCmd(g *globalFlags) *cobra.Command {
	return &cobra.Command{
		Use:   "deploy",
		Short: "Prepare + deploy against current kubecontext",
		RunE: func(cmd *cobra.Command, args []string) error {
			suite, err := requireSuite(g)
			if err != nil {
				return err
			}
			rep := report.New(suite.Metadata.Name)
			ctx, cancel := withSignalContext(cmd.Context())
			defer cancel()
			clients, err := kube.NewClients(kube.Options{Kubeconfig: g.kubeconfig, Context: g.context})
			if err != nil {
				return err
			}
			runner := &deploy.Runner{Suite: suite, Clients: clients, Report: rep, Timeout: g.timeout}
			if err := runner.Prepare(ctx); err != nil {
				_ = rep.WriteToStdout(g.output)
				return &exitError{report.ExitPipelineError, err}
			}
			if err := runner.Deploy(ctx); err != nil {
				_ = rep.WriteToStdout(g.output)
				return &exitError{report.ExitPipelineError, err}
			}
			return rep.WriteToStdout(g.output)
		},
	}
}

func newAssertCmd(g *globalFlags) *cobra.Command {
	return &cobra.Command{
		Use:   "assert",
		Short: "Run assert checks only",
		RunE: func(cmd *cobra.Command, args []string) error {
			suite, err := requireSuite(g)
			if err != nil {
				return err
			}
			rep := report.New(suite.Metadata.Name)
			ctx, cancel := withSignalContext(cmd.Context())
			defer cancel()
			clients, err := kube.NewClients(kube.Options{Kubeconfig: g.kubeconfig, Context: g.context})
			if err != nil {
				return err
			}
			runner := &assert.Runner{Suite: suite, Clients: clients, Report: rep, Timeout: g.timeout, FailFast: g.failFast}
			assertErr := runner.Run(ctx)
			_ = rep.WriteToStdout(g.output)
			if assertErr != nil {
				return &exitError{report.ExitAssertFailed, assertErr}
			}
			return nil
		},
	}
}
