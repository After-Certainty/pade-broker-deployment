package main

import (
	"bytes"
	"encoding/json"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

const fakeToken = "fake-sanity-token-for-tests-only-not-a-real-secret"

func wifConfig() map[string]interface{} {
	return map[string]interface{}{
		"fulfillment":    fulfillmentSubjectSecretWIF,
		"tokenEnv":       "SANITY_API_TOKEN",
		"projectNumber":  "123456789012",
		"poolId":         "pade-broker-cursor",
		"providerId":     "cursor",
		"secretIdPrefix": "sanity-token-sub",
	}
}

func TestMalformedRequest(t *testing.T) {
	cmd := exec.Command(testBinary(t))
	cmd.Stdin = strings.NewReader("{not-json")
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	if err == nil {
		t.Fatal("expected non-zero exit")
	}
	if strings.Contains(stderr.String(), fakeToken) {
		t.Fatalf("stderr leaked token")
	}
	if !strings.Contains(stderr.String(), "invalid request JSON") {
		t.Fatalf("stderr=%q", stderr.String())
	}
}

func TestUnsupportedOperation(t *testing.T) {
	_, stderr, code := runProvider(t, map[string]interface{}{
		"capability": "sanity.rehearsal.write",
		"operation":  "mint",
		"config":     wifConfig(),
	})
	if code == 0 {
		t.Fatal("expected non-zero exit")
	}
	if !strings.Contains(stderr, "unsupported operation") {
		t.Fatalf("stderr=%q", stderr)
	}
	assertNoSecretLeak(t, stderr)
}

func TestProbeMissingWIFConfig(t *testing.T) {
	out, stderr, code := runProvider(t, map[string]interface{}{
		"capability": "sanity.rehearsal.write",
		"operation":  "probe",
		"config": map[string]interface{}{
			"fulfillment": fulfillmentSubjectSecretWIF,
			"tokenEnv":    "SANITY_API_TOKEN",
		},
	})
	if code != 0 {
		t.Fatalf("exit %d stderr=%q", code, stderr)
	}
	assertNoSecretLeak(t, stderr, out)
	var resp map[string]interface{}
	mustJSON(t, out, &resp)
	if resp["status"] != "unavailable" {
		t.Fatalf("status=%v want unavailable", resp["status"])
	}
	msg, _ := resp["message"].(string)
	if !strings.Contains(msg, "projectNumber") {
		t.Fatalf("message=%q", msg)
	}
	meta, _ := resp["meta"].(map[string]interface{})
	if strings.Contains(fmtAny(meta), fakeToken) {
		t.Fatalf("meta leaked token: %v", meta)
	}
}

func TestProbeWithoutIdentityUnavailable(t *testing.T) {
	out, stderr, code := runProvider(t, map[string]interface{}{
		"capability": "sanity.rehearsal.write",
		"operation":  "probe",
		"config":     wifConfig(),
	})
	if code != 0 {
		t.Fatalf("exit %d stderr=%q", code, stderr)
	}
	assertNoSecretLeak(t, stderr, out)
	var resp map[string]interface{}
	mustJSON(t, out, &resp)
	if resp["status"] != "unavailable" {
		t.Fatalf("status=%v want unavailable", resp["status"])
	}
	msg, _ := resp["message"].(string)
	if !strings.Contains(msg, "identity.idToken") {
		t.Fatalf("message=%q", msg)
	}
	meta, _ := resp["meta"].(map[string]interface{})
	if meta["mode"] != fulfillmentSubjectSecretWIF {
		t.Fatalf("meta=%v", meta)
	}
	if strings.Contains(fmtAny(meta), fakeToken) {
		t.Fatalf("meta leaked token: %v", meta)
	}
}

func TestResolveWithoutIdentityFailsClosed(t *testing.T) {
	_, stderr, code := runProvider(t, map[string]interface{}{
		"capability": "sanity.rehearsal.write",
		"operation":  "resolve",
		"config":     wifConfig(),
	})
	if code == 0 {
		t.Fatal("expected non-zero exit")
	}
	if !strings.Contains(stderr, "identity.idToken") {
		t.Fatalf("stderr=%q", stderr)
	}
	assertNoSecretLeak(t, stderr)
}

func TestUnsupportedFulfillment(t *testing.T) {
	out, stderr, code := runProvider(t, map[string]interface{}{
		"capability": "sanity.rehearsal.write",
		"operation":  "probe",
		"config": map[string]interface{}{
			"fulfillment": "static-token-file",
			"tokenEnv":    "SANITY_API_TOKEN",
		},
	})
	if code != 0 {
		t.Fatalf("exit %d stderr=%q", code, stderr)
	}
	var resp map[string]interface{}
	mustJSON(t, out, &resp)
	if resp["status"] != "unavailable" {
		t.Fatalf("status=%v want unavailable", resp["status"])
	}
	msg, _ := resp["message"].(string)
	if !strings.Contains(msg, "unsupported fulfillment") {
		t.Fatalf("message=%q", msg)
	}
}

func runProvider(t *testing.T, req map[string]interface{}) (stdout, stderr string, code int) {
	t.Helper()
	payload, err := json.Marshal(req)
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(testBinary(t))
	cmd.Stdin = bytes.NewReader(payload)
	var outBuf, errBuf bytes.Buffer
	cmd.Stdout = &outBuf
	cmd.Stderr = &errBuf
	err = cmd.Run()
	code = 0
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		} else {
			t.Fatal(err)
		}
	}
	return outBuf.String(), errBuf.String(), code
}

func testBinary(t *testing.T) string {
	t.Helper()
	bin := filepath.Join(t.TempDir(), "pade-provider-sanity")
	cmd := exec.Command("go", "build", "-o", bin, ".")
	cmd.Dir = "."
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("go build: %v\n%s", err, out)
	}
	return bin
}

func mustJSON(t *testing.T, raw string, dest interface{}) {
	t.Helper()
	if err := json.Unmarshal([]byte(raw), dest); err != nil {
		t.Fatalf("json: %v raw=%q", err, raw)
	}
}

func assertNoSecretLeak(t *testing.T, parts ...string) {
	t.Helper()
	for _, p := range parts {
		if strings.Contains(p, fakeToken) {
			t.Fatalf("output leaked fake token: %q", p)
		}
	}
}

func fmtAny(v interface{}) string {
	b, err := json.Marshal(v)
	if err != nil {
		return ""
	}
	return string(b)
}
