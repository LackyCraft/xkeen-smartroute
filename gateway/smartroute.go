package main

import (
	"encoding/json"
	"os"
)

// Mirrors the JSON shapes lib/subscription.sh and lib/genroute.sh already
// write to disk -- the gateway reads the same files the shell tooling and
// LuCI app use, so there is exactly one source of truth for server/profile
// state, not a second copy the gateway could drift out of sync with.

const (
	serversFile = "/etc/xkeen-smartroute/state/servers.json"
	pingFile    = "/etc/xkeen-smartroute/state/ping.json"
	currentFile = "/etc/xkeen-smartroute/state/current.json"
	profilesDir = "/etc/xkeen-smartroute/profiles"
)

type srServer struct {
	Tag          string `json:"tag"`
	Name         string `json:"name"`
	Address      string `json:"address"`
	Port         int    `json:"port"`
	Protocol     string `json:"protocol"`
	Subscription string `json:"subscription"`
}

type srProfile struct {
	Name         string `json:"name"`
	DomainSource struct {
		Type  string `json:"type"`
		Value string `json:"value"`
		File  string `json:"file"`
	} `json:"domain_source"`
	Mode        string   `json:"mode"` // "balancer" | "fixed"
	Servers     []string `json:"servers"`
	FixedServer string   `json:"fixed_server"`
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
