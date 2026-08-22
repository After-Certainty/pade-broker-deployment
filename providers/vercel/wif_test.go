package main

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestSecretIDForSubjectStable(t *testing.T) {
	a := secretIDForSubject("vercel-token-sub", "user:alice")
	b := secretIDForSubject("vercel-token-sub", "user:alice")
	c := secretIDForSubject("vercel-token-sub", "user:bob")
	if a != b {
		t.Fatalf("unstable secret id: %q vs %q", a, b)
	}
	if a == c {
		t.Fatalf("different subjects must not collide: %q", a)
	}
	if !strings.HasPrefix(a, "vercel-token-sub-") {
		t.Fatalf("prefix missing: %q", a)
	}
	if len(a) != len("vercel-token-sub-")+16 {
		t.Fatalf("unexpected length: %q", a)
	}
}

func TestSubjectFromIDToken(t *testing.T) {
	tok := fakeJWT(t, map[string]string{"sub": "user:alice"})
	sub, err := subjectFromIDToken(tok)
	if err != nil {
		t.Fatal(err)
	}
	if sub != "user:alice" {
		t.Fatalf("sub=%q", sub)
	}
}

func TestProbeWIFMissingIdentity(t *testing.T) {
	out, stderr, code := runProvider(t, map[string]interface{}{
		"capability": "vercel.diagnostics",
		"operation":  "probe",
		"config": map[string]interface{}{
			"fulfillment":   fulfillmentSubjectSecretWIF,
			"tokenEnv":      "VERCEL_TOKEN",
			"projectNumber": "123456789012",
			"poolId":        "pade-broker-cursor",
			"providerId":    "cursor",
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
	if !strings.Contains(msg, "identity.idToken") {
		t.Fatalf("message=%q", msg)
	}
	meta, _ := resp["meta"].(map[string]interface{})
	if meta["mode"] != fulfillmentSubjectSecretWIF {
		t.Fatalf("meta=%v", meta)
	}
}

func TestResolveWIFMissingIdentityFailsClosed(t *testing.T) {
	_, stderr, code := runProvider(t, map[string]interface{}{
		"capability": "vercel.diagnostics",
		"operation":  "resolve",
		"config": map[string]interface{}{
			"fulfillment":   fulfillmentSubjectSecretWIF,
			"tokenEnv":      "VERCEL_TOKEN",
			"projectNumber": "123456789012",
			"poolId":        "pade-broker-cursor",
			"providerId":    "cursor",
		},
	})
	if code == 0 {
		t.Fatal("expected non-zero exit")
	}
	if !strings.Contains(stderr, "identity.idToken") {
		t.Fatalf("stderr=%q", stderr)
	}
	assertNoSecretLeak(t, stderr)
}

func TestResolveSubjectSecretWIFHappyPath(t *testing.T) {
	const wantToken = "subject-bound-vercel-token-for-tests-only"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/sts/token" && r.Method == http.MethodPost:
			_ = r.ParseForm()
			if r.Form.Get("subject_token") == "" {
				t.Errorf("missing subject_token")
			}
			_ = json.NewEncoder(w).Encode(map[string]string{
				"access_token": "fake-sts-access-token",
				"token_type":   "Bearer",
			})
		case strings.HasPrefix(r.URL.Path, "/sm/") && r.Method == http.MethodGet:
			if ah := r.Header.Get("Authorization"); !strings.HasPrefix(ah, "Bearer ") {
				t.Errorf("missing bearer auth")
			}
			payload := base64.StdEncoding.EncodeToString([]byte(wantToken))
			_ = json.NewEncoder(w).Encode(map[string]interface{}{
				"payload": map[string]string{"data": payload},
			})
		default:
			t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	origClient := httpClient
	origSTS := stsTokenURL
	origSM := secretManagerAccessFmt
	httpClient = server.Client()
	stsTokenURL = server.URL + "/sts/token"
	secretManagerAccessFmt = server.URL + "/sm/projects/%s/secrets/%s/versions/latest:access"
	defer func() {
		httpClient = origClient
		stsTokenURL = origSTS
		secretManagerAccessFmt = origSM
	}()

	idToken := fakeJWT(t, map[string]string{"sub": "user:alice"})
	cfg := providerConfig{
		Fulfillment:    fulfillmentSubjectSecretWIF,
		TokenEnv:       "VERCEL_TOKEN",
		ProjectNumber:  "123456789012",
		PoolID:         "pade-broker-cursor",
		ProviderID:     "cursor",
		SecretIDPrefix: "vercel-token-sub",
	}
	token, err := resolveSubjectSecretWIF(cfg, &identity{IDToken: idToken})
	if err != nil {
		t.Fatal(err)
	}
	if token != wantToken {
		t.Fatalf("token=%q", token)
	}
}

func TestResolveWIFSubjectMismatch(t *testing.T) {
	idToken := fakeJWT(t, map[string]string{"sub": "user:alice"})
	cfg := providerConfig{
		Fulfillment:    fulfillmentSubjectSecretWIF,
		ProjectNumber:  "1",
		PoolID:         "pool",
		ProviderID:     "prov",
		SecretIDPrefix: "vercel-token-sub",
	}
	_, err := resolveSubjectSecretWIF(cfg, &identity{Subject: "user:bob", IDToken: idToken})
	if err == nil || !strings.Contains(err.Error(), "does not match") {
		t.Fatalf("err=%v", err)
	}
}

func fakeJWT(t *testing.T, claims map[string]string) string {
	t.Helper()
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"none","typ":"JWT"}`))
	payloadBytes, err := json.Marshal(claims)
	if err != nil {
		t.Fatal(err)
	}
	payload := base64.RawURLEncoding.EncodeToString(payloadBytes)
	return header + "." + payload + ".sig"
}
