//go:build !unix

package testdb

// processAlive no sabe mirarlo fuera de Unix: nunca da por muerto a nadie, así que no se borra
// ningún clúster ajeno.
func processAlive(int) bool { return true }
