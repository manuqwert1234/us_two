package worker

import (
	"fmt"
	"os/exec"
	"strings"
)

// ExecuteDocker runs a command inside a Docker container.
// image: Docker image name (e.g., "python:3.11")
// command: command to run inside the container
// timeoutS: execution timeout in seconds (0 = unlimited)
func ExecuteDocker(image, command string, timeoutS int32) ExecutionResult {
	// Check if docker is available
	if _, err := exec.LookPath("docker"); err != nil {
		return ExecutionResult{
			Output:   "Docker not found on this worker. Falling back to shell execution.",
			ExitCode: 1,
			Err:      fmt.Errorf("docker not found: %w", err),
		}
	}

	// Build docker run command with resource limits
	args := []string{
		"run", "--rm",
		"--memory=512m",
		"--cpus=1.0",
		"--network=none", // security: no network by default
		"--pids-limit=256",
	}

	if timeoutS > 0 {
		args = append(args, fmt.Sprintf("--stop-timeout=%d", timeoutS))
	}

	args = append(args, image, "sh", "-c", command)

	// Wrap as a shell command so our existing Execute function handles it
	dockerCmd := fmt.Sprintf("docker %s", strings.Join(quoteArgs(args), " "))
	return Execute(dockerCmd, timeoutS)
}

// ParseDockerCommand checks if a command has a TITAN_DOCKER_IMAGE prefix
// and returns (image, actualCommand, isDocker).
func ParseDockerCommand(command string) (image string, actualCmd string, isDocker bool) {
	const prefix = "TITAN_DOCKER_IMAGE="
	if !strings.HasPrefix(command, prefix) {
		return "", command, false
	}
	// Format: TITAN_DOCKER_IMAGE=python:3.11 some command here
	rest := command[len(prefix):]
	parts := strings.SplitN(rest, " ", 2)
	if len(parts) < 2 {
		return parts[0], "", true
	}
	return parts[0], parts[1], true
}

func quoteArgs(args []string) []string {
	quoted := make([]string, len(args))
	for i, a := range args {
		if strings.Contains(a, " ") {
			quoted[i] = fmt.Sprintf("%q", a)
		} else {
			quoted[i] = a
		}
	}
	return quoted
}
