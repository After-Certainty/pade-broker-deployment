package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

const (
	fakeCallerToken  = "eyJhbGciOiJub25lIn0.fake-caller-broker-token-not-a-secret.x"
	fakeRuntimeToken = "eyJhbGciOiJub25lIn0.fake-runtime-metadata-token-not-a-secret.x"
	fakeAccessKey    = "ASIAFAKEACCESSKEYID000"
	fakeSecretKey    = "fakeSecretAccessKeyValueForTestsOnly000"
	fakeSessionTok   = "fakeSessionTokenValueForTestsOnly000000"
	fakeRoleARN      = "arn:aws:iam::111122223333:role/pade-broker-experiment-007-s3-write"
	fakeAudience     = "https://ci.example.invalid/pade-aws-s3"
)

func testConfig() map[string]interface{} {
	return map[string]interface{}{
		"roleArn":  fakeRoleARN,
		"region":   "us-east-1",
		"bucket":   "ci-fixture-007",
		"prefix":   "experiment-007/",
		"audience": fakeAudience,
	}
}

func googleIdentity() map[string]interface{} {
	return map[string]interface{}{
		"issuer":      "https://accounts.google.com",
		"issuerAlias": "google",
		"subject":     "123456789012345678901",
		"idToken":     fakeCallerToken,
	}
}

type fakeEnv struct {
	stsToken      atomic.Value // string
	metadataCalls atomic.Int32
}

func installFakes(t *testing.T) *fakeEnv {
	t.Helper()
	env := &fakeEnv{}
	env.stsToken.Store("")

	meta := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		env.metadataCalls.Add(1)
		if r.Header.Get("Metadata-Flavor") != "Google" {
			http.Error(w, "missing Metadata-Flavor", http.StatusForbidden)
			return
		}
		if r.URL.Query().Get("audience") != fakeAudience {
			http.Error(w, "wrong audience", http.StatusBadRequest)
			return
		}
		_, _ = io.WriteString(w, fakeRuntimeToken)
	}))
	t.Cleanup(meta.Close)

	sts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		if r.Form.Get("DurationSeconds") != "900" || r.Form.Get("Policy") != "" || r.Form.Get("PolicyArns") != "" {
			t.Error("unexpected STS duration or session policy; scope is owned by role IAM")
		}
		tok := r.Form.Get("WebIdentityToken")
		env.stsToken.Store(tok)
		if tok == fakeCallerToken {
			w.WriteHeader(http.StatusForbidden)
			_, _ = io.WriteString(w, errorXML("AccessDenied"))
			return
		}
		if tok != fakeRuntimeToken {
			w.WriteHeader(http.StatusForbidden)
			_, _ = io.WriteString(w, errorXML("AccessDenied"))
			return
		}
		if r.Form.Get("RoleArn") != fakeRoleARN {
			w.WriteHeader(http.StatusBadRequest)
			_, _ = io.WriteString(w, errorXML("ValidationError"))
			return
		}
		_, _ = io.WriteString(w, fmt.Sprintf(`<?xml version="1.0"?>
<AssumeRoleWithWebIdentityResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/">
  <AssumeRoleWithWebIdentityResult>
    <Credentials>
      <AccessKeyId>%s</AccessKeyId>
      <SecretAccessKey>%s</SecretAccessKey>
      <SessionToken>%s</SessionToken>
      <Expiration>2099-01-01T00:00:00Z</Expiration>
    </Credentials>
  </AssumeRoleWithWebIdentityResult>
</AssumeRoleWithWebIdentityResponse>`, fakeAccessKey, fakeSecretKey, fakeSessionTok))
	}))
	t.Cleanup(sts.Close)

	prevMeta, prevSTS, prevClient := metadataURL, stsURLFmt, httpClient
	metadataURL = meta.URL
	// fmt.Sprintf(stsURLFmt, region) must hit the fake STS server regardless of region.
	stsURLFmt = sts.URL + "?ignored=%s"
	httpClient = &http.Client{Timeout: prevClient.Timeout}
	t.Cleanup(func() {
		metadataURL = prevMeta
		stsURLFmt = prevSTS
		httpClient = prevClient
	})
	return env
}

func errorXML(code string) string {
	return fmt.Sprintf(`<ErrorResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/"><Error><Code>%s</Code><Message>safe</Message></Error></ErrorResponse>`, code)
}

func TestValidateCallerIdentity(t *testing.T) {
	if err := validateCallerIdentity(nil); err == nil {
		t.Fatal("expected error for missing identity")
	}
	if err := validateCallerIdentity(&identity{IssuerAlias: "cursor"}); err == nil {
		t.Fatal("expected error for cursor alias")
	}
	if err := validateCallerIdentity(&identity{
		IssuerAlias: "google",
		Issuer:      "https://evil.example",
	}); err == nil {
		t.Fatal("expected error for wrong issuer")
	}
	if err := validateCallerIdentity(&identity{IssuerAlias: "google"}); err != nil {
		t.Fatalf("google alias alone should pass: %v", err)
	}
	if err := validateCallerIdentity(&identity{
		IssuerAlias: "google",
		Issuer:      requiredIssuer,
		IDToken:     fakeCallerToken,
	}); err != nil {
		t.Fatalf("full google identity should pass: %v", err)
	}
}

func TestResolveUsesMetadataTokenNotCallerIDToken(t *testing.T) {
	env := installFakes(t)
	cfg, err := configFromMap(testConfig())
	if err != nil {
		t.Fatal(err)
	}
	id := &identity{
		Issuer:      requiredIssuer,
		IssuerAlias: requiredIssuerAlias,
		Subject:     "123456789012345678901",
		IDToken:     fakeCallerToken,
	}
	out, expires, err := resolve(cfg, id)
	if err != nil {
		t.Fatalf("resolve: %v", err)
	}
	gotTok, _ := env.stsToken.Load().(string)
	if gotTok != fakeRuntimeToken {
		t.Fatal("STS did not receive the runtime metadata token")
	}
	if gotTok == fakeCallerToken {
		t.Fatal("STS must not receive caller identity.idToken")
	}
	for _, k := range []string{
		"AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN",
		"AWS_REGION", "AWS_S3_BUCKET", "AWS_S3_PREFIX",
	} {
		if out[k] == "" {
			t.Fatalf("missing Material env %s", k)
		}
	}
	if out["AWS_ACCESS_KEY_ID"] != fakeAccessKey {
		t.Fatalf("unexpected access key id")
	}
	if out["AWS_S3_BUCKET"] != "ci-fixture-007" || out["AWS_S3_PREFIX"] != "experiment-007/" {
		t.Fatal("unexpected bucket/prefix binding")
	}
	if out["AWS_REGION"] != "us-east-1" {
		t.Fatalf("unexpected region %q", out["AWS_REGION"])
	}
	if expires != "2099-01-01T00:00:00Z" {
		t.Fatalf("unexpected expiresAt %q", expires)
	}
}

func TestResolveRejectsMissingIdentity(t *testing.T) {
	_ = installFakes(t)
	cfg, err := configFromMap(testConfig())
	if err != nil {
		t.Fatal(err)
	}
	_, _, err = resolve(cfg, nil)
	if err == nil {
		t.Fatal("expected missing identity error")
	}
	if !strings.Contains(err.Error(), "identity") {
		t.Fatalf("error should mention identity: %v", err)
	}
}

func TestResolveRejectsNonGoogleAlias(t *testing.T) {
	_ = installFakes(t)
	cfg, err := configFromMap(testConfig())
	if err != nil {
		t.Fatal(err)
	}
	_, _, err = resolve(cfg, &identity{IssuerAlias: "cursor", IDToken: fakeCallerToken})
	if err == nil {
		t.Fatal("expected non-google rejection")
	}
	if strings.Contains(err.Error(), fakeCallerToken) {
		t.Fatal("error must not include caller token")
	}
}

func TestRoleNameFromARN(t *testing.T) {
	if got := roleNameFromARN(fakeRoleARN); got != "pade-broker-experiment-007-s3-write" {
		t.Fatalf("got %q", got)
	}
}

func TestProviderBinaryIntegration(t *testing.T) {
	env := installFakes(t)
	bin := buildProvider(t)

	// Happy path via subprocess — override endpoints through env is not available;
	// package vars only apply in-process. So subprocess tests cover fail-closed paths
	// that do not need network, plus we keep in-process resolve coverage above.
	_ = env

	cases := []struct {
		name string
		req  map[string]interface{}
		want int
		err  string
	}{
		{
			name: "missing identity",
			req: map[string]interface{}{
				"capability": capabilityAWSBucketWrite,
				"operation":  "resolve",
				"config":     testConfig(),
			},
			want: 1,
			err:  "identity",
		},
		{
			name: "cursor identity",
			req: map[string]interface{}{
				"capability": capabilityAWSBucketWrite,
				"operation":  "resolve",
				"config":     testConfig(),
				"identity": map[string]interface{}{
					"issuerAlias": "cursor",
					"idToken":     fakeCallerToken,
				},
			},
			want: 1,
			err:  "issuerAlias",
		},
		{
			name: "wrong capability",
			req: map[string]interface{}{
				"capability": "vercel.diagnostics",
				"operation":  "probe",
				"config":     testConfig(),
				"identity":   googleIdentity(),
			},
			want: 1,
			err:  "unsupported capability",
		},
		{
			name: "missing roleArn",
			req: map[string]interface{}{
				"capability": capabilityAWSBucketWrite,
				"operation":  "probe",
				"config": map[string]interface{}{
					"region":   "us-east-1",
					"bucket":   "ci-fixture-007",
					"prefix":   "experiment-007/",
					"audience": fakeAudience,
				},
				"identity": googleIdentity(),
			},
			want: 1,
			err:  "roleArn",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			stdout, stderr, code := runProvider(t, bin, tc.req)
			if code != tc.want {
				t.Fatalf("exit %d stderr=%q stdout=%q", code, stderr, stdout)
			}
			if !strings.Contains(stderr, tc.err) {
				t.Fatalf("stderr %q want substring %q", stderr, tc.err)
			}
			assertNoSecrets(t, stdout+stderr)
		})
	}
}

func TestProbeAvailableInProcess(t *testing.T) {
	cfg, err := configFromMap(testConfig())
	if err != nil {
		t.Fatal(err)
	}
	status, msg := probe(cfg, &identity{IssuerAlias: "google"})
	if status != "available" {
		t.Fatalf("status=%s msg=%s", status, msg)
	}
	status, msg = probe(cfg, nil)
	if status != "unavailable" {
		t.Fatalf("expected unavailable, got %s (%s)", status, msg)
	}
}

func buildProvider(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	bin := filepath.Join(dir, "pade-provider-aws-s3")
	cmd := exec.Command("go", "build", "-o", bin, ".")
	cmd.Dir = "."
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("go build: %v\n%s", err, out)
	}
	return bin
}

func runProvider(t *testing.T, bin string, req map[string]interface{}) (stdout, stderr string, code int) {
	t.Helper()
	payload, err := json.Marshal(req)
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(bin)
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
			t.Fatalf("run: %v", err)
		}
	}
	return outBuf.String(), errBuf.String(), code
}

func assertNoSecrets(t *testing.T, s string) {
	t.Helper()
	for _, secret := range []string{
		fakeCallerToken, fakeRuntimeToken, fakeAccessKey, fakeSecretKey, fakeSessionTok,
	} {
		if strings.Contains(s, secret) {
			t.Fatalf("output leaked secret material")
		}
	}
}

func TestMain(m *testing.M) {
	os.Exit(m.Run())
}

// Both callers have already passed broker authorization. This provider does
// not independently apply a subject allowlist or create per-subject IAM scope.
func TestDistinctAuthorizedCallersUseSameRuntimeAuthority(t *testing.T) {
	fake := installFakes(t)
	cfg, err := configFromMap(testConfig())
	if err != nil {
		t.Fatal(err)
	}
	for _, subject := range []string{"synthetic-subject-a", "synthetic-subject-b"} {
		// No raw caller assertion is needed by this provider.
		out, expiry, err := resolve(cfg, &identity{Issuer: requiredIssuer, IssuerAlias: requiredIssuerAlias, Subject: subject})
		if err != nil {
			t.Fatal("verified attributes without raw JWT must suffice")
		}
		token, _ := fake.stsToken.Load().(string)
		if token != fakeRuntimeToken {
			t.Fatal("caller changed the downstream federation identity")
		}
		if out["AWS_S3_BUCKET"] != cfg.Bucket || out["AWS_S3_PREFIX"] != cfg.Prefix || expiry == "" {
			t.Fatal("operator scope or lifetime metadata lost")
		}
	}
}

func TestDeniedCallerDoesNotContactMetadataOrSTS(t *testing.T) {
	fake := installFakes(t)
	cfg, err := configFromMap(testConfig())
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []*identity{nil, {IssuerAlias: "cursor"}, {IssuerAlias: "google", Issuer: "https://untrusted.example.invalid"}} {
		if _, _, err := resolve(cfg, id); err == nil {
			t.Fatal("unsupported caller accepted")
		}
	}
	if token, _ := fake.stsToken.Load().(string); token != "" {
		t.Fatal("denied caller reached STS")
	}
	if fake.metadataCalls.Load() != 0 {
		t.Fatal("denied caller reached metadata")
	}
}
