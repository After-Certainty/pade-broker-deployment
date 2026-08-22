// Command pade-provider-vercel is a deployment-owned PADE exec provider.
//
// Milestone L: static Secret Manager–mounted Vercel token → Material (default).
// Milestone M: optional subject-secret-wif fulfillment exchanges broker-forwarded
// Cursor identity for federated Google credentials and reads a subject-bound
// secret. Not part of PADE core; not a Vercel SDK or CLI.
//
// Contract: PADE v0.1.0 docs/provider-contract.md (broker-side exec).
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
)

const (
	fulfillmentStaticTokenFile = "static-token-file"
	fulfillmentSubjectSecretWIF = "subject-secret-wif"
)

type identity struct {
	Subject string `json:"subject,omitempty"`
	IDToken string `json:"idToken,omitempty"`
}

type request struct {
	Capability string                 `json:"capability"`
	Operation  string                 `json:"operation"`
	Config     map[string]interface{} `json:"config"`
	Identity   *identity              `json:"identity,omitempty"`
}

type providerConfig struct {
	Fulfillment    string
	TokenFile      string
	TokenEnv       string
	ProjectNumber  string
	PoolID         string
	ProviderID     string
	SecretIDPrefix string
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

	cfg := configFromMap(req.Config)

	switch req.Operation {
	case "probe":
		status, message, mode := probe(cfg, req.Identity)
		write(map[string]interface{}{
			"status":  status,
			"message": message,
			"meta": map[string]string{
				"capability": req.Capability,
				"mode":       mode,
			},
		})
	case "resolve":
		envName := cfg.TokenEnv
		if envName == "" {
			envName = "VERCEL_TOKEN"
		}
		token, err := resolveToken(cfg, req.Identity)
		if err != nil {
			fail("%v", err)
		}
		write(map[string]interface{}{
			"env": map[string]string{
				envName: token,
			},
		})
	default:
		fail("unsupported operation %q", req.Operation)
	}
}

func configFromMap(m map[string]interface{}) providerConfig {
	if m == nil {
		return providerConfig{Fulfillment: fulfillmentStaticTokenFile}
	}
	fulfillment := stringFrom(m["fulfillment"])
	if fulfillment == "" {
		fulfillment = fulfillmentStaticTokenFile
	}
	prefix := stringFrom(m["secretIdPrefix"])
	if prefix == "" {
		prefix = "vercel-token-sub"
	}
	return providerConfig{
		Fulfillment:    fulfillment,
		TokenFile:      stringFrom(m["tokenFile"]),
		TokenEnv:       stringFrom(m["tokenEnv"]),
		ProjectNumber:  stringFrom(m["projectNumber"]),
		PoolID:         stringFrom(m["poolId"]),
		ProviderID:     stringFrom(m["providerId"]),
		SecretIDPrefix: prefix,
	}
}

func stringFrom(v interface{}) string {
	s, ok := v.(string)
	if !ok {
		return ""
	}
	return strings.TrimSpace(s)
}

func probe(cfg providerConfig, id *identity) (status, message, mode string) {
	switch cfg.Fulfillment {
	case fulfillmentSubjectSecretWIF:
		mode = fulfillmentSubjectSecretWIF
		if err := validateWIFConfig(cfg); err != nil {
			return "unavailable", err.Error(), mode
		}
		if id == nil || strings.TrimSpace(id.IDToken) == "" {
			return "unavailable", "broker-verified identity.idToken not provided (PADE identity context required for subject-secret-wif)", mode
		}
		return "available", "subject-secret-wif configured; identity.idToken present", mode
	case fulfillmentStaticTokenFile, "":
		mode = fulfillmentStaticTokenFile
		if cfg.TokenFile == "" {
			return "unavailable", "tokenFile not configured", mode
		}
		token, err := readToken(cfg.TokenFile)
		if err != nil {
			// Safe diagnostics only — never include file contents.
			return "unavailable", err.Error(), mode
		}
		if token == "" {
			return "unavailable", "token file is empty", mode
		}
		return "available", "vercel token file present", mode
	default:
		return "unavailable", fmt.Sprintf("unsupported fulfillment %q", cfg.Fulfillment), cfg.Fulfillment
	}
}

func resolveToken(cfg providerConfig, id *identity) (string, error) {
	switch cfg.Fulfillment {
	case fulfillmentSubjectSecretWIF:
		return resolveSubjectSecretWIF(cfg, id)
	case fulfillmentStaticTokenFile, "":
		return readToken(cfg.TokenFile)
	default:
		return "", fmt.Errorf("unsupported fulfillment %q", cfg.Fulfillment)
	}
}

func readToken(path string) (string, error) {
	if path == "" {
		return "", fmt.Errorf("tokenFile not configured")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return "", fmt.Errorf("token file not found")
		}
		return "", fmt.Errorf("token file unreadable")
	}
	return strings.TrimSpace(string(raw)), nil
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
