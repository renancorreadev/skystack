package cli

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/spf13/cobra"

	"github.com/skynance/skystack/internal/config"
	"github.com/skynance/skystack/internal/core"
	"github.com/skynance/skystack/internal/vm"
)

// newAPICmd exposes machine-readable JSON/NDJSON output for the native app. It's
// the stable surface the SwiftUI front-end consumes (and the shape a future
// gRPC/daemon API would mirror). Hidden from the human-facing help.
func newAPICmd() *cobra.Command {
	cmd := &cobra.Command{
		Use:    "api",
		Short:  "JSON/NDJSON output for the SkyStack app (internal)",
		Hidden: true,
	}
	cmd.AddCommand(
		newAPIHostsCmd(), newAPIPsCmd(), newAPILogsCmd(), newAPIActionCmd(), newAPIComposeCmd(),
		newAPIImagesCmd(), newAPIVolumesCmd(), newAPINetworksCmd(), newAPIMachinesCmd(),
		newAPIStatsCmd(), newAPIFilesCmd(), newAPIFileContentCmd(),
		newAPIRunCmd(), newAPIRmCmd(), newAPIPruneCmd(), newAPICreateCmd(),
		newAPIInspectCmd(), newAPIContextCmd(), newAPIConsumersCmd(), newAPIVMCmd(),
		newAPISSHHostsCmd(), newAPIFrameworkCmd(), newAPIWatchCmd(), newAPIHwStatsCmd(),
		newAPIWatchHostsCmd(), newAPITunnelCmd(), newAPIComposeUpCmd(), newAPIComposeDownCmd(),
		newAPIHostContextCmd(), newAPIHostSSHCmd(),
	)
	return cmd
}

func newAPICreateCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "create <volume|network> <host> <name>",
		Short: "Create a volume or network",
		Args:  cobra.ExactArgs(3),
		RunE: func(cmd *cobra.Command, args []string) error {
			kind, host, name := args[0], args[1], args[2]
			return withEngine(host, func(ctx context.Context, eng *core.Engine) error {
				var err error
				switch kind {
				case "volume":
					err = eng.CreateVolume(ctx, name)
				case "network":
					err = eng.CreateNetwork(ctx, name)
				default:
					return fmt.Errorf("unknown kind %q (volume|network)", kind)
				}
				if err != nil {
					return err
				}
				return emitJSON(map[string]any{"ok": true})
			})
		},
	}
}

// withEngine resolves a host engine, runs fn, and closes it.
func withEngine(host string, fn func(ctx context.Context, eng *core.Engine) error) error {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	eng, err := engineFor(ctx, host)
	if err != nil {
		return err
	}
	defer eng.Close()
	return fn(ctx, eng)
}

func newAPIRunCmd() *cobra.Command {
	var name string
	var ports []string
	cmd := &cobra.Command{
		Use:   "run <host> <image>",
		Short: "Run a container from an image",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			return withEngine(args[0], func(ctx context.Context, eng *core.Engine) error {
				id, err := eng.RunContainer(ctx, core.RunSpec{Image: args[1], Name: name, Ports: ports}, os.Stderr)
				if err != nil {
					return err
				}
				return emitJSON(map[string]any{"ok": true, "id": id})
			})
		},
	}
	cmd.Flags().StringVar(&name, "name", "", "container name")
	cmd.Flags().StringArrayVarP(&ports, "port", "p", nil, "publish host:container port (repeatable)")
	return cmd
}

func newAPIRmCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "rm <kind> <host> <id>",
		Short: "Remove a container|image|volume|network",
		Args:  cobra.ExactArgs(3),
		RunE: func(cmd *cobra.Command, args []string) error {
			kind, host, id := args[0], args[1], args[2]
			return withEngine(host, func(ctx context.Context, eng *core.Engine) error {
				var err error
				switch kind {
				case "container":
					err = eng.RemoveContainer(ctx, id)
				case "image":
					err = eng.RemoveImage(ctx, id)
				case "volume":
					err = eng.RemoveVolume(ctx, id)
				case "network":
					err = eng.RemoveNetwork(ctx, id)
				default:
					return fmt.Errorf("unknown kind %q (container|image|volume|network)", kind)
				}
				if err != nil {
					return err
				}
				return emitJSON(map[string]any{"ok": true})
			})
		},
	}
}

func newAPIPruneCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "prune <host> <kind>",
		Short: "Prune unused images|containers|volumes|networks",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			return withEngine(args[0], func(ctx context.Context, eng *core.Engine) error {
				reclaimed, err := eng.Prune(ctx, args[1])
				if err != nil {
					return err
				}
				return emitJSON(map[string]any{"ok": true, "reclaimed": reclaimed})
			})
		},
	}
}

func newAPIImagesCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "images [host]",
		Short: "List images as JSON",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			host := config.LocalHost
			if len(args) == 1 {
				host = args[0]
			}
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			eng, err := engineFor(ctx, host)
			if err != nil {
				return err
			}
			defer eng.Close()
			imgs, err := eng.ListImages(ctx)
			if err != nil {
				return err
			}
			return emitJSON(imgs)
		},
	}
}

func newAPIVolumesCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "volumes [host]",
		Short: "List volumes as JSON",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			host := config.LocalHost
			if len(args) == 1 {
				host = args[0]
			}
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			eng, err := engineFor(ctx, host)
			if err != nil {
				return err
			}
			defer eng.Close()
			vols, err := eng.ListVolumes(ctx)
			if err != nil {
				return err
			}
			return emitJSON(vols)
		},
	}
}

func newAPINetworksCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "networks [host]",
		Short: "List networks as JSON",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			host := config.LocalHost
			if len(args) == 1 {
				host = args[0]
			}
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			eng, err := engineFor(ctx, host)
			if err != nil {
				return err
			}
			defer eng.Close()
			nets, err := eng.ListNetworks(ctx)
			if err != nil {
				return err
			}
			return emitJSON(nets)
		},
	}
}

func newAPIMachinesCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "machines [host]",
		Short: "List Linux machines as JSON",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			host := config.SkyVMHost
			if len(args) == 1 {
				host = args[0]
			}
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			eng, err := engineFor(ctx, host)
			if err != nil {
				return err
			}
			defer eng.Close()
			machines, err := eng.ListMachines(ctx)
			if err != nil {
				return err
			}
			out := make([]map[string]any, 0, len(machines))
			for _, m := range machines {
				out = append(out, map[string]any{"name": m.Name, "distro": m.Distro, "image": m.Image, "state": m.State, "status": m.Status})
			}
			return emitJSON(out)
		},
	}
}

// newAPIInspectCmd emits the raw Docker inspect JSON for any resource kind, so
// the app can show a universal "Inspect" viewer.
func newAPIInspectCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "inspect <container|image|volume|network> <host> <id>",
		Short: "Emit a resource's raw inspect JSON",
		Args:  cobra.ExactArgs(3),
		RunE: func(cmd *cobra.Command, args []string) error {
			kind, host, id := args[0], args[1], args[2]
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			eng, err := engineFor(ctx, host)
			if err != nil {
				return err
			}
			defer eng.Close()
			var info any
			switch kind {
			case "container":
				c, rerr := eng.Resolve(ctx, id)
				if rerr != nil {
					return rerr
				}
				info, err = eng.Inspect(ctx, c.ID)
			case "image":
				info, err = eng.InspectImage(ctx, id)
			case "volume":
				info, err = eng.InspectVolume(ctx, id)
			case "network":
				info, err = eng.InspectNetwork(ctx, id)
			default:
				return fmt.Errorf("unknown kind %q (want container|image|volume|network)", kind)
			}
			if err != nil {
				return err
			}
			return emitJSON(info)
		},
	}
}

// newAPIConsumersCmd lists the containers using a volume or network.
func newAPIConsumersCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "consumers <volume|network> <host> <name>",
		Short: "List containers using a volume or network as a JSON array",
		Args:  cobra.ExactArgs(3),
		RunE: func(cmd *cobra.Command, args []string) error {
			kind, host, name := args[0], args[1], args[2]
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			eng, err := engineFor(ctx, host)
			if err != nil {
				return err
			}
			defer eng.Close()
			var names []string
			switch kind {
			case "volume":
				names, err = eng.VolumeConsumers(ctx, name)
			case "network":
				names, err = eng.NetworkConsumers(ctx, name)
			default:
				return fmt.Errorf("unknown kind %q (want volume|network)", kind)
			}
			if err != nil {
				return err
			}
			if names == nil {
				names = []string{}
			}
			return emitJSON(names)
		},
	}
}

// newAPISSHHostsCmd emits the aliases from ~/.ssh/config so the app can offer a
// one-click "connect" to a remote Docker host, reusing the user's SSH setup.
// Each entry is marked `registered` if it's already a SkyStack host.
func newAPISSHHostsCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "ssh-hosts",
		Short: "List ~/.ssh/config aliases as JSON (for one-click remote connect)",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			hosts, err := parseSSHHosts()
			if err != nil {
				return err
			}
			registered := map[string]bool{}
			if reg, err := loadRegistry(); err == nil {
				for name := range reg.Hosts {
					registered[name] = true
				}
			}
			type row struct {
				SSHHost
				Registered bool `json:"registered"`
			}
			out := make([]row, 0, len(hosts))
			for _, h := range hosts {
				out = append(out, row{SSHHost: h, Registered: registered[h.Alias]})
			}
			return emitJSON(out)
		},
	}
}

// newAPIVMCmd emits the local SkyVM's status as JSON for the app's host picker.
func newAPIVMCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "vm",
		Short: "Emit local SkyVM status as JSON",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			svc, err := vm.New()
			if err != nil {
				// Not configured yet — report a stable, non-error shape.
				return emitJSON(map[string]any{"configured": false, "running": false, "ready": false})
			}
			ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
			defer cancel()
			st := svc.Status(ctx)
			out := map[string]any{
				"configured": true,
				"running":    st.Running,
				"ready":      st.SocketReady,
				"version":    st.DockerVersion,
				"pid":        st.PID,
				"socket":     st.Socket,
				"caTrusted":  vm.CATrusted(),
			}
			if ns, nerr := vm.LoadNetState(); nerr == nil && ns.IP != "" && st.Running {
				out["ip"] = ns.IP
				out["routed"] = routePresent()
			}
			if st.SocketReady {
				if ports := forwardedPorts(ctx); len(ports) > 0 {
					out["ports"] = ports
				}
			}
			return emitJSON(out)
		},
	}
}

// newAPIContextCmd bundles everything an AI needs to reason about a container —
// identity, the raw inspect, a live stats sample, and a recent log tail — into a
// single JSON object, so the app gathers full context in one call.
func newAPIContextCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "context <[host/]container>",
		Short: "Emit a container's full AI context (inspect + stats + logs) as JSON",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			defer cancel()
			eng, c, err := resolveTarget(ctx, args[0])
			if err != nil {
				return err
			}
			defer eng.Close()
			return emitJSON(buildContainerContext(ctx, eng, c))
		},
	}
}

// buildContainerContext bundles a container's full AI context (identity, raw
// inspect, a live stats sample, and a recent severity-tagged log tail). Shared
// by the `api context` command and the daemon.
func buildContainerContext(ctx context.Context, eng *core.Engine, c core.Container) map[string]any {
	out := map[string]any{
		"name": c.Name, "image": c.Image, "state": c.State, "status": c.Status, "host": eng.Host.Name,
	}
	if info, err := eng.Inspect(ctx, c.ID); err == nil {
		out["inspect"] = info
	}
	if s, err := eng.SnapshotStats(ctx, c.ID); err == nil {
		out["stats"] = s
	}
	var logBuf strings.Builder
	logCtx, logCancel := context.WithTimeout(ctx, 8*time.Second)
	defer logCancel()
	lines := 0
	_ = eng.StreamLogs(logCtx, c, core.LogOptions{Tail: "200"}, func(l core.LogLine) {
		if lines >= 400 {
			return
		}
		if l.HasTime {
			logBuf.WriteString(l.Time.Format("15:04:05") + " ")
		}
		if l.Severity != "" {
			logBuf.WriteString("[" + l.Severity + "] ")
		}
		logBuf.WriteString(l.Message)
		logBuf.WriteByte('\n')
		lines++
	})
	out["logs"] = logBuf.String()
	return out
}

// newAPIFrameworkCmd detects a container's language/framework (for the app to
// pick a brand icon when the image/name alone don't reveal it).
// newAPIWatchCmd streams a host's container list as NDJSON, pushed on Docker
// events — one persistent, warm connection instead of repeated `ps` polling.
// newAPIWatchHostsCmd streams the host list (reachability + version) as NDJSON,
// emitting only when it changes. It holds a warm engine per host across cycles so
// the SSH masters stay alive — replacing the per-poll `api hosts` spawn. Liveness
// uses the cheap /_ping; the (static) version is fetched once and cached.
func newAPIWatchHostsCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "watch-hosts",
		Short: "Stream hosts (reachability + version) as NDJSON, holding warm connections",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := signalContext()
			defer cancel()
			engines := map[string]*core.Engine{}
			versions := map[string]string{}
			var mu sync.Mutex
			defer func() {
				for _, e := range engines {
					e.Close()
				}
			}()
			last := ""

			probe := func() {
				reg, err := loadRegistry()
				if err != nil {
					return
				}
				hosts := reg.All()
				rows := make([]apiHost, len(hosts))
				seen := map[string]bool{}
				var wg sync.WaitGroup
				for i, h := range hosts {
					seen[h.Name] = true
					rows[i] = apiHost{Name: h.Name, Kind: hostKind(h), Description: h.Description}
					wg.Add(1)
					go func(i int, h *config.Host) {
						defer wg.Done()
						if h.IsSkyVM() && !skyVMSocketPresent(h) {
							mu.Lock()
							if e := engines[h.Name]; e != nil {
								e.Close()
							}
							delete(engines, h.Name)
							delete(versions, h.Name)
							mu.Unlock()
							return
						}
						mu.Lock()
						eng := engines[h.Name]
						mu.Unlock()
						if eng == nil {
							cctx, c := context.WithTimeout(ctx, 12*time.Second)
							e, err := core.Connect(cctx, h)
							c()
							if err != nil {
								rows[i].Error = err.Error()
								return
							}
							eng = e
							mu.Lock()
							engines[h.Name] = e
							mu.Unlock()
						}
						actx, c := context.WithTimeout(ctx, 8*time.Second)
						alive := eng.Alive(actx)
						c()
						if !alive {
							eng.Close()
							mu.Lock()
							delete(engines, h.Name)
							delete(versions, h.Name)
							mu.Unlock()
							rows[i].Error = "unreachable"
							return
						}
						mu.Lock()
						ver := versions[h.Name]
						mu.Unlock()
						if ver == "" {
							vctx, c := context.WithTimeout(ctx, 8*time.Second)
							if v, err := eng.Ping(vctx); err == nil {
								ver = v
								mu.Lock()
								versions[h.Name] = v
								mu.Unlock()
							}
							c()
						}
						rows[i].Up = true
						rows[i].Engine = ver
					}(i, h)
				}
				wg.Wait()

				// Drop engines for hosts no longer in the registry.
				mu.Lock()
				for name, e := range engines {
					if !seen[name] {
						e.Close()
						delete(engines, name)
						delete(versions, name)
					}
				}
				mu.Unlock()

				b, _ := json.Marshal(map[string]any{"hosts": rows})
				if string(b) != last {
					last = string(b)
					os.Stdout.Write(append(b, '\n'))
				}
			}

			probe()
			ticker := time.NewTicker(4 * time.Second)
			defer ticker.Stop()
			for {
				select {
				case <-ctx.Done():
					return ctx.Err()
				case <-ticker.C:
					probe()
				}
			}
		},
	}
}

// newAPIHwStatsCmd streams a host's aggregate hardware usage as NDJSON.
func newAPIHwStatsCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "hwstats <host>",
		Short: "Stream a host's aggregate hardware usage as NDJSON",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := signalContext()
			defer cancel()
			eng, err := engineFor(ctx, args[0])
			if err != nil {
				return err
			}
			defer eng.Close()
			enc := json.NewEncoder(os.Stdout)
			return eng.StreamHardware(ctx, func(s core.HardwareSample) {
				_ = enc.Encode(s)
			})
		},
	}
}

func newAPIWatchCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "watch <host>",
		Short: "Stream a host's containers as NDJSON, pushed on Docker events",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := signalContext()
			defer cancel()
			eng, err := engineFor(ctx, args[0])
			if err != nil {
				return err
			}
			defer eng.Close()
			enc := json.NewEncoder(os.Stdout)
			return eng.WatchContainers(ctx, true, func(cs []core.Container) {
				out := make([]apiContainer, 0, len(cs))
				for _, c := range cs {
					out = append(out, apiContainer{
						Host: c.Host, ID: c.ID, Name: c.Name, Image: c.Image,
						State: c.State, Status: c.Status, Ports: c.Ports,
						Compose: c.Compose, Service: c.Service,
					})
				}
				sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
				_ = enc.Encode(map[string]any{"containers": out})
			})
		},
	}
}

func newAPIFrameworkCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "framework <[host/]container>",
		Short: "Detect a container's language/framework as JSON",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			eng, c, err := resolveTarget(ctx, args[0])
			if err != nil {
				return err
			}
			defer eng.Close()
			fw, err := eng.DetectFramework(ctx, c.ID)
			if err != nil {
				return err
			}
			return emitJSON(map[string]any{"framework": fw})
		},
	}
}

func newAPIStatsCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "stats <[host/]container>",
		Short: "Stream container resource stats as NDJSON",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := signalContext()
			defer cancel()
			eng, c, err := resolveTarget(ctx, args[0])
			if err != nil {
				return err
			}
			defer eng.Close()
			enc := json.NewEncoder(os.Stdout)
			return eng.StreamStats(ctx, c.ID, func(s core.StatsSample) {
				_ = enc.Encode(s)
			})
		},
	}
}

func newAPIFileContentCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "filecontent <[host/]container> <path>",
		Short: "Read a file's content from a container as JSON",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			eng, c, err := resolveTarget(ctx, args[0])
			if err != nil {
				return err
			}
			defer eng.Close()
			content, truncated, err := eng.ReadFile(ctx, c.ID, args[1])
			if err != nil {
				return err
			}
			return emitJSON(map[string]any{"path": args[1], "content": content, "truncated": truncated})
		},
	}
}

func newAPIFilesCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "files <[host/]container> [path]",
		Short: "List a container directory as JSON",
		Args:  cobra.RangeArgs(1, 2),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			eng, c, err := resolveTarget(ctx, args[0])
			if err != nil {
				return err
			}
			defer eng.Close()
			dir := "/"
			if len(args) == 2 {
				dir = args[1]
			}
			entries, err := eng.ListDir(ctx, c.ID, dir)
			if err != nil {
				return err
			}
			return emitJSON(map[string]any{"path": dir, "entries": entries})
		},
	}
}

func newAPIComposeCmd() *cobra.Command {
	var file string
	cmd := &cobra.Command{
		Use:   "compose",
		Short: "Emit a Compose project's service graph as JSON",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			path, err := resolveComposeFile(file)
			if err != nil {
				return err
			}
			data, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			proj, err := core.ParseCompose(data, projectFromDir(path))
			if err != nil {
				return err
			}
			return emitJSON(map[string]any{
				"name":     proj.Name,
				"services": proj.Services,
				"layers":   proj.Layers(),
			})
		},
	}
	cmd.Flags().StringVarP(&file, "file", "f", "", "compose file (default: auto-detect in cwd)")
	return cmd
}

// newAPITunnelCmd forwards a container port to localhost and blocks until killed,
// emitting one NDJSON "ready" line so the app knows the forward is live. Remote
// hosts go over SSH to the container IP; local hosts proxy the published port.
func newAPITunnelCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "tunnel <[host/]container> <localPort:containerPort>",
		Short: "Forward a container port to localhost (NDJSON status; blocks until killed)",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := signalContext()
			defer cancel()
			spec, err := core.ParsePorts(args[1])
			if err != nil {
				return err
			}
			eng, c, err := resolveTarget(ctx, args[0])
			if err != nil {
				return err
			}
			defer eng.Close()

			enc := json.NewEncoder(os.Stdout)
			emitted := false
			logf := func(string, ...any) {
				if emitted {
					return
				}
				emitted = true
				_ = enc.Encode(map[string]any{
					"ready": true, "localPort": spec.LocalPort, "containerPort": spec.ContainerPort,
					"url": fmt.Sprintf("http://localhost:%d", spec.LocalPort),
				})
			}
			if err := eng.Tunnel(ctx, c, spec, logf); err != nil && ctx.Err() == nil {
				_ = enc.Encode(map[string]any{"error": err.Error()})
				return err
			}
			return ctx.Err()
		},
	}
}

// newAPIComposeUpCmd / newAPIComposeDownCmd deploy or tear down a local compose
// file on any host (the app's "deploy to remote"). They shell `docker compose`
// with DOCKER_HOST set, streaming its build/run output verbatim to stdout.
func newAPIComposeUpCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "compose-up <host> <file>",
		Short: "Deploy a compose file to a host (docker compose up -d), streaming output",
		Args:  cobra.ExactArgs(2),
		RunE:  func(cmd *cobra.Command, args []string) error { return runComposeOnHost(args[0], args[1], "up", "-d") },
	}
}

func newAPIComposeDownCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "compose-down <host> <file>",
		Short: "Tear down a compose file on a host (docker compose down), streaming output",
		Args:  cobra.ExactArgs(2),
		RunE:  func(cmd *cobra.Command, args []string) error { return runComposeOnHost(args[0], args[1], "down") },
	}
}

// newAPIHostContextCmd bundles a host-wide triage context for the AI operator:
// the engine version, container counts, and every container's state/status, plus
// a recent log tail for any that are unhealthy/exited/restarting. One call gives
// Claude enough to reason about the whole host, not just a single container.
func newAPIHostContextCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "host-context <host>",
		Short: "Emit a host-wide AI triage context (containers + problem logs) as JSON",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			eng, err := engineFor(ctx, args[0])
			if err != nil {
				return err
			}
			defer eng.Close()
			out, err := buildHostContext(ctx, eng)
			if err != nil {
				return err
			}
			return emitJSON(out)
		},
	}
}

// buildHostContext bundles a host-wide triage context (engine version, container
// counts, every container's state/status, and a recent log tail for any that are
// unhealthy/exited/restarting). Shared by `api host-context` and the daemon.
func buildHostContext(ctx context.Context, eng *core.Engine) (map[string]any, error) {
	ver, _ := eng.Ping(ctx)
	cs, err := eng.List(ctx, true)
	if err != nil {
		return nil, err
	}
	type ctrSummary struct {
		Name    string   `json:"name"`
		Image   string   `json:"image"`
		State   string   `json:"state"`
		Status  string   `json:"status"`
		Compose string   `json:"compose,omitempty"`
		Ports   []string `json:"ports,omitempty"`
		Logs    string   `json:"logs,omitempty"`
	}
	isProblem := func(c core.Container) bool {
		if c.State != "running" {
			return true
		}
		s := strings.ToLower(c.Status)
		return strings.Contains(s, "unhealthy") || strings.Contains(s, "restarting")
	}
	summaries := make([]ctrSummary, 0, len(cs))
	running, problems, logged := 0, 0, 0
	for _, c := range cs {
		if c.State == "running" {
			running++
		}
		s := ctrSummary{Name: c.Name, Image: c.Image, State: c.State, Status: c.Status, Compose: c.Compose, Ports: c.Ports}
		if isProblem(c) {
			problems++
			if logged < 12 { // bound the bundle: only the first few problem containers carry logs
				logged++
				var buf strings.Builder
				lctx, lc := context.WithTimeout(ctx, 4*time.Second)
				n := 0
				_ = eng.StreamLogs(lctx, c, core.LogOptions{Tail: "40"}, func(l core.LogLine) {
					if n >= 50 {
						return
					}
					if l.Severity != "" {
						buf.WriteString("[" + l.Severity + "] ")
					}
					buf.WriteString(l.Message)
					buf.WriteByte('\n')
					n++
				})
				lc()
				s.Logs = strings.TrimSpace(buf.String())
			}
		}
		summaries = append(summaries, s)
	}
	return map[string]any{
		"host":       eng.Host.Name,
		"engine":     ver,
		"total":      len(cs),
		"running":    running,
		"problems":   problems,
		"containers": summaries,
	}, nil
}

// newAPIHostSSHCmd emits the `ssh` argv to reach a host's UNDERLYING machine (not
// a container) — so the app can open a real shell on the remote VM and run admin
// actions. Derived from the registered host's ssh:// endpoint (alias, user, port
// all honored via the user's ~/.ssh/config).
func newAPIHostSSHCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "host-ssh <name>",
		Short: "Emit the ssh argv to reach a host's machine as JSON",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			reg, err := loadRegistry()
			if err != nil {
				return err
			}
			h, err := reg.Get(args[0])
			if err != nil {
				return err
			}
			if h.SSH == "" {
				return emitJSON(map[string]any{"ok": false, "reason": "this host isn't reached over SSH (local/skyvm)"})
			}
			u, perr := url.Parse(h.SSH)
			if perr != nil || u.Hostname() == "" {
				return emitJSON(map[string]any{"ok": false, "reason": "could not parse the host's ssh endpoint"})
			}
			user := ""
			if u.User != nil {
				user = u.User.Username()
			}
			target := u.Hostname()
			if user != "" {
				target = user + "@" + target
			}
			sshArgs := []string{}
			if p := u.Port(); p != "" && p != "22" {
				sshArgs = append(sshArgs, "-p", p)
			}
			sshArgs = append(sshArgs, target)
			return emitJSON(map[string]any{"ok": true, "target": target, "args": sshArgs})
		},
	}
}

func runComposeOnHost(host, file string, dockerArgs ...string) error {
	if _, err := os.Stat(file); err != nil {
		return fmt.Errorf("compose file not found: %s", file)
	}
	reg, err := loadRegistry()
	if err != nil {
		return err
	}
	h, err := reg.Get(host)
	if err != nil {
		return err
	}
	argv := append([]string{"compose", "-f", file}, dockerArgs...)
	c := exec.Command("docker", argv...)
	c.Stdout, c.Stderr = os.Stdout, os.Stderr
	c.Env = os.Environ()
	if dh := dockerHostEnv(h); dh != "" {
		c.Env = append(c.Env, "DOCKER_HOST="+dh)
	}
	return c.Run()
}

type apiHost struct {
	Name        string `json:"name"`
	Kind        string `json:"kind"` // local | skyvm | ssh
	Description string `json:"description,omitempty"`
	Up          bool   `json:"up"`
	Engine      string `json:"engine,omitempty"`
	Error       string `json:"error,omitempty"`
}

func hostKind(h *config.Host) string {
	switch {
	case h.IsSkyVM():
		return "skyvm"
	case h.IsLocal():
		return "local"
	default:
		return "ssh"
	}
}

func newAPIHostsCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "hosts",
		Short: "List hosts with reachability + engine version",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			reg, err := loadRegistry()
			if err != nil {
				return err
			}
			hosts := reg.All()
			out := make([]apiHost, len(hosts))
			var wg sync.WaitGroup
			for i, h := range hosts {
				out[i] = apiHost{Name: h.Name, Kind: hostKind(h), Description: h.Description}
				wg.Add(1)
				go func(i int, h *config.Host) {
					defer wg.Done()
					if h.IsSkyVM() && !skyVMSocketPresent(h) {
						return // VM down → reported as up:false, no error noise
					}
					ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
					defer cancel()
					eng, err := core.Connect(ctx, h)
					if err != nil {
						out[i].Error = err.Error()
						return
					}
					defer eng.Close()
					ver, err := eng.Ping(ctx)
					if err != nil {
						out[i].Error = err.Error()
						return
					}
					out[i].Up = true
					out[i].Engine = ver
				}(i, h)
			}
			wg.Wait()
			return emitJSON(out)
		},
	}
}

type apiContainer struct {
	Host    string   `json:"host"`
	ID      string   `json:"id"`
	Name    string   `json:"name"`
	Image   string   `json:"image"`
	State   string   `json:"state"`
	Status  string   `json:"status"`
	Ports   []string `json:"ports"`
	Compose string   `json:"compose,omitempty"`
	Service string   `json:"service,omitempty"`
}

func newAPIPsCmd() *cobra.Command {
	var all bool
	cmd := &cobra.Command{
		Use:   "ps [host]",
		Short: "List containers as JSON (one host, or all if none given)",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			reg, err := loadRegistry()
			if err != nil {
				return err
			}
			var hosts []*config.Host
			if len(args) == 1 {
				h, err := reg.Get(args[0])
				if err != nil {
					return err
				}
				hosts = []*config.Host{h}
			} else {
				hosts = reg.All()
			}
			cs := gather(hosts, all)
			out := make([]apiContainer, 0, len(cs))
			for _, c := range cs {
				out = append(out, apiContainer{
					Host: c.Host, ID: c.ID, Name: c.Name, Image: c.Image,
					State: c.State, Status: c.Status, Ports: c.Ports,
					Compose: c.Compose, Service: c.Service,
				})
			}
			sort.Slice(out, func(i, j int) bool {
				if out[i].Host != out[j].Host {
					return out[i].Host < out[j].Host
				}
				return out[i].Name < out[j].Name
			})
			return emitJSON(out)
		},
	}
	cmd.Flags().BoolVarP(&all, "all", "a", true, "include stopped containers")
	return cmd
}

type apiLog struct {
	Time      string `json:"time,omitempty"` // RFC3339Nano, empty if none
	Host      string `json:"host"`
	Container string `json:"container"`
	Stream    string `json:"stream"`
	Severity  string `json:"severity,omitempty"`
	Message   string `json:"message"`
}

func newAPILogsCmd() *cobra.Command {
	var follow bool
	var tail, since string
	cmd := &cobra.Command{
		Use:   "logs <[host/]container>",
		Short: "Stream parsed logs as NDJSON",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := signalContext()
			defer cancel()
			eng, c, err := resolveTarget(ctx, args[0])
			if err != nil {
				return err
			}
			defer eng.Close()

			enc := json.NewEncoder(os.Stdout)
			return eng.StreamLogs(ctx, c, core.LogOptions{Follow: follow, Tail: tail, Since: since}, func(l core.LogLine) {
				rec := apiLog{
					Host: l.Host, Container: l.Container, Stream: l.Stream,
					Severity: l.Severity, Message: l.Message,
				}
				if l.HasTime {
					rec.Time = l.Time.Format(time.RFC3339Nano)
				}
				_ = enc.Encode(rec) // newline-delimited; os.Stdout is unbuffered
			})
		},
	}
	cmd.Flags().BoolVarP(&follow, "follow", "f", false, "stream new log lines")
	cmd.Flags().StringVar(&tail, "tail", "300", "lines of history (\"all\" or N)")
	cmd.Flags().StringVar(&since, "since", "", "only logs since (e.g. 10m, RFC3339)")
	return cmd
}

func newAPIActionCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "action <start|stop|restart> <[host/]container>",
		Short: "Run a lifecycle action, reporting JSON",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			action := args[0]
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			eng, c, err := resolveTarget(ctx, args[1])
			if err != nil {
				return err
			}
			defer eng.Close()
			switch action {
			case "start":
				err = eng.Start(ctx, c.ID)
			case "stop":
				err = eng.Stop(ctx, c.ID)
			case "restart":
				err = eng.Restart(ctx, c.ID)
			default:
				return fmt.Errorf("unknown action %q (want start|stop|restart)", action)
			}
			if err != nil {
				return err
			}
			return emitJSON(map[string]any{"ok": true, "action": action, "container": c.Name})
		},
	}
}

// emitJSON writes a value as indented JSON to stdout.
func emitJSON(v any) error {
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	return enc.Encode(v)
}
