package main

import (
	_ "embed"
	"html/template"
	"net/http"
	"strings"
)

//go:embed login.html
var loginHTMLRaw string

var loginTmpl = template.Must(template.New("login").Parse(loginHTMLRaw))

type loginData struct {
	Error    string
	Username string
	Project  string
}

type handler struct {
	cfg      *config
	sessions *sessionStore
}

const cookieName = "pcd-session"

// authVerify is called exclusively as an nginx auth_request subrequest.
// Returns 200 if the request carries a valid session cookie, 401 otherwise.
func (h *handler) authVerify(w http.ResponseWriter, r *http.Request) {
	cookie, err := r.Cookie(cookieName)
	if err != nil || !h.sessions.valid(cookie.Value) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	w.WriteHeader(http.StatusOK)
}

// login serves the login form (GET) and processes credentials (POST).
func (h *handler) login(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		h.renderLogin(w, loginData{Project: "service"})
	case http.MethodPost:
		h.handleLoginPost(w, r)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func (h *handler) handleLoginPost(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		h.renderLogin(w, loginData{Error: "invalid form data"})
		return
	}

	username := strings.TrimSpace(r.FormValue("username"))
	password := r.FormValue("password")
	project := strings.TrimSpace(r.FormValue("project"))

	if username == "" || password == "" || project == "" {
		h.renderLogin(w, loginData{
			Error:    "Username, password, and project are required.",
			Username: username,
			Project:  project,
		})
		return
	}

	result, err := keystoneAuth(h.cfg.keystoneURL, username, password, project)
	if err != nil {
		h.renderLogin(w, loginData{
			Error:    "Authentication failed: " + err.Error(),
			Username: username,
			Project:  project,
		})
		return
	}

	// Optional: enforce project allowlist (compare against project name)
	if len(h.cfg.allowedProjects) > 0 && !contains(h.cfg.allowedProjects, result.projectName) {
		h.renderLogin(w, loginData{
			Error:    "Project " + project + " is not permitted to access this proxy.",
			Username: username,
			Project:  project,
		})
		return
	}

	sessionID := h.sessions.create(result.projectID)
	http.SetCookie(w, &http.Cookie{
		Name:     cookieName,
		Value:    sessionID,
		Path:     "/",
		HttpOnly: true,
		Secure:   true,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   int(h.cfg.sessionTTL.Seconds()),
	})

	// Redirect back to the original URL the user was trying to reach.
	// Require a query string so static asset paths (/favicon.ico etc.) are ignored.
	next := "/"
	if nc, err := r.Cookie("pcd-next"); err == nil && strings.HasPrefix(nc.Value, "/") && strings.Contains(nc.Value, "?") {
		next = nc.Value
	}
	http.SetCookie(w, &http.Cookie{Name: "pcd-next", MaxAge: -1, Path: "/"})
	http.Redirect(w, r, next, http.StatusSeeOther)
}

func (h *handler) logout(w http.ResponseWriter, r *http.Request) {
	if cookie, err := r.Cookie(cookieName); err == nil {
		h.sessions.delete(cookie.Value)
	}
	http.SetCookie(w, &http.Cookie{Name: cookieName, MaxAge: -1, Path: "/"})
	http.Redirect(w, r, "/login", http.StatusSeeOther)
}

func (h *handler) renderLogin(w http.ResponseWriter, data loginData) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	loginTmpl.Execute(w, data)
}

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}
