package manager

import (
	"context"
	"time"
)

const (
	// HeartbeatTimeout is how long a worker can be silent before being declared dead.
	HeartbeatTimeout = 30 * time.Second
	// ReaperInterval is how often the Reaper wakes up to check for stale workers.
	ReaperInterval = 10 * time.Second
)

// Reaper is a background goroutine that scans for dead workers and
// re-queues their tasks so another worker can pick them up.
type Reaper struct {
	server *Server
}

// NewReaper creates a Reaper that watches the given server.
func NewReaper(s *Server) *Reaper {
	return &Reaper{server: s}
}

// Run starts the reaper loop. It blocks until ctx is cancelled.
func (r *Reaper) Run(ctx context.Context) {
	ticker := time.NewTicker(ReaperInterval)
	defer ticker.Stop()

	log.Info("Reaper started. Scanning every %s, timeout=%s.", ReaperInterval, HeartbeatTimeout)

	for {
		select {
		case <-ctx.Done():
			log.Info("Reaper shutting down.")
			return
		case <-ticker.C:
			r.sweep()
		}
	}
}

func (r *Reaper) sweep() {
	stalled := r.server.StalledWorkers(HeartbeatTimeout)
	if len(stalled) == 0 {
		return
	}
	log.Warn("Found %d stalled worker(s): %v", len(stalled), stalled)
	for _, id := range stalled {
		r.server.MarkWorkerDead(id)
	}
}
