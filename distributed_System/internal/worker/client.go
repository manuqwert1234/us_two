package worker

import (
	"context"
	"fmt"
	"math"
	"sync/atomic"
	"time"

	"github.com/adithyanca/titan/internal/logger"
	pb "github.com/adithyanca/titan/proto"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

const (
	heartbeatInterval  = 10 * time.Second
	maxReconnectDelay  = 60 * time.Second
	initialBackoff     = 1 * time.Second
	maxConsecutiveFails = 5
)

var log = logger.New("Worker")

// Client wraps the gRPC connection and manages the worker lifecycle.
type Client struct {
	id            string
	managerAddr   string
	dialOpts      []grpc.DialOption
	conn          *grpc.ClientConn
	managerClient pb.ManagerServiceClient
	currentTask   atomic.Pointer[pb.Task] // safe for goroutine access
}

// NewClient creates a new Worker client with insecure credentials.
func NewClient(workerID, managerAddr string) *Client {
	return &Client{
		id:          workerID,
		managerAddr: managerAddr,
		dialOpts:    []grpc.DialOption{grpc.WithTransportCredentials(insecure.NewCredentials())},
	}
}

// NewClientWithOpts creates a Worker client with custom dial options (e.g., mTLS).
func NewClientWithOpts(workerID, managerAddr string, opts []grpc.DialOption) *Client {
	return &Client{
		id:          workerID,
		managerAddr: managerAddr,
		dialOpts:    opts,
	}
}

// Run connects to the Manager with automatic reconnection, registers,
// and starts the heartbeat + task loop. It blocks until ctx is cancelled.
func (c *Client) Run(ctx context.Context) error {
	for {
		if err := c.connectWithBackoff(ctx); err != nil {
			if ctx.Err() != nil {
				return nil // graceful shutdown
			}
			return err
		}

		if err := c.register(ctx); err != nil {
			log.Error("[%s] Registration failed: %v. Reconnecting...", c.id, err)
			c.conn.Close()
			continue
		}

		err := c.loop(ctx)
		c.conn.Close()

		if ctx.Err() != nil {
			log.Info("[%s] Shutting down gracefully.", c.id)
			return nil
		}

		log.Warn("[%s] Connection lost: %v. Reconnecting...", c.id, err)
		time.Sleep(initialBackoff)
	}
}

// connectWithBackoff tries to connect to the Manager with exponential backoff.
func (c *Client) connectWithBackoff(ctx context.Context) error {
	attempt := 0
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		delay := time.Duration(math.Min(
			float64(initialBackoff)*math.Pow(2, float64(attempt)),
			float64(maxReconnectDelay),
		))

		if attempt > 0 {
			log.Info("[%s] Reconnect attempt %d (backoff %s)...", c.id, attempt+1, delay)
			select {
			case <-time.After(delay):
			case <-ctx.Done():
				return ctx.Err()
			}
		}

		log.Info("[%s] Connecting to Manager at %s...", c.id, c.managerAddr)

		dialCtx, dialCancel := context.WithTimeout(ctx, 10*time.Second)
		dialOpts := append(c.dialOpts, grpc.WithBlock())
		conn, err := grpc.DialContext(
			dialCtx,
			c.managerAddr,
			dialOpts...,
		)
		dialCancel()

		if err != nil {
			log.Warn("[%s] Connection failed: %v", c.id, err)
			attempt++
			if attempt > 10 {
				return fmt.Errorf("failed to connect after %d attempts: %w", attempt, err)
			}
			continue
		}

		c.conn = conn
		c.managerClient = pb.NewManagerServiceClient(conn)
		log.Info("[%s] Connected.", c.id)
		return nil
	}
}

func (c *Client) register(ctx context.Context) error {
	resp, err := c.managerClient.RegisterWorker(ctx, &pb.RegisterWorkerRequest{
		WorkerId: c.id,
		Address:  c.id,
	})
	if err != nil {
		return err
	}
	if !resp.Accepted {
		return fmt.Errorf("registration rejected: %s", resp.Message)
	}
	log.Info("[%s] Registered. Manager says: %s", c.id, resp.Message)
	return nil
}

func (c *Client) loop(ctx context.Context) error {
	ticker := time.NewTicker(heartbeatInterval)
	defer ticker.Stop()

	consecutiveFails := 0

	for {
		select {
		case <-ctx.Done():
			return nil

		case <-ticker.C:
			var currentTask *pb.Task
			if t := c.currentTask.Load(); t != nil {
				currentTask = t
			}

			status := pb.WorkerStatus_WORKER_STATUS_IDLE
			currentTaskID := ""
			if currentTask != nil {
				status = pb.WorkerStatus_WORKER_STATUS_BUSY
				currentTaskID = currentTask.Id
			}

			resp, err := c.managerClient.Pulse(ctx, &pb.PulseRequest{
				WorkerId:    c.id,
				Status:      status,
				CurrentTask: currentTaskID,
			})
			if err != nil {
				consecutiveFails++
				log.Warn("[%s] Heartbeat failed (%d/%d): %v",
					c.id, consecutiveFails, maxConsecutiveFails, err)
				if consecutiveFails >= maxConsecutiveFails {
					return fmt.Errorf("lost connection after %d failed heartbeats", consecutiveFails)
				}
				continue
			}

			consecutiveFails = 0 // reset on success

			if !resp.Ok {
				log.Warn("[%s] Manager rejected pulse.", c.id)
				continue
			}

			// If the manager assigned a new task and we're free, execute it.
			if resp.NewTask != nil && currentTask == nil {
				c.currentTask.Store(resp.NewTask)
				go c.executeTask(ctx, resp.NewTask)
			}
		}
	}
}

func (c *Client) executeTask(ctx context.Context, t *pb.Task) {
	log.Info("[%s] Executing task %s: %q (timeout=%ds)", c.id, t.Id, t.Command, t.TimeoutS)

	// Check if this is a Docker task
	var result ExecutionResult
	if image, cmd, isDocker := ParseDockerCommand(t.Command); isDocker {
		log.Info("[%s] Docker mode: image=%s command=%q", c.id, image, cmd)
		result = ExecuteDocker(image, cmd, t.TimeoutS)
	} else {
		result = Execute(t.Command, t.TimeoutS)
	}

	success := result.ExitCode == 0 && result.Err == nil
	_, rerr := c.managerClient.ReportTaskResult(ctx, &pb.ReportTaskResultRequest{
		WorkerId: c.id,
		TaskId:   t.Id,
		Success:  success,
		Output:   result.Output,
		ExitCode: int32(result.ExitCode),
	})
	if rerr != nil {
		log.Error("[%s] Failed to report result for task %s: %v", c.id, t.Id, rerr)
	}

	if success {
		log.Info("[%s] Task %s done (exit=0).", c.id, t.Id)
	} else {
		log.Warn("[%s] Task %s failed (exit=%d).", c.id, t.Id, result.ExitCode)
	}

	c.currentTask.Store(nil)
}
