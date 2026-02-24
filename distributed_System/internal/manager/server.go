package manager

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/adithyanca/titan/internal/logger"
	"github.com/adithyanca/titan/internal/store"
	pb "github.com/adithyanca/titan/proto"
)

const DefaultMaxRetries = 3

var log = logger.New("Manager")

// WorkerRecord tracks a registered worker's state.
type WorkerRecord struct {
	ID          string
	Address     string
	Status      pb.WorkerStatus
	CurrentTask string // task ID or ""
	LastSeen    time.Time
}

// TaskRecord holds the full lifecycle of a task.
type TaskRecord struct {
	Task           *pb.Task
	AssignedWorker string
}

// Server is the gRPC ManagerService implementation.
type Server struct {
	pb.UnimplementedManagerServiceServer

	mu           sync.RWMutex
	workers      map[string]*WorkerRecord // workerID → record
	tasks        map[string]*TaskRecord   // taskID   → record
	pending      []string                 // ordered queue of pending task IDs
	persistStore store.TaskStore          // optional durable store (nil = memory only)
}

// NewServer creates an in-memory Manager Server.
func NewServer() *Server {
	return &Server{
		workers: make(map[string]*WorkerRecord),
		tasks:   make(map[string]*TaskRecord),
	}
}

// NewServerWithStore creates a Manager Server with a pluggable persistent store.
// When set, tasks are written through to the store on every state change.
func NewServerWithStore(ts store.TaskStore) *Server {
	return &Server{
		workers:      make(map[string]*WorkerRecord),
		tasks:        make(map[string]*TaskRecord),
		persistStore: ts,
	}
}

// ─── Client-facing RPCs ──────────────────────────────────────────────────────

func (s *Server) SubmitTask(_ context.Context, req *pb.SubmitTaskRequest) (*pb.SubmitTaskResponse, error) {
	id := uuid.New().String()
	now := time.Now().Unix()

	maxRetries := int32(DefaultMaxRetries)
	if req.MaxRetries > 0 {
		maxRetries = req.MaxRetries
	}

	task := &pb.Task{
		Id:         id,
		Command:    req.Command,
		Status:     pb.TaskStatus_TASK_STATUS_PENDING,
		TimeoutS:   req.TimeoutS,
		MaxRetries: maxRetries,
		RetryCount: 0,
		CreatedAt:  now,
		UpdatedAt:  now,
	}

	s.mu.Lock()
	s.tasks[id] = &TaskRecord{Task: task}
	s.pending = append(s.pending, id)
	s.mu.Unlock()

	// Write-through to durable store if configured
	if s.persistStore != nil {
		if err := s.persistStore.SaveTask(task); err != nil {
			log.Warn("Failed to persist task %s to store: %v", id, err)
		}
	}

	log.Info("Task submitted: id=%s command=%q timeout=%ds max_retries=%d", id, req.Command, req.TimeoutS, maxRetries)
	return &pb.SubmitTaskResponse{
		TaskId:  id,
		Message: fmt.Sprintf("Task %s submitted. Status: PENDING.", id),
	}, nil
}

func (s *Server) GetTask(_ context.Context, req *pb.GetTaskRequest) (*pb.GetTaskResponse, error) {
	s.mu.RLock()
	rec, ok := s.tasks[req.TaskId]
	s.mu.RUnlock()
	if !ok {
		return nil, fmt.Errorf("task %s not found", req.TaskId)
	}
	return &pb.GetTaskResponse{Task: rec.Task}, nil
}

func (s *Server) ListTasks(_ context.Context, req *pb.ListTasksRequest) (*pb.ListTasksResponse, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var list []*pb.Task
	for _, rec := range s.tasks {
		if req.FilterStatus == pb.TaskStatus_TASK_STATUS_UNKNOWN || rec.Task.Status == req.FilterStatus {
			list = append(list, rec.Task)
		}
	}
	return &pb.ListTasksResponse{Tasks: list}, nil
}

func (s *Server) ClusterStatus(_ context.Context, _ *pb.ClusterStatusRequest) (*pb.ClusterStatusResponse, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var workers []*pb.WorkerInfo
	for _, w := range s.workers {
		workers = append(workers, &pb.WorkerInfo{
			WorkerId:    w.ID,
			Address:     w.Address,
			Status:      w.Status,
			CurrentTask: w.CurrentTask,
			LastSeen:    w.LastSeen.Unix(),
		})
	}

	var pending, running, completed, failed int32
	for _, rec := range s.tasks {
		switch rec.Task.Status {
		case pb.TaskStatus_TASK_STATUS_PENDING:
			pending++
		case pb.TaskStatus_TASK_STATUS_RUNNING:
			running++
		case pb.TaskStatus_TASK_STATUS_COMPLETED:
			completed++
		case pb.TaskStatus_TASK_STATUS_FAILED:
			failed++
		}
	}

	return &pb.ClusterStatusResponse{
		Workers:        workers,
		PendingTasks:   pending,
		RunningTasks:   running,
		CompletedTasks: completed,
		FailedTasks:    failed,
	}, nil
}

// ─── Worker-facing RPCs ──────────────────────────────────────────────────────

func (s *Server) RegisterWorker(_ context.Context, req *pb.RegisterWorkerRequest) (*pb.RegisterWorkerResponse, error) {
	s.mu.Lock()
	s.workers[req.WorkerId] = &WorkerRecord{
		ID:       req.WorkerId,
		Address:  req.Address,
		Status:   pb.WorkerStatus_WORKER_STATUS_IDLE,
		LastSeen: time.Now(),
	}
	s.mu.Unlock()

	log.Info("Worker registered: id=%s addr=%s", req.WorkerId, req.Address)
	return &pb.RegisterWorkerResponse{
		Accepted:           true,
		Message:            "Welcome to the cluster.",
		HeartbeatIntervalS: 10,
	}, nil
}

func (s *Server) Pulse(_ context.Context, req *pb.PulseRequest) (*pb.PulseResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	w, ok := s.workers[req.WorkerId]
	if !ok {
		return &pb.PulseResponse{Ok: false}, fmt.Errorf("unknown worker %s", req.WorkerId)
	}

	w.LastSeen = time.Now()
	w.Status = req.Status
	w.CurrentTask = req.CurrentTask

	// If the worker is idle, try to assign a pending task
	if req.Status == pb.WorkerStatus_WORKER_STATUS_IDLE && len(s.pending) > 0 {
		taskID := s.pending[0]
		s.pending = s.pending[1:]

		rec := s.tasks[taskID]
		rec.Task.Status = pb.TaskStatus_TASK_STATUS_RUNNING
		rec.Task.WorkerId = req.WorkerId
		rec.Task.UpdatedAt = time.Now().Unix()
		rec.AssignedWorker = req.WorkerId

		w.Status = pb.WorkerStatus_WORKER_STATUS_BUSY
		w.CurrentTask = taskID

		log.Info("Assigned task %s → worker %s (timeout=%ds, retry=%d/%d)",
			taskID, req.WorkerId, rec.Task.TimeoutS, rec.Task.RetryCount, rec.Task.MaxRetries)
		return &pb.PulseResponse{Ok: true, NewTask: rec.Task}, nil
	}

	return &pb.PulseResponse{Ok: true}, nil
}

func (s *Server) ReportTaskResult(_ context.Context, req *pb.ReportTaskResultRequest) (*pb.ReportTaskResultResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	rec, ok := s.tasks[req.TaskId]
	if !ok {
		return &pb.ReportTaskResultResponse{Ok: false}, fmt.Errorf("task %s not found", req.TaskId)
	}

	if req.Success {
		rec.Task.Status = pb.TaskStatus_TASK_STATUS_COMPLETED
		log.Info("Task %s COMPLETED (exit=%d, worker=%s)", req.TaskId, req.ExitCode, req.WorkerId)
	} else {
		// Check if we can retry
		rec.Task.RetryCount++
		if rec.Task.RetryCount < rec.Task.MaxRetries {
			rec.Task.Status = pb.TaskStatus_TASK_STATUS_PENDING
			rec.Task.WorkerId = ""
			rec.Task.UpdatedAt = time.Now().Unix()
			s.pending = append(s.pending, rec.Task.Id)
			log.Warn("Task %s FAILED (exit=%d). Retrying (%d/%d)...",
				req.TaskId, req.ExitCode, rec.Task.RetryCount, rec.Task.MaxRetries)
		} else {
			rec.Task.Status = pb.TaskStatus_TASK_STATUS_FAILED
			log.Error("Task %s FAILED permanently after %d retries (exit=%d)",
				req.TaskId, rec.Task.MaxRetries, req.ExitCode)
		}
	}
	rec.Task.Output = req.Output
	rec.Task.ExitCode = req.ExitCode
	rec.Task.UpdatedAt = time.Now().Unix()

	// Write-through to durable store if configured
	if s.persistStore != nil {
		if err := s.persistStore.SaveTask(rec.Task); err != nil {
			log.Warn("Failed to persist task %s update: %v", req.TaskId, err)
		}
	}

	// Free the worker
	if w, ok := s.workers[req.WorkerId]; ok {
		w.Status = pb.WorkerStatus_WORKER_STATUS_IDLE
		w.CurrentTask = ""
	}

	return &pb.ReportTaskResultResponse{Ok: true}, nil
}

// ─── Internal helpers (called by Reaper) ────────────────────────────────────

// MarkWorkerDead marks a worker as DEAD and re-queues its running task (if retries remain).
func (s *Server) MarkWorkerDead(workerID string) {
	s.mu.Lock()
	defer s.mu.Unlock()

	w, ok := s.workers[workerID]
	if !ok {
		return
	}

	w.Status = pb.WorkerStatus_WORKER_STATUS_DEAD

	if w.CurrentTask != "" {
		if rec, ok := s.tasks[w.CurrentTask]; ok {
			rec.Task.RetryCount++
			if rec.Task.RetryCount < rec.Task.MaxRetries {
				rec.Task.Status = pb.TaskStatus_TASK_STATUS_PENDING
				rec.Task.WorkerId = ""
				rec.Task.UpdatedAt = time.Now().Unix()
				s.pending = append([]string{rec.Task.Id}, s.pending...) // priority re-queue
				log.Warn("Worker %s DEAD. Re-queued task %s (retry %d/%d)",
					workerID, w.CurrentTask, rec.Task.RetryCount, rec.Task.MaxRetries)
			} else {
				rec.Task.Status = pb.TaskStatus_TASK_STATUS_FAILED
				rec.Task.UpdatedAt = time.Now().Unix()
				log.Error("Worker %s DEAD. Task %s FAILED permanently (no retries left)",
					workerID, w.CurrentTask)
			}
		}
		w.CurrentTask = ""
	} else {
		log.Warn("Worker %s declared DEAD (no active task)", workerID)
	}
}

// StalledWorkers returns IDs of workers whose last heartbeat is older than threshold.
func (s *Server) StalledWorkers(threshold time.Duration) []string {
	s.mu.RLock()
	defer s.mu.RUnlock()

	var dead []string
	cutoff := time.Now().Add(-threshold)
	for id, w := range s.workers {
		if w.Status != pb.WorkerStatus_WORKER_STATUS_DEAD && w.LastSeen.Before(cutoff) {
			dead = append(dead, id)
		}
	}
	return dead
}

// ─── Getters (for testing) ──────────────────────────────────────────────────

func (s *Server) GetWorkerCount() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.workers)
}

func (s *Server) GetPendingCount() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.pending)
}

func (s *Server) GetTaskRecord(taskID string) *TaskRecord {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.tasks[taskID]
}
