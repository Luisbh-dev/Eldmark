//go:build e2e && linux

package e2e

import (
	"os/exec"
	"syscall"
)

// setDeathSignal hace que el núcleo mate el proceso de Godot si la prueba muere antes de pararlo (un pánico, el
// plazo de go test, un Ctrl-C): ninguna zona ni ningún bot sobrevive a la prueba que lo lanzó.
func setDeathSignal(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGKILL}
}
