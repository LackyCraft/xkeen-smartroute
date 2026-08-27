package main

import (
	"context"
	"strings"
	"time"

	obscmd "github.com/xtls/xray-core/app/observatory/command"
	routercmd "github.com/xtls/xray-core/app/router/command"
	statscmd "github.com/xtls/xray-core/app/stats/command"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

// xrayClient wraps a single lazy gRPC connection to Xray's own API
// (127.0.0.1:10085, enabled via 00_api.smartroute.json). Traffic totals and
// health/failover data are read-only (StatsService, ObservatoryService).
// Proxy *selection* by the user doesn't go through Xray's HandlerService at
// all -- it goes through SmartRoute's own lib/genroute.sh (see selectProxy in
// main.go), which is the single place that already knows how to turn a
// choice into routing.rules/balancers and restart Xray safely. The one
// exception is failover.go's own automatic RoutingService.OverrideBalancerTarget
// calls, which react to observatory health rather than a user choice and
// never touch the on-disk profile files -- see failover.go for why that's a
// safe thing for this process to own.
type xrayClient struct {
	conn        *grpc.ClientConn
	stats       statscmd.StatsServiceClient
	observatory obscmd.ObservatoryServiceClient
	routing     routercmd.RoutingServiceClient
}

func newXrayClient(addr string) (*xrayClient, error) {
	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return nil, err
	}
	return &xrayClient{
		conn:        conn,
		stats:       statscmd.NewStatsServiceClient(conn),
		observatory: obscmd.NewObservatoryServiceClient(conn),
		routing:     routercmd.NewRoutingServiceClient(conn),
	}, nil
}

func (x *xrayClient) Close() error { return x.conn.Close() }

type trafficTotals struct {
	Up, Down int64
}

// queryTraffic sums queryOutboundTrafficByTag's per-tag breakdown into one
// up/down pair -- good enough for the dashboard's live speed graph, which is
// the only thing that reads this today. Deliberately not its own independent
// QueryStats call + parse loop: this and queryOutboundTrafficByTag used to
// each parse the identical "outbound>>>*>>>traffic>>>uplink/downlink" stat
// names separately, two copies of the same parsing logic for the same data.
func (x *xrayClient) queryTraffic(ctx context.Context) (trafficTotals, error) {
	byTag, err := x.queryOutboundTrafficByTag(ctx)
	if err != nil {
		return trafficTotals{}, err
	}
	var t trafficTotals
	for _, v := range byTag {
		t.Up += v.Up
		t.Down += v.Down
	}
	return t, nil
}

// queryOutboundTrafficByTag is the one place that actually calls
// StatsService and parses its response -- activity.go diffs this against
// the previous tick to tell which specific outbounds have actually carried
// traffic recently, which a single grand total (queryTraffic above) can't
// answer.
func (x *xrayClient) queryOutboundTrafficByTag(ctx context.Context) (map[string]trafficTotals, error) {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	resp, err := x.stats.QueryStats(ctx, &statscmd.QueryStatsRequest{Pattern: "outbound>>>", Reset_: false})
	if err != nil {
		return nil, err
	}
	out := map[string]trafficTotals{}
	for _, s := range resp.GetStat() {
		// "outbound>>>TAG>>>traffic>>>uplink" / "...>>>downlink"
		parts := strings.Split(s.GetName(), ">>>")
		if len(parts) != 4 {
			continue
		}
		t := out[parts[1]]
		switch parts[3] {
		case "uplink":
			t.Up += s.GetValue()
		case "downlink":
			t.Down += s.GetValue()
		}
		out[parts[1]] = t
	}
	return out, nil
}

// outboundHealth mirrors the fields of observatory's OutboundStatus that
// actually matter for failover decisions: whether the *real* probe request
// (routed through the outbound itself, REALITY handshake and all) succeeded,
// not just whether the bare TCP/TLS endpoint answers -- see failover.go for
// why that distinction is the entire point of this file existing.
//
// CheckedAt is ours, not Xray's -- stamped in persistHealth() at the moment
// this verdict was last actually refreshed by a live probe. It's what lets
// health.json keep serving a stale-but-real verdict across an Xray restart
// (see persistHealth) instead of the entry just vanishing, and lets the UI
// show the user how old a given answer is instead of presenting a
// hours-stale "alive" the same way as one from 20 seconds ago.
type outboundHealth struct {
	Alive     bool      `json:"alive"`
	DelayMs   int64     `json:"delay_ms"`
	LastError string    `json:"last_error,omitempty"`
	CheckedAt time.Time `json:"checked_at"`
}

// queryOutboundHealth returns every outbound observatory currently has an
// opinion on, keyed by outbound tag. An outbound absent from the map hasn't
// been probed yet (e.g. right after a restart, before the first
// probeInterval tick) -- callers must treat "absent" differently from
// "known dead", not default it to either.
func (x *xrayClient) queryOutboundHealth(ctx context.Context) (map[string]outboundHealth, error) {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	resp, err := x.observatory.GetOutboundStatus(ctx, &obscmd.GetOutboundStatusRequest{})
	if err != nil {
		return nil, err
	}
	now := time.Now()
	out := map[string]outboundHealth{}
	for _, s := range resp.GetStatus().GetStatus() {
		out[s.GetOutboundTag()] = outboundHealth{
			Alive:     s.GetAlive(),
			DelayMs:   s.GetDelay(),
			LastError: s.GetLastErrorReason(),
			CheckedAt: now,
		}
	}
	return out, nil
}

// balancerInfo is the pair of facts needed to decide whether a balancer
// needs our help: what leastPing would pick on its own (principleTarget),
// and what we've already forced it onto, if anything (override -- "" means
// no override, native strategy is in control).
type balancerInfo struct {
	Override        string
	PrincipleTarget string
}

func (x *xrayClient) getBalancerInfo(ctx context.Context, tag string) (balancerInfo, error) {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	resp, err := x.routing.GetBalancerInfo(ctx, &routercmd.GetBalancerInfoRequest{Tag: tag})
	if err != nil {
		return balancerInfo{}, err
	}
	info := balancerInfo{Override: resp.GetBalancer().GetOverride().GetTarget()}
	if tags := resp.GetBalancer().GetPrincipleTarget().GetTag(); len(tags) > 0 {
		info.PrincipleTarget = tags[0]
	}
	return info, nil
}

// overrideBalancer forces balancerTag to always resolve to target, bypassing
// its normal strategy (leastPing) entirely -- until called again with an
// empty target, which hands control back to that strategy. This is the same
// RPC `xray api bo` uses; see failover.go for why the gateway drives it
// itself instead of leaving it to leastPing.
func (x *xrayClient) overrideBalancer(ctx context.Context, balancerTag, target string) error {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	_, err := x.routing.OverrideBalancerTarget(ctx, &routercmd.OverrideBalancerTargetRequest{
		BalancerTag: balancerTag,
		Target:      target,
	})
	return err
}
