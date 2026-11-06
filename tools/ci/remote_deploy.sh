#!/usr/bin/env bash
# Runs ON THE VPS (deploy.yml sends it over SSH; docs/operations.md): points the stack at a new image tag, applies the
# migrations, restarts what changed and waits for the zones to be healthy. The previous tags are kept so that a
# rollback is one command.
#
# Usage: remote_deploy.sh <deploy_dir> <image_prefix> <tag> deploy
#        remote_deploy.sh <deploy_dir> <image_prefix> - rollback
#   deploy_dir    folder with docker-compose.yml, staging.env and secrets/
#   image_prefix  for example ghcr.io/luisbh-dev/eldmark (the images are <prefix>-zone, -platform and -ops)
#   tag           image tag to deploy
set -euo pipefail

DIR="${1:?deploy_dir}"
PREFIX="${2:?image_prefix}"
TAG="${3:?tag}"
ACTION="${4:?deploy or rollback}"
cd "$DIR"

IMAGES="images.env"
compose() {
	docker compose --env-file staging.env --env-file "$IMAGES" --profile zonas "$@"
}

case "$ACTION" in
	deploy)
		if [ -f "$IMAGES" ]; then
			cp "$IMAGES" "$IMAGES.previous"
		fi
		{
			echo "ELDMARK_PLATFORM_IMAGE=$PREFIX-platform:$TAG"
			echo "ELDMARK_OPS_IMAGE=$PREFIX-ops:$TAG"
			echo "ELDMARK_ZONE_IMAGE=$PREFIX-zone:$TAG"
		} > "$IMAGES"
		;;
	rollback)
		[ -f "$IMAGES.previous" ] || { echo "There is no previous deployment to go back to" >&2; exit 1; }
		cp "$IMAGES" "$IMAGES.failed"
		cp "$IMAGES.previous" "$IMAGES"
		;;
	*)
		echo "Unknown action: $ACTION" >&2
		exit 1
		;;
esac

echo "Images:"
cat "$IMAGES"
compose pull
compose up -d db
compose run --rm platform migrate up
# A zone whose image changed is stopped with SIGTERM and gets stop_grace_period (45 s) to save and deregister.
compose up -d --remove-orphans

for _ in $(seq 1 60); do
	state="$(compose ps --format '{{.Service}} {{.Health}}' | grep -E '^zone-' || true)"
	if [ -n "$state" ] && ! echo "$state" | grep -qvE ' healthy$'; then
		echo "Zones healthy:"
		echo "$state"
		exit 0
	fi
	sleep 5
done
echo "The zones are not healthy after 5 minutes; roll back with: $0 $DIR $PREFIX - rollback" >&2
compose ps >&2
exit 1
