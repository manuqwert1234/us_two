package manager

import (
	"context"
	"testing"

	pb "github.com/adithyanca/titan/proto"
)

func TestSubmitTask(t *testing.T) {
	s := NewServer()

	resp, err := s.SubmitTask(context.Background(), &pb.SubmitTaskRequest{
		Command:  "echo hello",
		TimeoutS: 10,
	})
	if err != nil {
		t.Fatalf("SubmitTask failed: %v", err)
	}
	if resp.TaskId == "" {
		t.Fatal("expected non-empty task ID")
	}
	if s.GetPendingCount() != 1 {
		t.Fatalf("expected 1 pending, got %d", s.GetPendingCount())
	}

	// Verify task record
	rec := s.GetTaskRecord(resp.TaskId)
	if rec == nil {
		t.Fatal("task record not found")
	}
	if rec.Task.Command != "echo hello" {
		t.Fatalf("expected command 'echo hello', got %q", rec.Task.Command)
	}
	if rec.Task.TimeoutS != 10 {
		t.Fatalf("expected timeout 10, got %d", rec.Task.TimeoutS)
	}
	if rec.Task.MaxRetries != DefaultMaxRetries {
		t.Fatalf("expected max_retries %d, got %d", DefaultMaxRetries, rec.Task.MaxRetries)
	}
	if rec.Task.Status != pb.TaskStatus_TASK_STATUS_PENDING {
		t.Fatalf("expected PENDING status, got %v", rec.Task.Status)
	}
}

func TestRegisterWorker(t *testing.T) {
	s := NewServer()

	resp, err := s.RegisterWorker(context.Background(), &pb.RegisterWorkerRequest{
		WorkerId: "w1",
		Address:  "localhost:8001",
	})
	if err != nil {
		t.Fatalf("RegisterWorker failed: %v", err)
	}
	if !resp.Accepted {
		t.Fatal("expected worker to be accepted")
	}
	if s.GetWorkerCount() != 1 {
		t.Fatalf("expected 1 worker, got %d", s.GetWorkerCount())
	}
}

func TestPulseAssignsTask(t *testing.T) {
	s := NewServer()
	ctx := context.Background()

	// Register a worker
	s.RegisterWorker(ctx, &pb.RegisterWorkerRequest{WorkerId: "w1", Address: "localhost:8001"})

	// Submit a task
	submitResp, _ := s.SubmitTask(ctx, &pb.SubmitTaskRequest{Command: "echo test", TimeoutS: 5})

	// Worker sends a heartbeat (IDLE) — should get the task assigned
	pulseResp, err := s.Pulse(ctx, &pb.PulseRequest{
		WorkerId: "w1",
		Status:   pb.WorkerStatus_WORKER_STATUS_IDLE,
	})
	if err != nil {
		t.Fatalf("Pulse failed: %v", err)
	}
	if !pulseResp.Ok {
		t.Fatal("expected Pulse ok=true")
	}
	if pulseResp.NewTask == nil {
		t.Fatal("expected a task assignment")
	}
	if pulseResp.NewTask.Id != submitResp.TaskId {
		t.Fatalf("expected task %s, got %s", submitResp.TaskId, pulseResp.NewTask.Id)
	}

	// Task should now be RUNNING
	rec := s.GetTaskRecord(submitResp.TaskId)
	if rec.Task.Status != pb.TaskStatus_TASK_STATUS_RUNNING {
		t.Fatalf("expected RUNNING, got %v", rec.Task.Status)
	}

	// No more pending
	if s.GetPendingCount() != 0 {
		t.Fatalf("expected 0 pending, got %d", s.GetPendingCount())
	}
}

func TestPulseBusyWorkerGetsNoTask(t *testing.T) {
	s := NewServer()
	ctx := context.Background()

	s.RegisterWorker(ctx, &pb.RegisterWorkerRequest{WorkerId: "w1", Address: "localhost:8001"})
	s.SubmitTask(ctx, &pb.SubmitTaskRequest{Command: "echo test"})

	// Worker sends BUSY pulse — should NOT get a task
	pulseResp, err := s.Pulse(ctx, &pb.PulseRequest{
		WorkerId:    "w1",
		Status:      pb.WorkerStatus_WORKER_STATUS_BUSY,
		CurrentTask: "some-other-task",
	})
	if err != nil {
		t.Fatalf("Pulse failed: %v", err)
	}
	if pulseResp.NewTask != nil {
		t.Fatal("expected no task assignment for busy worker")
	}
}

func TestReportTaskResult_Success(t *testing.T) {
	s := NewServer()
	ctx := context.Background()

	s.RegisterWorker(ctx, &pb.RegisterWorkerRequest{WorkerId: "w1", Address: "localhost:8001"})
	submitResp, _ := s.SubmitTask(ctx, &pb.SubmitTaskRequest{Command: "echo test"})

	// Assign task
	s.Pulse(ctx, &pb.PulseRequest{WorkerId: "w1", Status: pb.WorkerStatus_WORKER_STATUS_IDLE})

	// Report success
	_, err := s.ReportTaskResult(ctx, &pb.ReportTaskResultRequest{
		WorkerId: "w1",
		TaskId:   submitResp.TaskId,
		Success:  true,
		Output:   "test\n",
		ExitCode: 0,
	})
	if err != nil {
		t.Fatalf("ReportTaskResult failed: %v", err)
	}

	rec := s.GetTaskRecord(submitResp.TaskId)
	if rec.Task.Status != pb.TaskStatus_TASK_STATUS_COMPLETED {
		t.Fatalf("expected COMPLETED, got %v", rec.Task.Status)
	}
	if rec.Task.Output != "test\n" {
		t.Fatalf("expected output 'test\\n', got %q", rec.Task.Output)
	}
}

func TestReportTaskResult_FailureWithRetry(t *testing.T) {
	s := NewServer()
	ctx := context.Background()

	s.RegisterWorker(ctx, &pb.RegisterWorkerRequest{WorkerId: "w1", Address: "localhost:8001"})
	submitResp, _ := s.SubmitTask(ctx, &pb.SubmitTaskRequest{Command: "exit 1"})

	// Assign task
	s.Pulse(ctx, &pb.PulseRequest{WorkerId: "w1", Status: pb.WorkerStatus_WORKER_STATUS_IDLE})

	// Report failure — should trigger retry (retry_count 0 → 1, max is 3)
	s.ReportTaskResult(ctx, &pb.ReportTaskResultRequest{
		WorkerId: "w1",
		TaskId:   submitResp.TaskId,
		Success:  false,
		ExitCode: 1,
	})

	rec := s.GetTaskRecord(submitResp.TaskId)
	if rec.Task.Status != pb.TaskStatus_TASK_STATUS_PENDING {
		t.Fatalf("expected re-queued to PENDING, got %v", rec.Task.Status)
	}
	if rec.Task.RetryCount != 1 {
		t.Fatalf("expected retry_count=1, got %d", rec.Task.RetryCount)
	}
	if s.GetPendingCount() != 1 {
		t.Fatalf("expected 1 pending (re-queued), got %d", s.GetPendingCount())
	}
}

func TestReportTaskResult_MaxRetriesExceeded(t *testing.T) {
	s := NewServer()
	ctx := context.Background()

	s.RegisterWorker(ctx, &pb.RegisterWorkerRequest{WorkerId: "w1", Address: "localhost:8001"})
	submitResp, _ := s.SubmitTask(ctx, &pb.SubmitTaskRequest{Command: "exit 1"})

	// Simulate max retries
	for i := 0; i < DefaultMaxRetries; i++ {
		s.Pulse(ctx, &pb.PulseRequest{WorkerId: "w1", Status: pb.WorkerStatus_WORKER_STATUS_IDLE})
		s.ReportTaskResult(ctx, &pb.ReportTaskResultRequest{
			WorkerId: "w1",
			TaskId:   submitResp.TaskId,
			Success:  false,
			ExitCode: 1,
		})
	}

	rec := s.GetTaskRecord(submitResp.TaskId)
	if rec.Task.Status != pb.TaskStatus_TASK_STATUS_FAILED {
		t.Fatalf("expected FAILED after max retries, got %v", rec.Task.Status)
	}
	if rec.Task.RetryCount != int32(DefaultMaxRetries) {
		t.Fatalf("expected retry_count=%d, got %d", DefaultMaxRetries, rec.Task.RetryCount)
	}
}

func TestClusterStatus(t *testing.T) {
	s := NewServer()
	ctx := context.Background()

	s.RegisterWorker(ctx, &pb.RegisterWorkerRequest{WorkerId: "w1", Address: "localhost:8001"})
	s.RegisterWorker(ctx, &pb.RegisterWorkerRequest{WorkerId: "w2", Address: "localhost:8002"})
	s.SubmitTask(ctx, &pb.SubmitTaskRequest{Command: "echo 1"})
	s.SubmitTask(ctx, &pb.SubmitTaskRequest{Command: "echo 2"})

	// Assign one task
	s.Pulse(ctx, &pb.PulseRequest{WorkerId: "w1", Status: pb.WorkerStatus_WORKER_STATUS_IDLE})

	status, err := s.ClusterStatus(ctx, &pb.ClusterStatusRequest{})
	if err != nil {
		t.Fatalf("ClusterStatus failed: %v", err)
	}
	if len(status.Workers) != 2 {
		t.Fatalf("expected 2 workers, got %d", len(status.Workers))
	}
	if status.PendingTasks != 1 {
		t.Fatalf("expected 1 pending, got %d", status.PendingTasks)
	}
	if status.RunningTasks != 1 {
		t.Fatalf("expected 1 running, got %d", status.RunningTasks)
	}
}

func TestGetTask_NotFound(t *testing.T) {
	s := NewServer()
	_, err := s.GetTask(context.Background(), &pb.GetTaskRequest{TaskId: "nonexistent"})
	if err == nil {
		t.Fatal("expected error for nonexistent task")
	}
}

func TestListTasks_Filter(t *testing.T) {
	s := NewServer()
	ctx := context.Background()

	s.RegisterWorker(ctx, &pb.RegisterWorkerRequest{WorkerId: "w1", Address: "localhost:8001"})
	s.SubmitTask(ctx, &pb.SubmitTaskRequest{Command: "echo 1"})
	s.SubmitTask(ctx, &pb.SubmitTaskRequest{Command: "echo 2"})

	// Assign one
	s.Pulse(ctx, &pb.PulseRequest{WorkerId: "w1", Status: pb.WorkerStatus_WORKER_STATUS_IDLE})

	// List only PENDING
	resp, _ := s.ListTasks(ctx, &pb.ListTasksRequest{FilterStatus: pb.TaskStatus_TASK_STATUS_PENDING})
	if len(resp.Tasks) != 1 {
		t.Fatalf("expected 1 pending task, got %d", len(resp.Tasks))
	}

	// List all
	resp, _ = s.ListTasks(ctx, &pb.ListTasksRequest{FilterStatus: pb.TaskStatus_TASK_STATUS_UNKNOWN})
	if len(resp.Tasks) != 2 {
		t.Fatalf("expected 2 total tasks, got %d", len(resp.Tasks))
	}
}
