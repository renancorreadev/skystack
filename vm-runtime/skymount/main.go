//go:build linux

// Command skymount performs a mount(2) syscall directly and, on failure, prints
// rich diagnostics — busybox's mount applet hides the real errno behind a
// generic message inside a minimal initramfs.
//
// Usage: skymount <source> <target> <fstype> [data]
package main

import (
	"fmt"
	"os"
	"syscall"
)

func main() {
	if len(os.Args) < 4 {
		fmt.Fprintln(os.Stderr, "usage: skymount <source> <target> <fstype> [data]")
		os.Exit(2)
	}
	source, target, fstype := os.Args[1], os.Args[2], os.Args[3]
	data := ""
	if len(os.Args) > 4 {
		data = os.Args[4]
	}

	// Can we open the source block device at all?
	if f, err := os.OpenFile(source, os.O_RDONLY, 0); err != nil {
		fmt.Fprintf(os.Stderr, "skymount: open(%s) failed: %v\n", source, err)
	} else {
		b := make([]byte, 4)
		n, _ := f.Read(b)
		f.Close()
		fmt.Fprintf(os.Stderr, "skymount: open(%s) ok, read %d bytes: % x\n", source, n, b[:n])
	}
	if fi, err := os.Stat(target); err != nil {
		fmt.Fprintf(os.Stderr, "skymount: stat(%s) failed: %v\n", target, err)
	} else {
		fmt.Fprintf(os.Stderr, "skymount: target %s isdir=%v\n", target, fi.IsDir())
	}

	for _, fl := range []uintptr{0, syscall.MS_RDONLY} {
		err := syscall.Mount(source, target, fstype, fl, data)
		fmt.Fprintf(os.Stderr, "skymount: mount(%s,%s,%s,flags=%d) -> %v\n", source, target, fstype, fl, err)
		if err == nil {
			os.Exit(0)
		}
	}
	os.Exit(1)
}
