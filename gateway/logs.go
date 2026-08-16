package main

import (
	"bufio"
	"context"
	"net/http"
	"os"
	"time"
)

// Xray's own log files -- there's no LoggerService streaming API, so this
// tails the actual files the same way `tail -f` would. Polling instead of
// inotify: one process, two files, checked twice a second is plenty for a
// log viewer and needs no extra dependency.
const (
	accessLogPath = "/opt/var/log/xray/access.log"
	errorLogPath  = "/opt/var/log/xray/error.log"
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

		out := make(chan logLine, 64)
		go tailFile(ctx, accessLogPath, "access", out)
		go tailFile(ctx, errorLogPath, "error", out)

		for {
			select {
			case <-ctx.Done():
				return
			case l := <-out:
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

	open := func() bool {
		var err error
		f, err = os.Open(path)
		if err != nil {
			return false
		}
		fi, err := f.Stat()
		if err == nil {
			pos = fi.Size() // start at EOF, only stream *new* lines
		}
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
			if fi.Size() < pos {
				// truncated/rotated -- restart from the top of the new file
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
