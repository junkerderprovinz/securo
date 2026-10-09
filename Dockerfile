# syntax=docker/dockerfile:1.27@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# Securo for Unraid: the official backend image with the official frontend's
# static build, nginx, the Celery worker and scheduler, and on request a
# built-in PostgreSQL with pgvector and Redis, all under s6-overlay.
#
# GitHub:  https://github.com/junkerderprovinz/securo
# Image:   ghcr.io/junkerderprovinz/securo
# License: AGPL-3.0-only

# The component versions live only here, where Renovate bumps them. Backend and
# frontend are released together upstream and share the version.
ARG SECURO_VERSION=0.16.3
ARG POSTGRES_MAJOR=16
ARG S6_OVERLAY_VERSION=3.2.0.2

ARG SECURO_VERSION
FROM ghcr.io/securo-finance/securo-frontend:${SECURO_VERSION} AS frontend

FROM tianon/gosu:1.19@sha256:5afac3970da83806ba3d7789a3a42da92fbe4f703d94984c601e183208d035d3 AS gosu

ARG SECURO_VERSION
FROM ghcr.io/securo-finance/securo-backend:${SECURO_VERSION}

ARG SECURO_VERSION
ARG POSTGRES_MAJOR
ARG S6_OVERLAY_VERSION
ARG TARGETARCH

LABEL org.opencontainers.image.title="Securo" \
      org.opencontainers.image.description="Securo personal finance manager in one container for Unraid" \
      org.opencontainers.image.source="https://github.com/junkerderprovinz/securo" \
      org.opencontainers.image.licenses="AGPL-3.0-only" \
      org.opencontainers.image.vendor="junkerderprovinz" \
      io.github.junkerderprovinz.securo.upstream-version="${SECURO_VERSION}" \
      maintainer="junkerderprovinz"

# pipefail, so a failing curl in `curl | tar` stops the build.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# PostgreSQL comes from the PGDG archive because Debian ships one major per
# release: the built-in database must stay on the major its data directory was
# created with, and 16 is the one upstream's compose file runs. Debian's
# postgresql-common would otherwise create a cluster under /var/lib right away.
# The archives track security fixes within each series, so the versions are
# left to them.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && install -d /usr/share/postgresql-common/pgdg /etc/postgresql-common/createcluster.d \
    && curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
        https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    && . /etc/os-release \
    && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
        > /etc/apt/sources.list.d/pgdg.list \
    && echo "create_main_cluster = false" > /etc/postgresql-common/createcluster.d/no-main-cluster.conf \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        nginx \
        redis-server \
        "postgresql-${POSTGRES_MAJOR}" \
        "postgresql-${POSTGRES_MAJOR}-pgvector" \
        openssl \
        tzdata \
        xz-utils \
    && rm -f /etc/nginx/sites-enabled/default \
    && rm -rf /var/lib/apt/lists/*

ENV PATH="/usr/lib/postgresql/${POSTGRES_MAJOR}/bin:${PATH}"

COPY --from=gosu /gosu /usr/local/bin/gosu

# s6-overlay names its release files after the machine architecture, not TARGETARCH.
RUN case "${TARGETARCH}" in \
        amd64)  S6_ARCH="x86_64"   ;; \
        arm64)  S6_ARCH="aarch64"  ;; \
        *)      echo "Unsupported arch: ${TARGETARCH}" && exit 1 ;; \
    esac \
    && S6_BASE="https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}" \
    && curl -fsSL "${S6_BASE}/s6-overlay-noarch.tar.xz"     | tar -C / -Jxp \
    && curl -fsSL "${S6_BASE}/s6-overlay-${S6_ARCH}.tar.xz" | tar -C / -Jxp

# The frontend image serves this directory with its own nginx; the API proxy in
# front of it moves into /defaults/nginx.conf.
COPY --from=frontend /usr/share/nginx/html /usr/share/securo/html

COPY rootfs/ /

COPY .github/assets/banner-raw.txt /usr/local/share/banner-raw.txt
RUN tr -d '\r' < /usr/local/share/banner-raw.txt > /usr/local/share/banner.txt \
    && rm /usr/local/share/banner-raw.txt \
    && find /etc/cont-init.d /etc/services.d /usr/local/bin -type f -print0 | xargs -0 chmod +x \
    && test -f /usr/share/securo/html/index.html

# Every exit 1 in cont-init.d is a setting the user has to fix, so the container
# stops instead of starting the services on top of it.
ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    SECURO_VERSION=${SECURO_VERSION} \
    POSTGRES_MAJOR=${POSTGRES_MAJOR}

VOLUME /data

EXPOSE 8080

# The backend is asked first, so checks during the migrations leave no
# connection errors in nginx's log.
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD ["sh", "-c", "curl -fsS -o /dev/null http://127.0.0.1:8000/api/health && curl -fsS -o /dev/null http://127.0.0.1:8080/api/health"]

# The base image's CMD starts uvicorn; under /init it would run as the container's
# main program and take the container down whenever it exits.
ENTRYPOINT ["/init"]
CMD []
