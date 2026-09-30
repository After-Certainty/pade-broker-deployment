// Command pade-provider-aws-s3 is a deployment-owned PADE exec provider.
//
// It fulfills aws.s3.bucket.write by minting a Google ID token from the Cloud
// Run runtime service-account metadata endpoint (audience = config.audience),
// exchanging that token via AWS STS AssumeRoleWithWebIdentity, and returning
// temporary AWS credential Material plus the operator-bound bucket/prefix.
//
// The caller's broker-verified identity authenticates/authorizes the request
// (Google/GCE only for this experiment). That caller idToken is NEVER used as
// the AWS federation subject token — the broker runtime identity is.
//
// Not part of PADE core. No AWS access keys or durable credentials.
//
// Contract: PADE v0.3.0 docs/provider-contract.md (broker-side exec + identity).
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
	"time"
)

const (
	capabilityAWSBucketWrite = "aws.s3.bucket.write"
	requiredIssuerAlias      = "google"
	requiredIssuer           = "https://accounts.google.com"
	sessionDurationSeconds   = 900
)

type identity struct {
	Issuer      string `json:"issuer,omitempty"`
	IssuerAlias string `json:"issuerAlias,omitempty"`
	Subject     string `json:"subject,omitempty"`
	IDToken     string `json:"idToken,omitempty"`
}

type request struct {
	Capability string                 `json:"capability"`
	Operation  string                 `json:"operation"`
	Config     map[string]interface{} `json:"config"`
	Identity   *identity              `json:"identity,omitempty"`
}

type providerConfig struct {
	RoleARN  string
	Region   string
	Bucket   string
	Prefix   string
	Audience string
}

func main() {
	data, err := io.ReadAll(os.Stdin)
	if err != nil {
		fail("read stdin: %v", err)
	}
	var req request
	if err := json.Unmarshal(data, &req); err != nil {
		fail("invalid request JSON")
	}

	if req.Capability != "" && req.Capability != capabilityAWSBucketWrite {
		fail("unsupported capability %q (want %s)", req.Capability, capabilityAWSBucketWrite)
	}

	cfg, err := configFromMap(req.Config)
	if err != nil {
		fail("%v", err)
	}

	switch req.Operation {
	case "probe":
		status, message := probe(cfg, req.Identity)
		write(map[string]interface{}{
			"status":  status,
			"message": message,
			"meta": map[string]string{
				"capability": capabilityAWSBucketWrite,
			},
		})
	case "resolve":
		env, expiresAt, err := resolve(cfg, req.Identity)
		if err != nil {
			fail("%v", err)
		}
		resp := map[string]interface{}{"env": env}
		if expiresAt != "" {
			resp["expiresAt"] = expiresAt
		}
		write(resp)
	default:
		fail("unsupported operation %q", req.Operation)
	}
}

func configFromMap(m map[string]interface{}) (providerConfig, error) {
	if m == nil {
		return providerConfig{}, fmt.Errorf("config required")
	}
	cfg := providerConfig{
		RoleARN:  stringFrom(m["roleArn"]),
		Region:   stringFrom(m["region"]),
		Bucket:   stringFrom(m["bucket"]),
		Prefix:   stringFrom(m["prefix"]),
		Audience: stringFrom(m["audience"]),
	}
	if err := validateConfig(cfg); err != nil {
		return providerConfig{}, err
	}
	return cfg, nil
}

func validateConfig(cfg providerConfig) error {
	if cfg.RoleARN == "" {
		return fmt.Errorf("roleArn not configured")
	}
	if !strings.HasPrefix(cfg.RoleARN, "arn:aws:iam::") || !strings.Contains(cfg.RoleARN, ":role/") {
		return fmt.Errorf("roleArn is not a valid IAM role ARN")
	}
	if cfg.Region == "" {
		return fmt.Errorf("region not configured")
	}
	if cfg.Bucket == "" {
		return fmt.Errorf("bucket not configured")
	}
	if cfg.Prefix == "" {
		return fmt.Errorf("prefix not configured")
	}
	if cfg.Audience == "" {
		return fmt.Errorf("audience not configured")
	}
	return nil
}

func stringFrom(v interface{}) string {
	s, ok := v.(string)
	if !ok {
		return ""
	}
	return strings.TrimSpace(s)
}

func probe(cfg providerConfig, id *identity) (status, message string) {
	if err := validateCallerIdentity(id); err != nil {
		return "unavailable", err.Error()
	}
	return "available", "aws.s3.bucket.write configured; google caller identity present"
}

func resolve(cfg providerConfig, id *identity) (map[string]string, string, error) {
	if err := validateCallerIdentity(id); err != nil {
		return nil, "", err
	}

	// Broker-forwarded caller token authenticates the request only.
	// AWS federation uses Cloud Run runtime metadata identity.
	googleToken, err := mintRuntimeIDToken(cfg.Audience)
	if err != nil {
		return nil, "", err
	}

	creds, err := assumeRoleWithWebIdentity(cfg, googleToken)
	if err != nil {
		return nil, "", err
	}

	env := map[string]string{
		"AWS_ACCESS_KEY_ID":     creds.AccessKeyID,
		"AWS_SECRET_ACCESS_KEY": creds.SecretAccessKey,
		"AWS_SESSION_TOKEN":     creds.SessionToken,
		"AWS_REGION":            cfg.Region,
		"AWS_S3_BUCKET":         cfg.Bucket,
		"AWS_S3_PREFIX":         cfg.Prefix,
	}
	return env, creds.Expiration, nil
}

func validateCallerIdentity(id *identity) error {
	if id == nil {
		return fmt.Errorf("broker-verified identity not provided (PADE identity context required)")
	}
	alias := strings.TrimSpace(id.IssuerAlias)
	if alias == "" {
		return fmt.Errorf("identity.issuerAlias required (want %q)", requiredIssuerAlias)
	}
	if alias != requiredIssuerAlias {
		return fmt.Errorf("identity.issuerAlias %q not authorized for %s (want %q)", alias, capabilityAWSBucketWrite, requiredIssuerAlias)
	}
	issuer := strings.TrimSpace(id.Issuer)
	if issuer != "" && issuer != requiredIssuer {
		return fmt.Errorf("identity.issuer %q not authorized (want %q)", issuer, requiredIssuer)
	}
	return nil
}

func roleNameFromARN(arn string) string {
	const marker = ":role/"
	i := strings.LastIndex(arn, marker)
	if i < 0 {
		return "role"
	}
	return arn[i+len(marker):]
}

func sessionName() string {
	return "pade-aws-s3-" + time.Now().UTC().Format("20060102T150405Z")
}

func write(v interface{}) {
	if err := json.NewEncoder(os.Stdout).Encode(v); err != nil {
		fail("encode response: %v", err)
	}
}

func fail(format string, args ...interface{}) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}
