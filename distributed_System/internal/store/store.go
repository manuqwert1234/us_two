package store

import (
	pb "github.com/adithyanca/titan/proto"
)

// TaskStore abstracts persistence for tasks.
// The in-memory map-based store in server.go is the default.
// Swap in PostgresStore for durable persistence.
type TaskStore interface {
	// SaveTask creates or updates a task.
	SaveTask(task *pb.Task) error

	// GetTask retrieves a task by ID.
	GetTask(id string) (*pb.Task, error)

	// ListTasks returns all tasks, optionally filtered by status.
	// Pass TaskStatus_TASK_STATUS_UNKNOWN for no filter.
	ListTasks(filter pb.TaskStatus) ([]*pb.Task, error)

	// DeleteTask removes a task by ID.
	DeleteTask(id string) error
}

// WorkerStore abstracts persistence for worker records.
type WorkerStore interface {
	// SaveWorker creates or updates a worker.
	SaveWorker(worker *WorkerRecord) error

	// GetWorker retrieves a worker by ID.
	GetWorker(id string) (*WorkerRecord, error)

	// ListWorkers returns all workers.
	ListWorkers() ([]*WorkerRecord, error)

	// DeleteWorker removes a worker.
	DeleteWorker(id string) error
}

// WorkerRecord is the store representation of a worker.
type WorkerRecord struct {
	ID          string
	Address     string
	Status      int32  // maps to pb.WorkerStatus
	CurrentTask string
	LastSeen    int64  // unix timestamp
}
