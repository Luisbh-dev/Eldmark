//go:build !unix

package testdb

// processAlive does not know how to check this outside Unix: it never considers anyone dead, so
// no foreign cluster is deleted.
func processAlive(int) bool { return true }
