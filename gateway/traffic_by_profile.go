package main

import (
	"net/http"
)

type profileTraffic struct {
	Name string `json:"name"`
	Up   int64  `json:"up"`
	Down int64  `json:"down"`
}

// handleTrafficByProfile aggregates Xray's own per-outbound cumulative
// counters (the same ones activity.go already polls for the "online now"
// dot) up to profile level -- no new tracking loop needed, just a
// stateless read-and-sum on request. Cumulative since Xray's last start
// (not a rate), which is what the Home dashboard's "traffic by profile"
// bar chart wants: a relative share, not a live speed.
func handleTrafficByProfile(xc *xrayClient) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		byTag, err := xc.queryOutboundTrafficByTag(r.Context())
		if err != nil {
			writeErr(w, http.StatusBadGateway, err.Error())
			return
		}
		profiles, err := loadProfiles()
		if err != nil {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}

		out := make([]profileTraffic, 0, len(profiles))
		for _, p := range profiles {
			tags := p.Servers
			if p.Mode == "fixed" && p.FixedServer != "" {
				tags = []string{p.FixedServer}
			}
			var up, down int64
			for _, tag := range tags {
				t := byTag[tag]
				up += t.Up
				down += t.Down
			}
			out = append(out, profileTraffic{Name: p.Name, Up: up, Down: down})
		}
		writeJSON(w, http.StatusOK, out)
	}
}
