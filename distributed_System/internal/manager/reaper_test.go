package manager

import (
	"context"
	"testing"
	"time"

	pb "github.com/adithyanca/titan/proto"
)

func TestReaper_MarksDeadWorker(t *testing.T) {
	s := NewServer()
	ctx := context.Background()

	// Register a worker
	s.RegisterWorker(ctx, &pb.RegisterWorkerRequest{WorkerId: "w1", Address: "localhost:8001"})

	// Manually set the worker's LastSeen to 60 seconds ago (past the 30s threshold)
	s.mu.Lock()
	s.workers["w1"].LastSeen = time.Now().Add(-60 * time.Second)
	s.mu.Unlock()

	// Check stalled workers
	stalled := s.StalledWorkers(30 * time.Second)
	if len(stalled) != 1 {
		t.Fatalf("expected 1 stalled worker, got %d", len(stalled))
	}
	if stalled[0] != "w1" {
		t.Fatalf("expected worker 'w1', got %s", stalled[0])
	}

	// Mark dead
	s.MarkWorkerDead("w1")

	// Verify worker is now DEAD
	s.mu.RLock()
	w := s.workers["w1"]
	s.mu.RUnlock()
	if w.Status != pb.WorkerStatus_WORKER_STATUS_DEAD {
		t.Fatalf("expected DEAD, got %v", w.Status)
	}
}

func TestReaper_RequeuesTaskFromDeadWorker(t *testing.T) {
	s := NewServer()
	ctx := context.Background()

	s.RegisterWorker(ctx, &pb.RegisterWorkerRequest{WorkerId: "w1", Address: "localhost:8001"})
	submitResp, _ := s.SubmitTask(ctx, &pb.SubmitTaskRequest{Command: "sleep 100"})

	// Assign the task via Pulse
	s.Pulse(ctx, &pb.PulseRequest{WorkerId: "w1", Status: pb.WorkerStatus_WORKER_STATUS_IDLE})

	// Verify it's running
	rec := s.GetTaskRecord(submitResp.TaskId)
	if rec.Task.Status != pb.TaskStatus_TASK_STATUS_RUNNING {
		t.Fatalf("expected RUNNING, got %v", rec.Task.Status)
	}

	// Kill the worker
	s.MarkWorkerDead("w1")

	// Task should be back to PENDING
	rec = s.GetTaskRecord(submitResp.TaskId)
	if rec.Task.Status != pb.TaskStatus_TASK_STATUS_PENDING {
		t.Fatalf("expected PENDING after worker death, got %v", rec.Task.Status)
	}
	if rec.Task.RetryCount != 1 {
		t.Fatalf("expected retry_count=1, got %d", rec.Task.RetryCount)
	}
	if s.GetPendingCount() != 1 {
		t.Fatalf("expected 1 pending, got %d", s.GetPendingCount())
	}
}

func TestReaper_TaskFailsPermanentlyAfterMaxRetries(t *testing.T) {
	s := NewServer()
	ctx := context.Background()

	s.RegisterWorker(ctx, &pb.RegisterWorkerRequest{WorkerId: "w1", Address: "localhost:8001"})
	submitResp, _ := s.SubmitTask(ctx, &pb.SubmitTaskRequest{Command: "sleep 100"})

	// Exhaust retries via worker deaths
	for i := 0; i < DefaultMaxRetries; i++ {
		s.Pulse(ctx, &pb.PulseRequest{WorkerId: "w1", Status: pb.WorkerStatus_WORKER_STATUS_IDLE})
		s.MarkWorkerDead("w1")

		// Re-register the worker (it would reconnect in real life)
		s.mu.Lock()
		s.workers["w1"].Status = pb.WorkerStatus_WORKER_STATUS_IDLE
		s.workers["w1"].LastSeen = time.Now()
		s.mu.Unlock()
	}

	rec := s.GetTaskRecord(submitResp.TaskId)
	if rec.Task.Status != pb.TaskStatus_TASK_STATUS_FAILED {
		t.Fatalf("expected FAILED after %d retries, got %v", DefaultMaxRetries, rec.Task.Status)
	}
}

func TestReaper_IgnoresAlreadyDeadWorkers(t *testing.T) {
	s := NewServer()
	ctx := context.Background()

	s.RegisterWorker(ctx, &pb.RegisterWorkerRequest{WorkerId: "w1", Address: "localhost:8001"})

	// Mark dead first
	s.MarkWorkerDead("w1")

	// Set old timestamp
	s.mu.Lock()
	s.workers["w1"].LastSeen = time.Now().Add(-60 * time.Second)
	s.mu.Unlock()

	// Should NOT find already-dead workers
	stalled := s.StalledWorkers(30 * time.Second)
	if len(stalled) != 0 {
		t.Fatalf("expected 0 stalled (w1 is already DEAD), got %d", len(stalled))
	}
}

func TestReaper_ActiveWorkerNotStalled(t *testing.T) {
	s := NewServer()
	ctx := context.Background()

	s.RegisterWorker(ctx, &pb.RegisterWorkerRequest{WorkerId: "w1", Address: "localhost:8001"})

	// Worker just registered (LastSeen = now), should NOT be stalled
	stalled := s.StalledWorkers(30 * time.Second)
	if len(stalled) != 0 {
		t.Fatalf("expected 0 stalled workers, got %d", len(stalled))
	}
}

func TestReaper_RunSweep(t *testing.T) {
	s := NewServer()
	ctx := context.Background()

	s.RegisterWorker(ctx, &pb.RegisterWorkerRequest{WorkerId: "w1", Address: "localhost:8001"})

	// Make worker stale
	s.mu.Lock()
	s.workers["w1"].LastSeen = time.Now().Add(-60 * time.Second)
	s.mu.Unlock()

	// Create and run reaper once
	reaper := NewReaper(s)
	reaper.sweep()

	// Verify worker was marked dead
	s.mu.RLock()
	w := s.workers["w1"]
	s.mu.RUnlock()
	if w.Status != pb.WorkerStatus_WORKER_STATUS_DEAD {
		t.Fatalf("expected DEAD after sweep, got %v", w.Status)
	}
}
