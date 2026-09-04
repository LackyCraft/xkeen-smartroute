package main

import (
	"context"
	"encoding/json"
	"log"
	"os"
	"os/exec"
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
const failoverInterval = 20 * time.Second

// Built from srEtcDir (main.go), not hardcoded -- see its own comment for
// why (KeeneticOS's read-only /etc).
var healthStateFile = srEtcDir + "/state/health.json"

func startFailoverLoop(xc *xrayClient) {
	ticker := time.NewTicker(failoverInterval)
	go func() {
		defer ticker.Stop()
		st := &failoverState{prevAlive: map[string]bool{}}
		for range ticker.C {
			runFailoverTick(xc, st)
		}
	}()
}

// failoverState carries everything that needs to persist between ticks of
// the same ticker goroutine -- kept as one struct (instead of loose
// variables threaded through return values, the original wasFailing-only
// shape) once triggerFastRegenOnDeadPick needed its own carry-over state
// too.
type failoverState struct {
	wasFailing    bool
	prevAlive     map[string]bool // outbound tag -> alive, as of the previous tick
	lastRegenFast time.Time
}

// runFailoverTick logs a queryOutboundHealth failure only on the
// success->failure transition (and the reverse, on recovery), not on every
// tick -- on an install with no balancer-mode profile at all (the single
// most common real reason for this to fail: no
// 07_observatory.smartroute.json for ObservatoryService to report against,
// see lib/genroute.sh), this ran at failoverInterval forever, ~4300 log
// lines/day for a condition that was never going away and never needed
// repeating.
func runFailoverTick(xc *xrayClient, st *failoverState) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	health, err := xc.queryOutboundHealth(ctx)
	if err != nil {
		if !st.wasFailing {
			// Most commonly means no balancer-mode profile exists yet
			// (07_observatory.smartroute.json isn't written, see
			// lib/genroute.sh) so ObservatoryService has nothing to report
			// -- also logged here since it's just as likely to mean
			// ObservatoryService isn't enabled in 00_api.smartroute.json,
			// or Xray's API isn't reachable at all.
			log.Printf("failover: queryOutboundHealth: %v", err)
		}
		st.wasFailing = true
		return
	}
	if st.wasFailing {
		log.Printf("failover: queryOutboundHealth recovered")
	}
	st.wasFailing = false
	persistHealth(health)
	triggerFastRegenOnDeadPick(health, st)

	// reconcileBalancer (below, commented out) is currently dead: it patches
	// a gap in Xray's native `leastPing` balancer, but genroute.sh stopped
	// emitting `balancerTag` routing rules at all after finding that any
	// such rule breaks *every* routing rule's matching, not just the
	// balancer's own (XTLS/Xray-core#6642 -- see docs/functionality_doc/
	// balancer.md and gateway-telemetry.md for the full story). With no
	// `bal_<profile>` tag ever existing in Xray's live config anymore,
	// every call below would fail at its first line (GetBalancerInfo:
	// "app/router: cannot find tag") and return immediately having done
	// nothing -- confirmed live, this was pure log noise before being
	// disabled here. Left in place, commented, rather than deleted: if
	// #6642 is ever fixed upstream and balancerTag rules come back, this
	// reconciliation logic (and xray.go's getBalancerInfo/overrideBalancer,
	// which only this calls) is ready to re-enable as-is, no rewrite
	// needed -- just uncomment this block and reconcileBalancer below it.
	//
	// profiles, err := loadProfiles()
	// if err != nil {
	// 	log.Printf("failover: loadProfiles: %v", err)
	// 	return
	// }
	// for _, p := range profiles {
	// 	if p.Mode != "balancer" || len(p.Servers) == 0 {
	// 		continue
	// 	}
	// 	reconcileBalancer(ctx, xc, "bal_"+p.Name, p.Servers, health)
	// }
}

// regenFastCooldown rate-limits how often triggerFastRegenOnDeadPick can
// fire genroute.sh regen-fast -- each call still costs a real Xray restart
// (regen-fast only skips the fresh-ping pass, see genroute.sh's own
// comment), so a pool with no healthy candidate left at all doesn't restart
// Xray on every single failoverInterval tick forever.
const regenFastCooldown = 30 * time.Second

// triggerFastRegenOnDeadPick reacts the moment ObservatoryService flags a
// profile's *currently active* pick (current.json, written by
// lib/genroute.sh's sr_pick_top1) as dead, instead of waiting for the next
// plain 3-minute cron "regen" -- see genroute.sh's own regen-fast comment
// for why skipping the fresh ping pass here is correct (this call already
// has the fresh verdict that triggered it). Edge-triggered, not
// level-triggered: it only fires the tick a tag's alive state actually
// flips to false, not on every tick it stays that way -- a pool with
// nothing healthy left would otherwise trigger a restart every tick
// forever for no gain, since sr_pick_top1 has no better candidate to switch
// to either way.
func triggerFastRegenOnDeadPick(health map[string]outboundHealth, st *failoverState) {
	newAlive := make(map[string]bool, len(health))
	for tag, h := range health {
		newAlive[tag] = h.Alive
	}

	current, err := loadCurrent()
	if err != nil {
		st.prevAlive = newAlive
		return
	}

	deadNow := false
	for _, tag := range current {
		h, known := health[tag]
		if !known || h.Alive {
			continue
		}
		if wasAlive, seen := st.prevAlive[tag]; !seen || wasAlive {
			deadNow = true
		}
	}
	st.prevAlive = newAlive

	if !deadNow || time.Since(st.lastRegenFast) < regenFastCooldown {
		return
	}
	st.lastRegenFast = time.Now()
	go func() {
		if out, err := exec.Command("sh", genrouteScript, "regen-fast").CombinedOutput(); err != nil {
			log.Printf("failover: regen-fast: %v: %s", err, out)
		} else {
			log.Printf("failover: regen-fast triggered (an active pick went dead)")
		}
	}()
}

// reconcileBalancer -- DISABLED, see the comment in runFailoverTick above.
// Kept intact (not deleted) so it can be turned back on with a one-line
// change if XTLS/Xray-core#6642 is ever fixed upstream and genroute.sh
// starts emitting balancerTag rules again.
//
// func reconcileBalancer(ctx context.Context, xc *xrayClient, balancerTag string, candidates []string, health map[string]outboundHealth) {
// 	info, err := xc.getBalancerInfo(ctx, balancerTag)
// 	if err != nil {
// 		log.Printf("failover: getBalancerInfo(%s): %v", balancerTag, err)
// 		return
// 	}
//
// 	effective := info.Override
// 	if effective == "" {
// 		effective = info.PrincipleTarget
// 	}
// 	if effective != "" {
// 		h, known := health[effective]
// 		switch {
// 		case known && h.Alive:
// 			// Whichever mechanism is currently in charge (native leastPing
// 			// or our own earlier override) is pointed at a genuinely
// 			// healthy outbound -- leave it alone.
// 			return
// 		case !known:
// 			// Not probed yet -- right after a restart, before observatory's
// 			// first probe cycle, forcing a switch on no evidence would be
// 			// worse than waiting one tick.
// 			return
// 		}
// 		// known && !h.Alive: effective pick is confirmed dead, fall through
// 		// and take over.
// 	}
//
// 	best, bestDelay := "", int64(-1)
// 	for _, tag := range candidates {
// 		h, known := health[tag]
// 		if !known || !h.Alive {
// 			continue
// 		}
// 		if best == "" || h.DelayMs < bestDelay {
// 			best, bestDelay = tag, h.DelayMs
// 		}
// 	}
//
// 	switch {
// 	case best != "" && best != info.Override:
// 		if err := xc.overrideBalancer(ctx, balancerTag, best); err == nil {
// 			log.Printf("failover: %s -> %s (%dms) [was %q]", balancerTag, best, bestDelay, effective)
// 		}
// 	case best == "" && info.Override != "":
// 		// Nothing in the candidate list is currently alive per observatory.
// 		// Don't keep pinning to a target we already know is bad -- hand
// 		// back to leastPing, which is no worse off and will pick back up
// 		// automatically the moment observatory sees anything recover.
// 		if err := xc.overrideBalancer(ctx, balancerTag, ""); err == nil {
// 			log.Printf("failover: %s -> (cleared, nothing alive)", balancerTag)
// 		}
// 	}
// }

// persistHealth merges this tick's observatory data into health.json rather
// than overwriting it outright. Xray's own in-process observatory state
// resets to nothing on every restart (it's never persisted by Xray itself),
// so `health` here only ever contains tags the *current* Xray process has
// actually gotten around to re-probing since it started -- which, for a
// large subscription, is a small and slowly-growing subset for a long time
// after every restart (confirmed live: ~20-30s per outbound, so a ~160-node
// subscription takes the better part of an hour to fully re-cover). A plain
// overwrite would make every not-yet-re-probed tag's verdict vanish the
// instant Xray restarts, right when genroute.sh's sr_pick_top1 (and the
// LuCI Subscriptions page's health column) need it most. Keeping the old,
// on-disk entry for any tag this tick didn't report -- stale but real, and
// stamped with its own CheckedAt so callers can tell how old it is -- is
// strictly more useful than treating it the same as "never checked".
func persistHealth(health map[string]outboundHealth) {
	merged := map[string]outboundHealth{}
	if old, err := os.ReadFile(healthStateFile); err == nil {
		_ = json.Unmarshal(old, &merged)
	}
	for tag, h := range health {
		merged[tag] = h
	}

	// Prune entries for tags a subscription refresh has genuinely removed
	// -- gateway-telemetry.md calls this file "critically important" but
	// it never shrank, only ever grew: every server that ever existed
	// stayed in it forever, one stale entry per churned tag, accumulating
	// for the life of the router. This does NOT undo the merge above (the
	// whole point of which is keeping a tag's last-known verdict around
	// while Xray hasn't gotten around to re-probing it since its last
	// restart, which for a large subscription can take the better part of
	// an hour) -- only tags loadServers() no longer knows about at all get
	// dropped, never ones just pending re-probe.
	if servers, err := loadServers(); err == nil {
		live := make(map[string]struct{}, len(servers))
		for _, s := range servers {
			live[s.Tag] = struct{}{}
		}
		for tag := range merged {
			if _, ok := live[tag]; !ok {
				delete(merged, tag)
			}
		}
	}

	b, err := json.Marshal(merged)
	if err != nil {
		log.Printf("persistHealth: marshal: %v", err)
		return
	}
	// A power cut mid-write (this fires every 20s, all day) can leave a
	// direct os.WriteFile truncated or corrupt; the read above then
	// silently treats that as "no old data" (its own error is ignored too)
	// and overwrites with just the current tick's sparse data, discarding
	// everything Xray hadn't re-probed yet since its last restart -- which
	// is most of a large subscription, most of the time. Write to a temp
	// file in the same directory and rename over the target instead:
	// rename is atomic on the same filesystem, so the file on disk is
	// always either the complete old version or the complete new one,
	// never a partial write.
	tmp := healthStateFile + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		log.Printf("persistHealth: write %s: %v", tmp, err)
		return
	}
	if err := os.Rename(tmp, healthStateFile); err != nil {
		log.Printf("persistHealth: rename %s -> %s: %v", tmp, healthStateFile, err)
	}
}
