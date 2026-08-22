package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// httpClient is overridable in unit tests (httptest).
var httpClient = &http.Client{Timeout: 20 * time.Second}

// Overridable endpoints for unit tests.
var (
	stsTokenURL           = "https://sts.googleapis.com/v1/token"
	secretManagerAccessFmt = "https://secretmanager.googleapis.com/v1/projects/%s/secrets/%s/versions/latest:access"
)

func validateWIFConfig(cfg providerConfig) error {
	if cfg.ProjectNumber == "" {
		return fmt.Errorf("projectNumber not configured")
	}
	if cfg.PoolID == "" {
		return fmt.Errorf("poolId not configured")
	}
	if cfg.ProviderID == "" {
		return fmt.Errorf("providerId not configured")
	}
	if cfg.SecretIDPrefix == "" {
		return fmt.Errorf("secretIdPrefix not configured")
	}
	return nil
}

func resolveSubjectSecretWIF(cfg providerConfig, id *identity) (string, error) {
	if err := validateWIFConfig(cfg); err != nil {
		return "", err
	}
	if id == nil || strings.TrimSpace(id.IDToken) == "" {
		return "", fmt.Errorf("broker-verified identity.idToken not provided (PADE identity context required for subject-secret-wif)")
	}
	subject := strings.TrimSpace(id.Subject)
	if subject == "" {
		var err error
		subject, err = subjectFromIDToken(id.IDToken)
		if err != nil {
			return "", err
		}
	} else {
		tokenSub, err := subjectFromIDToken(id.IDToken)
		if err != nil {
			return "", err
		}
		if tokenSub != subject {
			return "", fmt.Errorf("identity.subject does not match idToken sub claim")
		}
	}

	accessToken, err := exchangeSTS(cfg, id.IDToken)
	if err != nil {
		return "", err
	}
	secretID := secretIDForSubject(cfg.SecretIDPrefix, subject)
	return accessSecretVersion(cfg.ProjectNumber, secretID, accessToken)
}

func secretIDForSubject(prefix, subject string) string {
	sum := sha256.Sum256([]byte(subject))
	return fmt.Sprintf("%s-%s", prefix, hex.EncodeToString(sum[:])[:16])
}

func subjectFromIDToken(idToken string) (string, error) {
	parts := strings.Split(idToken, ".")
	if len(parts) != 3 {
		return "", fmt.Errorf("identity.idToken is not a JWT")
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return "", fmt.Errorf("identity.idToken payload decode failed")
	}
	var claims struct {
		Sub string `json:"sub"`
	}
	if err := json.Unmarshal(payload, &claims); err != nil {
		return "", fmt.Errorf("identity.idToken payload is not JSON")
	}
	if strings.TrimSpace(claims.Sub) == "" {
		return "", fmt.Errorf("identity.idToken missing sub claim")
	}
	return claims.Sub, nil
}

func exchangeSTS(cfg providerConfig, idToken string) (string, error) {
	audience := fmt.Sprintf(
		"//iam.googleapis.com/projects/%s/locations/global/workloadIdentityPools/%s/providers/%s",
		cfg.ProjectNumber, cfg.PoolID, cfg.ProviderID,
	)
	form := url.Values{}
	form.Set("grant_type", "urn:ietf:params:oauth:grant-type:token-exchange")
	form.Set("audience", audience)
	form.Set("scope", "https://www.googleapis.com/auth/cloud-platform")
	form.Set("requested_token_type", "urn:ietf:params:oauth:token-type:access_token")
	form.Set("subject_token_type", "urn:ietf:params:oauth:token-type:id_token")
	form.Set("subject_token", idToken)

	req, err := http.NewRequest(http.MethodPost, stsTokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return "", fmt.Errorf("sts request build failed")
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := httpClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("sts token exchange failed")
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("sts token exchange returned HTTP %d", resp.StatusCode)
	}
	var parsed struct {
		AccessToken string `json:"access_token"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil || parsed.AccessToken == "" {
		return "", fmt.Errorf("sts token exchange returned invalid JSON")
	}
	return parsed.AccessToken, nil
}

func accessSecretVersion(projectNumber, secretID, accessToken string) (string, error) {
	endpoint := fmt.Sprintf(
		secretManagerAccessFmt,
		projectNumber, url.PathEscape(secretID),
	)
	req, err := http.NewRequest(http.MethodGet, endpoint, nil)
	if err != nil {
		return "", fmt.Errorf("secretmanager request build failed")
	}
	req.Header.Set("Authorization", "Bearer "+accessToken)

	resp, err := httpClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("secretmanager access failed")
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("secretmanager access returned HTTP %d", resp.StatusCode)
	}
	var parsed struct {
		Payload struct {
			Data string `json:"data"`
		} `json:"payload"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil {
		return "", fmt.Errorf("secretmanager response is not JSON")
	}
	raw, err := base64.StdEncoding.DecodeString(parsed.Payload.Data)
	if err != nil {
		return "", fmt.Errorf("secretmanager payload decode failed")
	}
	token := strings.TrimSpace(string(raw))
	if token == "" {
		return "", fmt.Errorf("subject secret is empty")
	}
	return token, nil
}
