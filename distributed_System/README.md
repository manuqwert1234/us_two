# Titan: Distributed Task Orchestrator

Titan is a fault-tolerant, heartbeat-monitored distributed task orchestration system written in Go. It consists of a central Manager, multiple stateless Workers, and a command-line interface. Titan leverages gRPC and Protocol Buffers for high-performance communication and guarantees task completion even when underlying worker nodes fail abruptly.

## Architecture and Components

The system is composed of four primary components:

### 1. Manager (Control Plane)
The Manager acts as the central brain of the cluster. It receives task submissions from users, maintains a registry of active workers, and orchestrates the execution of tasks. Key responsibilities include:
*   Maintaining a thread-safe task queue.
*   Tracking worker state (Idle, Busy, Dead).
*   Assigning tasks to available workers via a pull-based "Pulse" heartbeat mechanism.
*   Enforcing timeout and retry policies.
*   Optionally handling Raft-based consensus for multi-manager high availability and PostgreSQL persistence for durable state.

### 2. Worker (Data Plane)
Workers are the execution engines. They connect to the Manager and request work. Key responsibilities include:
*   Connecting automatically to the Manager with exponential backoff on connection loss.
*   Sending periodic heartbeats (Pulses) to advertise availability.
*   Executing arbitrary shell commands or Docker containers as directed by the Manager.
*   Enforcing execution timeouts and capturing standard output, standard error, and exit codes.
*   Reporting results back to the control plane.

### 3. Reaper (Failure Detector)
Running as a background routine alongside the Manager, the Reaper monitors the health of the cluster.
*   It periodically sweeps the worker registry to check the `LastSeen` timestamp of every worker.
*   If a worker fails to send a heartbeat within a configurable threshold, the Reaper marks it as dead.
*   If a dead worker was executing a task, the Reaper immediately salvages the task and re-queues it for another worker to pick up, guaranteeing execution.

### 4. Command Line Interface (CLI)
The `titan` binary provides operator interactions with the cluster.
*   Task submission (`titan submit --command="..."`).
*   Configuring execution specifics like timeouts (`--timeout`), retry limits (`--max-retries`), and isolated environments (`--docker`).
*   Retrieving real-time cluster status, task lists, and detailed execution logs.

## Core Features and Guarantees

*   Fault Tolerance: Built to withstand unpredictable node failures. The Reaper guarantees that orphaned tasks are recovered and executed by surviving nodes.
*   Retry Policies: Commands that fail with non-zero exit codes are automatically retried according to a configurable maximum retry limit before being marked permanently failed.
*   Docker Execution: Tasks can execute simple shell commands or run within fully isolated Docker containers with strict resource limits (CPU, Memory, Network).
*   Mutual TLS (mTLS): All gRPC communications between the CLI, Manager, and Workers can be secured using TLS 1.3 with mandatory client certificate verification.
*   API Authentication: Request-level Bearer token verification via gRPC interceptors.
*   Web Dashboard: The Manager exposes a built-in, real-time web dashboard for visualizing cluster health, active workers, and task progression.
*   Persistence: State can be held entirely in-memory for ephemeral workloads, or backed by an automatically-migrated PostgreSQL database for persistent, durable execution records.

## Installation and Build

Ensure you have Go 1.21+ installed on your system.

To build all binaries:
```bash
make build
```
This produces three binaries in the `bin/` directory: `manager`, `worker`, and `titan` (the CLI).

To configure Mutual TLS (optional):
```bash
make certs
```
This will run a script to generate a local Certificate Authority (CA), alongside server and client certificates in the `certs/` directory.

## Running the Cluster

### Standard Mode
Start the Manager on the default port (50051):
```bash
./bin/manager
```
The web dashboard will automatically start on `http://localhost:8080`.

Start one or more Workers in new terminal windows:
```bash
./bin/worker --id=worker-01
./bin/worker --id=worker-02
```

### Advanced Modes

Enabling mTLS:
```bash
./bin/manager --tls
./bin/worker --tls
```

Enabling PostgreSQL Persistence:
```bash
./bin/manager --pg-dsn="postgres://user:password@localhost:5432/titan?sslmode=disable"
```

Enabling API Token Authentication:
```bash
./bin/manager --api-token="secret-token"
./bin/titan submit --command="echo hello" # Fails implicitly, needs token wiring or env variables configuration depending on user setup
```

## CLI Usage Examples

Submit a basic shell command:
```bash
./bin/titan submit --command="echo 'Hello Titan'"
```

Submit a command with a strict execution timeout and automatic retries:
```bash
./bin/titan submit --command="curl example.com" --timeout=5 --max-retries=3
```

Submit a task to execute within an isolated Docker container:
```bash
./bin/titan submit --command="python -c 'print(10 * 10)'" --docker=python:3.11
```

Check the real-time status of the cluster:
```bash
./bin/titan status
```

List all tasks in the system:
```bash
./bin/titan tasks
```

Retrieve detailed output and exit code for a specific task:
```bash
./bin/titan get --id=<task-id>
```

## Development and Testing

The repository includes a comprehensive `Makefile` mapped to a full CI pipeline.

Run static analysis and linting:
```bash
make vet
make lint
```

Run the unit test suite with the race detector enabled:
```bash
make test
```

Update Protocol Buffer definitions:
```bash
make proto
```

Using Docker Compose to bring up a local test environment:
```bash
docker-compose up --build
```

## License

This project is licensed under the MIT License.
