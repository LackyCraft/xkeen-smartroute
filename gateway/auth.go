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
	sessionCookieName = "sr_session"
	sessionTTL        = 7 * 24 * time.Hour
)

// Built from srEtcDir (main.go), not hardcoded -- see its own comment for
// why (KeeneticOS's read-only /etc).
var passwordHashFile = srEtcDir + "/state/gateway_password_hash"

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
	// Drop the key entirely once it has nothing recent left, rather than
	// keeping an empty slice around forever -- with clientIP no longer
	// spoofable via XFF this map can only grow as large as the number of
	// distinct real client IPs that have ever failed a login, but there's
	// no reason to let entries that "aged out" sit in memory permanently.
	if len(recent) == 0 {
		delete(l.fails, ip)
	} else {
		l.fails[ip] = recent
	}
	return len(recent) < 10
}

func (l *loginLimiter) recordFail(ip string) {
	l.mu.Lock()
	l.fails[ip] = append(l.fails[ip], time.Now())
	l.mu.Unlock()
}

// clientIP: deliberately RemoteAddr only, never X-Forwarded-For -- this
// gateway has no reverse proxy in front of it (same fact isLoopback below
// already relies on), so XFF is a plain client-supplied header any caller
// can set to an arbitrary, rotating value. Keying the login rate limiter
// on it let a real attacker bypass the throttle entirely by sending a
// fresh XFF on every attempt, and grew loginLimiter.fails without bound
// (a fresh map key per attempted value) -- a memory-exhaustion vector, not
// just a throttle bypass.
func clientIP(r *http.Request) string {
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

// isLoopback: deliberately reads r.RemoteAddr only, never X-Forwarded-For
// (client-supplied, spoofable) -- RemoteAddr is the actual TCP peer address
// Go's own listener recorded, nothing upstream rewrites it since this
// gateway has no reverse proxy in front of it. A request that genuinely
// originates on the router itself already has root-equivalent access (this
// is exactly how the rpcd script's own internal `curl 127.0.0.1:1001/...`
// calls reach the gateway, e.g. get_activity in the rpcd script) -- the
// password protects the LAN-facing surface, not the router talking to
// itself.
func isLoopback(r *http.Request) bool {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
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
//
// Used to gate by URL *extension* (".js"/".png"/etc. => public) rather
// than by route -- confirmed live as a real bypass: any protected route
// whose last path segment merely *ends* in one of those extensions (e.g.
// PUT /proxies/whatever.svg) skipped the auth check entirely and reached
// the real handler, saved only by that handler's own downstream "not
// found" logic rather than by this gate. Inverted to an explicit list of
// this binary's actual sensitive routes instead -- anything not on it
// (the SPA shell, its JS/CSS/images, /version) is public by construction,
// the same set that was reachable before, just checked by what the route
// *is* instead of by what its last path segment happens to look like.
func isPublicPath(p string) bool {
	switch p {
	case "/api/login", "/api/auth/status", "/version":
		return true
	}
	switch {
	case strings.HasPrefix(p, "/api/"): // /api/call/*, /api/change-password, /api/logout, /api/traffic-by-profile
		return false
	case p == "/proxies", strings.HasPrefix(p, "/proxies/"):
		return false
	case p == "/connections", p == "/rules", p == "/configs":
		return false
	case p == "/traffic", p == "/activity", p == "/logs":
		return false
	}
	return true // the SPA shell and everything served from staticDir
}

func requireAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// CORS preflight never carries credentials/cookies -- gating it
		// would just break the preflight itself, not add any protection;
		// the actual GET/POST that follows still goes through this check.
		if r.Method == http.MethodOptions || isPublicPath(r.URL.Path) || isLoopback(r) || isAuthed(r) {
			next.ServeHTTP(w, r)
			return
		}
		writeErr(w, http.StatusUnauthorized, "unauthorized")
	})
}
