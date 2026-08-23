package main

import (
	"crypto/tls"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

// No Access-Control-Allow-Origin set here on purpose -- corsWrap (main.go)
// already sets it once, correctly, for every response this binary sends,
// after checking the Origin against the request's own Host. This used to
// also set a hardcoded wildcard here, silently overwriting corsWrap's
// value on every single JSON response in the whole API surface (Set
// replaces, it doesn't merge) -- confirmed live, this was the actual
// reason a same-origin-only corsWrap still measured as wide-open "*" on
// every real endpoint.
func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]interface{}{"success": false, "error": msg})
}

// --- /version ---

func handleVersion(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"version": "smartroute-gateway/0.1 (xray)",
		"premium": false,
		"meta":    true,
	})
}

// --- proxy model ---
//
// Clash's model is proxies (individual nodes) + groups (selectors that pick
// among proxies). SmartRoute's model is servers (individual nodes, same
// idea) + profiles (a domain list bound to either one fixed server or a
// pool SmartRoute's own sr_pick_top1 chooses from). Each profile becomes one
// Clash group here; each server becomes one Clash proxy. "now" on a
// balancer-mode group is read from current.json (see loadCurrent) -- the
// actual tag sr_pick_top1 most recently picked -- falling back to the
// synthetic "auto (leastPing)" marker only if that file doesn't have an
// entry for this profile yet (e.g. right after upgrading from an older
// install that never wrote one).

type clashProxy struct {
	Name    string        `json:"name"`
	Type    string        `json:"type"`
	UDP     bool          `json:"udp"`
	Now     string        `json:"now,omitempty"`
	All     []string      `json:"all,omitempty"`
	History []delayRecord `json:"history"`
}

type delayRecord struct {
	Time  string `json:"time"`
	Delay int    `json:"delay"`
}

func buildProxyMap() (map[string]clashProxy, error) {
	servers, err := loadServers()
	if err != nil {
		return nil, err
	}
	pings, _ := loadPings()
	current, _ := loadCurrent()
	profiles, err := loadProfiles()
	if err != nil {
		return nil, err
	}

	out := map[string]clashProxy{}
	var allNames []string
	for _, s := range servers {
		hist := []delayRecord{}
		if ms, ok := pings[s.Tag]; ok && ms != nil {
			hist = append(hist, delayRecord{Time: time.Now().UTC().Format(time.RFC3339), Delay: *ms})
		}
		out[s.Name] = clashProxy{Name: s.Name, Type: strings.ToUpper(s.Protocol), UDP: true, History: hist}
		allNames = append(allNames, s.Name)
	}

	tagToName := map[string]string{}
	for _, s := range servers {
		tagToName[s.Tag] = s.Name
	}

	for _, p := range profiles {
		now := "auto (leastPing)"
		if p.Mode == "fixed" {
			if n, ok := tagToName[p.FixedServer]; ok {
				now = n
			} else {
				now = p.FixedServer
			}
		} else if tag, ok := current[p.Name]; ok && tag != "" {
			if n, ok := tagToName[tag]; ok {
				now = n
			} else {
				now = tag
			}
		}
		names := make([]string, 0, len(p.Servers)+1)
		names = append(names, "auto (leastPing)")
		for _, tag := range p.Servers {
			if n, ok := tagToName[tag]; ok {
				names = append(names, n)
			}
		}
		out[p.Name] = clashProxy{Name: p.Name, Type: "Selector", UDP: true, Now: now, All: names, History: []delayRecord{}}
	}

	out["GLOBAL"] = clashProxy{Name: "GLOBAL", Type: "Selector", UDP: true, Now: "", All: allNames, History: []delayRecord{}}
	return out, nil
}

func handleProxies(w http.ResponseWriter, r *http.Request) {
	m, err := buildProxyMap()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"proxies": m})
}

func handleProxyByName(w http.ResponseWriter, r *http.Request, name string) {
	m, err := buildProxyMap()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	p, ok := m[name]
	if !ok {
		writeErr(w, http.StatusNotFound, "proxy not found")
		return
	}
	writeJSON(w, http.StatusOK, p)
}

// --- PUT /proxies/{group}: select a server within a profile's group ---
//
// Writes straight back through lib/genroute.sh, the one place that already
// knows how to turn a profile into routing.rules/balancers and restart Xray
// safely (config validation, self-managed restart -- see lib/common.sh). No
// second copy of that logic lives here.

type selectRequest struct {
	Name string `json:"name"`
}

func handleSelectProxy(w http.ResponseWriter, r *http.Request, groupName string) {
	var req selectRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, http.StatusBadRequest, "invalid body")
		return
	}

	profiles, err := loadProfiles()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	var target *srProfile
	for i := range profiles {
		if profiles[i].Name == groupName {
			target = &profiles[i]
			break
		}
	}
	if target == nil {
		writeErr(w, http.StatusNotFound, "profile not found")
		return
	}

	if req.Name == "auto (leastPing)" || req.Name == "" {
		target.Mode = "balancer"
		target.FixedServer = ""
	} else {
		servers, err := loadServers()
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		var tag string
		for _, s := range servers {
			if s.Name == req.Name {
				tag = s.Tag
				break
			}
		}
		if tag == "" {
			writeErr(w, http.StatusBadRequest, "unknown proxy name")
			return
		}
		target.Mode = "fixed"
		target.FixedServer = tag
	}

	if err := saveProfile(*target); err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func saveProfile(p srProfile) error {
	b, err := json.Marshal(p)
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp("", "sr-profile-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		return err
	}
	tmp.Close()

	cmd := exec.Command("sh", genrouteScript, "save", tmp.Name())
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("genroute save failed: %v: %s", err, out)
	}
	return nil
}

// --- GET /proxies/{name}/delay: plain TCP-connect latency, same technique
// as lib/subscription.sh's sr_ping_one (no real proxy handshake needed to
// know whether a node is reachable at all) ---

func handleDelay(w http.ResponseWriter, r *http.Request, name string) {
	timeoutMs := 3000
	if v := r.URL.Query().Get("timeout"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			timeoutMs = n
		}
	}

	servers, err := loadServers()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	var addr string
	for _, s := range servers {
		if s.Name == name {
			addr = net.JoinHostPort(s.Address, strconv.Itoa(s.Port))
			break
		}
	}
	if addr == "" {
		writeErr(w, http.StatusNotFound, "proxy not found")
		return
	}

	start := time.Now()
	d := &net.Dialer{Timeout: time.Duration(timeoutMs) * time.Millisecond}
	conn, err := tls.DialWithDialer(d, "tcp", addr, &tls.Config{InsecureSkipVerify: true})
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, "connect failed: "+err.Error())
		return
	}
	conn.Close()
	writeJSON(w, http.StatusOK, map[string]interface{}{"delay": int(time.Since(start).Milliseconds())})
}

// --- GET /connections: Xray's API doesn't track live per-connection
// metadata the way Mihomo's sniffer-based one does, only aggregate byte
// counters -- an honest empty list beats a fake one ---

func handleConnections(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"downloadTotal": 0, "uploadTotal": 0, "connections": []interface{}{}, "memory": 0,
	})
}

// --- GET /rules: mirror what lib/genroute.sh's sr_regen actually wrote ---

func handleRules(w http.ResponseWriter, r *http.Request) {
	profiles, err := loadProfiles()
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err.Error())
		return
	}
	type rule struct {
		Type    string `json:"type"`
		Payload string `json:"payload"`
		Proxy   string `json:"proxy"`
	}
	rules := []rule{}
	for _, p := range profiles {
		payload := p.DomainSource.Value
		if p.DomainSource.Type == "geosite" {
			payload = "geosite:" + payload
		} else {
			payload = p.DomainSource.File
		}
		rules = append(rules, rule{Type: "DOMAIN-SET", Payload: payload, Proxy: p.Name})
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{"rules": rules})
}

// --- GET /activity: outbound tags that have carried traffic in the last
// few seconds, for the LuCI Profiles page's live "online now" dot. See
// activity.go for why this is in-memory only, never written to disk. ---

func handleActivity(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]interface{}{"active": activeTagsSnapshot()})
}

func handleConfigs(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPatch {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"port": 0, "socks-port": 0, "mixed-port": 0, "allow-lan": false, "mode": "rule", "log-level": "info",
	})
}
