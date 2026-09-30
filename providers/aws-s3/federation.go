package main

import (
	"encoding/xml"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// Overridable for unit tests (fake metadata / STS). Never log token values.
var (
	httpClient  = &http.Client{Timeout: 20 * time.Second}
	metadataURL = "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity"
	stsURLFmt   = "https://sts.%s.amazonaws.com/"
)

type awsCredentials struct {
	AccessKeyID     string
	SecretAccessKey string
	SessionToken    string
	Expiration      string // RFC3339 from STS when present
}

type stsAssumeRoleResponse struct {
	XMLName xml.Name `xml:"AssumeRoleWithWebIdentityResponse"`
	Result  struct {
		Credentials struct {
			AccessKeyID     string `xml:"AccessKeyId"`
			SecretAccessKey string `xml:"SecretAccessKey"`
			SessionToken    string `xml:"SessionToken"`
			Expiration      string `xml:"Expiration"`
		} `xml:"Credentials"`
	} `xml:"AssumeRoleWithWebIdentityResult"`
	Error struct {
		Code    string `xml:"Code"`
		Message string `xml:"Message"`
	} `xml:"Error"`
}

func mintRuntimeIDToken(audience string) (string, error) {
	if audience == "" {
		return "", fmt.Errorf("audience not configured")
	}
	u, err := url.Parse(metadataURL)
	if err != nil {
		return "", fmt.Errorf("metadata identity request failed")
	}
	q := u.Query()
	q.Set("audience", audience)
	u.RawQuery = q.Encode()

	req, err := http.NewRequest(http.MethodGet, u.String(), nil)
	if err != nil {
		return "", fmt.Errorf("metadata identity request failed")
	}
	req.Header.Set("Metadata-Flavor", "Google")

	resp, err := httpClient.Do(req)
	if err != nil {
		return "", fmt.Errorf("metadata identity request failed")
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	if err != nil {
		return "", fmt.Errorf("metadata identity read failed")
	}
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("metadata identity HTTP %d", resp.StatusCode)
	}
	token := strings.TrimSpace(string(body))
	if token == "" {
		return "", fmt.Errorf("metadata identity returned empty token")
	}
	return token, nil
}

func assumeRoleWithWebIdentity(cfg providerConfig, webIdentityToken string) (*awsCredentials, error) {
	if webIdentityToken == "" {
		return nil, fmt.Errorf("web identity token missing")
	}
	stsEndpoint := fmt.Sprintf(stsURLFmt, cfg.Region)
	form := url.Values{}
	form.Set("Action", "AssumeRoleWithWebIdentity")
	form.Set("Version", "2011-06-15")
	form.Set("RoleArn", cfg.RoleARN)
	form.Set("RoleSessionName", sessionName())
	form.Set("WebIdentityToken", webIdentityToken)
	form.Set("DurationSeconds", strconv.Itoa(sessionDurationSeconds))

	req, err := http.NewRequest(http.MethodPost, stsEndpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return nil, fmt.Errorf("sts AssumeRoleWithWebIdentity request failed")
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("sts AssumeRoleWithWebIdentity request failed for role %s", roleNameFromARN(cfg.RoleARN))
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 256<<10))
	if err != nil {
		return nil, fmt.Errorf("sts AssumeRoleWithWebIdentity read failed for role %s", roleNameFromARN(cfg.RoleARN))
	}

	var parsed stsAssumeRoleResponse
	if err := xml.Unmarshal(body, &parsed); err != nil {
		// Do not surface raw body — may contain credential material on success paths
		// and error detail we cannot sanitize reliably.
		if resp.StatusCode != http.StatusOK {
			return nil, fmt.Errorf("sts AssumeRoleWithWebIdentity HTTP %d for role %s", resp.StatusCode, roleNameFromARN(cfg.RoleARN))
		}
		return nil, fmt.Errorf("sts AssumeRoleWithWebIdentity response parse failed for role %s", roleNameFromARN(cfg.RoleARN))
	}

	if parsed.Error.Code != "" {
		code := parsed.Error.Code
		return nil, fmt.Errorf("sts AssumeRoleWithWebIdentity %s for role %s", code, roleNameFromARN(cfg.RoleARN))
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("sts AssumeRoleWithWebIdentity HTTP %d for role %s", resp.StatusCode, roleNameFromARN(cfg.RoleARN))
	}

	c := parsed.Result.Credentials
	if c.AccessKeyID == "" || c.SecretAccessKey == "" || c.SessionToken == "" {
		return nil, fmt.Errorf("sts AssumeRoleWithWebIdentity returned incomplete credentials for role %s", roleNameFromARN(cfg.RoleARN))
	}
	return &awsCredentials{
		AccessKeyID:     c.AccessKeyID,
		SecretAccessKey: c.SecretAccessKey,
		SessionToken:    c.SessionToken,
		Expiration:      strings.TrimSpace(c.Expiration),
	}, nil
}
