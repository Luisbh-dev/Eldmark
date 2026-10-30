//go:build !unix

package testdb

// startWatchdog no hace nada fuera de Unix (no hay sh): si el proceso muere sin pasar por Main, el
// clúster lo recoge la siguiente ejecución (reapStale).
func (c *cluster) startWatchdog() error { return nil }
