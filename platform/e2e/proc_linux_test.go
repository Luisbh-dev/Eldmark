//go:build e2e && linux

package e2e

import (
	"os/exec"
	"syscall"
)

// setDeathSignal makes the kernel kill the Godot process if the test dies before stopping it (a
// panic, go test's timeout, a Ctrl-C): no zone or bot survives the test that launched it.
func setDeathSignal(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGKILL}
}
