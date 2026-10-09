package kube

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/portforward"
	"k8s.io/client-go/tools/remotecommand"
	"k8s.io/client-go/transport/spdy"
)

// PortForward opens a local port-forward to a service and returns local port + stop func.
func PortForward(ctx context.Context, cfg *rest.Config, typed kubernetes.Interface, namespace, service string, remotePort int) (localPort int, stop func(), err error) {
	svc, err := typed.CoreV1().Services(namespace).Get(ctx, service, metav1.GetOptions{})
	if err != nil {
		return 0, nil, fmt.Errorf("get service %s/%s: %w", namespace, service, err)
	}
	if len(svc.Spec.Selector) == 0 {
		return 0, nil, fmt.Errorf("service %s/%s has no pod selector: port-forwarding would match every pod in the namespace", namespace, service)
	}
	pods, err := typed.CoreV1().Pods(namespace).List(ctx, metav1.ListOptions{
		LabelSelector: labelSelectorFromMap(svc.Spec.Selector),
	})
	if err != nil {
		return 0, nil, fmt.Errorf("list pods for service: %w", err)
	}
	var pod *corev1.Pod
	for i := range pods.Items {
		if podIsReady(pods.Items[i]) {
			pod = &pods.Items[i]
			break
		}
	}
	if pod == nil {
		return 0, nil, fmt.Errorf("no ready pods for service %s/%s", namespace, service)
	}

	// The suite passes the Service's port; a pod port-forward must dial the
	// port the Service actually routes to. Resolve the service port's
	// targetPort — a number or a container-port name — against the selected
	// pod, falling back to the service port number when the pod declares no
	// matching container port.
	podPort := remotePort
	for i := range svc.Spec.Ports {
		if int(svc.Spec.Ports[i].Port) != remotePort {
			continue
		}
		tp := svc.Spec.Ports[i].TargetPort
		switch {
		case tp.IntVal > 0:
			podPort = int(tp.IntVal)
		case tp.String() != "":
			for _, c := range pod.Spec.Containers {
				for _, p := range c.Ports {
					if p.Name == tp.String() {
						podPort = int(p.ContainerPort)
					}
				}
			}
		}
		break
	}

	transport, upgrader, err := spdy.RoundTripperFor(cfg)
	if err != nil {
		return 0, nil, err
	}
	path := fmt.Sprintf("/api/v1/namespaces/%s/pods/%s/portforward", namespace, pod.Name)
	hostURL, err := url.Parse(cfg.Host)
	if err != nil {
		return 0, nil, err
	}
	hostURL.Path = path

	readyCh := make(chan struct{})
	stopCh := make(chan struct{})
	out := &bytes.Buffer{}
	errOut := &bytes.Buffer{}

	dialer := spdy.NewDialer(upgrader, &http.Client{Transport: transport}, http.MethodPost, hostURL)
	fw, err := portforward.New(dialer, []string{fmt.Sprintf("0:%d", podPort)}, stopCh, readyCh, out, errOut)
	if err != nil {
		return 0, nil, err
	}
	errCh := make(chan error, 1)
	go func() {
		errCh <- fw.ForwardPorts()
	}()

	select {
	case <-readyCh:
	case err := <-errCh:
		return 0, nil, fmt.Errorf("port-forward failed: %w (%s)", err, errOut.String())
	case <-ctx.Done():
		close(stopCh)
		return 0, nil, ctx.Err()
	case <-time.After(30 * time.Second):
		close(stopCh)
		return 0, nil, fmt.Errorf("port-forward ready timeout: %s", errOut.String())
	}

	ports, err := fw.GetPorts()
	if err != nil || len(ports) == 0 {
		close(stopCh)
		return 0, nil, fmt.Errorf("get forwarded ports: %w", err)
	}
	stop = func() { close(stopCh) }
	return int(ports[0].Local), stop, nil
}

func labelSelectorFromMap(m map[string]string) string {
	if len(m) == 0 {
		return ""
	}
	buf := &bytes.Buffer{}
	first := true
	for k, v := range m {
		if !first {
			buf.WriteByte(',')
		}
		first = false
		fmt.Fprintf(buf, "%s=%s", k, v)
	}
	return buf.String()
}

// podIsReady reports whether the pod is Running with a True Ready condition;
// a freshly started pod that has not passed readiness yet cannot serve the
// forwarded traffic.
func podIsReady(p corev1.Pod) bool {
	if p.Status.Phase != corev1.PodRunning {
		return false
	}
	for _, c := range p.Status.Conditions {
		if c.Type == corev1.PodReady && c.Status == corev1.ConditionTrue {
			return true
		}
	}
	return false
}

// ExecInPod runs a command in a pod and returns combined stdout/stderr.
func ExecInPod(ctx context.Context, cfg *rest.Config, typed kubernetes.Interface, namespace, pod, container string, command []string) (string, error) {
	req := typed.CoreV1().RESTClient().Post().
		Resource("pods").
		Name(pod).
		Namespace(namespace).
		SubResource("exec").
		VersionedParams(&corev1.PodExecOptions{
			Container: container,
			Command:   command,
			Stdout:    true,
			Stderr:    true,
		}, scheme.ParameterCodec)

	exec, err := remotecommand.NewSPDYExecutor(cfg, http.MethodPost, req.URL())
	if err != nil {
		return "", err
	}
	var stdout, stderr bytes.Buffer
	err = exec.StreamWithContext(ctx, remotecommand.StreamOptions{
		Stdout: &stdout,
		Stderr: &stderr,
	})
	out := stdout.String() + stderr.String()
	if err != nil {
		return out, fmt.Errorf("exec failed: %w: %s", err, out)
	}
	return out, nil
}

// HTTPGet performs an HTTP GET with timeout.
func HTTPGet(ctx context.Context, rawURL string, timeout time.Duration) (int, []byte, error) {
	return HTTPGetWithBasicAuth(ctx, rawURL, timeout, ProbeOptions{})
}

// ProbeOptions carries the HTTP options a serviceProbe can set.
type ProbeOptions struct {
	// Username/Password add HTTP basic auth to the probe request.
	Username, Password string
	// Host overrides the request's Host header: the port-forward bypasses
	// the Service, so virtual-host-validated endpoints need the public name.
	Host string
	// Headers adds arbitrary request headers (Authelia, for example,
	// derives its endpoint URLs from X-Forwarded-Proto).
	Headers map[string]string
}

// HTTPGetWithBasicAuth performs an HTTP GET with timeout and the given
// probe options.
func HTTPGetWithBasicAuth(ctx context.Context, rawURL string, timeout time.Duration, opts ProbeOptions) (int, []byte, error) {
	client := &http.Client{Timeout: timeout}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return 0, nil, err
	}
	if opts.Username != "" {
		req.SetBasicAuth(opts.Username, opts.Password)
	}
	if opts.Host != "" {
		req.Host = opts.Host
	}
	for k, v := range opts.Headers {
		req.Header.Set(k, v)
	}
	resp, err := client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return resp.StatusCode, nil, err
	}
	return resp.StatusCode, body, nil
}
