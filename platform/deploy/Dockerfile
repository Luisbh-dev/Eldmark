# syntax=docker/dockerfile:1
# Imágenes de la plataforma (docs/plataforma.md §12). El contexto es platform/:
#   docker build -f deploy/Dockerfile --target platform -t eldmark-platform platform
#   docker build -f deploy/Dockerfile --target ops -t eldmark-ops platform
# docker-compose.yml las construye igual. Los textos legales van dentro del binario (embed).

# Compilación: binario estático (sin cgo), con el toolchain fijo de go.mod (§2.2).
FROM golang:1.24.7-bookworm AS build
ENV CGO_ENABLED=0 GOTOOLCHAIN=local
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN go build -trimpath -ldflags="-s -w" -o /out/eldmark-platform ./cmd/eldmark-platform

# platform: serve, migrate y admin sobre debian-slim, con un usuario sin privilegios. Escucha en
# todas las interfaces del contenedor: la pública (:24680) solo la alcanza Caddy por la red edge y
# la interna (:24681), las zonas por la red zones; el compose no publica ninguna de las dos.
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

# ops: las copias y sus comprobaciones (backup.sh, restore_check.sh, pitr_check.sh) sobre la imagen
# de PostgreSQL 16, que trae pg_dump, pg_restore, initdb y pg_ctl de la misma versión que la base,
# con el mismo binario de la plataforma (reapply-purges y migrate en restore_check.sh). Corre como
# root y los scripts levantan sus clústeres de prueba con el usuario postgres (runuser).
FROM postgres:16-bookworm AS ops
COPY --from=build /out/eldmark-platform /usr/local/bin/eldmark-platform
COPY deploy/pglib.sh deploy/backup.sh deploy/restore_check.sh deploy/pitr_check.sh /opt/eldmark/deploy/
ENV ELDMARK_PLATFORM_BIN=/usr/local/bin/eldmark-platform \
	ELDMARK_PG_BIN=/usr/lib/postgresql/16/bin \
	TMPDIR=/tmp
ENTRYPOINT []
CMD ["/opt/eldmark/deploy/restore_check.sh", "--help"]

# La imagen por defecto (sin --target) es la de la plataforma.
FROM platform
