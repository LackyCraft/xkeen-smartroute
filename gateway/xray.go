package main

import (
	"context"
	"strings"
	"time"

	statscmd "github.com/xtls/xray-core/app/stats/command"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

// xrayClient wraps a single lazy gRPC connection to Xray's own API
// (127.0.0.1:10085, enabled via 00_api.smartroute.json). It's read-only for
// now: traffic totals via StatsService. Proxy *selection* doesn't go through
// Xray's HandlerService at all -- it goes through SmartRoute's own
// lib/genroute.sh (see selectProxy in main.go), which is the single place
// that already knows how to turn a choice into routing.rules/balancers and
// restart Xray safely. Two independent ways to mutate the same live routing
// config would drift out of sync with each other.
type xrayClient struct {
	conn  *grpc.ClientConn
	stats statscmd.StatsServiceClient
}

func newXrayClient(addr string) (*xrayClient, error) {
	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return nil, err
	}
	return &xrayClient{conn: conn, stats: statscmd.NewStatsServiceClient(conn)}, nil
}

func (x *xrayClient) Close() error { return x.conn.Close() }

type trafficTotals struct {
	Up, Down int64
}

// queryTraffic sums every "outbound>>>*>>>traffic>>>uplink/downlink" counter
// Xray tracks (enabled by the "system" block in 00_api.smartroute.json's
// policy) into one up/down pair -- good enough for the dashboard's live
// speed graph, which is the only thing that reads this today.
func (x *xrayClient) queryTraffic(ctx context.Context) (trafficTotals, error) {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	resp, err := x.stats.QueryStats(ctx, &statscmd.QueryStatsRequest{Pattern: "outbound>>>", Reset_: false})
	if err != nil {
		return trafficTotals{}, err
	}
	var t trafficTotals
	for _, s := range resp.GetStat() {
		name := s.GetName()
		switch {
		case strings.HasSuffix(name, ">>>traffic>>>uplink"):
			t.Up += s.GetValue()
		case strings.HasSuffix(name, ">>>traffic>>>downlink"):
			t.Down += s.GetValue()
		}
	}
	return t, nil
}
