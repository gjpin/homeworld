package deps

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"time"

	"github.com/gjpin/homeworld/e2e/internal/config"
)

// Manager brings Docker Compose projects up and down.
type Manager struct {
	Suite *config.Suite
}

// ComposeArgs builds the docker compose invocation for a project entry.
func ComposeArgs(suite *config.Suite, dc config.DockerCompose, action string, extra ...string) []string {
	args := []string{"compose", "-p", dc.ProjectName, "-f", suite.ResolvePath(dc.File)}
	if dc.EnvFile != "" {
		args = append(args, "--env-file", suite.ResolvePath(dc.EnvFile))
	}
	args = append(args, action)
	args = append(args, extra...)
	return args
}

// Up starts all compose projects and waits for health probes.
func (m *Manager) Up(ctx context.Context) error {
	if m.Suite.Spec.Deps == nil {
		return nil
	}
	for _, dc := range m.Suite.Spec.Deps.DockerCompose {
		args := ComposeArgs(m.Suite, dc, "up", "-d")
		if err := runDocker(ctx, args...); err != nil {
			return fmt.Errorf("compose up %s: %w", dc.Name, err)
		}
		for _, w := range dc.Wait {
			timeout, err := config.ParseDuration(w.Timeout, 5*time.Minute)
			if err != nil {
				return err
			}
			if err := waitURL(ctx, w.URL, timeout); err != nil {
				return fmt.Errorf("compose wait %s (%s): %w", dc.Name, w.URL, err)
			}
		}
	}
	return nil
}

// Down stops all compose projects (with volumes).
func (m *Manager) Down(ctx context.Context) error {
	if m.Suite.Spec.Deps == nil {
		return nil
	}
	var firstErr error
	// Tear down in reverse order.
	for i := len(m.Suite.Spec.Deps.DockerCompose) - 1; i >= 0; i-- {
		dc := m.Suite.Spec.Deps.DockerCompose[i]
		args := ComposeArgs(m.Suite, dc, "down", "-v", "--remove-orphans")
		if err := runDocker(ctx, args...); err != nil && firstErr == nil {
			firstErr = fmt.Errorf("compose down %s: %w", dc.Name, err)
		}
	}
	return firstErr
}

func waitURL(ctx context.Context, rawURL string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	client := &http.Client{Timeout: 5 * time.Second}
	var lastErr error
	for {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
		if err != nil {
			return err
		}
		resp, err := client.Do(req)
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode >= 200 && resp.StatusCode < 500 {
				// Infisical /api/status may return 200 when ready.
				if resp.StatusCode < 400 {
					return nil
				}
			}
			lastErr = fmt.Errorf("status %d", resp.StatusCode)
		} else {
			lastErr = err
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("timeout after %s: %v", timeout, lastErr)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(2 * time.Second):
		}
	}
}

func runDocker(ctx context.Context, args ...string) error {
	cmd := exec.CommandContext(ctx, "docker", args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}
