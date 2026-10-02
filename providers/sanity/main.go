// Command pade-provider-sanity is a deployment-owned PADE exec provider.
//
// Deployed bindings use subject-secret-wif: exchange broker-forwarded Cursor
// identity for federated Google credentials and read a subject-bound Sanity
// API token from Secret Manager. Credential fulfillment only — no Sanity API
// or CLI calls. Not part of PADE core.
//
// Capability id sanity.rehearsal.write is deployment-owned and non-normative;
// it does not mediate individual Sanity operations. Downstream credential
// authority remains authoritative.
//
// Contract: PADE v0.2.1 docs/provider-contract.md (broker-side exec + identity).
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
)

const fulfillmentSubjectSecretWIF = "subject-secret-wif"

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
			envName = "SANITY_API_TOKEN"
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
		return providerConfig{Fulfillment: fulfillmentSubjectSecretWIF}
	}
	fulfillment := stringFrom(m["fulfillment"])
	if fulfillment == "" {
		fulfillment = fulfillmentSubjectSecretWIF
	}
	prefix := stringFrom(m["secretIdPrefix"])
	if prefix == "" {
		prefix = "sanity-token-sub"
	}
	return providerConfig{
		Fulfillment:    fulfillment,
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
	if cfg.Fulfillment != fulfillmentSubjectSecretWIF {
		return "unavailable", fmt.Sprintf("unsupported fulfillment %q", cfg.Fulfillment), cfg.Fulfillment
	}
	mode = fulfillmentSubjectSecretWIF
	if err := validateWIFConfig(cfg); err != nil {
		return "unavailable", err.Error(), mode
	}
	if id == nil || strings.TrimSpace(id.IDToken) == "" {
		return "unavailable", "broker-verified identity.idToken not provided (PADE identity context required for subject-secret-wif)", mode
	}
	return "available", "subject-secret-wif configured; identity.idToken present", mode
}

func resolveToken(cfg providerConfig, id *identity) (string, error) {
	if cfg.Fulfillment != fulfillmentSubjectSecretWIF {
		return "", fmt.Errorf("unsupported fulfillment %q", cfg.Fulfillment)
	}
	return resolveSubjectSecretWIF(cfg, id)
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
