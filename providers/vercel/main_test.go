package main

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

const fakeToken = "fake-vercel-token-for-tests-only-not-a-real-secret"

func TestProbeAvailable(t *testing.T) {
	dir := t.TempDir()
	tokenPath := filepath.Join(dir, "token")
	writeFile(t, tokenPath, fakeToken+"\n")

	out, stderr, code := runProvider(t, map[string]interface{}{
		"capability": "vercel.diagnostics",
		"operation":  "probe",
		"config": map[string]interface{}{
			"tokenFile": tokenPath,
			"tokenEnv":  "VERCEL_TOKEN",
		},
	})
	if code != 0 {
		t.Fatalf("exit %d stderr=%q", code, stderr)
	}
	assertNoSecretLeak(t, stderr, out)
	var resp map[string]interface{}
	mustJSON(t, out, &resp)
	if resp["status"] != "available" {
		t.Fatalf("status=%v want available", resp["status"])
	}
}

func TestProbeMissingTokenFile(t *testing.T) {
	out, stderr, code := runProvider(t, map[string]interface{}{
		"capability": "vercel.diagnostics",
		"operation":  "probe",
		"config": map[string]interface{}{
			"tokenFile": filepath.Join(t.TempDir(), "missing"),
			"tokenEnv":  "VERCEL_TOKEN",
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
	if strings.Contains(msg, fakeToken) {
		t.Fatalf("message leaked token material")
	}
}

func TestProbeEmptyTokenFile(t *testing.T) {
	dir := t.TempDir()
	tokenPath := filepath.Join(dir, "token")
	writeFile(t, tokenPath, "   \n")

	out, stderr, code := runProvider(t, map[string]interface{}{
		"capability": "vercel.diagnostics",
		"operation":  "probe",
		"config": map[string]interface{}{
			"tokenFile": tokenPath,
			"tokenEnv":  "VERCEL_TOKEN",
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
}

func TestResolveValid(t *testing.T) {
	dir := t.TempDir()
	tokenPath := filepath.Join(dir, "token")
	writeFile(t, tokenPath, fakeToken)

	out, stderr, code := runProvider(t, map[string]interface{}{
		"capability": "vercel.diagnostics",
		"operation":  "resolve",
		"config": map[string]interface{}{
			"tokenFile": tokenPath,
			"tokenEnv":  "VERCEL_TOKEN",
		},
	})
	if code != 0 {
		t.Fatalf("exit %d stderr=%q", code, stderr)
	}
	if strings.Contains(stderr, fakeToken) {
		t.Fatalf("stderr leaked token")
	}
	var resp struct {
		Env       map[string]string `json:"env"`
		ExpiresAt string            `json:"expiresAt"`
	}
	mustJSON(t, out, &resp)
	if resp.Env["VERCEL_TOKEN"] != fakeToken {
		t.Fatalf("VERCEL_TOKEN=%q", resp.Env["VERCEL_TOKEN"])
	}
	if resp.ExpiresAt != "" {
		t.Fatalf("expiresAt should be omitted, got %q", resp.ExpiresAt)
	}
}

func TestResolveCustomTokenEnv(t *testing.T) {
	dir := t.TempDir()
	tokenPath := filepath.Join(dir, "token")
	writeFile(t, tokenPath, fakeToken)

	out, stderr, code := runProvider(t, map[string]interface{}{
		"capability": "vercel.diagnostics",
		"operation":  "resolve",
		"config": map[string]interface{}{
			"tokenFile": tokenPath,
			"tokenEnv":  "CUSTOM_VERCEL_TOKEN",
		},
	})
	if code != 0 {
		t.Fatalf("exit %d stderr=%q", code, stderr)
	}
	assertNoSecretLeak(t, stderr)
	var resp struct {
		Env map[string]string `json:"env"`
	}
	mustJSON(t, out, &resp)
	if resp.Env["CUSTOM_VERCEL_TOKEN"] != fakeToken {
		t.Fatalf("env=%v", resp.Env)
	}
	if _, ok := resp.Env["VERCEL_TOKEN"]; ok {
		t.Fatalf("unexpected VERCEL_TOKEN key")
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
		"capability": "vercel.diagnostics",
		"operation":  "mint",
		"config": map[string]interface{}{
			"tokenFile": "/tmp/x",
			"tokenEnv":  "VERCEL_TOKEN",
		},
	})
	if code == 0 {
		t.Fatal("expected non-zero exit")
	}
	if !strings.Contains(stderr, "unsupported operation") {
		t.Fatalf("stderr=%q", stderr)
	}
	assertNoSecretLeak(t, stderr)
}

func TestResolveMissingFileFails(t *testing.T) {
	_, stderr, code := runProvider(t, map[string]interface{}{
		"capability": "vercel.diagnostics",
		"operation":  "resolve",
		"config": map[string]interface{}{
			"tokenFile": filepath.Join(t.TempDir(), "missing"),
			"tokenEnv":  "VERCEL_TOKEN",
		},
	})
	if code == 0 {
		t.Fatal("expected non-zero exit")
	}
	if strings.Contains(stderr, fakeToken) {
		t.Fatalf("stderr leaked token")
	}
	if !strings.Contains(stderr, "token file not found") {
		t.Fatalf("stderr=%q", stderr)
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
	bin := filepath.Join(t.TempDir(), "pade-provider-vercel")
	cmd := exec.Command("go", "build", "-o", bin, ".")
	cmd.Dir = "."
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("go build: %v\n%s", err, out)
	}
	return bin
}

func writeFile(t *testing.T, path, contents string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
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
