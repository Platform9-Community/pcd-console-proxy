package main

import (
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

type config struct {
	keystoneURL     string
	allowedProjects []string // empty = allow any valid project
	sessionTTL      time.Duration
}

func loadConfig(path string) *config {
	cfg := &config{sessionTTL: 10 * time.Minute}

	data, err := os.ReadFile(path)
	if err != nil {
		log.Printf("warn: config not found at %s, using defaults", path)
		return cfg
	}

	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		v = strings.Trim(strings.TrimSpace(v), `"'`)
		switch strings.TrimSpace(k) {
		case "OS_AUTH_URL":
			cfg.keystoneURL = v
		case "ALLOWED_PROJECTS":
			for _, p := range strings.Split(v, ",") {
				if p = strings.TrimSpace(p); p != "" {
					cfg.allowedProjects = append(cfg.allowedProjects, p)
				}
			}
		case "SESSION_TTL_MINUTES":
			if n, err := strconv.Atoi(v); err == nil && n > 0 {
				cfg.sessionTTL = time.Duration(n) * time.Minute
			}
		}
	}
	return cfg
}

func main() {
	configPath := "/etc/pcd-proxy/state.conf"
	if len(os.Args) > 1 {
		configPath = os.Args[1]
	}

	cfg := loadConfig(configPath)
	if cfg.keystoneURL == "" {
		log.Println("warn: OS_AUTH_URL not set — all logins will fail until configured via TUI")
	}

	store := newSessionStore(cfg.sessionTTL)
	h := &handler{cfg: cfg, sessions: store}

	mux := http.NewServeMux()
	mux.HandleFunc("/auth_verify", h.authVerify)
	mux.HandleFunc("/login", h.login)
	mux.HandleFunc("/logout", h.logout)

	log.Printf("pcd-auth listening on :9000 (keystone: %q, ttl: %s)", cfg.keystoneURL, cfg.sessionTTL)
	log.Fatal(http.ListenAndServe(":9000", mux))
}
