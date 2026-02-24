package logger

import (
	"fmt"
	"log"
	"os"
	"strings"
	"time"
)

// Level represents log severity.
type Level int

const (
	DEBUG Level = iota
	INFO
	WARN
	ERROR
	FATAL
)

var levelNames = map[Level]string{
	DEBUG: "DEBUG",
	INFO:  "INFO",
	WARN:  "WARN",
	ERROR: "ERROR",
	FATAL: "FATAL",
}

var levelColors = map[Level]string{
	DEBUG: "\033[36m", // cyan
	INFO:  "\033[32m", // green
	WARN:  "\033[33m", // yellow
	ERROR: "\033[31m", // red
	FATAL: "\033[35m", // magenta
}

const resetColor = "\033[0m"

// Logger provides structured, leveled logging.
type Logger struct {
	component string
	minLevel  Level
	inner     *log.Logger
}

// New creates a logger for the given component.
func New(component string) *Logger {
	return &Logger{
		component: component,
		minLevel:  INFO,
		inner:     log.New(os.Stdout, "", 0),
	}
}

// SetLevel sets the minimum log level.
func (l *Logger) SetLevel(level Level) {
	l.minLevel = level
}

func (l *Logger) log(level Level, format string, args ...any) {
	if level < l.minLevel {
		return
	}
	ts := time.Now().Format("15:04:05.000")
	color := levelColors[level]
	name := levelNames[level]
	msg := fmt.Sprintf(format, args...)
	l.inner.Printf("%s %s%-5s%s [%s] %s", ts, color, name, resetColor, l.component, msg)
}

func (l *Logger) Debug(format string, args ...any) { l.log(DEBUG, format, args...) }
func (l *Logger) Info(format string, args ...any)  { l.log(INFO, format, args...) }
func (l *Logger) Warn(format string, args ...any)  { l.log(WARN, format, args...) }
func (l *Logger) Error(format string, args ...any) { l.log(ERROR, format, args...) }

func (l *Logger) Fatal(format string, args ...any) {
	l.log(FATAL, format, args...)
	os.Exit(1)
}

// ParseLevel parses a level string (e.g., "debug", "info", "warn", "error").
func ParseLevel(s string) Level {
	switch strings.ToLower(s) {
	case "debug":
		return DEBUG
	case "info":
		return INFO
	case "warn", "warning":
		return WARN
	case "error":
		return ERROR
	case "fatal":
		return FATAL
	default:
		return INFO
	}
}
