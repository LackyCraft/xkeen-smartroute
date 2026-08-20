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
//
// A balancer-mode profile's own .servers is its whole *candidate pool*
// (10-50 tags), not what it's actually routing through right now -- and
// pools genuinely overlap across profiles in practice (confirmed live:
// this project's own test subscription has the same server picked as a
// candidate by three different profiles at once). Summing the whole pool
// would double- or triple-count that shared server's traffic into every
// profile that merely lists it as a candidate, not just the one actually
// using it. current.json (loadCurrent, the same file the Profiles table's
// "online now" dot and target column already key off) has the one tag
// sr_pick_top1 actually chose -- that, and only that, is what counts as
// "this profile's" traffic for a balancer-mode profile.
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
		current, err := loadCurrent()
		if err != nil {
			current = map[string]string{}
		}

		out := make([]profileTraffic, 0, len(profiles))
		for _, p := range profiles {
			tag := p.FixedServer
			if p.Mode != "fixed" {
				tag = current[p.Name]
			}
			t := byTag[tag]
			out = append(out, profileTraffic{Name: p.Name, Up: t.Up, Down: t.Down})
		}
		writeJSON(w, http.StatusOK, out)
	}
}
