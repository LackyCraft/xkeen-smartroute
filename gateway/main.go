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
	"os"
	"time"

	"github.com/gorilla/websocket"
)

const genrouteScript = "/opt/share/xkeen-smartroute/lib/genroute.sh"

func main() {
	listenAddr := envOr("SR_GATEWAY_LISTEN", "0.0.0.0:9095")
	xrayAddr := envOr("SR_GATEWAY_XRAY_API", "127.0.0.1:10085")
	staticDir := envOr("SR_GATEWAY_STATIC_DIR", "")

	xc, err := newXrayClient(xrayAddr)
	if err != nil {
		log.Fatalf("xray client: %v", err)
	}
	defer xc.Close()

	mux := http.NewServeMux()

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
	mux.HandleFunc("OPTIONS /", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, PUT, PATCH, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "*")
	})

	if staticDir != "" {
		mux.Handle("/", http.FileServer(http.Dir(staticDir)))
	}

	log.Printf("smartroute-gateway listening on %s (xray api %s, static %q)", listenAddr, xrayAddr, staticDir)
	log.Fatal(http.ListenAndServe(listenAddr, corsWrap(mux)))
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func corsWrap(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		h.ServeHTTP(w, r)
	})
}

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
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

		var last trafficTotals
		haveLast := false
		ticker := time.NewTicker(1 * time.Second)
		defer ticker.Stop()

		for {
			select {
			case <-ctx.Done():
				return
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
