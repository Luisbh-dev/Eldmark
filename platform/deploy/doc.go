// Package deploy holds the platform deployment (docs/platform.md §10 and §12): Dockerfile,
// docker-compose.yml, Caddyfile, journald-eldmark.conf, staging.env.example and
// production.env.example, and the scripts dev.sh, backup.sh, restore_check.sh and pitr_check.sh
// (with their common functions in pglib.sh). It has no code: its tests run the scripts against
// ephemeral PostgreSQL instances and validate the compose file and the Caddyfile.
package deploy
