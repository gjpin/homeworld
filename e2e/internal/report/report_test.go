package report

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestReportAggregation(t *testing.T) {
	r := New("demo")
	r.Add(Pass("assert", "a", "ok", time.Millisecond))
	r.Add(Fail("assert", "b", "nope", time.Millisecond, nil))
	r.Add(Skip("deploy", "c", "n/a"))
	if r.Passed != 1 || r.Failed != 1 || r.Skipped != 1 {
		t.Fatalf("counters: %+v", r)
	}
	if r.ExitCode() != ExitAssertFailed {
		t.Fatalf("exit=%d", r.ExitCode())
	}
}

func TestReportJSON(t *testing.T) {
	r := New("demo")
	r.Add(Pass("assert", "a", "ok", time.Second))
	var buf bytes.Buffer
	if err := r.Write(&buf, "json"); err != nil {
		t.Fatal(err)
	}
	var decoded Report
	if err := json.Unmarshal(buf.Bytes(), &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.Suite != "demo" || decoded.Passed != 1 {
		t.Fatalf("decoded=%+v", decoded)
	}
}

func TestReportText(t *testing.T) {
	r := New("demo")
	r.Add(Pass("assert", "pods", "ok", time.Millisecond))
	var buf bytes.Buffer
	if err := r.Write(&buf, "text"); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(buf.String(), "pods") {
		t.Fatalf("missing pods in %s", buf.String())
	}
}
