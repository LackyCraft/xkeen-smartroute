// smartroute-gateway bridges Xray-core's own gRPC API and SmartRoute's
// on-disk state (servers.json / profiles/*.json, the same files
// lib/subscription.sh and lib/genroute.sh already own) to a REST+WebSocket
// surface shaped like the "Clash API" -- the protocol yacd/metacubexd (and
// Mihomo itself) speak. Point one of those dashboards at this instead of a
// real Mihomo/Clash core and it renders the same way, because from its
// point of view it's talking to an ordinary Clash-API backend.
//
// Deliberately NOT a second source of truth: reading happens straight from
// SmartRoute's files, and the one write path (PUT /proxies/{group}) goes
// through lib/genroute.sh, not a parallel config store.
package main

import (
	"context"
	"log"
	"net/http"
	"net/url"
	"os"
	"time"

	"github.com/gorilla/websocket"
)

const genrouteScript = "/opt/share/xkeen-smartroute/lib/genroute.sh"

func main() {
	listenAddr := envOr("SR_GATEWAY_LISTEN", "0.0.0.0:9095")
	xrayAddr := envOr("SR_GATEWAY_XRAY_API", "127.0.0.1:10085")
	staticDir := envOr("SR_GATEWAY_STATIC_DIR", "")
	rpcdScript := envOr("SR_GATEWAY_RPCD_SCRIPT", defaultRpcdScript)

	xc, err := newXrayClient(xrayAddr)
	if err != nil {
		log.Fatalf("xray client: %v", err)
	}
	defer xc.Close()

	startFailoverLoop(xc)
	startActivityLoop(xc)
	startLogCapLoop()

	rpc := newRPCBridge(rpcdScript)

	mux := http.NewServeMux()

	mux.HandleFunc("GET /api/auth/status", handleAuthStatus)
	mux.HandleFunc("POST /api/login", handleLogin)
	mux.HandleFunc("POST /api/logout", handleLogout)
	mux.HandleFunc("POST /api/change-password", handleChangePassword)
	mux.HandleFunc("POST /api/call/{method}", handleRPC(rpc))

	mux.HandleFunc("GET /version", handleVersion)
	mux.HandleFunc("GET /proxies", handleProxies)
	mux.HandleFunc("GET /proxies/{name}", func(w http.ResponseWriter, r *http.Request) {
		handleProxyByName(w, r, r.PathValue("name"))
	})
	mux.HandleFunc("PUT /proxies/{name}", func(w http.ResponseWriter, r *http.Request) {
		handleSelectProxy(w, r, r.PathValue("name"))
	})
	mux.HandleFunc("GET /proxies/{name}/delay", func(w http.ResponseWriter, r *http.Request) {
		handleDelay(w, r, r.PathValue("name"))
	})
	mux.HandleFunc("GET /connections", handleConnections)
	mux.HandleFunc("GET /rules", handleRules)
	mux.HandleFunc("GET /configs", handleConfigs)
	mux.HandleFunc("PATCH /configs", handleConfigs)
	mux.HandleFunc("GET /traffic", trafficWSHandler(xc))
	mux.HandleFunc("GET /activity", handleActivity)
	mux.HandleFunc("GET /api/traffic-by-profile", handleTrafficByProfile(xc))
	mux.HandleFunc("GET /logs", logsWSHandler())

	if staticDir != "" {
		mux.Handle("/", noCacheStatic(http.FileServer(http.Dir(staticDir))))
	}

	log.Printf("smartroute-gateway listening on %s (xray api %s, static %q, rpcd %q)", listenAddr, xrayAddr, staticDir, rpcdScript)
	// Bare http.ListenAndServe has no ReadHeaderTimeout/IdleTimeout/
	// MaxHeaderBytes at all -- a slowloris-style client that trickles
	// request headers a byte at a time, or just opens connections and
	// leaves them idle, can hold them open indefinitely with nothing to
	// evict them, real exposure on hardware this constrained. None of the
	// three apply once a connection is hijacked for a WebSocket upgrade
	// (/traffic, /logs) -- they only govern the plain-HTTP phase before
	// that, which is exactly what wsKeepalive's own read/write deadlines
	// (main.go/logs.go) pick up afterward.
	srv := &http.Server{
		Addr:              listenAddr,
		Handler:           corsWrap(requireAuth(mux)),
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    1 << 20, // 1MB
	}
	log.Fatal(srv.ListenAndServe())
}

// noCacheStatic forces every static asset to revalidate with the server on
// every load instead of a browser trusting its own heuristic cache -- Go's
// plain http.FileServer sets no Cache-Control at all, so a browser that
// already has a copy of e.g. doublevpn.js can keep serving it verbatim for
// an arbitrary amount of time after a redeploy, with no way to tell it's
// stale short of a manual hard refresh. Confirmed live: server-side data,
// the rpcd script, and the deployed JS file all matched exactly, yet the
// panel still rendered stale state -- the browser's own cached copy of the
// JS was the only thing left that could explain it.
//
// "no-cache" (not "no-store") still lets the browser keep a local copy, it
// just can't use it without asking first -- http.FileServer already sets
// Last-Modified/ETag and answers a conditional GET with a bare 304, so a
// revalidation that finds nothing changed costs one small round trip, not a
// full re-download.
func noCacheStatic(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-cache")
		h.ServeHTTP(w, r)
	})
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// sameOriginHost: true if the browser-supplied Origin header names the same
// host:port this request itself arrived on (r.Host -- what the browser put
// in its own Host header dialing in, so this holds regardless of which
// LAN IP/hostname the panel happens to be reached at, no hardcoded
// allowlist needed). An empty Origin (same-tab navigation, curl, the rpcd
// script's own loopback calls) is treated as same-origin -- only a
// genuine cross-site browser request ever sends a *mismatching* Origin.
func sameOriginHost(origin, host string) bool {
	if origin == "" {
		return true
	}
	u, err := url.Parse(origin)
	if err != nil || u.Host == "" {
		return false
	}
	return u.Host == host
}

// corsWrap: found live wide open -- Access-Control-Allow-Origin:* on every
// response plus a blanket `OPTIONS /` handler meant any website a LAN user
// had open in another tab could call this panel's API cross-origin and
// read the response (traffic stats, profiles, kill-switch state), and with
// no password set (the shipped default) actually change state too. Now
// reflects the Origin back only when it matches this request's own Host,
// and answers preflight generically instead of via a separate always-on
// route -- a cross-site page gets no CORS header at all, which is what
// makes the browser refuse to hand the response back to that page's JS.
func corsWrap(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		if origin != "" && sameOriginHost(origin, r.Host) {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Vary", "Origin")
		}
		if r.Method == http.MethodOptions {
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "*")
			w.WriteHeader(http.StatusNoContent)
			return
		}
		h.ServeHTTP(w, r)
	})
}

// upgrader.CheckOrigin was unconditionally true -- any website could open a
// cross-site WebSocket to /traffic or /logs and stream live traffic
// counters or the router's own browsing-domain log. Same same-origin rule
// as corsWrap; an empty Origin (non-browser clients, same-origin fetches
// in some older engines) is still allowed through.
var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool {
		return sameOriginHost(r.Header.Get("Origin"), r.Host)
	},
}

// WebSocket keepalive tuning, shared by every WS handler in this binary
// (/traffic here, /logs in logs.go). Neither handler used to read from its
// connection at all -- gorilla/websocket only processes incoming control
// frames (pong, close) while something is actively calling ReadMessage, so
// with no read pump a client whose TCP connection drops without a clean
// FIN/RST (a phone leaving wifi mid-session, a laptop sleeping, a NAT
// timeout -- not rare events) left conn.WriteJSON with nothing to fail
// against until the OS's own TCP retransmission timeout gave up, which can
// take minutes. That kept the handler's goroutine, ticker, and (for
// /traffic) per-second Xray API polling alive the whole time for a peer
// that was already gone -- real drain on a router with 256MB total RAM.
// wsKeepalive adds the standard heartbeat: a read pump (the only way to
// ever see a pong) plus a read deadline only a fresh pong pushes back, so a
// genuinely dead peer is noticed within wsPongWait instead of however long
// bare TCP takes.
const (
	wsWriteWait  = 10 * time.Second
	wsPongWait   = 30 * time.Second
	wsPingPeriod = (wsPongWait * 8) / 10
)

func wsKeepalive(conn *websocket.Conn, cancel context.CancelFunc) {
	conn.SetReadDeadline(time.Now().Add(wsPongWait))
	conn.SetPongHandler(func(string) error {
		conn.SetReadDeadline(time.Now().Add(wsPongWait))
		return nil
	})
	go func() {
		defer cancel()
		for {
			if _, _, err := conn.ReadMessage(); err != nil {
				return
			}
		}
	}()
}

// trafficWSHandler pushes {"up":N,"down":N} once a second -- bytes/sec deltas
// computed from Xray's cumulative counters, matching what Clash-API clients
// expect from GET /traffic (a streaming endpoint, not a snapshot).
func trafficWSHandler(xc *xrayClient) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer conn.Close()

		ctx, cancel := context.WithCancel(r.Context())
		defer cancel()
		wsKeepalive(conn, cancel)

		var last trafficTotals
		haveLast := false
		ticker := time.NewTicker(1 * time.Second)
		defer ticker.Stop()
		pingTicker := time.NewTicker(wsPingPeriod)
		defer pingTicker.Stop()

		for {
			select {
			case <-ctx.Done():
				return
			case <-pingTicker.C:
				conn.SetWriteDeadline(time.Now().Add(wsWriteWait))
				if err := conn.WriteMessage(websocket.PingMessage, nil); err != nil {
					return
				}
			case <-ticker.C:
				cur, err := xc.queryTraffic(ctx)
				if err != nil {
					continue
				}
				up, down := int64(0), int64(0)
				if haveLast {
					up, down = diffNonNeg(cur.Up, last.Up), diffNonNeg(cur.Down, last.Down)
				}
				last, haveLast = cur, true
				conn.SetWriteDeadline(time.Now().Add(wsWriteWait))
				if err := conn.WriteJSON(map[string]int64{"up": up, "down": down}); err != nil {
					return
				}
			}
		}
	}
}

func diffNonNeg(a, b int64) int64 {
	if a < b {
		return 0
	}
	return a - b
}
