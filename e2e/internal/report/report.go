package report

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
	"time"
)

const (
	ExitOK            = 0
	ExitAssertFailed  = 1
	ExitPipelineError = 2
	ExitUsageError    = 3
)

// Result is a single named step/check outcome.
type Result struct {
	Name     string        `json:"name"`
	Phase    string        `json:"phase"`
	Status   string        `json:"status"` // passed, failed, skipped
	Message  string        `json:"message,omitempty"`
	Duration time.Duration `json:"duration"`
	Error    string        `json:"error,omitempty"`
}

// Report aggregates pipeline results.
type Report struct {
	Suite     string    `json:"suite"`
	StartedAt time.Time `json:"startedAt"`
	EndedAt   time.Time `json:"endedAt"`
	Results   []Result  `json:"results"`
	Passed    int       `json:"passed"`
	Failed    int       `json:"failed"`
	Skipped   int       `json:"skipped"`
}

// New creates an empty report.
func New(suite string) *Report {
	return &Report{
		Suite:     suite,
		StartedAt: time.Now().UTC(),
		Results:   []Result{},
	}
}

// Add appends a result and updates counters.
func (r *Report) Add(res Result) {
	r.Results = append(r.Results, res)
	switch res.Status {
	case "passed":
		r.Passed++
	case "failed":
		r.Failed++
	case "skipped":
		r.Skipped++
	}
}

// Finish sets the end timestamp.
func (r *Report) Finish() {
	r.EndedAt = time.Now().UTC()
}

// ExitCode returns the process exit code for this report.
func (r *Report) ExitCode() int {
	if r.Failed > 0 {
		return ExitAssertFailed
	}
	return ExitOK
}

// Write emits the report in the requested format.
func (r *Report) Write(w io.Writer, format string) error {
	r.Finish()
	switch strings.ToLower(format) {
	case "json":
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		return enc.Encode(r)
	case "text", "":
		return r.writeText(w)
	default:
		return fmt.Errorf("unknown output format %q", format)
	}
}

func (r *Report) writeText(w io.Writer) error {
	fmt.Fprintf(w, "Suite: %s\n", r.Suite)
	fmt.Fprintf(w, "Started: %s\n", r.StartedAt.Format(time.RFC3339))
	fmt.Fprintf(w, "Ended:   %s\n", r.EndedAt.Format(time.RFC3339))
	fmt.Fprintln(w, strings.Repeat("-", 60))
	for _, res := range r.Results {
		icon := "·"
		switch res.Status {
		case "passed":
			icon = "✓"
		case "failed":
			icon = "✗"
		case "skipped":
			icon = "–"
		}
		line := fmt.Sprintf("%s [%s] %s (%s)", icon, res.Phase, res.Name, res.Duration.Round(time.Millisecond))
		if res.Message != "" {
			line += " — " + res.Message
		}
		fmt.Fprintln(w, line)
		if res.Error != "" {
			fmt.Fprintf(w, "    error: %s\n", res.Error)
		}
	}
	fmt.Fprintln(w, strings.Repeat("-", 60))
	fmt.Fprintf(w, "passed=%d failed=%d skipped=%d\n", r.Passed, r.Failed, r.Skipped)
	return nil
}

// WriteToStdout is a convenience for CLI commands.
func (r *Report) WriteToStdout(format string) error {
	return r.Write(os.Stdout, format)
}

// Pass helper.
func Pass(phase, name, msg string, d time.Duration) Result {
	return Result{Name: name, Phase: phase, Status: "passed", Message: msg, Duration: d}
}

// Fail helper.
func Fail(phase, name, msg string, d time.Duration, err error) Result {
	res := Result{Name: name, Phase: phase, Status: "failed", Message: msg, Duration: d}
	if err != nil {
		res.Error = err.Error()
	}
	return res
}

// Skip helper.
func Skip(phase, name, msg string) Result {
	return Result{Name: name, Phase: phase, Status: "skipped", Message: msg}
}
