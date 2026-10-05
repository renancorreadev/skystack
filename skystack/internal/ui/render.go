// Package ui holds terminal rendering helpers: aligned tables and the colored,
// severity-aware log formatting that the CLI shares across commands.
package ui

import (
	"fmt"
	"os"
	"strings"
	"time"

	"golang.org/x/term"

	"github.com/skynance/skystack/internal/core"
)

// ANSI color helpers, disabled automatically when stdout is not a TTY or when
// NO_COLOR is set (https://no-color.org).
var colorEnabled = term.IsTerminal(int(os.Stdout.Fd())) && os.Getenv("NO_COLOR") == ""

const (
	reset   = "\x1b[0m"
	dim     = "\x1b[2m"
	bold    = "\x1b[1m"
	red     = "\x1b[31m"
	green   = "\x1b[32m"
	yellow  = "\x1b[33m"
	blue    = "\x1b[34m"
	magenta = "\x1b[35m"
	cyan    = "\x1b[36m"
)

func color(c, s string) string {
	if !colorEnabled {
		return s
	}
	return c + s + reset
}

// Table renders rows with aligned columns under the given headers.
func Table(headers []string, rows [][]string) string {
	widths := make([]int, len(headers))
	for i, h := range headers {
		widths[i] = len(h)
	}
	for _, row := range rows {
		for i, cell := range row {
			if i < len(widths) && len(cell) > widths[i] {
				widths[i] = len(cell)
			}
		}
	}
	var b strings.Builder
	for i, h := range headers {
		b.WriteString(color(bold, pad(strings.ToUpper(h), widths[i])))
		if i < len(headers)-1 {
			b.WriteString("  ")
		}
	}
	b.WriteString("\n")
	for _, row := range rows {
		for i := range headers {
			cell := ""
			if i < len(row) {
				cell = row[i]
			}
			b.WriteString(pad(cell, widths[i]))
			if i < len(headers)-1 {
				b.WriteString("  ")
			}
		}
		b.WriteString("\n")
	}
	return b.String()
}

func pad(s string, w int) string {
	if len(s) >= w {
		return s
	}
	return s + strings.Repeat(" ", w-len(s))
}

// StateDot returns a colored status indicator for a container state.
func StateDot(state string) string {
	switch state {
	case "running":
		return color(green, "●")
	case "paused":
		return color(yellow, "●")
	case "exited", "dead":
		return color(red, "●")
	default:
		return color(dim, "●")
	}
}

// Bold / Dim wrap text in the respective ANSI style (no-op when not a TTY).
func Bold(s string) string { return color(bold, s) }
func Dim(s string) string  { return color(dim, s) }

// LogLine formats an enriched log line for the terminal: dimmed timestamp,
// colored severity tag, host/container prefix when streaming multiple sources.
func LogLine(l core.LogLine, showSource bool) string {
	var b strings.Builder
	if l.HasTime {
		b.WriteString(color(dim, l.Time.Format("15:04:05")) + " ")
	}
	if showSource {
		src := l.Container
		if l.Host != "" && l.Host != "local" {
			src = l.Host + "/" + l.Container
		}
		b.WriteString(color(cyan, pad(truncate(src, 18), 18)) + " ")
	}
	if l.Severity != "" {
		b.WriteString(sevTag(l.Severity) + " ")
	}
	msg := l.Message
	if l.Stream == "stderr" && l.Severity == "" {
		msg = color(red, msg)
	}
	b.WriteString(msg)
	return b.String()
}

func sevTag(sev string) string {
	switch sev {
	case "ERROR":
		return color(red, "ERROR")
	case "WARN":
		return color(yellow, "WARN ")
	case "INFO":
		return color(green, "INFO ")
	case "DEBUG":
		return color(blue, "DEBUG")
	default:
		return color(magenta, sev)
	}
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	if n <= 1 {
		return s[:n]
	}
	return s[:n-1] + "…"
}

// Errorf prints a formatted, red-tagged error to stderr.
func Errorf(format string, a ...any) {
	fmt.Fprintln(os.Stderr, color(red, "error:")+" "+fmt.Sprintf(format, a...))
}

// Successf prints a green check line.
func Successf(format string, a ...any) {
	fmt.Println(color(green, "✓") + " " + fmt.Sprintf(format, a...))
}

// Spinner shows an animated status line on stderr and returns a stop function
// that clears it. On a non-TTY it prints the message once and the stop is a
// no-op, so output stays clean in scripts and logs.
func Spinner(message string) func() {
	if !colorEnabled {
		fmt.Fprintln(os.Stderr, message+"…")
		return func() {}
	}
	done := make(chan struct{})
	cleared := make(chan struct{})
	go func() {
		frames := []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
		t := time.NewTicker(90 * time.Millisecond)
		defer t.Stop()
		i := 0
		for {
			select {
			case <-done:
				fmt.Fprint(os.Stderr, "\r\x1b[K")
				close(cleared)
				return
			case <-t.C:
				fmt.Fprintf(os.Stderr, "\r%s %s", color(cyan, frames[i%len(frames)]), message)
				i++
			}
		}
	}()
	return func() {
		close(done)
		<-cleared
	}
}
