package worker

import (
	"testing"
)

func TestExecute_EchoSuccess(t *testing.T) {
	result := Execute("echo hello", 0)
	if result.ExitCode != 0 {
		t.Fatalf("expected exit code 0, got %d", result.ExitCode)
	}
	if result.Err != nil {
		t.Fatalf("expected no error, got %v", result.Err)
	}
	expected := "hello\n"
	if result.Output != expected {
		t.Fatalf("expected output %q, got %q", expected, result.Output)
	}
}

func TestExecute_NonZeroExit(t *testing.T) {
	result := Execute("exit 42", 0)
	if result.ExitCode != 42 {
		t.Fatalf("expected exit code 42, got %d", result.ExitCode)
	}
}

func TestExecute_StderrCaptured(t *testing.T) {
	result := Execute("echo err >&2", 0)
	if result.ExitCode != 0 {
		t.Fatalf("expected exit code 0, got %d", result.ExitCode)
	}
	if result.Output != "err\n" {
		t.Fatalf("expected stderr captured as 'err\\n', got %q", result.Output)
	}
}

func TestExecute_PipeCommand(t *testing.T) {
	result := Execute("echo 'line1\nline2\nline3' | wc -l", 0)
	if result.ExitCode != 0 {
		t.Fatalf("expected exit code 0, got %d", result.ExitCode)
	}
	// wc -l should output a number (with possibly leading whitespace)
	if result.Output == "" {
		t.Fatal("expected non-empty output from pipe command")
	}
}

func TestExecute_Timeout(t *testing.T) {
	result := Execute("sleep 10", 1)
	if result.ExitCode != 124 {
		t.Fatalf("expected exit code 124 (timeout), got %d", result.ExitCode)
	}
	if result.Err == nil {
		t.Fatal("expected timeout error")
	}
}

func TestExecute_InvalidCommand(t *testing.T) {
	result := Execute("nonexistent_command_xyz_123", 0)
	if result.ExitCode == 0 {
		t.Fatal("expected non-zero exit code for invalid command")
	}
}

func TestExecute_MultilineOutput(t *testing.T) {
	result := Execute("echo line1 && echo line2 && echo line3", 0)
	if result.ExitCode != 0 {
		t.Fatalf("expected exit code 0, got %d", result.ExitCode)
	}
	expected := "line1\nline2\nline3\n"
	if result.Output != expected {
		t.Fatalf("expected output %q, got %q", expected, result.Output)
	}
}

func TestExecute_EmptyCommand(t *testing.T) {
	result := Execute("", 0)
	// Empty command should succeed on most shells
	if result.ExitCode != 0 {
		t.Logf("empty command returned exit code %d (shell-dependent)", result.ExitCode)
	}
}

func TestExecute_EnvironmentVariable(t *testing.T) {
	result := Execute("echo $HOME", 0)
	if result.ExitCode != 0 {
		t.Fatalf("expected exit code 0, got %d", result.ExitCode)
	}
	if result.Output == "" || result.Output == "\n" {
		t.Fatal("expected $HOME to be expanded")
	}
}
