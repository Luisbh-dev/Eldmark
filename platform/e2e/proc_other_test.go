//go:build e2e && !linux

package e2e

import "os/exec"

// setDeathSignal does nothing outside Linux: there the Godot processes are stopped in the test's
// cleanup.
func setDeathSignal(*exec.Cmd) {}
