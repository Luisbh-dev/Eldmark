# syntax=docker/dockerfile:1
# Platform images (docs/platform.md §12). The context is platform/:
#   docker build -f deploy/Dockerfile --target platform -t eldmark-platform platform
#   docker build -f deploy/Dockerfile --target ops -t eldmark-ops platform
# docker-compose.yml builds them the same way. The legal texts go inside the binary (embed).

# Build: static binary (no cgo), with the toolchain pinned in go.mod (§2.2).
FROM golang:1.24.7-bookworm AS build
ENV CGO_ENABLED=0 GOTOOLCHAIN=local
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN go build -trimpath -ldflags="-s -w" -o /out/eldmark-platform ./cmd/eldmark-platform

# platform: serve, migrate and admin on debian-slim, with an unprivileged user. It listens on all
# the container's interfaces: the public one (:24680) is reached only by Caddy over the edge network
# and the internal one (:24681) by the zones over the zones network; the compose file publishes
# neither.
FROM debian:bookworm-slim AS platform
RUN apt-get update \
	&& apt-get install -y --no-install-recommends ca-certificates tzdata \
	&& rm -rf /var/lib/apt/lists/* \
	&& useradd --system --uid 10001 --user-group --no-create-home --shell /usr/sbin/nologin eldmark
COPY --from=build /out/eldmark-platform /usr/local/bin/eldmark-platform
ENV ELDMARK_PUBLIC_ADDR=0.0.0.0:24680 \
	ELDMARK_INTERNAL_ADDR=0.0.0.0:24681
USER eldmark:eldmark
EXPOSE 24680 24681
ENTRYPOINT ["/usr/local/bin/eldmark-platform"]
CMD ["serve"]

# ops: the backups and their checks (backup.sh, restore_check.sh, pitr_check.sh) on top of the
# PostgreSQL 16 image, which ships pg_dump, pg_restore, initdb and pg_ctl of the same version as the
# database, with the same platform binary (reapply-purges and migrate in restore_check.sh). It runs
# as root and the scripts bring up their test clusters with the postgres user (runuser).
FROM postgres:16-bookworm AS ops
COPY --from=build /out/eldmark-platform /usr/local/bin/eldmark-platform
COPY deploy/pglib.sh deploy/backup.sh deploy/restore_check.sh deploy/pitr_check.sh /opt/eldmark/deploy/
ENV ELDMARK_PLATFORM_BIN=/usr/local/bin/eldmark-platform \
	ELDMARK_PG_BIN=/usr/lib/postgresql/16/bin \
	TMPDIR=/tmp
ENTRYPOINT []
CMD ["/opt/eldmark/deploy/restore_check.sh", "--help"]

# The default image (without --target) is the platform one.
FROM platform
