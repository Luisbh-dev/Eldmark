# syntax=docker/dockerfile:1
# Image of one zone (TEC-20): the EXPORTED dedicated server ("Servidor Linux" preset, tools/export.sh server)
# on debian-slim, with an unprivileged user. The context is the root of the repository, filtered by
# zone.Dockerfile.dockerignore (only exports/server and the entrypoint go in):
#   tools/export.sh server
#   docker build -f platform/deploy/zone.Dockerfile -t eldmark-zone:local .
# docker-compose.yml (profile zonas) builds it the same way.
#
# Shutdown: Godot scripts cannot catch SIGTERM or SIGINT (docs/networking.md 1.3), so the entrypoint does it and
# creates the server's --stop-file, which makes the zone announce the shutdown, save every character and
# deregister. Health: the entrypoint passes --report and the HEALTHCHECK looks at how fresh that file is (the
# zone rewrites it every 10 s).
FROM debian:bookworm-slim

ARG SERVER_DIR=exports/server

RUN apt-get update \
	&& apt-get install -y --no-install-recommends ca-certificates \
	&& rm -rf /var/lib/apt/lists/* \
	&& useradd --system --uid 10001 --user-group --create-home --home-dir /home/eldmark --shell /usr/sbin/nologin eldmark \
	&& mkdir -p /opt/eldmark /run/eldmark \
	&& chown eldmark:eldmark /run/eldmark

COPY ${SERVER_DIR}/ /opt/eldmark/
COPY platform/deploy/zone-entrypoint.sh /usr/local/bin/zone-entrypoint.sh
RUN chmod 0755 /opt/eldmark/eldmark-server.x86_64 /usr/local/bin/zone-entrypoint.sh

ENV HOME=/home/eldmark \
	ELDMARK_RUN_DIR=/run/eldmark
USER eldmark:eldmark
WORKDIR /opt/eldmark
EXPOSE 24600/udp

# The report is rewritten every 10 s; 45 s without a rewrite is a stuck tick loop. The first one arrives once the
# zone has loaded, hence the start period.
HEALTHCHECK --interval=15s --timeout=5s --start-period=90s --retries=3 \
	CMD ["/usr/local/bin/zone-entrypoint.sh", "--healthcheck"]

ENTRYPOINT ["/usr/local/bin/zone-entrypoint.sh"]
CMD ["--server", "--zone=vado_gris"]
