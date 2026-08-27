// The LuCI app's rpcd backend (luci-app-xkeen-smartroute/root/usr/libexec/
// rpcd/luci.xkeen-smartroute) is already a small, self-contained CLI: `list`
// prints a JSON method schema, `call <method>` reads JSON args from stdin
// and prints a JSON result -- ubus is just one way to reach it, not a
// requirement baked into the script itself. Exec'ing it directly gives this
// gateway the entire subscriptions/profiles/kill-switch/leak-protection
// surface LuCI already has, for free, with zero duplicated business logic
// and zero risk of the two UIs drifting apart -- both talk to the exact
// same shell functions.
//
// The allow-list below is read from the script's own `list` output at
// startup rather than hardcoded, so it can never go stale relative to the
// script; a method the script doesn't know about is rejected before exec
// ever runs, the same protection an allow-list would give without a second
// copy of the method names to maintain.
//
// "At startup" alone isn't enough, though -- confirmed live: this gateway
// runs as a long-lived process, entirely separate from the rpcd script it
// execs (a plain file on disk, redeployed independently -- see
// docs/functionality_doc/rpc-bridge.md). Adding a new method to the script
// without restarting this process left the new method permanently
// "unknown_method" here even though the script itself already handled it
// correctly, because the cached allow-list from process start never saw it.
// allowed() below self-heals instead: a miss triggers one re-read of the
// script's `list` output (rate-limited so a client hammering a genuinely
// bogus method name can't turn into a exec() flood) before actually
// rejecting, so a script redeploy takes effect without needing this
// process restarted too.
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os/exec"
	"strings"
	"sync"
	"time"
)

const defaultRpcdScript = "/usr/libexec/rpcd/luci.xkeen-smartroute"

// refreshCooldown bounds how often a cache-miss in allowed() can trigger a
// re-exec of the script's own `list` -- a genuinely unknown/typo'd method
// would otherwise re-trigger a fresh exec on every single request.
const refreshCooldown = 5 * time.Second

type rpcBridge struct {
	script string

	mu          sync.RWMutex
	methods     map[string]struct{}
	lastRefresh time.Time

	// refreshMu serializes refreshMethods itself (separate from mu, which
	// only protects the map/timestamp) -- allowed() below used to let every
	// concurrent cache-miss call refreshMethods independently, N concurrent
	// misses meaning N parallel `sh script list` execs against the same
	// script at once. Holding this for the whole refresh means the 2nd..Nth
	// caller blocks, then (after acquiring it) re-checks the now-current
	// state before ever considering its own redundant exec.
	refreshMu sync.Mutex
}

func newRPCBridge(script string) *rpcBridge {
	b := &rpcBridge{script: script, methods: map[string]struct{}{}}
	b.refreshMethods()
	return b
}

func (b *rpcBridge) refreshMethods() {
	out, err := exec.Command("sh", b.script, "list").Output()
	if err != nil {
		log.Printf("rpc bridge: could not read method list from %s: %v", b.script, err)
		// Still bump lastRefresh -- otherwise a script that's temporarily
		// broken/unreachable makes every single call see "stale" forever,
		// each one re-triggering its own exec attempt instead of backing
		// off for refreshCooldown like a normal failure would.
		b.mu.Lock()
		b.lastRefresh = time.Now()
		b.mu.Unlock()
		return
	}
	var schema map[string]json.RawMessage
	if err := json.Unmarshal(out, &schema); err != nil {
		log.Printf("rpc bridge: method list from %s is not valid JSON: %v", b.script, err)
		b.mu.Lock()
		b.lastRefresh = time.Now()
		b.mu.Unlock()
		return
	}
	methods := make(map[string]struct{}, len(schema))
	for name := range schema {
		methods[name] = struct{}{}
	}
	b.mu.Lock()
	b.methods = methods
	b.lastRefresh = time.Now()
	b.mu.Unlock()
	log.Printf("rpc bridge: %d methods available via %s", len(methods), b.script)
}

func (b *rpcBridge) allowed(method string) bool {
	b.mu.RLock()
	_, ok := b.methods[method]
	stale := time.Since(b.lastRefresh) > refreshCooldown
	b.mu.RUnlock()
	if ok || !stale {
		return ok
	}

	b.refreshMu.Lock()
	defer b.refreshMu.Unlock()
	// Another goroutine may have already refreshed while this one was
	// waiting for refreshMu -- re-check before doing a redundant exec.
	b.mu.RLock()
	_, ok = b.methods[method]
	stillStale := time.Since(b.lastRefresh) > refreshCooldown
	b.mu.RUnlock()
	if ok || !stillStale {
		return ok
	}

	b.refreshMethods()
	b.mu.RLock()
	_, ok = b.methods[method]
	b.mu.RUnlock()
	return ok
}

// call runs `sh <script> call <method>` with args piped to stdin, exactly
// how rpcd itself would invoke it -- same process, same environment
// expectations (PATH is set inside common.sh itself, see its own comment).
//
// callTimeout is deliberately generous, not the 30s this used to be: a
// real refresh_subscription/import_subscription/ping_servers on a
// 150-200 server subscription routinely runs well past 30s on this
// hardware -- a fetch, a full parse, up to 20 sequential
// validate-strip-retry cycles for XHTTP nodes with a rejected "extra"
// combination (_sr_xray_validate in lib/common.sh, each cycle a real
// `xray run -test` over the whole confdir), then a real Xray restart.
// Confirmed live: exec.CommandContext SIGKILLs the shell the instant the
// context expires, mid-write between servers.json and
// 04_outbounds.smartroute.json -- which orphans lib/subscription.sh's
// own import lock (its EXIT trap never runs on SIGKILL) and leaves the
// two files inconsistent (servers.json updated, Xray's actual outbound
// list stuck on the old count) until the lock's own 300s staleness
// timeout lets a later attempt reclaim it. A 30s ceiling here was
// actively causing the exact "subscription won't update" symptom it
// looks like from the panel. sr_ping_all's own sequential per-server
// probe (subscription.sh, 3s timeout each) is the other genuinely slow
// method this needs to accommodate -- worst case ~150 servers x 3s.
const callTimeout = 10 * time.Minute

// call deliberately roots its context in context.Background(), never in the
// HTTP request's own r.Context() -- confirmed live: a client that closes the
// tab, navigates away, or just loses the LAN link mid subscription-refresh
// cancels r.Context() the instant the connection drops, and that used to
// propagate straight into this exec.CommandContext, SIGKILLing the shell for
// the exact same reason callTimeout above was widened from 30s: the script's
// own EXIT trap (its import lock cleanup) never runs on SIGKILL, leaving
// servers.json and 04_outbounds.smartroute.json inconsistent until the
// lock's 300s staleness timeout expires. A dropped connection is not a
// reason to abort a write that's already in progress -- the script runs to
// completion either way, bounded only by callTimeout; handleRPC below simply
// finds it has no live connection left to write the response to.
func (b *rpcBridge) call(method string, args json.RawMessage) (json.RawMessage, error) {
	ctx, cancel := context.WithTimeout(context.Background(), callTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "sh", b.script, "call", method)
	if len(args) > 0 {
		cmd.Stdin = bytes.NewReader(args)
	} else {
		cmd.Stdin = bytes.NewReader([]byte("{}"))
	}
	out, err := cmd.Output()
	if err != nil {
		// cmd.Output() does capture stderr into err.(*exec.ExitError).Stderr,
		// but err.Error() alone never includes it -- just "exit status N",
		// completely undiagnosable for exactly the methods most likely to
		// fail in an interesting way (refresh/import/save, the long-running
		// ones handleRPC exists to bridge in the first place). handlers.go's
		// saveProfile already surfaces its own script's stderr via
		// CombinedOutput; do the same here, just without mixing stderr into
		// the stdout bytes returned on the success path above (those have
		// to stay clean JSON).
		if ee, ok := err.(*exec.ExitError); ok && len(ee.Stderr) > 0 {
			return nil, fmt.Errorf("%v: %s", err, strings.TrimSpace(string(ee.Stderr)))
		}
		return nil, err
	}
	return json.RawMessage(out), nil
}

// handleRPC bridges POST /api/call/{method} to the script above. Every
// method the script exposes is reachable this way -- read and write alike
// -- since the script itself is the same trust boundary rpcd already
// enforces for LuCI; this gateway runs with equivalent privilege already
// (it manages xray/servers.json/profiles directly elsewhere in this
// codebase).
func handleRPC(b *rpcBridge) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		method := r.PathValue("method")
		if !b.allowed(method) {
			writeErr(w, http.StatusNotFound, "unknown_method")
			return
		}
		var args json.RawMessage
		if r.Body != nil {
			body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
			if err == nil && len(body) > 0 {
				args = json.RawMessage(body)
			}
		}
		out, err := b.call(method, args)
		if err != nil {
			writeErr(w, http.StatusBadGateway, "rpc_failed: "+err.Error())
			return
		}
		// No Access-Control-Allow-Origin here -- see writeJSON's comment in
		// handlers.go for why (corsWrap already set the correct value; a
		// second hardcoded wildcard here would silently override it, same
		// bug, same fix).
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(out)
	}
}
