package worker

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"time"
)

// ExecutionResult holds the output of a completed task.
type ExecutionResult struct {
	Output   string
	ExitCode int
	Err      error
}

// Execute runs the given shell command, optionally capped to timeoutS seconds.
// It returns stdout+stderr combined and the exit code.
func Execute(command string, timeoutS int32) ExecutionResult {
	ctx := context.Background()
	var cancel context.CancelFunc

	if timeoutS > 0 {
		ctx, cancel = context.WithTimeout(ctx, time.Duration(timeoutS)*time.Second)
		defer cancel()
	}

	// Run via shell so the full command string (pipes, redirects, etc.) works.
	cmd := exec.CommandContext(ctx, "sh", "-c", command)

	var buf bytes.Buffer
	cmd.Stdout = &buf
	cmd.Stderr = &buf

	err := cmd.Run()

	exitCode := 0
	if err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			return ExecutionResult{
				Output:   fmt.Sprintf("TIMEOUT after %ds\n%s", timeoutS, buf.String()),
				ExitCode: 124,
				Err:      ctx.Err(),
			}
		} else if exitErr, ok := err.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
		} else {
			return ExecutionResult{Output: err.Error(), ExitCode: 1, Err: err}
		}
	}

	return ExecutionResult{
		Output:   buf.String(),
		ExitCode: exitCode,
	}
}
