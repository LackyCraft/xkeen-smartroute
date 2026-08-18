package main

import (
	"context"
	"log"
	"sync"
	"time"
)

// Why this file exists: the LuCI Profiles page wants to show a live "this
// profile is passing traffic right now" dot next to each profile -- e.g. the
// user is watching YouTube and the YouTube profile lights up green. That
// needs a signal that reacts within a couple of seconds, which rules out
// piggybacking on health.json (persisted to /etc/xkeen-smartroute/state,
// i.e. the router's own flash overlay, refreshed every 20s -- both too slow
// for "right now" and, if pushed to a 3-5s cadence instead, exactly the kind
// of constant-flash-write pattern already rejected once this project
// (loglevel:warning log-scraping, see AGENTS.md). So this state lives only
// in this process's memory, refreshed on its own fast ticker, and is served
// over the gateway's existing HTTP API (GET /activity) instead of a file --
// zero additional disk writes, whether the Profiles page is open or not.
const activityInterval = 3 * time.Second

// A tag counts as "active" if its traffic counters moved within this many
// ticks' worth of time -- a little over one interval so a single slow tick
// doesn't flicker a genuinely-active tag off.
const activityWindow = 8 * time.Second

var (
	activityMu   sync.Mutex
	activityLast = map[string]time.Time{}
)

func startActivityLoop(xc *xrayClient) {
	ticker := time.NewTicker(activityInterval)
	go func() {
		defer ticker.Stop()
		prev := map[string]trafficTotals{}
		for range ticker.C {
			prev = runActivityTick(xc, prev)
		}
	}()
}

func runActivityTick(xc *xrayClient, prev map[string]trafficTotals) map[string]trafficTotals {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	cur, err := xc.queryOutboundTrafficByTag(ctx)
	if err != nil {
		log.Printf("activity: queryOutboundTrafficByTag: %v", err)
		return prev
	}

	now := time.Now()
	activityMu.Lock()
	for tag, t := range cur {
		if p := prev[tag]; t.Up > p.Up || t.Down > p.Down {
			activityLast[tag] = now
		}
	}
	// Forget tags that have been quiet a long while so this map doesn't grow
	// forever across a subscription's full server history.
	for tag, at := range activityLast {
		if now.Sub(at) > 10*time.Minute {
			delete(activityLast, tag)
		}
	}
	activityMu.Unlock()

	return cur
}

// activeTagsSnapshot returns every outbound tag observed carrying traffic
// within activityWindow of now.
func activeTagsSnapshot() []string {
	now := time.Now()
	activityMu.Lock()
	defer activityMu.Unlock()
	out := make([]string, 0, len(activityLast))
	for tag, at := range activityLast {
		if now.Sub(at) <= activityWindow {
			out = append(out, tag)
		}
	}
	return out
}
