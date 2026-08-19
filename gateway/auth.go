// Optional password gate for the gateway's own panel. The rest of this
// binary (the Clash-API-shaped /proxies etc., and now the rpc bridge in
// rpc.go) already runs at whatever trust level the router itself grants
// anyone on the LAN -- this only adds a login step in front of the panel
// UI and its APIs, matching the same "simple shared password" model
// xkeen-UI already offers (see install.sh's xkeen-UI password prompt).
// No password configured at all (fresh install, or an operator who
// deliberately never sets one) means auth is simply off, same as today.
package main

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

const (
	passwordHashFile  = "/etc/xkeen-smartroute/state/gateway_password_hash"
	sessionCookieName = "sr_session"
	sessionTTL        = 7 * 24 * time.Hour
)

// --- password storage ---

// hashPassword: sha256 with a fixed, project-specific prefix -- not meant
// to resist an offline attack on a stolen hash file (this is a single
// shared password for a home LAN panel, not a multi-tenant login system),
// only to avoid storing the plaintext password on disk.
func hashPassword(pw string) string {
	sum := sha256.Sum256([]byte("xkeen-smartroute-gateway:" + pw))
	return hex.EncodeToString(sum[:])
}

func readPasswordHash() (string, bool) {
	b, err := os.ReadFile(passwordHashFile)
	if err != nil {
		return "", false
	}
	h := strings.TrimSpace(string(b))
	return h, h != ""
}

func writePasswordHash(hash string) error {
	if err := os.MkdirAll(filepath.Dir(passwordHashFile), 0o700); err != nil {
		return err
	}
	return os.WriteFile(passwordHashFile, []byte(hash+"\n"), 0o600)
}

func authEnabled() bool {
	_, ok := readPasswordHash()
	return ok
}

// --- sessions (in-memory; a restart of this process logs everyone out,
// which is fine for a "simple password" tier -- no persistence needed) ---

type sessionStore struct {
	mu   sync.Mutex
	byID map[string]time.Time // token -> expiry
}

var sessions = &sessionStore{byID: map[string]time.Time{}}

func (s *sessionStore) create() string {
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	token := hex.EncodeToString(b)
	s.mu.Lock()
	s.byID[token] = time.Now().Add(sessionTTL)
	s.mu.Unlock()
	return token
}

func (s *sessionStore) valid(token string) bool {
	if token == "" {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	exp, ok := s.byID[token]
	if !ok || time.Now().After(exp) {
		delete(s.byID, token)
		return false
	}
	s.byID[token] = time.Now().Add(sessionTTL) // sliding expiry
	return true
}

func (s *sessionStore) revoke(token string) {
	s.mu.Lock()
	delete(s.byID, token)
	s.mu.Unlock()
}

func (s *sessionStore) revokeAll() {
	s.mu.Lock()
	s.byID = map[string]time.Time{}
	s.mu.Unlock()
}

// --- brute-force throttling: a small per-IP failure window, enough to make
// guessing impractical on a LAN-facing single password without turning a
// mistyped password into a lockout ---

type loginLimiter struct {
	mu    sync.Mutex
	fails map[string][]time.Time
}

var limiter = &loginLimiter{fails: map[string][]time.Time{}}

func (l *loginLimiter) allow(ip string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	cutoff := time.Now().Add(-5 * time.Minute)
	recent := l.fails[ip][:0]
	for _, t := range l.fails[ip] {
		if t.After(cutoff) {
			recent = append(recent, t)
		}
	}
	l.fails[ip] = recent
	return len(recent) < 10
}

func (l *loginLimiter) recordFail(ip string) {
	l.mu.Lock()
	l.fails[ip] = append(l.fails[ip], time.Now())
	l.mu.Unlock()
}

func clientIP(r *http.Request) string {
	if xf := r.Header.Get("X-Forwarded-For"); xf != "" {
		return strings.TrimSpace(strings.Split(xf, ",")[0])
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func isAuthed(r *http.Request) bool {
	if !authEnabled() {
		return true
	}
	c, err := r.Cookie(sessionCookieName)
	if err != nil {
		return false
	}
	return sessions.valid(c.Value)
}

func setSessionCookie(w http.ResponseWriter, token string) {
	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookieName,
		Value:    token,
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteLaxMode,
		MaxAge:   int(sessionTTL.Seconds()),
	})
}

func clearSessionCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{Name: sessionCookieName, Value: "", Path: "/", MaxAge: -1})
}

// --- HTTP handlers ---

func handleAuthStatus(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]bool{
		"authRequired": authEnabled(),
		"authed":       isAuthed(r),
	})
}

func handleLogin(w http.ResponseWriter, r *http.Request) {
	ip := clientIP(r)
	if !limiter.allow(ip) {
		writeErr(w, http.StatusTooManyRequests, "too_many_attempts")
		return
	}
	var body struct {
		Password string `json:"password"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request")
		return
	}
	hash, ok := readPasswordHash()
	if !ok {
		writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
		return
	}
	if subtle.ConstantTimeCompare([]byte(hashPassword(body.Password)), []byte(hash)) != 1 {
		limiter.recordFail(ip)
		writeErr(w, http.StatusUnauthorized, "invalid_password")
		return
	}
	setSessionCookie(w, sessions.create())
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func handleLogout(w http.ResponseWriter, r *http.Request) {
	if c, err := r.Cookie(sessionCookieName); err == nil {
		sessions.revoke(c.Value)
	}
	clearSessionCookie(w)
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// handleChangePassword: also accepts *setting* a password for the first
// time (current == "" when none is configured yet) -- same endpoint, one
// less concept for the UI to special-case.
func handleChangePassword(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Current string `json:"current"`
		New     string `json:"new"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "bad_request")
		return
	}
	if len(body.New) < 6 {
		writeErr(w, http.StatusBadRequest, "password_too_short")
		return
	}
	if hash, ok := readPasswordHash(); ok {
		if subtle.ConstantTimeCompare([]byte(hashPassword(body.Current)), []byte(hash)) != 1 {
			writeErr(w, http.StatusUnauthorized, "invalid_current_password")
			return
		}
	}
	if err := writePasswordHash(hashPassword(body.New)); err != nil {
		writeErr(w, http.StatusInternalServerError, "write_failed")
		return
	}
	sessions.revokeAll() // force re-login everywhere, including this session
	setSessionCookie(w, sessions.create())
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

// isPublicPath: the SPA shell and its static assets are always reachable
// (there's nothing sensitive in the HTML/CSS/JS itself, and the login
// screen has to load from somewhere); every data-bearing endpoint --
// everything else -- requires a session once a password is configured.
func isPublicPath(p string) bool {
	switch p {
	case "/api/login", "/api/auth/status":
		return true
	}
	if p == "/" {
		return true
	}
	switch filepath.Ext(p) {
	case ".html", ".css", ".js", ".png", ".svg", ".ico", ".webmanifest":
		return true
	}
	return false
}

func requireAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// CORS preflight never carries credentials/cookies -- gating it
		// would just break the preflight itself, not add any protection;
		// the actual GET/POST that follows still goes through this check.
		if r.Method == http.MethodOptions || isPublicPath(r.URL.Path) || isAuthed(r) {
			next.ServeHTTP(w, r)
			return
		}
		writeErr(w, http.StatusUnauthorized, "unauthorized")
	})
}
