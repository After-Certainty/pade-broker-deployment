// Command pade-provider-vercel is a deployment-owned PADE exec provider.
//
// Milestone L dogfood: turns a Secret Manager–mounted Vercel access token into
// generic Material (VERCEL_TOKEN). Not part of PADE core; not a Vercel SDK or CLI.
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

type request struct {
	Capability string                 `json:"capability"`
	Operation  string                 `json:"operation"`
	Config     map[string]interface{} `json:"config"`
}

type providerConfig struct {
	TokenFile string
	TokenEnv  string
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
		status, message := probe(cfg)
		write(map[string]interface{}{
			"status":  status,
			"message": message,
			"meta": map[string]string{
				"capability": req.Capability,
				"mode":       "static-token-file",
			},
		})
	case "resolve":
		token, err := readToken(cfg.TokenFile)
		if err != nil {
			fail("%v", err)
		}
		envName := cfg.TokenEnv
		if envName == "" {
			envName = "VERCEL_TOKEN"
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
		return providerConfig{}
	}
	return providerConfig{
		TokenFile: stringFrom(m["tokenFile"]),
		TokenEnv:  stringFrom(m["tokenEnv"]),
	}
}

func stringFrom(v interface{}) string {
	s, ok := v.(string)
	if !ok {
		return ""
	}
	return strings.TrimSpace(s)
}

func probe(cfg providerConfig) (status, message string) {
	if cfg.TokenFile == "" {
		return "unavailable", "tokenFile not configured"
	}
	token, err := readToken(cfg.TokenFile)
	if err != nil {
		// Safe diagnostics only — never include file contents.
		return "unavailable", err.Error()
	}
	if token == "" {
		return "unavailable", "token file is empty"
	}
	return "available", "vercel token file present"
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
