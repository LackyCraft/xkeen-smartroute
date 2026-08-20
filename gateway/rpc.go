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
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os/exec"
	"time"
)

const defaultRpcdScript = "/usr/libexec/rpcd/luci.xkeen-smartroute"

type rpcBridge struct {
	script  string
	methods map[string]struct{}
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
		return
	}
	var schema map[string]json.RawMessage
	if err := json.Unmarshal(out, &schema); err != nil {
		log.Printf("rpc bridge: method list from %s is not valid JSON: %v", b.script, err)
		return
	}
	methods := make(map[string]struct{}, len(schema))
	for name := range schema {
		methods[name] = struct{}{}
	}
	b.methods = methods
	log.Printf("rpc bridge: %d methods available via %s", len(methods), b.script)
}

func (b *rpcBridge) allowed(method string) bool {
	_, ok := b.methods[method]
	return ok
}

// call runs `sh <script> call <method>` with args piped to stdin, exactly
// how rpcd itself would invoke it -- same process, same environment
// expectations (PATH is set inside common.sh itself, see its own comment).
func (b *rpcBridge) call(ctx context.Context, method string, args json.RawMessage) (json.RawMessage, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "sh", b.script, "call", method)
	if len(args) > 0 {
		cmd.Stdin = bytes.NewReader(args)
	} else {
		cmd.Stdin = bytes.NewReader([]byte("{}"))
	}
	out, err := cmd.Output()
	if err != nil {
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
		out, err := b.call(r.Context(), method, args)
		if err != nil {
			writeErr(w, http.StatusBadGateway, "rpc_failed: "+err.Error())
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(out)
	}
}
