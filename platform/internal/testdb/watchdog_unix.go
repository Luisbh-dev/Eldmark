//go:build unix

package testdb

import (
	"os"
	"os/exec"
	"syscall"
)

// watchdogScript is the watchdog: it waits for a line on its input; with "done" (Main finished
// cleanly and already cleaned up) it exits without touching anything; with the end of the pipe
// (the test process died: a panic, the go test deadline, a signal, a kill -9) it stops the server
// and deletes the folder.
const watchdogScript = `dir=$1; shift
read -r line
[ "$line" = done ] && exit 0
"$@" >/dev/null 2>&1
rm -rf "$dir"`

// startWatchdog launches the cluster's watchdog: an sh in its own process group (a Ctrl-C to go
// test does not reach it) with its input on a pipe whose write end only this process holds. When
// this one dies, the system closes the pipe and the sh cleans up; Main, when done, writes "done"
// to it ([cluster.stopWatchdog]).
func (c *cluster) startWatchdog() error {
	r, w, err := os.Pipe()
	if err != nil {
		return err
	}
	stop := c.argv("pg_ctl", "-s", "-D", c.dir+"/data", "-m", "immediate", "stop")
	cmd := exec.Command("/bin/sh", append([]string{"-c", watchdogScript, "eldmark-testdb-vigilante", c.dir}, stop...)...)
	cmd.Stdin = r
	cmd.Dir = c.dir
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	err = cmd.Start()
	r.Close()
	if err != nil {
		w.Close()
		return err
	}
	c.watchdog, c.watchdogPipe = cmd, w
	return nil
}
