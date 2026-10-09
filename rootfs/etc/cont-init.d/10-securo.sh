#!/command/with-contenv bash
# shellcheck shell=bash
# Runs on every start: checks the settings, keeps the generated secrets in
# /data/secrets.env, creates the built-in PostgreSQL when it is switched on, and
# hands the connection URLs to the services through the s6 environment.

log() { printf '[init] %s\n' "$*"; }

fail() {
    printf '[init] ERROR: %s\n' "$*" >&2
    exit 1
}

enabled() {
    case "${1,,}" in
        true | yes | on | 1) return 0 ;;
        *) return 1 ;;
    esac
}

# with-contenv reads the services' environment from this directory.
set_env() {
    printf '%s' "$2" > "/run/s6/container_environment/$1"
    export "$1=$2"
}

PUID="${PUID:-99}"
PGID="${PGID:-100}"
secrets=/data/secrets.env

# Prints a generated value from the secrets file, creating it on first use.
secret() {
    local value
    value=$(sed -n "s/^$1=//p" "$secrets")
    if [ -z "$value" ]; then
        value=$(openssl rand -hex 32)
        printf '%s=%s\n' "$1" "$value" >> "$secrets"
    fi
    printf '%s' "$value"
}

urlquote() {
    python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

# Builds the cluster next to its final place and moves it there only after the
# role, the database and pgvector exist, so an interrupted first start leaves
# nothing half done.
init_postgres() {
    local password=$1 datadir=/data/postgres.new
    rm -rf "$datadir"
    install -d -o postgres -g postgres -m 700 "$datadir"
    # Everything in this container runs as the uid that owns the data files, so
    # peer authentication on the socket would guard nothing; it would only break
    # when another account shares PUID. Securo itself logs in over TCP.
    gosu postgres initdb -D "$datadir" -U postgres -E UTF8 --locale=C.UTF-8 \
        --auth-local=trust --auth-host=scram-sha-256 > /dev/null \
        || fail "initdb could not create the built-in database in $datadir."
    if ! gosu postgres pg_ctl -D "$datadir" -o "-c listen_addresses=''" \
        -l /tmp/postgres-init.log -w -s start; then
        cat /tmp/postgres-init.log >&2
        fail "The built-in PostgreSQL did not come up for its first setup."
    fi
    gosu postgres psql -X -q -U postgres -v ON_ERROR_STOP=1 -v password="$password" -d postgres <<'SQL' \
        || fail "Could not create the securo role and database."
CREATE ROLE securo LOGIN PASSWORD :'password';
CREATE DATABASE securo OWNER securo;
\connect securo
CREATE EXTENSION vector;
SQL
    gosu postgres pg_ctl -D "$datadir" -w -s stop
    mv "$datadir" /data/postgres
}

install -d -m 755 /data /run/securo
# pydantic-settings looks for Docker secrets here and warns on every import
# when the directory is missing.
install -d -m 755 /run/secrets
touch "$secrets"
chmod 600 "$secrets"

if [ -f "/usr/share/zoneinfo/${TZ:-}" ]; then
    ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime
    echo "${TZ}" > /etc/timezone
fi

# The built-in services run as PUID:PGID too, so everything in the appdata folder
# belongs to the same user. initdb insists on a named account for its uid, Redis
# does not.
usermod -o -u "$PUID" postgres > /dev/null
groupmod -o -g "$PGID" postgres

if enabled "${BUILTIN_POSTGRES:-false}"; then
    set_env BUILTIN_POSTGRES true
else
    set_env BUILTIN_POSTGRES false
    [ -n "${POSTGRES_HOST:-}" ] \
        || fail "POSTGRES_HOST is empty. Point it at your PostgreSQL server, which needs pgvector, or set BUILTIN_POSTGRES=true."
    [ -n "${POSTGRES_PASSWORD:-}" ] \
        || fail "POSTGRES_PASSWORD is empty. Set the password of ${POSTGRES_USER:-postgres} on ${POSTGRES_HOST}."
fi
if enabled "${BUILTIN_REDIS:-false}"; then
    set_env BUILTIN_REDIS true
else
    set_env BUILTIN_REDIS false
    [ -n "${REDIS_HOST:-}" ] \
        || fail "REDIS_HOST is empty. Point it at your Redis server, or set BUILTIN_REDIS=true."
fi

if [ "$BUILTIN_POSTGRES" = true ]; then
    password=$(secret POSTGRES_PASSWORD)
    install -d -o postgres -g postgres -m 2775 /run/postgresql
    if [ ! -f /data/postgres/PG_VERSION ]; then
        log "Creating the built-in PostgreSQL ${POSTGRES_MAJOR} in /data/postgres."
        init_postgres "$password"
    fi
    major=$(cat /data/postgres/PG_VERSION)
    [ "$major" = "$POSTGRES_MAJOR" ] \
        || fail "/data/postgres was created by PostgreSQL ${major}, this image runs ${POSTGRES_MAJOR}. Dump it with ${major} and restore it into an empty /data/postgres."
    if [ "$(stat -c %u:%g /data/postgres)" != "${PUID}:${PGID}" ]; then
        chown -R "${PUID}:${PGID}" /data/postgres
    fi
    chmod 700 /data/postgres
    set_env POSTGRES_HOST 127.0.0.1
    set_env POSTGRES_PORT 5432
    set_env POSTGRES_USER securo
    set_env POSTGRES_PASSWORD "$password"
    set_env POSTGRES_DB securo
    log "Database: built-in PostgreSQL ${POSTGRES_MAJOR}"
else
    log "Database: ${POSTGRES_USER:-postgres}@${POSTGRES_HOST}:${POSTGRES_PORT:-5432}/${POSTGRES_DB:-securo}"
fi

if [ "$BUILTIN_REDIS" = true ]; then
    install -d -m 750 /data/redis
    if [ "$(stat -c %u:%g /data/redis)" != "${PUID}:${PGID}" ]; then
        chown -R "${PUID}:${PGID}" /data/redis
    fi
    set_env REDIS_HOST 127.0.0.1
    set_env REDIS_PORT 6379
    set_env REDIS_PASSWORD ""
    log "Redis: built-in"
else
    log "Redis: ${REDIS_HOST}:${REDIS_PORT:-6379}, database ${REDIS_DB:-0}"
fi

# Alembic hands the URL to configparser, which rejects every %, so a percent-encoded
# @ or % in the credentials would stop the migrations. Any other character passes
# through SQLAlchemy's URL parser unencoded.
for part in "${POSTGRES_USER:-postgres}" "$POSTGRES_PASSWORD" "${POSTGRES_DB:-securo}"; do
    case "$part" in
        *[@%]*) fail "The PostgreSQL user, password and database name must not contain @ or %." ;;
    esac
done
set_env DATABASE_URL "postgresql+asyncpg://${POSTGRES_USER:-postgres}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT:-5432}/${POSTGRES_DB:-securo}"

redis_auth=""
if [ -n "${REDIS_PASSWORD:-}" ]; then
    redis_auth=":$(urlquote "$REDIS_PASSWORD")@"
fi
set_env REDIS_URL "redis://${redis_auth}${REDIS_HOST}:${REDIS_PORT:-6379}/${REDIS_DB:-0}"

if [ -z "${SECRET_KEY:-}" ]; then
    set_env SECRET_KEY "$(secret SECRET_KEY)"
fi

if [ -z "${FRONTEND_URL:-}" ]; then
    set_env FRONTEND_URL "http://localhost:8080"
    log "FRONTEND_URL is empty. Bank sync and OIDC login need it as the address you open Securo on."
fi

set_env STORAGE_LOCAL_PATH /data/attachments
set_env ENABLE_BANKING_PRIVATE_KEY_FILE "${ENABLE_BANKING_PRIVATE_KEY_FILE:-/data/secrets/enable_banking_private.pem}"
set_env TRUSTED_PROXY_HOPS "${TRUSTED_PROXY_HOPS:-1}"

for dir in /data/attachments /data/secrets /data/celery /tmp/securo; do
    install -d "$dir"
    if [ "$(stat -c %u:%g "$dir")" != "${PUID}:${PGID}" ]; then
        chown -R "${PUID}:${PGID}" "$dir"
    fi
done

log "Securo ${SECURO_VERSION}, running as ${PUID}:${PGID}"
