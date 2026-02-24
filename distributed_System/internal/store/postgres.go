package store

import (
	"database/sql"
	"fmt"
	"time"

	"github.com/adithyanca/titan/internal/logger"
	pb "github.com/adithyanca/titan/proto"
	_ "github.com/lib/pq"
)

var log = logger.New("Postgres")

// PostgresStore implements TaskStore and WorkerStore with PostgreSQL.
type PostgresStore struct {
	db *sql.DB
}

// NewPostgresStore connects to PostgreSQL and initializes the schema.
func NewPostgresStore(dsn string) (*PostgresStore, error) {
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		return nil, fmt.Errorf("open postgres: %w", err)
	}

	db.SetMaxOpenConns(20)
	db.SetMaxIdleConns(5)
	db.SetConnMaxLifetime(5 * time.Minute)

	if err := db.Ping(); err != nil {
		return nil, fmt.Errorf("ping postgres: %w", err)
	}

	store := &PostgresStore{db: db}
	if err := store.migrate(); err != nil {
		return nil, fmt.Errorf("migrate: %w", err)
	}

	log.Info("Connected to PostgreSQL")
	return store, nil
}

// migrate creates tables if they don't exist.
func (s *PostgresStore) migrate() error {
	schema := `
	CREATE TABLE IF NOT EXISTS tasks (
		id          TEXT PRIMARY KEY,
		command     TEXT NOT NULL,
		status      INTEGER NOT NULL DEFAULT 1,
		worker_id   TEXT DEFAULT '',
		output      TEXT DEFAULT '',
		exit_code   INTEGER DEFAULT 0,
		timeout_s   INTEGER DEFAULT 0,
		retry_count INTEGER DEFAULT 0,
		max_retries INTEGER DEFAULT 3,
		created_at  BIGINT NOT NULL,
		updated_at  BIGINT NOT NULL
	);

	CREATE TABLE IF NOT EXISTS workers (
		id           TEXT PRIMARY KEY,
		address      TEXT NOT NULL,
		status       INTEGER NOT NULL DEFAULT 1,
		current_task TEXT DEFAULT '',
		last_seen    BIGINT NOT NULL
	);

	CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
	CREATE INDEX IF NOT EXISTS idx_workers_status ON workers(status);
	`
	_, err := s.db.Exec(schema)
	if err != nil {
		return fmt.Errorf("create schema: %w", err)
	}
	log.Info("Schema migrated successfully")
	return nil
}

// Close closes the database connection.
func (s *PostgresStore) Close() error {
	return s.db.Close()
}

// ─── TaskStore Implementation ────────────────────────────────────────────────

func (s *PostgresStore) SaveTask(task *pb.Task) error {
	_, err := s.db.Exec(`
		INSERT INTO tasks (id, command, status, worker_id, output, exit_code, timeout_s, retry_count, max_retries, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
		ON CONFLICT (id) DO UPDATE SET
			command = EXCLUDED.command,
			status = EXCLUDED.status,
			worker_id = EXCLUDED.worker_id,
			output = EXCLUDED.output,
			exit_code = EXCLUDED.exit_code,
			timeout_s = EXCLUDED.timeout_s,
			retry_count = EXCLUDED.retry_count,
			max_retries = EXCLUDED.max_retries,
			updated_at = EXCLUDED.updated_at
	`,
		task.Id, task.Command, int32(task.Status), task.WorkerId,
		task.Output, task.ExitCode, task.TimeoutS,
		task.RetryCount, task.MaxRetries, task.CreatedAt, task.UpdatedAt,
	)
	return err
}

func (s *PostgresStore) GetTask(id string) (*pb.Task, error) {
	row := s.db.QueryRow(`SELECT id, command, status, worker_id, output, exit_code, timeout_s, retry_count, max_retries, created_at, updated_at FROM tasks WHERE id = $1`, id)

	task := &pb.Task{}
	var status int32
	err := row.Scan(
		&task.Id, &task.Command, &status, &task.WorkerId,
		&task.Output, &task.ExitCode, &task.TimeoutS,
		&task.RetryCount, &task.MaxRetries, &task.CreatedAt, &task.UpdatedAt,
	)
	if err == sql.ErrNoRows {
		return nil, fmt.Errorf("task %s not found", id)
	}
	if err != nil {
		return nil, err
	}
	task.Status = pb.TaskStatus(status)
	return task, nil
}

func (s *PostgresStore) ListTasks(filter pb.TaskStatus) ([]*pb.Task, error) {
	var rows *sql.Rows
	var err error

	if filter == pb.TaskStatus_TASK_STATUS_UNKNOWN {
		rows, err = s.db.Query(`SELECT id, command, status, worker_id, output, exit_code, timeout_s, retry_count, max_retries, created_at, updated_at FROM tasks ORDER BY created_at DESC`)
	} else {
		rows, err = s.db.Query(`SELECT id, command, status, worker_id, output, exit_code, timeout_s, retry_count, max_retries, created_at, updated_at FROM tasks WHERE status = $1 ORDER BY created_at DESC`, int32(filter))
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var tasks []*pb.Task
	for rows.Next() {
		task := &pb.Task{}
		var status int32
		if err := rows.Scan(
			&task.Id, &task.Command, &status, &task.WorkerId,
			&task.Output, &task.ExitCode, &task.TimeoutS,
			&task.RetryCount, &task.MaxRetries, &task.CreatedAt, &task.UpdatedAt,
		); err != nil {
			return nil, err
		}
		task.Status = pb.TaskStatus(status)
		tasks = append(tasks, task)
	}
	return tasks, rows.Err()
}

func (s *PostgresStore) DeleteTask(id string) error {
	_, err := s.db.Exec(`DELETE FROM tasks WHERE id = $1`, id)
	return err
}

// ─── WorkerStore Implementation ─────────────────────────────────────────────

func (s *PostgresStore) SaveWorker(w *WorkerRecord) error {
	_, err := s.db.Exec(`
		INSERT INTO workers (id, address, status, current_task, last_seen)
		VALUES ($1, $2, $3, $4, $5)
		ON CONFLICT (id) DO UPDATE SET
			address = EXCLUDED.address,
			status = EXCLUDED.status,
			current_task = EXCLUDED.current_task,
			last_seen = EXCLUDED.last_seen
	`, w.ID, w.Address, w.Status, w.CurrentTask, w.LastSeen)
	return err
}

func (s *PostgresStore) GetWorker(id string) (*WorkerRecord, error) {
	row := s.db.QueryRow(`SELECT id, address, status, current_task, last_seen FROM workers WHERE id = $1`, id)
	w := &WorkerRecord{}
	err := row.Scan(&w.ID, &w.Address, &w.Status, &w.CurrentTask, &w.LastSeen)
	if err == sql.ErrNoRows {
		return nil, fmt.Errorf("worker %s not found", id)
	}
	return w, err
}

func (s *PostgresStore) ListWorkers() ([]*WorkerRecord, error) {
	rows, err := s.db.Query(`SELECT id, address, status, current_task, last_seen FROM workers`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var workers []*WorkerRecord
	for rows.Next() {
		w := &WorkerRecord{}
		if err := rows.Scan(&w.ID, &w.Address, &w.Status, &w.CurrentTask, &w.LastSeen); err != nil {
			return nil, err
		}
		workers = append(workers, w)
	}
	return workers, rows.Err()
}

func (s *PostgresStore) DeleteWorker(id string) error {
	_, err := s.db.Exec(`DELETE FROM workers WHERE id = $1`, id)
	return err
}
