package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// keystoneResult is returned from a successful auth attempt.
type keystoneResult struct {
	token       string
	projectID   string
	projectName string
}

// keystoneAuth authenticates username/password scoped to the named project.
// Returns the scoped X-Subject-Token and resolved project ID on success.
// Returns a non-nil error if credentials are wrong, user is not in the project,
// or the project does not exist.
func keystoneAuth(authURL, username, password, project string) (*keystoneResult, error) {
	if authURL == "" {
		return nil, fmt.Errorf("keystone URL not configured")
	}

	body := buildAuthBody(username, password, project)
	url := strings.TrimRight(authURL, "/") + "/auth/tokens"

	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("keystone request: %w", err)
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))

	if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
		return nil, fmt.Errorf("invalid credentials or not a member of project %q", project)
	}
	if resp.StatusCode == http.StatusNotFound {
		return nil, fmt.Errorf("project %q not found", project)
	}
	if resp.StatusCode != http.StatusCreated {
		return nil, fmt.Errorf("keystone returned %d", resp.StatusCode)
	}

	token := resp.Header.Get("X-Subject-Token")
	if token == "" {
		return nil, fmt.Errorf("keystone response missing X-Subject-Token")
	}

	projectID, projectName, err := extractProjectInfo(respBody)
	if err != nil {
		return nil, fmt.Errorf("parse keystone response: %w", err)
	}

	return &keystoneResult{token: token, projectID: projectID, projectName: projectName}, nil
}

func buildAuthBody(username, password, project string) []byte {
	payload := map[string]any{
		"auth": map[string]any{
			"identity": map[string]any{
				"methods": []string{"password"},
				"password": map[string]any{
					"user": map[string]any{
						"name":     username,
						"domain":   map[string]string{"name": "Default"},
						"password": password,
					},
				},
			},
			"scope": map[string]any{
				"project": map[string]any{
					"name":   project,
					"domain": map[string]string{"name": "Default"},
				},
			},
		},
	}
	b, _ := json.Marshal(payload)
	return b
}

func extractProjectInfo(body []byte) (id, name string, err error) {
	var resp struct {
		Token struct {
			Project struct {
				ID   string `json:"id"`
				Name string `json:"name"`
			} `json:"project"`
		} `json:"token"`
	}
	if err = json.Unmarshal(body, &resp); err != nil {
		return
	}
	if resp.Token.Project.ID == "" {
		err = fmt.Errorf("project ID missing in token response")
		return
	}
	return resp.Token.Project.ID, resp.Token.Project.Name, nil
}
