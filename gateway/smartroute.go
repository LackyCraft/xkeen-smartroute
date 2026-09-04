package main

import (
	"encoding/json"
	"os"
)

// Mirrors the JSON shapes lib/subscription.sh and lib/genroute.sh already
// write to disk -- the gateway reads the same files the shell tooling and
// LuCI app use, so there is exactly one source of truth for server/profile
// state, not a second copy the gateway could drift out of sync with.

// Built from srEtcDir (main.go), not hardcoded -- see its own comment for
// why (KeeneticOS's read-only /etc).
var (
	serversFile = srEtcDir + "/state/servers.json"
	pingFile    = srEtcDir + "/state/ping.json"
	currentFile = srEtcDir + "/state/current.json"
	profilesDir = srEtcDir + "/profiles"
)

type srServer struct {
	Tag          string `json:"tag"`
	Name         string `json:"name"`
	Address      string `json:"address"`
	Port         int    `json:"port"`
	Protocol     string `json:"protocol"`
	Subscription string `json:"subscription"`
}

// srProfile is round-tripped through saveProfile (handlers.go's PUT
// /proxies/{group}, the Clash-API-style "pick a server" endpoint): loaded
// via loadProfiles, one field mutated (Mode/FixedServer), then the whole
// struct is re-marshaled and written back via genroute.sh save. Every field
// lib/genroute.sh's own profile schema can carry has to be listed here, or
// json.Unmarshal silently drops it on load and the re-marshal on save
// silently erases it from the file on disk -- confirmed missing here before:
// a profile scoped to specific devices or IP ranges (Devices/IPRanges) lost
// that restriction entirely (silently widened to match everything) the
// first time its server was changed through this endpoint, and
// RemovedServers (the "these disappeared in a subscription refresh"
// warning list genroute.sh/subscription.sh maintain) was wiped the same way.
type srProfile struct {
	Name         string `json:"name"`
	DomainSource struct {
		Type  string `json:"type"`
		Value string `json:"value"`
		File  string `json:"file"`
	} `json:"domain_source"`
	Mode           string   `json:"mode"` // "balancer" | "fixed"
	Servers        []string `json:"servers"`
	FixedServer    string   `json:"fixed_server"`
	Devices        []string `json:"devices,omitempty"`
	IPRanges       []string `json:"ip_ranges,omitempty"`
	RemovedServers []struct {
		Tag       string `json:"tag"`
		Name      string `json:"name"`
		RemovedAt string `json:"removed_at"`
	} `json:"removed_servers,omitempty"`
}

func loadServers() ([]srServer, error) {
	b, err := os.ReadFile(serversFile)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var out []srServer
	if len(b) == 0 {
		return nil, nil
	}
	if err := json.Unmarshal(b, &out); err != nil {
		return nil, err
	}
	return out, nil
}

func loadPings() (map[string]*int, error) {
	b, err := os.ReadFile(pingFile)
	if err != nil {
		if os.IsNotExist(err) {
			return map[string]*int{}, nil
		}
		return nil, err
	}
	out := map[string]*int{}
	if len(b) == 0 {
		return out, nil
	}
	if err := json.Unmarshal(b, &out); err != nil {
		return map[string]*int{}, nil
	}
	return out, nil
}

// loadCurrent reads current.json (profile name -> the outbound tag
// lib/genroute.sh's sr_pick_top1 most recently picked for it, written on
// every regen alongside routing.smartroute.json). For "fixed" mode this
// duplicates FixedServer; for "balancer" mode it's the only way to know
// which pool member is actually live right now, since that choice is made
// entirely in shell/jq and never reported back through Xray's own API.
func loadCurrent() (map[string]string, error) {
	b, err := os.ReadFile(currentFile)
	if err != nil {
		if os.IsNotExist(err) {
			return map[string]string{}, nil
		}
		return nil, err
	}
	out := map[string]string{}
	if len(b) == 0 {
		return out, nil
	}
	if err := json.Unmarshal(b, &out); err != nil {
		return map[string]string{}, nil
	}
	return out, nil
}

func loadProfiles() ([]srProfile, error) {
	entries, err := os.ReadDir(profilesDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var out []srProfile
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		b, err := os.ReadFile(profilesDir + "/" + e.Name())
		if err != nil {
			continue
		}
		var p srProfile
		if err := json.Unmarshal(b, &p); err != nil {
			continue
		}
		out = append(out, p)
	}
	return out, nil
}
