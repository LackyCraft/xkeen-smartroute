package main

import (
	"context"
	"encoding/json"
	"log"
	"os"
	"time"
)

// Why this file exists: Xray's own `leastPing` balancer strategy relies on
// its `observatory` feature to know which outbound is actually healthy, but
// observatory's own probe result doesn't reliably stop leastPing from
// picking (or staying on) an outbound observatory has already flagged dead
// -- a known, unresolved gap in Xray-core itself (XTLS/Xray-core#5295).
// Concretely: a REALITY server can fail its real protocol handshake
// ("received real certificate (potential MITM or redirection)") while still
// answering the bare probeUrl-through-a-dead-outbound-check-that-never-runs
// -- Xray never demotes it, and every new connection into that balancer
// keeps landing on the broken server until Xray itself restarts.
//
// Rather than wait on an upstream fix, this loop reads the same health data
// leastPing is supposed to act on (ObservatoryService.GetOutboundStatus --
// real per-outbound alive/delay from a probe request actually routed
// through that outbound, REALITY handshake included) and, when the
// balancer's current pick (native or a previous override of ours) isn't
// alive, force it onto the fastest outbound observatory *does* currently
// believe is alive (RoutingService.OverrideBalancerTarget) -- exactly what
// the user expects "leastPing" to already do. When our own override target
// itself goes bad, or a previously-dead pick recovers, the loop notices on
// the next tick and adjusts. Nothing here writes to profiles/*.json or any
// Xray config file -- it only calls the same override RPC `xray api bo`
// uses, so SmartRoute's on-disk state (the source of truth genroute.sh
// reads) never drifts from what's actually running.
const (
	failoverInterval = 20 * time.Second
	healthStateFile  = "/etc/xkeen-smartroute/state/health.json"
)

func startFailoverLoop(xc *xrayClient) {
	ticker := time.NewTicker(failoverInterval)
	go func() {
		defer ticker.Stop()
		for range ticker.C {
			runFailoverTick(xc)
		}
	}()
}

func runFailoverTick(xc *xrayClient) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	health, err := xc.queryOutboundHealth(ctx)
	if err != nil {
		// Most commonly means no balancer-mode profile exists yet
		// (07_observatory.smartroute.json isn't written, see
		// lib/genroute.sh) so ObservatoryService has nothing to report --
		// still logged (at a low volume, once per tick) since it's just as
		// likely to mean ObservatoryService isn't enabled in
		// 00_api.smartroute.json, or Xray's API isn't reachable at all.
		log.Printf("failover: queryOutboundHealth: %v", err)
		return
	}
	persistHealth(health)

	profiles, err := loadProfiles()
	if err != nil {
		log.Printf("failover: loadProfiles: %v", err)
		return
	}

	for _, p := range profiles {
		if p.Mode != "balancer" || len(p.Servers) == 0 {
			continue
		}
		reconcileBalancer(ctx, xc, "bal_"+p.Name, p.Servers, health)
	}
}

func reconcileBalancer(ctx context.Context, xc *xrayClient, balancerTag string, candidates []string, health map[string]outboundHealth) {
	info, err := xc.getBalancerInfo(ctx, balancerTag)
	if err != nil {
		log.Printf("failover: getBalancerInfo(%s): %v", balancerTag, err)
		return
	}

	effective := info.Override
	if effective == "" {
		effective = info.PrincipleTarget
	}
	if effective != "" {
		h, known := health[effective]
		switch {
		case known && h.Alive:
			// Whichever mechanism is currently in charge (native leastPing
			// or our own earlier override) is pointed at a genuinely
			// healthy outbound -- leave it alone.
			return
		case !known:
			// Not probed yet -- right after a restart, before observatory's
			// first probe cycle, forcing a switch on no evidence would be
			// worse than waiting one tick.
			return
		}
		// known && !h.Alive: effective pick is confirmed dead, fall through
		// and take over.
	}

	best, bestDelay := "", int64(-1)
	for _, tag := range candidates {
		h, known := health[tag]
		if !known || !h.Alive {
			continue
		}
		if best == "" || h.DelayMs < bestDelay {
			best, bestDelay = tag, h.DelayMs
		}
	}

	switch {
	case best != "" && best != info.Override:
		if err := xc.overrideBalancer(ctx, balancerTag, best); err == nil {
			log.Printf("failover: %s -> %s (%dms) [was %q]", balancerTag, best, bestDelay, effective)
		}
	case best == "" && info.Override != "":
		// Nothing in the candidate list is currently alive per observatory.
		// Don't keep pinning to a target we already know is bad -- hand
		// back to leastPing, which is no worse off and will pick back up
		// automatically the moment observatory sees anything recover.
		if err := xc.overrideBalancer(ctx, balancerTag, ""); err == nil {
			log.Printf("failover: %s -> (cleared, nothing alive)", balancerTag)
		}
	}
}

func persistHealth(health map[string]outboundHealth) {
	b, err := json.Marshal(health)
	if err != nil {
		return
	}
	_ = os.WriteFile(healthStateFile, b, 0o644)
}
