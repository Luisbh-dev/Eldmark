//go:build !unix

package testdb

// startWatchdog does nothing outside Unix (there is no sh): if the process dies without going
// through Main, the cluster is collected by the next run (reapStale).
func (c *cluster) startWatchdog() error { return nil }
