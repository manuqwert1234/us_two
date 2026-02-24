package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"text/tabwriter"
	"time"

	pb "github.com/adithyanca/titan/proto"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

func main() {
	managerAddr := flag.String("manager", "localhost:50051", "Manager gRPC address")
	flag.Parse()

	if flag.NArg() == 0 {
		printUsage()
		os.Exit(1)
	}

	conn, err := grpc.Dial(
		*managerAddr,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		log.Fatalf("Failed to connect to Manager at %s: %v", *managerAddr, err)
	}
	defer conn.Close()

	client := pb.NewManagerServiceClient(conn)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	switch flag.Arg(0) {
	case "submit":
		handleSubmit(ctx, client)
	case "status":
		handleClusterStatus(ctx, client)
	case "tasks":
		handleListTasks(ctx, client)
	case "get":
		handleGetTask(ctx, client)
	default:
		fmt.Fprintf(os.Stderr, "Unknown command: %s\n", flag.Arg(0))
		printUsage()
		os.Exit(1)
	}
}

// ─── Subcommand handlers ──────────────────────────────────────────────────────

func handleSubmit(ctx context.Context, client pb.ManagerServiceClient) {
	fs := flag.NewFlagSet("submit", flag.ExitOnError)
	command := fs.String("command", "", "Shell command to execute (required)")
	timeout := fs.Int("timeout", 0, "Timeout in seconds (0 = unlimited)")
	maxRetries := fs.Int("max-retries", 0, "Max retries on failure (0 = server default of 3)")
	docker := fs.String("docker", "", "Docker image to run command in (empty = run as shell)")
	fs.Parse(flag.Args()[1:])

	if *command == "" {
		fmt.Fprintln(os.Stderr, "Error: --command is required")
		fs.Usage()
		os.Exit(1)
	}

	// If docker image specified, wrap command
	actualCommand := *command
	if *docker != "" {
		actualCommand = fmt.Sprintf("TITAN_DOCKER_IMAGE=%s %s", *docker, *command)
	}

	resp, err := client.SubmitTask(ctx, &pb.SubmitTaskRequest{
		Command:    actualCommand,
		TimeoutS:   int32(*timeout),
		MaxRetries: int32(*maxRetries),
	})
	if err != nil {
		log.Fatalf("SubmitTask failed: %v", err)
	}

	fmt.Printf("\n  ✓  %s\n\n", resp.Message)
	fmt.Printf("  Task ID    : %s\n", resp.TaskId)
	fmt.Printf("  Timeout    : %ds\n", *timeout)
	fmt.Printf("  Max Retries: %d (0=default)\n", *maxRetries)
	if *docker != "" {
		fmt.Printf("  Docker     : %s\n", *docker)
	}
	fmt.Printf("  Check      : titan get --id=%s\n\n", resp.TaskId)
}

func handleClusterStatus(ctx context.Context, client pb.ManagerServiceClient) {
	resp, err := client.ClusterStatus(ctx, &pb.ClusterStatusRequest{})
	if err != nil {
		log.Fatalf("ClusterStatus failed: %v", err)
	}

	fmt.Println("\n━━━  Titan Cluster Status  ━━━")
	fmt.Printf("  Pending  : %d\n", resp.PendingTasks)
	fmt.Printf("  Running  : %d\n", resp.RunningTasks)
	fmt.Printf("  Completed: %d\n", resp.CompletedTasks)
	fmt.Printf("  Failed   : %d\n\n", resp.FailedTasks)

	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "  WORKER ID\tSTATUS\tCURRENT TASK\tLAST SEEN")
	fmt.Fprintln(w, "  ─────────\t──────\t────────────\t─────────")
	for _, wk := range resp.Workers {
		lastSeen := time.Unix(wk.LastSeen, 0).Format("15:04:05")
		task := wk.CurrentTask
		if task == "" {
			task = "—"
		}
		fmt.Fprintf(w, "  %s\t%s\t%s\t%s\n",
			wk.WorkerId,
			workerStatusString(wk.Status),
			task,
			lastSeen,
		)
	}
	w.Flush()
	fmt.Println()
}

func handleListTasks(ctx context.Context, client pb.ManagerServiceClient) {
	resp, err := client.ListTasks(ctx, &pb.ListTasksRequest{
		FilterStatus: pb.TaskStatus_TASK_STATUS_UNKNOWN,
	})
	if err != nil {
		log.Fatalf("ListTasks failed: %v", err)
	}

	fmt.Println("\n━━━  Titan Tasks  ━━━")
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "  TASK ID\tSTATUS\tRETRY\tWORKER\tCOMMAND")
	fmt.Fprintln(w, "  ───────\t──────\t─────\t──────\t───────")
	for _, t := range resp.Tasks {
		wid := t.WorkerId
		if wid == "" {
			wid = "—"
		}
		cmd := t.Command
		if len(cmd) > 40 {
			cmd = cmd[:37] + "..."
		}
		fmt.Fprintf(w, "  %s\t%s\t%d/%d\t%s\t%s\n",
			t.Id[:8]+"...",
			taskStatusString(t.Status),
			t.RetryCount,
			t.MaxRetries,
			wid,
			cmd,
		)
	}
	w.Flush()
	fmt.Println()
}

func handleGetTask(ctx context.Context, client pb.ManagerServiceClient) {
	fs := flag.NewFlagSet("get", flag.ExitOnError)
	id := fs.String("id", "", "Task ID (required)")
	fs.Parse(flag.Args()[1:])

	if *id == "" {
		fmt.Fprintln(os.Stderr, "Error: --id is required")
		os.Exit(1)
	}

	resp, err := client.GetTask(ctx, &pb.GetTaskRequest{TaskId: *id})
	if err != nil {
		log.Fatalf("GetTask failed: %v", err)
	}
	t := resp.Task

	fmt.Printf("\n━━━  Task %s  ━━━\n", t.Id)
	fmt.Printf("  Command    : %s\n", t.Command)
	fmt.Printf("  Status     : %s\n", taskStatusString(t.Status))
	fmt.Printf("  Worker     : %s\n", t.WorkerId)
	fmt.Printf("  Timeout    : %ds\n", t.TimeoutS)
	fmt.Printf("  Retries    : %d / %d\n", t.RetryCount, t.MaxRetries)
	fmt.Printf("  Exit Code  : %d\n", t.ExitCode)
	if t.Output != "" {
		fmt.Printf("  Output     :\n%s\n", t.Output)
	}
	fmt.Println()
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

func workerStatusString(s pb.WorkerStatus) string {
	switch s {
	case pb.WorkerStatus_WORKER_STATUS_IDLE:
		return "IDLE"
	case pb.WorkerStatus_WORKER_STATUS_BUSY:
		return "BUSY"
	case pb.WorkerStatus_WORKER_STATUS_DEAD:
		return "DEAD"
	default:
		return "UNKNOWN"
	}
}

func taskStatusString(s pb.TaskStatus) string {
	switch s {
	case pb.TaskStatus_TASK_STATUS_PENDING:
		return "PENDING"
	case pb.TaskStatus_TASK_STATUS_RUNNING:
		return "RUNNING"
	case pb.TaskStatus_TASK_STATUS_COMPLETED:
		return "COMPLETED"
	case pb.TaskStatus_TASK_STATUS_FAILED:
		return "FAILED"
	default:
		return "UNKNOWN"
	}
}

func printUsage() {
	fmt.Println(`
Titan CLI — Distributed Task Orchestrator

Usage: titan [--manager=host:port] <command> [flags]

Commands:
  submit   --command="<cmd>" [options]   Submit a task to the cluster
  status                                 Show cluster / worker status
  tasks                                  List all tasks
  get      --id=<task-id>                Get details for a single task

Submit Options:
  --command="<cmd>"   Shell command to execute (required)
  --timeout=<s>       Timeout in seconds (0 = unlimited)
  --max-retries=<n>   Max retries on failure (0 = server default of 3)
  --docker=<image>    Docker image to run command in

Examples:
  titan submit --command="sleep 5"
  titan submit --command="echo hello" --timeout=30 --max-retries=5
  titan submit --command="python train.py" --docker=python:3.11
  titan status
  titan tasks
  titan get --id=<uuid>`)
}
