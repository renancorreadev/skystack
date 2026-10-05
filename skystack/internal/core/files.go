package core

import (
	"bytes"
	"context"
	"fmt"
	"path"
	"sort"
	"strings"
)

// ReadFile returns up to ~64 KiB of a file's content from inside a container,
// flagging truncation. Needs sh + head in the container.
func (e *Engine) ReadFile(ctx context.Context, id, p string) (string, bool, error) {
	const limit = 64 * 1024
	var out bytes.Buffer
	err := e.ExecSimple(ctx, id, ExecConfig{
		Cmd:    []string{"sh", "-c", fmt.Sprintf("head -c %d %s", limit+1, shellQuote(p))},
		Stdout: &out,
		Stderr: &out,
	})
	if err != nil {
		return "", false, err
	}
	s := out.String()
	if len(s) > limit {
		return s[:limit], true, nil
	}
	return s, false, nil
}

// shellQuote single-quotes a path for safe embedding in `sh -c`.
func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// FileEntry is one item in a container directory listing.
type FileEntry struct {
	Name  string `json:"name"`
	IsDir bool   `json:"isDir"`
	Path  string `json:"path"`
}

// ListDir lists a directory inside a container by exec'ing `ls`. Directories
// come back with IsDir=true (ls -p marks them with a trailing slash).
func (e *Engine) ListDir(ctx context.Context, id, dir string) ([]FileEntry, error) {
	if dir == "" {
		dir = "/"
	}
	var out bytes.Buffer
	err := e.ExecSimple(ctx, id, ExecConfig{
		Cmd:    []string{"ls", "-1Ap", "--", dir},
		Stdout: &out,
		Stderr: &out,
	})
	if err != nil {
		return nil, err
	}
	var entries []FileEntry
	for _, line := range strings.Split(out.String(), "\n") {
		name := strings.TrimRight(line, "\r")
		if name == "" {
			continue
		}
		isDir := strings.HasSuffix(name, "/")
		name = strings.TrimSuffix(name, "/")
		if name == "" || name == "." || name == ".." {
			continue
		}
		entries = append(entries, FileEntry{Name: name, IsDir: isDir, Path: path.Join(dir, name)})
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].IsDir != entries[j].IsDir {
			return entries[i].IsDir // dirs first
		}
		return entries[i].Name < entries[j].Name
	})
	return entries, nil
}
