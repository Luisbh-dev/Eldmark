//go:build e2e && !linux

package e2e

import "os/exec"

// setDeathSignal no hace nada fuera de Linux: allí los procesos de Godot se paran en la limpieza de la prueba.
func setDeathSignal(*exec.Cmd) {}
