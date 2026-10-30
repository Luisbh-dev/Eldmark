//go:build unix

package testdb

import (
	"os"
	"os/exec"
	"syscall"
)

// watchdogScript es el vigilante: espera una línea en la entrada; con «done» (Main terminó bien y
// ya limpió) sale sin tocar nada; con el fin de la tubería (el proceso de pruebas murió: un pánico,
// el plazo de go test, una señal, un kill -9) para el servidor y borra la carpeta.
const watchdogScript = `dir=$1; shift
read -r line
[ "$line" = done ] && exit 0
"$@" >/dev/null 2>&1
rm -rf "$dir"`

// startWatchdog lanza el vigilante del clúster: un sh en su propio grupo de procesos (un Ctrl-C a
// go test no le llega) con la entrada en una tubería cuyo extremo de escritura solo tiene este
// proceso. Al morir este, el sistema cierra la tubería y el sh limpia; Main, al acabar, le escribe
// «done» ([cluster.stopWatchdog]).
func (c *cluster) startWatchdog() error {
	r, w, err := os.Pipe()
	if err != nil {
		return err
	}
	stop := c.argv("pg_ctl", "-s", "-D", c.dir+"/data", "-m", "immediate", "stop")
	cmd := exec.Command("/bin/sh", append([]string{"-c", watchdogScript, "eldmark-testdb-vigilante", c.dir}, stop...)...)
	cmd.Stdin = r
	cmd.Dir = c.dir
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	err = cmd.Start()
	r.Close()
	if err != nil {
		w.Close()
		return err
	}
	c.watchdog, c.watchdogPipe = cmd, w
	return nil
}
