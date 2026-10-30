// Package deploy guarda el despliegue de la plataforma (docs/plataforma.md §10 y §12): Dockerfile,
// docker-compose.yml, Caddyfile, journald-eldmark.conf, staging.env.example y
// production.env.example, y los scripts dev.sh, backup.sh, restore_check.sh y pitr_check.sh (con
// sus funciones comunes en pglib.sh). No tiene código: sus pruebas corren los scripts contra
// PostgreSQL efímeros y validan el compose y el Caddyfile.
package deploy
