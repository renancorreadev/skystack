package core

import (
	"context"
	"time"

	"github.com/docker/docker/api/types/events"
	"github.com/docker/docker/api/types/filters"
)

// WatchContainers pushes the host's container list to sink: once immediately,
// then again whenever Docker reports a container event (create/start/stop/die/
// destroy/rename/health). Bursts (e.g. a `compose up`) are debounced into a
// single re-list. The Docker events stream holds the connection open, so this is
// also what keeps a host's SSH master warm. Returns when ctx is cancelled or the
// event stream breaks (the caller restarts).
func (e *Engine) WatchContainers(ctx context.Context, all bool, sink func([]Container)) error {
	relist := func() {
		cctx, cancel := context.WithTimeout(ctx, 15*time.Second)
		defer cancel()
		if cs, err := e.List(cctx, all); err == nil {
			sink(cs)
		}
	}
	relist() // initial snapshot

	f := filters.NewArgs(filters.Arg("type", "container"))
	msgs, errs := e.Docker.Events(ctx, events.ListOptions{Filters: f})

	debounce := time.NewTimer(time.Hour)
	debounce.Stop()
	pending := false

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case err := <-errs:
			return err
		case <-msgs:
			if !pending {
				pending = true
				debounce.Reset(300 * time.Millisecond)
			}
		case <-debounce.C:
			pending = false
			relist()
		}
	}
}
