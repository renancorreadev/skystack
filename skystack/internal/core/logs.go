package core

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"regexp"
	"strings"
	"time"

	"github.com/docker/docker/api/types/container"
	"github.com/docker/docker/pkg/stdcopy"
)

// LogLine is a single parsed, enriched log entry.
type LogLine struct {
	Host      string
	Container string
	Stream    string // "stdout" | "stderr"
	Time      time.Time
	HasTime   bool
	Severity  string // ERROR | WARN | INFO | DEBUG | "" (detected)
	Message   string // the message with the docker timestamp prefix stripped
	Raw       string
	JSON      map[string]any // populated when the line is structured JSON
}

// LogOptions controls a streaming log read.
type LogOptions struct {
	Follow   bool
	Tail     string // "all" or a number
	Since    string // e.g. "10m", RFC3339
	Grep     *regexp.Regexp
	MinLevel string // "", DEBUG, INFO, WARN, ERROR — filter by detected severity
}

// severityRank orders detected log levels for threshold filtering.
func severityRank(sev string) int {
	switch sev {
	case "DEBUG":
		return 1
	case "INFO":
		return 2
	case "WARN":
		return 3
	case "ERROR":
		return 4
	default:
		return 0
	}
}

var (
	// matches the RFC3339Nano timestamp docker prefixes each line with.
	tsPrefix  = regexp.MustCompile(`^(\S+?Z|\S+?[+-]\d{2}:\d{2})\s`)
	sevDetect = regexp.MustCompile(`(?i)\b(ERROR|ERR|FATAL|PANIC|WARN(?:ING)?|INFO|DEBUG|TRACE)\b`)
)

// StreamLogs reads container logs, parses and enriches each line, applies an
// optional grep filter, and invokes sink for every line that passes. It blocks
// until the stream ends (or, with Follow, until ctx is cancelled).
func (e *Engine) StreamLogs(ctx context.Context, c Container, opts LogOptions, sink func(LogLine)) error {
	tail := opts.Tail
	if tail == "" {
		tail = "200"
	}
	rc, err := e.Docker.ContainerLogs(ctx, c.ID, container.LogsOptions{
		ShowStdout: true,
		ShowStderr: true,
		Follow:     opts.Follow,
		Since:      normalizeSince(opts.Since),
		Tail:       tail,
		Timestamps: true,
	})
	if err != nil {
		return err
	}
	defer rc.Close()

	// Demux stdout/stderr into a single ordered pipe so we can scan lines while
	// preserving which stream each came from.
	pr, pw := io.Pipe()
	go func() {
		// stdcopy interleaves both streams; we tag via a per-line prefix writer.
		so, se := false, false
		_, cpErr := stdcopy.StdCopy(
			&streamTagger{pw, []byte("\x00stdout\x00"), &so},
			&streamTagger{pw, []byte("\x00stderr\x00"), &se},
			rc)
		pw.CloseWithError(cpErr)
	}()

	scanner := bufio.NewScanner(pr)
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for scanner.Scan() {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		line := parseLine(c, scanner.Text())
		if opts.Grep != nil && !opts.Grep.MatchString(line.Raw) {
			continue
		}
		if opts.MinLevel != "" && severityRank(line.Severity) < severityRank(opts.MinLevel) {
			continue
		}
		sink(line)
	}
	return scanner.Err()
}

// streamTagger prefixes each LINE with its stream name so the scanner can
// recover it. It tracks line state (inLine) so a single logical line that spans
// multiple writes — a large log line split across docker frames — gets exactly
// ONE marker at its start. The old per-write prefix injected markers mid-line,
// corrupting big JSON/SQL logs.
type streamTagger struct {
	w      io.Writer
	marker []byte
	inLine *bool
}

func (s *streamTagger) Write(p []byte) (int, error) {
	total := 0
	for len(p) > 0 {
		if !*s.inLine {
			if _, err := s.w.Write(s.marker); err != nil {
				return total, err
			}
			*s.inLine = true
		}
		if nl := bytes.IndexByte(p, '\n'); nl >= 0 {
			n, err := s.w.Write(p[:nl+1])
			total += n
			if err != nil {
				return total, err
			}
			*s.inLine = false
			p = p[nl+1:]
		} else {
			n, err := s.w.Write(p)
			total += n
			return total, err
		}
	}
	return total, nil
}

func parseLine(c Container, raw string) LogLine {
	l := LogLine{Host: c.Host, Container: c.Name, Stream: "stdout", Raw: raw, Message: raw}

	if strings.HasPrefix(raw, "\x00") {
		if end := strings.IndexByte(raw[1:], '\x00'); end >= 0 {
			l.Stream = raw[1 : 1+end]
			raw = raw[2+end:]
			l.Raw = raw
			l.Message = raw
		}
	}

	// Strip docker's RFC3339 timestamp prefix.
	if m := tsPrefix.FindStringSubmatch(raw); m != nil {
		if t, err := time.Parse(time.RFC3339Nano, m[1]); err == nil {
			l.Time, l.HasTime = t, true
		}
		l.Message = strings.TrimPrefix(raw[len(m[0]):], " ")
	}

	// Structured JSON logs: surface level/msg if present.
	if trimmed := strings.TrimSpace(l.Message); strings.HasPrefix(trimmed, "{") {
		var obj map[string]any
		if json.Unmarshal([]byte(trimmed), &obj) == nil {
			l.JSON = obj
			if lvl := firstString(obj, "level", "lvl", "severity"); lvl != "" {
				l.Severity = strings.ToUpper(lvl)
			}
		}
	}

	if l.Severity == "" {
		if m := sevDetect.FindString(l.Message); m != "" {
			l.Severity = normalizeSeverity(m)
		}
	}
	return l
}

func normalizeSeverity(s string) string {
	switch strings.ToUpper(s) {
	case "ERR", "ERROR", "FATAL", "PANIC":
		return "ERROR"
	case "WARN", "WARNING":
		return "WARN"
	case "TRACE", "DEBUG":
		return "DEBUG"
	default:
		return "INFO"
	}
}

func firstString(m map[string]any, keys ...string) string {
	for _, k := range keys {
		if v, ok := m[k]; ok {
			if s, ok := v.(string); ok {
				return s
			}
		}
	}
	return ""
}

// normalizeSince accepts relative durations like "10m" and converts them to a
// unix timestamp the Docker API understands; otherwise it passes through.
func normalizeSince(s string) string {
	if s == "" {
		return ""
	}
	if d, err := time.ParseDuration(s); err == nil {
		return time.Now().Add(-d).Format(time.RFC3339)
	}
	return s
}
