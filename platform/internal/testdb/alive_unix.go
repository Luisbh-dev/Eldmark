//go:build unix

package testdb

import (
	"errors"
	"syscall"
)

// processAlive says whether process pid is still alive (signal 0 is not sent, only checked).
func processAlive(pid int) bool {
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}
