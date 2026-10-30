//go:build unix

package testdb

import (
	"errors"
	"syscall"
)

// processAlive dice si el proceso pid sigue vivo (la señal 0 no se envía, solo se comprueba).
func processAlive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}
