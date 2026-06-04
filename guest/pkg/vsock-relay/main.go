// vsock-relay is the guest side of Velox's Docker API bridge. It listens on a
// VSOCK data port and, for each connection from the host, dials an upstream
// (dockerd) and copies bytes both ways. With -echo it loops bytes back instead.
//
// It also listens on a control port: connecting there triggers sync(2) (which
// flushes ALL guest filesystems, regardless of container namespace) and returns
// "OK". The host calls this before stopping the VM so the persistent data disk
// is durable without depending on ACPI shutdown.
//
// The VSOCK listeners bind AF_VSOCK directly via raw syscalls (CID =
// VMADDR_CID_ANY), needing neither /dev/vsock nor a third-party vsock library.
package main

import (
	"bufio"
	"flag"
	"io"
	"log"
	"net"
	"os"
	"strings"
	"sync"

	"golang.org/x/sys/unix"
)

func main() {
	port := flag.Uint("port", 2375, "VSOCK data port (bridged to dockerd)")
	control := flag.Uint("control-port", 2374, "VSOCK control port (sync on connect)")
	reverse := flag.Uint("reverse-port", 2376, "VSOCK reverse port-forward port")
	connect := flag.String("connect", "unix:///run/docker.sock",
		"upstream to dial per connection: unix:///path or tcp://host:port")
	echo := flag.Bool("echo", false, "echo bytes back instead of dialing -connect")
	flag.Parse()

	dataFd := mustListen(uint32(*port))
	controlFd := mustListen(uint32(*control))
	reverseFd := mustListen(uint32(*reverse))
	log.Printf("vsock-relay: data=%d control=%d reverse=%d echo=%v connect=%s",
		*port, *control, *reverse, *echo, *connect)

	go acceptLoop(controlFd, handleControl)
	go acceptLoop(reverseFd, handleReverse)
	acceptLoop(dataFd, func(vfd int) { handleData(vfd, *connect, *echo) })
}

// handleReverse forwards a host connection to a guest-published port. The host
// sends a one-line header "<port>\n" (or "host:port\n"); we dial it and pipe.
// Used for `-p` published ports → localhost on the Mac.
func handleReverse(vfd int) {
	vsock := os.NewFile(uintptr(vfd), "vsock-rev")
	defer vsock.Close()

	br := bufio.NewReader(vsock)
	line, err := br.ReadString('\n')
	if err != nil {
		return
	}
	target := strings.TrimSpace(line)
	if target == "" {
		return
	}
	if !strings.Contains(target, ":") {
		target = "127.0.0.1:" + target
	}
	up, err := net.Dial("tcp", target)
	if err != nil {
		log.Printf("reverse dial %s: %v", target, err)
		return
	}
	defer up.Close()

	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); io.Copy(up, br); closeWrite(up) }() // vsock (+buffered) -> upstream
	go func() { defer wg.Done(); io.Copy(vsock, up); closeWrite(vsock) }()
	wg.Wait()
}

func mustListen(port uint32) int {
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM, 0)
	if err != nil {
		log.Fatalf("vsock socket: %v", err)
	}
	if err := unix.Bind(fd, &unix.SockaddrVM{CID: unix.VMADDR_CID_ANY, Port: port}); err != nil {
		log.Fatalf("vsock bind port %d: %v", port, err)
	}
	if err := unix.Listen(fd, 128); err != nil {
		log.Fatalf("vsock listen port %d: %v", port, err)
	}
	return fd
}

func acceptLoop(fd int, h func(int)) {
	for {
		nfd, _, err := unix.Accept(fd)
		if err != nil {
			log.Printf("accept: %v", err)
			continue
		}
		go h(nfd)
	}
}

// handleControl flushes all filesystems and acknowledges.
func handleControl(vfd int) {
	f := os.NewFile(uintptr(vfd), "control")
	defer f.Close()
	unix.Sync()
	f.Write([]byte("OK\n"))
}

func handleData(vfd int, target string, echo bool) {
	vsock := os.NewFile(uintptr(vfd), "vsock")
	defer vsock.Close()

	if echo {
		io.Copy(vsock, vsock)
		return
	}

	up, err := dial(target)
	if err != nil {
		log.Printf("dial %s: %v", target, err)
		return
	}
	defer up.Close()

	// Half-close each direction independently so Docker's hijacked streams
	// (attach/logs -f/exec -it) aren't truncated when one side stops writing.
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); io.Copy(up, vsock); closeWrite(up) }()
	go func() { defer wg.Done(); io.Copy(vsock, up); closeWrite(vsock) }()
	wg.Wait()
}

// closeWrite shuts down only the write side, propagating EOF to the peer.
func closeWrite(c interface{}) {
	switch v := c.(type) {
	case *net.TCPConn:
		v.CloseWrite()
	case *net.UnixConn:
		v.CloseWrite()
	case *os.File:
		if rc, err := v.SyscallConn(); err == nil {
			rc.Control(func(fd uintptr) { unix.Shutdown(int(fd), unix.SHUT_WR) })
		}
	}
}

func dial(target string) (net.Conn, error) {
	switch {
	case strings.HasPrefix(target, "tcp://"):
		return net.Dial("tcp", strings.TrimPrefix(target, "tcp://"))
	case strings.HasPrefix(target, "unix://"):
		return net.Dial("unix", strings.TrimPrefix(target, "unix://"))
	default:
		return net.Dial("unix", target)
	}
}
