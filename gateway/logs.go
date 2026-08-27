package main

import (
	"bufio"
	"context"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

// Xray's own log files -- there's no LoggerService streaming API, so this
// tails the actual files the same way `tail -f` would. Polling instead of
// inotify: one process, two files, checked twice a second is plenty for a
// log viewer and needs no extra dependency.
//
// Logging itself is off by default and, when on, writes to tmpfs rather
// than flash -- see lib/common.sh's sr_apply_log_config (the single place
// that decides the path/loglevel Xray actually uses; keep this constant in
// sync with it). Path stays the same whether logging is on or off, only
// loglevel changes, so this file never needs to know which state it's in.
const (
	accessLogPath   = "/tmp/xray-logs/access.log"
	errorLogPath    = "/tmp/xray-logs/error.log"
	logCapMBFile    = "/etc/xkeen-smartroute/state/log_cap_mb"
	defaultLogCapMB = 10
)

type logLine struct {
	Type string `json:"type"` // "access" | "error"
	Line string `json:"payload"`
}

func logsWSHandler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer conn.Close()

		ctx, cancel := context.WithCancel(r.Context())
		defer cancel()
		wsKeepalive(conn, cancel)

		out := make(chan logLine, 64)
		go tailFile(ctx, accessLogPath, "access", out)
		go tailFile(ctx, errorLogPath, "error", out)

		pingTicker := time.NewTicker(wsPingPeriod)
		defer pingTicker.Stop()

		for {
			select {
			case <-ctx.Done():
				return
			case <-pingTicker.C:
				conn.SetWriteDeadline(time.Now().Add(wsWriteWait))
				if err := conn.WriteMessage(websocket.PingMessage, nil); err != nil {
					return
				}
			case l := <-out:
				conn.SetWriteDeadline(time.Now().Add(wsWriteWait))
				if err := conn.WriteJSON(l); err != nil {
					return
				}
			}
		}
	}
}

func tailFile(ctx context.Context, path, kind string, out chan<- logLine) {
	var f *os.File
	var pos int64
	var curInfo os.FileInfo

	open := func() bool {
		nf, err := os.Open(path)
		if err != nil {
			return false
		}
		fi, err := nf.Stat()
		if err != nil {
			nf.Close()
			return false
		}
		f, curInfo = nf, fi
		pos = fi.Size() // start at EOF, only stream *new* lines
		return true
	}

	for !open() {
		select {
		case <-ctx.Done():
			return
		case <-time.After(2 * time.Second):
		}
	}
	defer f.Close()

	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			fi, err := os.Stat(path)
			if err != nil {
				continue
			}
			if !os.SameFile(fi, curInfo) {
				// The path now resolves to a different inode than the
				// handle we have open -- the file was deleted and
				// recreated, not truncated in place. Nothing in this
				// project's own code does that today (sr_clear_logs and
				// enforceLogCap both truncate in place, see below), but a
				// tail -f that silently keeps reading a dead inode forever
				// the moment something else ever does rotate this file
				// (logrotate, a future feature, anything) is a latent bug
				// worth not having. Reopen fresh from the top of the new
				// file.
				if nf, err := os.Open(path); err == nil {
					f.Close()
					f, curInfo, pos = nf, fi, 0
				}
			}
			if fi.Size() < pos {
				// truncated in place (logging just got re-enabled, or the
				// size-cap loop below or a manual "clear logs" reset it)
				// -- restart from the top of the same file
				pos = 0
			}
			if fi.Size() == pos {
				continue
			}
			if _, err := f.Seek(pos, 0); err != nil {
				continue
			}
			scanner := bufio.NewScanner(f)
			scanner.Buffer(make([]byte, 64*1024), 1024*1024)
			for scanner.Scan() {
				select {
				case out <- logLine{Type: kind, Line: scanner.Text()}:
				case <-ctx.Done():
					return
				}
			}
			pos, _ = f.Seek(0, 1)
		}
	}
}

// startLogCapLoop enforces the configurable tmpfs size cap continuously,
// independent of whether anyone currently has the log viewer open -- the
// whole point is bounding RAM usage while logging is left on, not just
// while being watched. Runs unconditionally (cheap: two stats a tick) since
// checking "is logging even on" would just be one more file read of
// similar cost, and this needs to catch growth promptly right after
// someone flips the toggle on regardless.
func startLogCapLoop() {
	go func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for range ticker.C {
			capBytes := readLogCapMB() * 1024 * 1024
			enforceLogCap(accessLogPath, capBytes)
			enforceLogCap(errorLogPath, capBytes)
		}
	}()
}

func readLogCapMB() int64 {
	b, err := os.ReadFile(logCapMBFile)
	if err != nil {
		return defaultLogCapMB
	}
	n, err := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
	if err != nil || n <= 0 {
		return defaultLogCapMB
	}
	return n
}

func enforceLogCap(path string, capBytes int64) {
	fi, err := os.Stat(path)
	if err != nil || fi.Size() <= capBytes {
		return
	}
	// Truncate in place (not remove) so Xray's already-open file handle
	// keeps writing into the same inode -- see sr_clear_logs's identical
	// reasoning in lib/common.sh, this is the same operation for the same
	// reason, just triggered by size instead of a button.
	_ = os.Truncate(path, 0)
}
