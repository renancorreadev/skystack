package core

import (
	"context"
	"encoding/json"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/docker/docker/api/types"
	"github.com/docker/docker/api/types/container"
)

// ContainerUsage is one container's slice of resource usage (for "top consumers").
type ContainerUsage struct {
	Name string  `json:"name"`
	CPU  float64 `json:"cpu"`
	Mem  int64   `json:"mem"`
}

// HardwareSample is a host's capacity, system info, and the live aggregate
// resource usage of its containers — including the heaviest consumers.
type HardwareSample struct {
	CPU        float64 `json:"cpu"`
	CPUs       int     `json:"cpus"`
	MemUsed    int64   `json:"memUsed"`
	MemTotal   int64   `json:"memTotal"`
	MemPercent float64 `json:"memPercent"`
	NetRx      int64   `json:"netRx"`
	NetTx      int64   `json:"netTx"`
	Containers int     `json:"containers"`
	Running    int     `json:"running"`

	OS            string `json:"os,omitempty"`
	Kernel        string `json:"kernel,omitempty"`
	Arch          string `json:"arch,omitempty"`
	ServerVersion string `json:"serverVersion,omitempty"`
	Images        int    `json:"images"`
	DiskUsed      int64  `json:"diskUsed"`

	TopCPU []ContainerUsage `json:"topCpu"`
	TopMem []ContainerUsage `json:"topMem"`
}

// StreamHardware samples aggregate hardware usage every 2s until ctx is done.
// Capacity + system info come from `docker info` (and disk from `docker df`),
// refreshed every ~10s; usage is the sum of each running container's one-shot
// stats. CPU% is derived from the change in container CPU time vs the host's
// system CPU time between ticks; per-container CPU% feeds the top-consumer lists.
func (e *Engine) StreamHardware(ctx context.Context, sink func(HardwareSample)) error {
	var (
		cpus         int
		memTotal     int64
		osName, kern string
		arch, srvVer string
		images       int
		disk         int64
		dmu          sync.Mutex
	)
	// docker info is fast; fetch it inline. docker df can be slow over SSH (it
	// walks every image layer) — run it in the background so the dashboard shows
	// immediately and disk fills in when it's ready.
	refreshInfo := func() {
		ictx, c := context.WithTimeout(ctx, 8*time.Second)
		if info, err := e.Docker.Info(ictx); err == nil {
			cpus, memTotal = info.NCPU, info.MemTotal
			osName, kern, arch = info.OperatingSystem, info.KernelVersion, info.Architecture
			srvVer, images = info.ServerVersion, info.Images
		}
		c()
		go func() {
			dctx, c2 := context.WithTimeout(ctx, 25*time.Second)
			defer c2()
			if du, err := e.Docker.DiskUsage(dctx, types.DiskUsageOptions{}); err == nil {
				d := du.LayersSize + du.BuilderSize
				for _, v := range du.Volumes {
					if v.UsageData != nil && v.UsageData.Size > 0 {
						d += v.UsageData.Size
					}
				}
				dmu.Lock()
				disk = d
				dmu.Unlock()
			}
		}()
	}

	prevTotal := map[string]int64{}
	var prevSystem int64
	count := 0

	sample := func() {
		if count%5 == 0 {
			refreshInfo()
		}
		count++

		all, err := e.Docker.ContainerList(ctx, container.ListOptions{All: true})
		if err != nil {
			return
		}
		names := map[string]string{}
		var runningIDs []string
		for _, c := range all {
			if c.State == "running" {
				runningIDs = append(runningIDs, c.ID)
				name := c.ID[:min(12, len(c.ID))]
				if len(c.Names) > 0 {
					name = strings.TrimPrefix(c.Names[0], "/")
				}
				names[c.ID] = name
			}
		}

		type res struct {
			id            string
			total, system int64
			mem, rx, tx   int64
			ok            bool
		}
		results := make([]res, len(runningIDs))
		var wg sync.WaitGroup
		sem := make(chan struct{}, 8)
		for i, id := range runningIDs {
			wg.Add(1)
			go func(i int, id string) {
				defer wg.Done()
				sem <- struct{}{}
				defer func() { <-sem }()
				cctx, cancel := context.WithTimeout(ctx, 8*time.Second)
				defer cancel()
				resp, err := e.Docker.ContainerStats(cctx, id, false)
				if err != nil {
					return
				}
				defer resp.Body.Close()
				var s dockerStats
				if json.NewDecoder(resp.Body).Decode(&s) != nil {
					return
				}
				mem := s.MemoryStats.Usage
				if inactive, ok := s.MemoryStats.Stats["inactive_file"]; ok {
					mem -= inactive
				}
				var rx, tx int64
				for _, n := range s.Networks {
					rx += n.RxBytes
					tx += n.TxBytes
				}
				results[i] = res{
					id: id, total: s.CPUStats.CPUUsage.TotalUsage, system: s.CPUStats.SystemUsage,
					mem: mem, rx: rx, tx: tx, ok: true,
				}
			}(i, id)
		}
		wg.Wait()

		var sumDelta, curSystem, memUsed, rx, tx int64
		curTotal := map[string]int64{}
		for _, r := range results {
			if !r.ok {
				continue
			}
			curTotal[r.id] = r.total
			if r.system > curSystem {
				curSystem = r.system
			}
			memUsed += r.mem
			rx += r.rx
			tx += r.tx
			if pt, ok := prevTotal[r.id]; ok {
				sumDelta += r.total - pt
			}
		}
		sysDelta := curSystem - prevSystem

		// Per-container usage for the top-consumer lists.
		usage := make([]ContainerUsage, 0, len(results))
		for _, r := range results {
			if !r.ok {
				continue
			}
			var pct float64
			if pt, ok := prevTotal[r.id]; ok && sysDelta > 0 {
				pct = float64(r.total-pt) / float64(sysDelta) * 100
			}
			usage = append(usage, ContainerUsage{Name: names[r.id], CPU: pct, Mem: r.mem})
		}
		prevTotal = curTotal
		prevSystem = curSystem

		topCPU := topN(usage, 5, func(a, b ContainerUsage) bool { return a.CPU > b.CPU })
		topMem := topN(usage, 5, func(a, b ContainerUsage) bool { return a.Mem > b.Mem })

		var cpuPct, memPct float64
		if prevSystem > 0 && sysDelta > 0 {
			cpuPct = float64(sumDelta) / float64(sysDelta) * 100
		}
		if memTotal > 0 {
			memPct = float64(memUsed) / float64(memTotal) * 100
		}

		dmu.Lock()
		curDisk := disk
		dmu.Unlock()
		sink(HardwareSample{
			CPU: cpuPct, CPUs: cpus, MemUsed: memUsed, MemTotal: memTotal, MemPercent: memPct,
			NetRx: rx, NetTx: tx, Containers: len(all), Running: len(runningIDs),
			OS: osName, Kernel: kern, Arch: arch, ServerVersion: srvVer, Images: images, DiskUsed: curDisk,
			TopCPU: topCPU, TopMem: topMem,
		})
	}

	sample()
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
			sample()
		}
	}
}

func topN(items []ContainerUsage, n int, less func(a, b ContainerUsage) bool) []ContainerUsage {
	s := make([]ContainerUsage, len(items))
	copy(s, items)
	sort.Slice(s, func(i, j int) bool { return less(s[i], s[j]) })
	if len(s) > n {
		s = s[:n]
	}
	return s
}
