package core

import (
	"context"
	"encoding/json"
)

// StatsSample is one resource snapshot of a container.
type StatsSample struct {
	CPUPercent float64 `json:"cpu"`
	MemUsed    int64   `json:"memUsed"`
	MemLimit   int64   `json:"memLimit"`
	MemPercent float64 `json:"memPercent"`
	NetRx      int64   `json:"netRx"`
	NetTx      int64   `json:"netTx"`
}

// dockerStats mirrors the subset of Docker's stats JSON we use.
type dockerStats struct {
	CPUStats    cpuStats `json:"cpu_stats"`
	PreCPUStats cpuStats `json:"precpu_stats"`
	MemoryStats struct {
		Usage int64            `json:"usage"`
		Limit int64            `json:"limit"`
		Stats map[string]int64 `json:"stats"`
	} `json:"memory_stats"`
	Networks map[string]struct {
		RxBytes int64 `json:"rx_bytes"`
		TxBytes int64 `json:"tx_bytes"`
	} `json:"networks"`
}

type cpuStats struct {
	CPUUsage struct {
		TotalUsage int64 `json:"total_usage"`
	} `json:"cpu_usage"`
	SystemUsage int64 `json:"system_cpu_usage"`
	OnlineCPUs  int   `json:"online_cpus"`
}

// StreamStats streams resource samples for a container until ctx is cancelled.
func (e *Engine) StreamStats(ctx context.Context, id string, sink func(StatsSample)) error {
	resp, err := e.Docker.ContainerStats(ctx, id, true)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	dec := json.NewDecoder(resp.Body)
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		var s dockerStats
		if err := dec.Decode(&s); err != nil {
			return err
		}
		sink(toSample(s))
	}
}

// SnapshotStats returns a single resource sample. It reads two frames so CPU%
// is a real delta (the first frame's precpu is the previous read); if only one
// frame arrives, that sample is returned as-is.
func (e *Engine) SnapshotStats(ctx context.Context, id string) (StatsSample, error) {
	resp, err := e.Docker.ContainerStats(ctx, id, true)
	if err != nil {
		return StatsSample{}, err
	}
	defer resp.Body.Close()
	dec := json.NewDecoder(resp.Body)
	var sample StatsSample
	for i := 0; i < 2; i++ {
		var s dockerStats
		if err := dec.Decode(&s); err != nil {
			if i == 0 {
				return StatsSample{}, err
			}
			break
		}
		sample = toSample(s)
	}
	return sample, nil
}

func toSample(s dockerStats) StatsSample {
	out := StatsSample{}

	cpuDelta := float64(s.CPUStats.CPUUsage.TotalUsage - s.PreCPUStats.CPUUsage.TotalUsage)
	sysDelta := float64(s.CPUStats.SystemUsage - s.PreCPUStats.SystemUsage)
	cpus := s.CPUStats.OnlineCPUs
	if cpus == 0 {
		cpus = 1
	}
	if sysDelta > 0 && cpuDelta > 0 {
		out.CPUPercent = (cpuDelta / sysDelta) * float64(cpus) * 100
	}

	used := s.MemoryStats.Usage
	// cgroup v2 reports inactive_file in stats; subtract it for the "real" working set.
	if inactive, ok := s.MemoryStats.Stats["inactive_file"]; ok {
		used -= inactive
	} else if cache, ok := s.MemoryStats.Stats["cache"]; ok {
		used -= cache
	}
	if used < 0 {
		used = 0
	}
	out.MemUsed = used
	out.MemLimit = s.MemoryStats.Limit
	if s.MemoryStats.Limit > 0 {
		out.MemPercent = float64(used) / float64(s.MemoryStats.Limit) * 100
	}

	for _, n := range s.Networks {
		out.NetRx += n.RxBytes
		out.NetTx += n.TxBytes
	}
	return out
}
