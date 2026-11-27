#!/usr/bin/env bash
#
# DMARCo installer.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/dmarcoapp/dmarcoapp/main/install.sh)"
#
# Downloads the Compose stack, asks for the handful of settings DMARCo needs,
# generates secrets and starts everything. Run again over an existing install,
# it upgrades it. Answers can also be supplied as environment variables, in
# which case the installer does not ask for them:
#
#   APP_DOMAIN=dmarc.example.com ACME_EMAIL=you@example.com \
#   DMARCO_INTAKE=imap IMAP_HOST=imap.example.com IMAP_USERNAME=dmarc@example.com \
#   IMAP_PASSWORD=... ./install.sh
#
# The installer saves a copy of itself in the install directory. Run from there
# with upgrade, it fetches the current version of itself and of the stack and
# upgrades without asking. DMARCO_UPGRADE=1 does the same for the command above:
#
#   cd dmarco && bash install.sh upgrade
#
set -euo pipefail

REPO="${DMARCO_REPO:-dmarcoapp/dmarcoapp}"
REF="${DMARCO_REF:-main}"
RAW_BASE="${DMARCO_RAW_BASE:-https://raw.githubusercontent.com/${REPO}/${REF}}"
STACK_FILES=(compose.yaml Caddyfile .env.example clamav/clamd.conf clamav/freshclam.conf install.sh)

# The last release of the retired mail gateway.
GATEWAY_VERSION=0.4

# The settings 0.4 kept in .env, which live in the database from 0.5 on.
LEGACY_SETTINGS=(REPORT_DOMAIN WEBHOOK_SECRET MAILER_DSN APP_EMAIL_SENDER_ADDRESS
    APP_REPORT_RETENTION_DAYS APP_IP_LOOKUP_ENABLED)

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_BLUE=$'\033[34m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
else
    C_RESET=''; C_BOLD=''; C_DIM=''; C_BLUE=''; C_GREEN=''; C_YELLOW=''; C_RED=''
fi

info() { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok() { printf '%s  ok%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%swarn%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die() { printf '%serror%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }
note() { printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }

# True when the script can actually read from the terminal, which is what lets
# the installer prompt even when it is piped into bash.
has_tty() {
    { : < /dev/tty; } 2> /dev/null
}

# Prompts are read from the terminal when there is one.
if has_tty; then
    INPUT=/dev/tty
else
    INPUT=/dev/stdin
fi

ask() {
    local var="$1" text="$2" default="${3:-}" answer at_end
    if [ -n "${!var:-}" ]; then
        return 0
    fi
    # Unattended, a question with a default takes it.
    if [ -n "${DMARCO_YES:-}" ] && [ -n "$default" ]; then
        printf -v "$var" '%s' "$default"
        return 0
    fi
    while true; do
        if [ -n "$default" ]; then
            printf '%s%s%s [%s]: ' "$C_BOLD" "$text" "$C_RESET" "$default" >&2
        else
            printf '%s%s%s: ' "$C_BOLD" "$text" "$C_RESET" >&2
        fi
        at_end=''
        if ! IFS= read -r answer < "$INPUT"; then
            at_end=1
        fi
        answer="${answer:-$default}"
        if [ -n "$answer" ]; then
            printf -v "$var" '%s' "$answer"
            return 0
        fi
        # Nothing more is coming, so asking again would loop for good.
        [ -z "$at_end" ] || die "No answer for \"${text}\". Pass it as ${var} in the environment."
        warn "A value is required."
    done
}

ask_secret() {
    local var="$1" text="$2" answer
    if [ -n "${!var:-}" ]; then
        return 0
    fi
    while true; do
        printf '%s%s%s: ' "$C_BOLD" "$text" "$C_RESET" >&2
        if ! IFS= read -rs answer < "$INPUT"; then
            printf '\n' >&2
            [ -n "${answer:-}" ] || die "No answer for \"${text}\". Pass it as ${var} in the environment."
        else
            printf '\n' >&2
        fi
        if [ -n "$answer" ]; then
            printf -v "$var" '%s' "$answer"
            return 0
        fi
        warn "A value is required."
    done
}

confirm() {
    local text="$1" answer
    if [ -n "${DMARCO_YES:-}" ]; then
        return 0
    fi
    printf '%s%s%s [y/N]: ' "$C_BOLD" "$text" "$C_RESET" >&2
    IFS= read -r answer < "$INPUT" || answer=''
    case "$answer" in
        [yY] | [yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

random_hex() {
    local bytes="$1"
    if command -v openssl > /dev/null 2>&1; then
        openssl rand -hex "$bytes"
    else
        LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c "$((bytes * 2))"
        printf '\n'
    fi
}

generate_secret() {
    random_hex 24
}

# The backend wants 32 bytes, as 64 hexadecimal characters.
generate_encryption_key() {
    random_hex 32
}

# Escapes a hostname for use inside the CORS origin regular expression.
regex_escape() {
    # shellcheck disable=SC2016  # the sed expression is intentionally literal
    printf '%s' "$1" | sed -e 's/[.[\*^$()+?{}|\\]/\\&/g'
}

# Looks up existing MX records, so the installer can warn before a domain that
# already receives email is pointed at the mail gateway.
existing_mx() {
    local domain="$1"
    # No records is the normal case, so never fail the caller.
    if command -v dig > /dev/null 2>&1; then
        dig +short +timeout=3 MX "$domain" 2> /dev/null | grep -v '^$' | head -n 3 || true
    elif command -v host > /dev/null 2>&1; then
        host -t MX -W 3 "$domain" 2> /dev/null | grep 'mail is handled by' | head -n 3 || true
    fi
}

# Writes next to the target and renames, so a failed download leaves the old
# file in place, and the copy of this script that bash is running keeps
# reading the file it opened. A file that has not changed is left as it is: a
# running container that mounts it would otherwise keep the replaced file,
# or, with Docker Desktop, lose it. REPLACED says whether an existing file
# was replaced.
download() {
    local url="$1" target="$2"
    REPLACED=''
    mkdir -p "$(dirname "$target")"
    if command -v curl > /dev/null 2>&1; then
        curl -fsSL "$url" -o "${target}.download" || { rm -f "${target}.download"; return 1; }
    else
        wget -qO "${target}.download" "$url" || { rm -f "${target}.download"; return 1; }
    fi
    if [ -f "$target" ] && cmp -s "${target}.download" "$target"; then
        rm -f "${target}.download"
        return 0
    fi
    [ ! -f "$target" ] || REPLACED=1
    [ "${target##*.}" != sh ] || chmod 755 "${target}.download"
    mv "${target}.download" "$target"
}

compose() {
    docker compose "$@"
}

wait_for_service() {
    local service="$1" timeout="${2:-300}" waited=0 id state restarts baseline=''
    while [ "$waited" -lt "$timeout" ]; do
        id="$(compose ps -q "$service" 2> /dev/null | head -n 1)"
        if [ -n "$id" ]; then
            state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2> /dev/null || printf 'unknown')"
            restarts="$(docker inspect -f '{{.RestartCount}}' "$id" 2> /dev/null || printf '0')"
            # "unhealthy" is not decisive: a container whose start takes longer
            # than its health check allows for, such as the backend running a
            # long migration, reports it and then recovers.
            case "$state" in
                healthy | running) return 0 ;;
                exited | dead) return 1 ;;
            esac
            # A container that restarts while we watch is failing at startup,
            # and its health check never gets far enough to report anything but
            # "starting", so waiting out the timeout would only hide the error.
            # The count is a lifetime total, hence the comparison with what this
            # wait started from rather than with zero.
            case "$restarts" in
                '' | *[!0-9]*) ;;
                *)
                    [ -n "$baseline" ] || baseline="$restarts"
                    [ "$restarts" -le "$baseline" ] || return 1
                    ;;
            esac
        fi
        sleep 3
        waited=$((waited + 3))
    done
    return 1
}

# Prints the end of a service log, indented, so a failure explains itself
# instead of sending the reader looking for it.
show_log_tail() {
    local service="$1" lines="${2:-15}"
    compose logs --no-color --tail "$lines" "$service" 2> /dev/null |
        sed 's/^/       /' >&2 || true
}

check_requirements() {
    info "Checking requirements"

    command -v docker > /dev/null 2>&1 ||
        die "Docker is not installed. See https://docs.docker.com/engine/install/"
    docker compose version > /dev/null 2>&1 ||
        die "Docker Compose v2 is not available. See https://docs.docker.com/compose/install/"
    docker info > /dev/null 2>&1 ||
        die "Cannot talk to the Docker daemon. Start Docker, or run this installer as a user in the docker group."
    command -v curl > /dev/null 2>&1 || command -v wget > /dev/null 2>&1 ||
        die "Either curl or wget is required."

    ok "Docker $(docker version --format '{{.Server.Version}}' 2> /dev/null || printf 'ok')"

    local port
    for port in 80 443; do
        if port_in_use "$port"; then
            warn "Port ${port} is already in use. DMARCo needs it and will fail to start until it is free."
        fi
    done
}

port_in_use() {
    local port="$1"
    if command -v ss > /dev/null 2>&1; then
        ss -ltn 2> /dev/null | grep -qE "[:.]${port}[[:space:]]"
    elif command -v netstat > /dev/null 2>&1; then
        netstat -ltn 2> /dev/null | grep -qE "[:.]${port}[[:space:]]"
    else
        return 1
    fi
}

fetch_stack() {
    local source_dir="$1" file
    if [ -n "$source_dir" ]; then
        [ -n "${DMARCO_FETCHED:-}" ] || info "Using the Compose stack from ${source_dir}"
        return 0
    fi

    info "Downloading the Compose stack"
    for file in "${STACK_FILES[@]}"; do
        download "${RAW_BASE}/${file}" "${INSTALL_DIR}/${file}"
        ok "$file"
        [ -n "$REPLACED" ] || continue
        # Services that read a file of the stack mounted in, and only when
        # they start. DMARCO_RECREATE also reaches the installer this one
        # continues in.
        case "$file" in
            Caddyfile) DMARCO_RECREATE="${DMARCO_RECREATE:-} caddy" ;;
            clamav/*) DMARCO_RECREATE="${DMARCO_RECREATE:-} clamav" ;;
        esac
    done
    export DMARCO_RECREATE="${DMARCO_RECREATE:-}"
}

# Compose recreates a container when its configuration changes, but not when
# a file mounted into it does, so those services start again by name.
recreate_changed_mounts() {
    local service services=()
    for service in $(printf '%s' "${DMARCO_RECREATE:-}" | tr ' ' '\n' | sort -u); do
        # A service of a profile that is off would be started by naming it.
        [ "$service" != clamav ] || has_profile mail-gateway || continue
        services+=("$service")
    done
    [ "${#services[@]}" -gt 0 ] || return 0

    info "Restarting ${services[*]} with the configuration just downloaded"
    compose up -d --no-deps --force-recreate "${services[@]}" ||
        warn "Could not restart them. Run: cd ${INSTALL_DIR} && docker compose up -d --force-recreate ${services[*]}"
}

# ------------------------------------------------------------- reading .env

# Prints the value of one setting in .env. The file is read rather than
# sourced: the shell would eat the backslashes and dollar signs that Compose
# passes through untouched, among them the ones in the CORS_ALLOW_ORIGIN
# regular expression.
env_file_value() {
    local file="${INSTALL_DIR}/.env" key="$1" value
    [ -f "$file" ] || return 0
    value="$(sed -n "s/^[[:space:]]*${key}=//p" "$file" | head -n 1)"
    value="${value%$'\r'}"
    # Compose strips one pair of surrounding quotes, and so does this.
    case "$value" in
        \"*\") value="${value#\"}"; value="${value%\"}" ;;
        \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac
    printf '%s' "$value"
}

env_file_has() {
    grep -qE "^[[:space:]]*${1}=" "${INSTALL_DIR}/.env" 2> /dev/null
}

# Reads settings out of an existing .env, skipping the ones the caller already
# has, because a value in the environment is the one Compose uses as well.
# Succeeds when it read anything.
load_env_values() {
    local key value loaded=1
    [ -f "${INSTALL_DIR}/.env" ] || return 1

    for key in "$@"; do
        [ -z "${!key:-}" ] || continue
        value="$(env_file_value "$key")"
        [ -n "$value" ] || continue
        printf -v "$key" '%s' "$value"
        loaded=0
    done

    return "$loaded"
}

# ------------------------------------------------------------- changing .env

# Keeps the .env as it was before this run changed it, once per run, because
# it holds the only copy of secrets the data depends on.
backup_env() {
    [ -z "${ENV_BACKUP:-}" ] || return 0
    ENV_BACKUP="${INSTALL_DIR}/.env.backup-$(date -u '+%Y%m%d%H%M%S')"
    cp "${INSTALL_DIR}/.env" "$ENV_BACKUP"
    chmod 600 "$ENV_BACKUP"
}

# Writes the result of an awk program over .env back to .env, keeping its mode.
rewrite_env() {
    local file="${INSTALL_DIR}/.env" tmp
    tmp="$(mktemp "${file}.XXXXXX")"
    awk "$@" "$file" > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$file"
}

# Sets one setting, in place of the line that holds it or at the end. The
# values go through the environment, where awk leaves backslashes alone.
env_set() {
    # shellcheck disable=SC2016  # an awk program, read by awk and not the shell
    ENV_KEY="$1" ENV_LINE="$1=$2" rewrite_env '
        BEGIN { key = ENVIRON["ENV_KEY"]; done = 0 }
        {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            if (index(line, key "=") == 1) {
                if (!done) print ENVIRON["ENV_LINE"]
                done = 1
                next
            }
            print
        }
        END { if (!done) print ENVIRON["ENV_LINE"] }'
}

env_remove() {
    # shellcheck disable=SC2016  # an awk program, read by awk and not the shell
    ENV_KEYS="$*" rewrite_env '
        BEGIN { n = split(ENVIRON["ENV_KEYS"], keys, " "); for (i = 1; i <= n; i++) drop[keys[i]] = 1 }
        {
            line = $0
            sub(/^[[:space:]]*/, "", line)
            eq = index(line, "=")
            if (eq > 1 && (substr(line, 1, eq - 1) in drop)) next
            # One empty line where the removed lines leave two.
            if ($0 ~ /^[[:space:]]*$/ && blank) next
            blank = ($0 ~ /^[[:space:]]*$/)
            print
        }'
}

has_profile() {
    case ",${COMPOSE_PROFILES:-}," in
        *",$1,"*) return 0 ;;
    esac
    return 1
}

add_profile() {
    has_profile "$1" || COMPOSE_PROFILES="${COMPOSE_PROFILES:+${COMPOSE_PROFILES},}$1"
}

# ------------------------------------------------------------ configuration

# Which ways in the reports take. Any combination works, side by side. The
# mail gateway is retired: only an install that already runs it, and whose
# configuration is being overwritten, may keep it.
choose_intake() {
    local choice token valid retired default=1 answers='1, 2'
    INTAKE_IMAP=''; INTAKE_API=''; INTAKE_GATEWAY=''
    if [ -n "${GATEWAY_IN_USE:-}" ]; then
        default=3; answers='1, 2, 3'
    fi

    if [ -z "${DMARCO_INTAKE:-}" ]; then
        printf '\n%sHow should DMARC reports reach DMARCo?%s\n\n' "$C_BOLD" "$C_RESET"
        printf '  1  From a mailbox you already have, read over IMAP\n'
        printf '  2  Uploaded through the API, with a key\n'
        if [ -n "${GATEWAY_IN_USE:-}" ]; then
            printf '  3  By the mail gateway on port 25, as this install does now. It is\n'
            printf '     retired and gets no more updates, so plan the move to a mailbox.\n'
        fi
        printf '\n'
    fi

    while true; do
        choice="${DMARCO_INTAKE:-}"
        ask choice "Pick one or more, such as 1 or 1,2" "$default"
        valid=1; retired=''
        for token in ${choice//,/ }; do
            case "$token" in
                1 | imap) INTAKE_IMAP=1 ;;
                2 | api) INTAKE_API=1 ;;
                3 | gateway)
                    if [ -n "${GATEWAY_IN_USE:-}" ]; then
                        INTAKE_GATEWAY=1
                    elif [ -n "${DMARCO_INTAKE:-}" ]; then
                        die "The mail gateway is retired, and new installs cannot use it. Read reports from a mailbox instead, with DMARCO_INTAKE=imap."
                    else
                        warn "The mail gateway is retired, and new installs cannot use it. Read reports from a mailbox instead."
                        valid=''; retired=1
                    fi
                    ;;
                *) valid='' ;;
            esac
        done
        if [ -n "$valid" ] && [ -n "${INTAKE_IMAP}${INTAKE_API}${INTAKE_GATEWAY}" ]; then
            return 0
        fi
        [ -z "${DMARCO_INTAKE:-}" ] || die "DMARCO_INTAKE takes imap and api, separated by a comma."
        [ -n "$retired" ] || warn "Answer with ${answers}, or several of them separated by commas."
        INTAKE_IMAP=''; INTAKE_API=''; INTAKE_GATEWAY=''
    done
}

# Whether the install in INSTALL_DIR receives its reports through the mail
# gateway: its profile is on, or the .env is from 0.4 or earlier, when the
# gateway was the only way in.
gateway_in_use() {
    [ -f "${INSTALL_DIR}/.env" ] || return 1
    case ",$(env_file_value COMPOSE_PROFILES)," in
        *,mail-gateway,*) return 0 ;;
    esac
    env_file_has REPORT_DOMAIN
}

collect_mailbox() {
    printf '\n%sThe mailbox your DMARC records send reports to. DMARCo signs in over TLS,\nchecks the certificate, and touches only messages with a report attached.%s\n\n' "$C_DIM" "$C_RESET"

    ask IMAP_HOST "IMAP server" ""
    while true; do
        ask IMAP_SECURITY "Encryption, tls or starttls" "tls"
        case "$IMAP_SECURITY" in
            tls | starttls) break ;;
        esac
        warn "Answer tls or starttls. DMARCo does not sign in without encryption."
        IMAP_SECURITY=''
    done
    if [ "$IMAP_SECURITY" = tls ]; then
        ask IMAP_PORT "Port" "993"
    else
        ask IMAP_PORT "Port" "143"
    fi
    ask IMAP_USERNAME "Username" ""
    ask_secret IMAP_PASSWORD "Password, or an app password if the provider has them"
    ask IMAP_FOLDER "Folder the reports arrive in" "INBOX"
    case "$IMAP_USERNAME" in
        *@*.*) ask IMAP_REPORT_ADDRESS "Address your DMARC records send reports to" "$IMAP_USERNAME" ;;
        *) ask IMAP_REPORT_ADDRESS "Address your DMARC records send reports to" "" ;;
    esac
    IMAP_NAME="${IMAP_NAME:-DMARC reports}"
}

collect_gateway() {
    printf '\n%sThe mail gateway runs Postfix on port 25, for a domain whose MX record points\nhere, and scans each report with ClamAV, which needs about 1.5 GB of memory.%s\n\n' "$C_DIM" "$C_RESET"

    local previous
    previous="$(env_file_value MAIL_GATEWAY_DOMAIN)"
    ask MAIL_GATEWAY_DOMAIN "Domain your DMARC reports are sent to, which must not receive other email" "${previous:-${REPORT_DOMAIN:-$APP_DOMAIN}}"
    check_gateway_domain
    ask SMTP_HOSTNAME "Public hostname of the mail gateway" "$APP_DOMAIN"
    if port_in_use 25; then
        warn "Port 25 is already in use. The mail gateway needs it and will fail to start until it is free."
    fi
    WEBHOOK_SECRET="${WEBHOOK_SECRET:-$(generate_secret)}"
}

check_gateway_domain() {
    local mx=''
    mx="$(existing_mx "$MAIL_GATEWAY_DOMAIN")" || true
    [ -n "$mx" ] || return 0

    warn "${MAIL_GATEWAY_DOMAIN} already has MX records:"
    printf '%s\n' "$mx" | sed 's/^/       /' >&2
    warn "The gateway replaces them and accepts only DMARC reports, so any other email sent to ${MAIL_GATEWAY_DOMAIN} would be lost."
    warn "Use a dedicated domain or subdomain instead, such as dmarc.${MAIL_GATEWAY_DOMAIN}."

    confirm "Use ${MAIL_GATEWAY_DOMAIN} anyway?" ||
        die "Run the installer again with a domain that does not receive other email."
}

collect_configuration() {
    info "Configuration"
    printf '%sDMARCo needs a domain that points to this server.%s\n\n' "$C_DIM" "$C_RESET"

    ask APP_DOMAIN "Domain for the dashboard and API" ""
    ask ACME_EMAIL "Email address for Let's Encrypt" ""

    choose_intake
    [ -z "$INTAKE_IMAP" ] || collect_mailbox
    [ -z "$INTAKE_GATEWAY" ] || collect_gateway

    printf '\n%sOutgoing email for notifications, report retention, and IP lookups are set\non the Platform page of the dashboard once it runs.%s\n' "$C_DIM" "$C_RESET"

    APP_SCHEME="${APP_SCHEME:-https}"
    CORS_ALLOW_ORIGIN="${CORS_ALLOW_ORIGIN:-^${APP_SCHEME}://$(regex_escape "$APP_DOMAIN")$}"

    APP_SECRET="${APP_SECRET:-$(generate_secret)}"
    POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(generate_secret)}"
    APP_ENCRYPTION_KEY="${APP_ENCRYPTION_KEY:-$(generate_encryption_key)}"
}

# Postgres stores the password it is given the first time it initializes its
# volume and ignores the environment from then on, so freshly
# generated secrets would lock the stack out of data an earlier install left
# behind. An overwrite therefore starts from the secrets already on disk, the
# rest of them included, so nothing signed or encrypted with the old ones
# breaks either. The settings 0.4 kept in .env are read as well, so they reach
# the database instead of being lost with the old file.
keep_existing_secrets() {
    local stored=''
    if load_env_values APP_SECRET APP_ENCRYPTION_KEY WEBHOOK_SECRET POSTGRES_PASSWORD; then
        info "Keeping the secrets from the existing .env, which its data depends on"
    fi
    if [ -z "${WEBHOOK_SECRET:-}" ] && [ -f "${INSTALL_DIR}/secrets/webhook_secret.txt" ]; then
        stored="$(head -n 1 "${INSTALL_DIR}/secrets/webhook_secret.txt")"
        [ "$stored" = unused ] || WEBHOOK_SECRET="$stored"
    fi
    load_env_values REPORT_DOMAIN MAILER_DSN APP_EMAIL_SENDER_ADDRESS \
        APP_REPORT_RETENTION_DAYS APP_IP_LOOKUP_ENABLED || true
}

# What the installer itself needs when it keeps an existing .env: the summary
# prints the domains, and the password has to match what the database has. The
# rest of the file is Compose's business, and Compose reads it.
load_existing_configuration() {
    load_env_values APP_DOMAIN APP_SCHEME REPORT_DOMAIN MAIL_GATEWAY_DOMAIN SMTP_HOSTNAME \
        COMPOSE_PROFILES APP_ENCRYPTION_KEY POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB \
        BACKEND_VERSION DASHBOARD_VERSION || true
}

# An .env from before 0.5 has no APP_ENCRYPTION_KEY. Until it has one, the
# backend keeps reading its settings from .env and has no mailboxes or API keys.
ensure_encryption_key() {
    [ -z "${APP_ENCRYPTION_KEY:-}" ] || return 0

    info "Upgrading the configuration"
    note "DMARCo now keeps outgoing email, report retention, IP lookups, and how reports
come in on the dashboard's Platform page, and encrypts the passwords among them
with a key of its own. The installer adds that key to .env, the database takes the
settings over when DMARCo starts, and the lines they came from are removed."
    backup_env
    APP_ENCRYPTION_KEY="$(generate_encryption_key)"
    env_set APP_ENCRYPTION_KEY "$APP_ENCRYPTION_KEY"
    ok "APP_ENCRYPTION_KEY, saved in .env. Keep a copy with your backups."
}

# Every install before 0.5 received its reports through the mail gateway,
# which runs only with the mail-gateway profile now.
keep_gateway_running() {
    has_profile mail-gateway && return 0
    env_file_has REPORT_DOMAIN || return 0

    info "Keeping the mail gateway running"
    note "This install receives its reports through the mail gateway, which now runs only
with mail-gateway in COMPOSE_PROFILES. It stays on for now, but it is retired and
gets no more updates. Mailboxes read over IMAP replace it: add one on the Platform
page, and the README says how to move over and switch the gateway off."
    backup_env
    add_profile mail-gateway
    env_set COMPOSE_PROFILES "$COMPOSE_PROFILES"
    ok "COMPOSE_PROFILES=${COMPOSE_PROFILES}"
}

# The containers of this install, by Compose service, whatever compose.yaml
# now says: an upgrade looks at what the previous version left running.
project_container() {
    docker ps -aq \
        --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME:-dmarco}" \
        --filter "label=com.docker.compose.service=$1" 2> /dev/null | head -n 1
}

# True when a version tag is below the minor release 0.<minor>, such as 0.4 or
# v0.3.2 below 0.5. A tag that is not a version, latest among them, passes.
version_below() {
    local tag="${1#v}" wanted="$2" major minor
    case "$tag" in
        [0-9]*.[0-9]*) ;;
        *) return 1 ;;
    esac
    major="${tag%%.*}"
    minor="${tag#*.}"
    minor="${minor%%.*}"
    case "$major$minor" in
        *[!0-9]*) return 1 ;;
    esac
    [ "$major" -eq 0 ] && [ "$minor" -lt "$wanted" ]
}

# The oldest release of each image this recipe works with. The backend needs
# 0.6, the first with Valkey queues; the dashboard needs 0.5, the first with the
# Platform page. One pinned below would start without what the recipe sets up,
# so the pin is raised, or the run stops before anything changes.
raise_pinned_versions() {
    local name value minimum
    for name in BACKEND_VERSION DASHBOARD_VERSION; do
        case "$name" in
            BACKEND_VERSION) minimum=6 ;;
            *) minimum=5 ;;
        esac
        value="${!name:-}"
        if [ -z "$value" ] || ! version_below "$value" "$minimum"; then
            continue
        fi

        warn "${name} is pinned to ${value}, and this recipe needs 0.${minimum} or later."
        confirm "Raise ${name} to 0.${minimum}?" ||
            die "Stopped. Neither .env nor the running stack was changed, and this recipe needs ${name} 0.${minimum} or later."
        printf -v "$name" '%s' "0.${minimum}"
        if [ -f "${INSTALL_DIR}/.env" ] && env_file_has "$name"; then
            backup_env
            env_set "$name" "0.${minimum}"
        fi
        ok "${name}=0.${minimum}"
    done
}

# The minor release of a version tag: 7 for 0.7 or v0.7.2. Fails on a tag that
# is not a 0.x version, latest among them.
minor_release() {
    local tag="${1#v}" minor
    case "$tag" in
        0.[0-9]*) ;;
        *) return 1 ;;
    esac
    minor="${tag#0.}"
    minor="${minor%%.*}"
    case "$minor" in
        '' | *[!0-9]*) return 1 ;;
    esac
    printf '%s' "$minor"
}

# From 0.7 on, every minor release ships the backend and the dashboard
# together, and a dashboard works with any backend of the same minor release:
# 0.7 with 0.7.1, for example. Patch releases come out on their own. Two pins
# on different minor releases, one of them 0.7 or later, are offered the newer
# minor release, as its first tag, which both images have. Older pairs, and
# latest, are left alone.
align_pinned_versions() {
    local backend dashboard lower higher value
    backend="$(minor_release "${BACKEND_VERSION:-}")" || return 0
    dashboard="$(minor_release "${DASHBOARD_VERSION:-}")" || return 0
    [ "$backend" -ne "$dashboard" ] || return 0
    [ "$backend" -ge 7 ] || [ "$dashboard" -ge 7 ] || return 0

    if [ "$backend" -lt "$dashboard" ]; then
        lower=BACKEND_VERSION higher=DASHBOARD_VERSION
    else
        lower=DASHBOARD_VERSION higher=BACKEND_VERSION
    fi

    value="0.$(minor_release "${!higher}")"
    warn "BACKEND_VERSION is ${BACKEND_VERSION} and DASHBOARD_VERSION is ${DASHBOARD_VERSION}. From 0.7 on, a dashboard works with a backend of the same minor release, such as 0.7 with 0.7.1."
    if ! confirm "Set ${lower} to ${value} as well?"; then
        warn "Kept ${lower}=${!lower}. Pages that need the other version may be empty or fail."
        return 0
    fi
    printf -v "$lower" '%s' "$value"
    if [ -f "${INSTALL_DIR}/.env" ] && env_file_has "$lower"; then
        backup_env
        env_set "$lower" "$value"
    fi
    ok "${lower}=${value}"
}

# The mail gateway is retired, and 0.4 is its last release, the one that
# posts each report in the webhook. latest names the same images today but
# would hide that nothing newer comes, and a pin below 0.4 still expects the
# object storage that 0.5 removed. Other pins are left alone.
pin_gateway_version() {
    local value
    env_file_has MAIL_INBOUND_VERSION || return 0
    value="$(env_file_value MAIL_INBOUND_VERSION)"
    if [ -n "$value" ] && [ "$value" != latest ] && ! version_below "$value" 4; then
        return 0
    fi

    backup_env
    env_set MAIL_INBOUND_VERSION "$GATEWAY_VERSION"
    ok "MAIL_INBOUND_VERSION=${GATEWAY_VERSION}, the mail gateway's last release"
}

# The messages waiting in the broker of the previous install, or nothing when
# there is no broker container to ask. A broker that has just started answers
# before it has loaded its queues, and would count none, so the count waits for
# its startup to finish.
queued_messages() {
    local id="$1" output waited=0
    while [ "$waited" -lt 120 ]; do
        if docker exec "$id" rabbitmqctl -q await_startup > /dev/null 2>&1 &&
            output="$(docker exec "$id" rabbitmqctl -q list_queues messages 2> /dev/null)"; then
            printf '%s\n' "$output" | awk '$1 ~ /^[0-9]+$/ { total += $1 } END { print total + 0 }'
            return 0
        fi
        sleep 3
        waited=$((waited + 3))
    done
    return 1
}

# Up to 0.3 a queued report only pointed at its copy in the MinIO object store,
# which 0.4 dropped. Those reports have to be processed by the version that
# queued them, before the stack moves on and MinIO goes.
drain_object_storage_queue() {
    local broker worker gateway count waited=0
    [ -n "$(project_container minio)" ] || [ -f "${INSTALL_DIR}/secrets/s3_access_key.txt" ] || return 0

    broker="$(project_container rabbitmq)"
    if [ -z "$broker" ]; then
        remove_object_storage_settings
        return 0
    fi

    info "Finishing the reports queued by the previous version"
    docker start "$broker" > /dev/null 2>&1 || true
    count="$(queued_messages "$broker")" ||
        die "Could not ask the message broker how many reports are queued. Check: docker logs ${broker}"
    if [ "$count" -eq 0 ]; then
        ok "Nothing queued"
        remove_object_storage_settings
        return 0
    fi

    # No new mail while the queue empties. Sending servers retry it later.
    for gateway in postfix processor; do
        gateway="$(project_container "$gateway")"
        [ -z "$gateway" ] || docker stop "$gateway" > /dev/null 2>&1 || true
    done
    worker="$(project_container worker)"
    [ -n "$worker" ] ||
        die "${count} reports are queued for the previous version, and its worker container is gone. Start that version again until they are processed, then run the installer again."
    docker start "$worker" > /dev/null 2>&1 || true
    note "     ${count} queued. The previous version processes them now, which can take a few minutes."

    while [ "$waited" -lt 900 ]; do
        sleep 10
        waited=$((waited + 10))
        count="$(queued_messages "$broker")" || count=''
        if [ "$count" = 0 ]; then
            ok "Queue empty"
            remove_object_storage_settings
            return 0
        fi
    done
    die "${count:-Some} reports are still queued after 15 minutes. Check the previous worker with: docker logs ${worker}. Run the installer again once docker exec ${broker} rabbitmqctl list_queues shows 0."
}

# What the object store left in the configuration. Its data volume stays,
# because deleting data is the operator's call. The summary says how.
remove_object_storage_settings() {
    local stale=() key
    for key in S3_ACCESS_KEY S3_SECRET_KEY S3_RETENTION_DAYS; do
        if env_file_has "$key"; then
            stale+=("$key")
        fi
    done
    if [ "${#stale[@]}" -gt 0 ]; then
        backup_env
        env_remove "${stale[@]}"
    fi
    rm -f "${INSTALL_DIR}/secrets/s3_access_key.txt" "${INSTALL_DIR}/secrets/s3_secret_key.txt"
    OBJECT_STORAGE_REMOVED=1
}

# Up to 0.5 the work queues lived in RabbitMQ, and from 0.6 they live in Valkey,
# which already held the cache. Nothing carries the queued work from one to the
# other, so the previous version finishes it first: with nothing coming in, its
# worker runs until the queues are empty, and then RabbitMQ goes. The count
# that decides is taken with the worker stopped, because the worker queues
# follow-up work of its own.
drain_message_broker() {
    local project="${COMPOSE_PROJECT_NAME:-dmarco}" broker worker service count waited=0 temporary=''
    broker="$(project_container rabbitmq)"
    if [ -z "$broker" ]; then
        # After docker compose down the containers are gone, but the volume
        # may still hold queued work. A broker of its own on it can tell. Once
        # the RabbitMQ settings are out of .env, that question was answered.
        env_file_has RABBITMQ_PASSWORD || return 0
        if ! docker volume inspect "${project}_rabbitmq_data" > /dev/null 2>&1; then
            remove_broker_settings
            return 0
        fi
        temporary="${project}-rabbitmq-check"
        docker rm -f "$temporary" > /dev/null 2>&1 || true
        docker run -d --name "$temporary" --hostname rabbitmq \
            -v "${project}_rabbitmq_data:/var/lib/rabbitmq" rabbitmq:3.13-management > /dev/null 2>&1 ||
            die "Could not start RabbitMQ to check the work the previous version left queued. Check that Docker can pull rabbitmq:3.13-management, then run the installer again."
        broker="$temporary"
    fi

    info "Finishing the work queued by the previous version"
    docker start "$broker" > /dev/null 2>&1 || true

    # Without the previous containers nothing can process the work, so the
    # count decides before anything else is touched.
    if [ -n "$temporary" ]; then
        count="$(queued_messages "$broker")" || count=''
        docker rm -f "$temporary" > /dev/null 2>&1 || true
        [ -n "$count" ] ||
            die "Could not ask RabbitMQ how much work is queued. Run the installer again."
        [ "$count" -eq 0 ] ||
            die "Work is still queued for the previous version (${count} messages), and its containers are gone. Start that version again with its own compose.yaml until it is processed, then run the installer again. To drop the work instead: docker volume rm ${project}_rabbitmq_data"
        ok "Queues empty"
        remove_broker_settings
        return 0
    fi

    # Nothing new comes in while the queues empty. Mail servers and uploaders
    # retry, and mailboxes keep their reports until they are read.
    for service in php postfix processor; do
        service="$(project_container "$service")"
        [ -z "$service" ] || docker stop "$service" > /dev/null 2>&1 || true
    done
    worker="$(project_container worker)"

    while :; do
        [ -z "$worker" ] || docker stop "$worker" > /dev/null 2>&1 || true
        count="$(queued_messages "$broker")" ||
            die "Could not ask RabbitMQ how much work is queued. Check: docker logs ${broker}"
        [ "$count" -gt 0 ] || break

        [ -n "$worker" ] ||
            die "Work is still queued for the previous version (${count} messages), and its worker container is gone. Start that version again with its own compose.yaml until it is processed, then run the installer again. To drop the work instead: docker volume rm ${project}_rabbitmq_data"
        [ "$waited" -gt 0 ] ||
            note "     ${count} queued. The previous version processes them now, which can take a few minutes."
        docker start "$worker" > /dev/null 2>&1 || true
        while [ "$count" -gt 0 ]; do
            [ "$waited" -lt 900 ] ||
                die "${count} messages are still queued after 15 minutes. Check the previous worker with: docker logs ${worker}. Run the installer again once docker exec ${broker} rabbitmqctl list_queues shows 0."
            sleep 5
            waited=$((waited + 5))
            count="$(queued_messages "$broker")" || count=1
        done
    done
    ok "Queues empty"

    # Removed by name, because the volume stays, and a broker container from
    # the previous version would otherwise be asked again on every run.
    docker rm -f "$broker" > /dev/null 2>&1 || true
    remove_broker_settings
}

# Redis kept the cache, which holds the sign-outs: a token signed out before
# the switch would work again for the rest of its hour without it. Valkey
# cannot read what Redis 7.4 writes, neither its dump file nor its DUMP
# payloads, so the backend copies the keys one by one, values and expiry, from
# the Redis the previous version left running. Only into an empty Valkey, so a
# later run cannot overwrite newer entries, and a failure costs no more than
# the cache.
carry_cache_over() {
    local redis copied
    redis="$(project_container redis)"
    [ -n "$redis" ] || return 0
    [ "$(compose exec -T valkey valkey-cli -n 0 dbsize 2> /dev/null | tr -d '\r')" = 0 ] || return 0

    info "Copying the cache from Redis to Valkey"
    docker start "$redis" > /dev/null 2>&1 || true
    # shellcheck disable=SC2016  # PHP code, expanded by PHP and not the shell
    if copied="$(compose run --rm --no-deps -T --entrypoint php php -r '
        $from = new Redis(); $from->connect("redis", 6379, 5);
        $to = new Redis(); $to->connect("valkey", 6379, 5);
        $copied = 0; $it = null;
        $from->setOption(Redis::OPT_SCAN, Redis::SCAN_RETRY);
        while (false !== ($keys = $from->scan($it, "*", 500))) {
            foreach ($keys as $key) {
                if (Redis::REDIS_STRING !== $from->type($key)) { continue; }
                $value = $from->get($key); $ttl = $from->pttl($key);
                if (false === $value || -2 === $ttl) { continue; }
                $ttl > 0 ? $to->set($key, $value, ["px" => $ttl]) : $to->set($key, $value);
                ++$copied;
            }
        }
        echo $copied;' 2> /dev/null | tail -n 1)"; then
        ok "${copied:-0} entries"
    else
        warn "Could not copy the cache. Valkey starts empty: anyone signed out in the last hour may have to sign out again."
    fi
}

# What RabbitMQ left in the configuration. Its data volume stays, because
# deleting data is the operator's call. The summary says how.
remove_broker_settings() {
    local stale=() key
    for key in RABBITMQ_USER RABBITMQ_PASSWORD; do
        if env_file_has "$key"; then
            stale+=("$key")
        fi
    done
    if [ "${#stale[@]}" -gt 0 ]; then
        backup_env
        env_remove "${stale[@]}"
    fi
    BROKER_REMOVED=1
}

# 0.5 serves one account, and its migration stops on a database with more,
# because which ones to keep is the operator's decision. Asked before the new
# backend starts, so the previous version can still delete them.
check_single_account() {
    local user="${POSTGRES_USER:-dmarco}" db="${POSTGRES_DB:-dmarco}" accounts count
    accounts="$(compose exec -T database psql --quiet --no-psqlrc -At --username "$user" --dbname "$db" \
        -c 'SELECT email FROM "user" ORDER BY created_at' 2> /dev/null | tr -d '\r')" || return 0
    count="$(printf '%s\n' "$accounts" | grep -c .)" || true
    [ "${count:-0}" -gt 1 ] || return 0

    warn "This database has ${count} accounts, and DMARCo now serves one:"
    printf '%s\n' "$accounts" | sed 's/^/       /' >&2
    warn "Delete the ones you do not need with the version you are upgrading from, which deletes their domains and reports as well, then run the installer again:"
    printf '       cd %s\n       BACKEND_VERSION=0.4 docker compose run --rm php bin/console app:user:delete\n' "$INSTALL_DIR" >&2
    die "Stopped before the new version started. Nothing in the database was changed."
}

# What can stop an upgrade is asked before anything is stopped or changed: the
# pinned versions and whether they match, whether the new images can be pulled at all, and how many
# accounts the database holds.
prepare_upgrade() {
    raise_pinned_versions
    align_pinned_versions
    pin_gateway_version
    pull_images
    check_single_account
}

# Docker volumes outlive the install directory, so an install that starts
# without an .env can still land on the data of an earlier one.
existing_data_volume() {
    local project="${COMPOSE_PROJECT_NAME:-dmarco}"
    docker volume ls --quiet --filter "name=^${project}_database_data$" 2> /dev/null |
        grep -q .
}

report_existing_data() {
    existing_data_volume || return 0
    warn "An earlier DMARCo install left its data behind in Docker volumes."
    warn "Its reports and accounts are kept, and its stored passwords are updated to the ones this install generates."
    warn "To start from nothing instead, delete that data first, which cannot be undone: cd ${INSTALL_DIR} && docker compose down -v"
}

write_configuration() {
    info "Writing configuration"

    if [ -n "${INTAKE_GATEWAY:-}" ]; then
        add_profile mail-gateway
    fi

    umask 077
    {
        printf '# Generated by install.sh on %s.\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        printf '# See .env.example for what every setting does. How reports come in, outgoing\n'
        printf '# email, retention, and IP lookups are set on the Platform page.\n\n'
        printf 'APP_DOMAIN=%s\n' "$APP_DOMAIN"
        printf 'ACME_EMAIL=%s\n' "$ACME_EMAIL"
        printf 'CORS_ALLOW_ORIGIN=%s\n' "$CORS_ALLOW_ORIGIN"
        printf 'APP_SCHEME=%s\n\n' "$APP_SCHEME"
        printf 'APP_SECRET=%s\n' "$APP_SECRET"
        printf 'APP_ENCRYPTION_KEY=%s\n' "$APP_ENCRYPTION_KEY"
        printf 'POSTGRES_PASSWORD=%s\n\n' "$POSTGRES_PASSWORD"
        if [ -n "${COMPOSE_PROFILES:-}" ]; then
            printf 'COMPOSE_PROFILES=%s\n' "$COMPOSE_PROFILES"
        fi
        if [ -n "${INTAKE_GATEWAY:-}" ]; then
            printf 'MAIL_GATEWAY_DOMAIN=%s\n' "$MAIL_GATEWAY_DOMAIN"
            printf 'SMTP_HOSTNAME=%s\n' "$SMTP_HOSTNAME"
            printf 'SMTP_TLS_MODE=%s\n' "${SMTP_TLS_MODE:-self-signed}"
            printf 'CLAMAV_SCAN_ENABLED=%s\n' "${CLAMAV_SCAN_ENABLED:-true}"
        fi
        [ -z "${COMPOSE_PROFILES:-}${INTAKE_GATEWAY:-}" ] || printf '\n'
        printf 'BACKEND_VERSION=%s\n' "${BACKEND_VERSION:-latest}"
        printf 'DASHBOARD_VERSION=%s\n' "${DASHBOARD_VERSION:-latest}"
        if [ -n "${INTAKE_GATEWAY:-}" ]; then
            printf 'MAIL_INBOUND_VERSION=%s\n' "$GATEWAY_VERSION"
        fi
    } > "${INSTALL_DIR}/.env"
    chmod 600 "${INSTALL_DIR}/.env"
    ok ".env"

    mkdir -p "${INSTALL_DIR}/secrets"
    chmod 700 "${INSTALL_DIR}/secrets"
    if [ -n "${INTAKE_GATEWAY:-}" ]; then
        printf '%s\n' "$WEBHOOK_SECRET" > "${INSTALL_DIR}/secrets/webhook_secret.txt"
    elif [ ! -f "${INSTALL_DIR}/secrets/webhook_secret.txt" ]; then
        # Read by the mail gateway alone, which is off.
        printf 'unused\n' > "${INSTALL_DIR}/secrets/webhook_secret.txt"
    fi
    # The credentials of the MinIO store releases before 0.4 ran, which nothing
    # reads any more.
    rm -f "${INSTALL_DIR}/secrets/s3_access_key.txt" "${INSTALL_DIR}/secrets/s3_secret_key.txt"
    # Only used when SMTP_TLS_MODE=real, see the README.
    [ -f "${INSTALL_DIR}/secrets/cloudflare_token.txt" ] ||
        printf 'unused\n' > "${INSTALL_DIR}/secrets/cloudflare_token.txt"
    # Docker mounts these files into the containers keeping the host's owner and
    # mode, and the processor runs as an unprivileged user that is not this one.
    # The 0700 directory is what keeps other users on the host out.
    chmod 644 "${INSTALL_DIR}"/secrets/*.txt
    ok "secrets/"
    umask 022
}

# Postgres only reads its password from the environment while it initializes
# an empty volume. Over data from an earlier install it keeps that install's
# password instead, and every part of DMARCo then fails to sign in. Setting the
# password from .env on every run keeps .env the one place it is defined.
sync_credentials() {
    local db_user="${POSTGRES_USER:-dmarco}"

    info "Setting the stored password"

    # :'password' lets psql quote the value, so a password containing a quote
    # stays a password instead of becoming SQL.
    if [ -z "${POSTGRES_PASSWORD:-}" ]; then
        warn "There is no POSTGRES_PASSWORD to set."
    elif printf '%s\n' "ALTER ROLE \"${db_user}\" WITH PASSWORD :'password';" |
        compose exec -T database psql --quiet --no-psqlrc \
            --username "$db_user" --dbname postgres \
            -v ON_ERROR_STOP=1 -v "password=${POSTGRES_PASSWORD}" > /dev/null 2>&1; then
        ok "Database"
    else
        warn "Could not set the database password."
        warn "If this server still holds data from an earlier install, put that install's POSTGRES_PASSWORD back in ${INSTALL_DIR}/.env, or delete the old data with: cd ${INSTALL_DIR} && docker compose down -v"
    fi
}

# Run once before an upgrade changes anything, and again before the start,
# when .env may name more images, such as the mail gateway's. The second pull
# finds the images it already has.
pull_images() {
    if [ -n "${IMAGES_PULLED:-}" ]; then
        info "Pulling the images the configuration added, if any"
    else
        info "Pulling images, which takes a few minutes on the first run"
    fi
    compose pull --quiet ||
        die "Could not pull the images. Check the network connection and run the installer again."
    IMAGES_PULLED=1
}

start_stack() {
    pull_images

    # The data stores go up first, because the database password has to match
    # .env before anything tries to connect.
    info "Starting the database and Valkey"
    compose up -d database valkey ||
        die "Could not start them. See what went wrong with: cd ${INSTALL_DIR} && docker compose logs database valkey"
    if wait_for_service database 300 && wait_for_service valkey 300; then
        sync_credentials
        check_single_account
        carry_cache_over
    else
        warn "The database or Valkey did not come up. Check: docker compose logs database valkey"
    fi

    # Compose leaves the containers of a profile that is no longer active
    # running, so a mail gateway switched off has to be removed by name.
    if ! has_profile mail-gateway; then
        compose --profile mail-gateway rm --stop --force postfix processor clamav > /dev/null 2>&1 || true
    fi

    # An install over an earlier one also clears out the services the recipe no
    # longer has, such as the object storage releases before 0.4 ran, and the
    # RabbitMQ and Redis of releases before 0.6.
    info "Starting DMARCo"
    compose up -d --remove-orphans ||
        die "Could not start the stack. See what went wrong with: cd ${INSTALL_DIR} && docker compose logs"
    recreate_changed_mounts

    info "Waiting for the application to become ready"
    if wait_for_service php 300; then
        BACKEND_READY=1
        ok "Backend is up"
    else
        warn "The backend did not come up. The end of its log:"
        show_log_tail php
        warn "Full log: cd ${INSTALL_DIR} && docker compose logs php"
    fi
}

# --------------------------------------------------- settings in the database

# The answer of app:platform:import-env --format=json is one line of JSON with
# lists of variable names. These read it without needing jq.
json_list() {
    printf '%s' "$2" | sed -n "s/.*\"$1\":\[\([^]]*\)\].*/\1/p" | tr ',' '\n' | tr -d '" ' | grep -v '^$' || true
}

json_string() {
    printf '%s' "$2" | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"
}

# The backend names two of them differently from .env.
env_name_of() {
    case "$1" in
        APP_DMARC_AGGREGATE_REPORT_EMAIL_RECEIVER_DOMAIN) printf 'REPORT_DOMAIN' ;;
        APP_INBOUND_REPORT_EMAIL_WEBHOOK_SECRET) printf 'WEBHOOK_SECRET' ;;
        *) printf '%s' "$1" ;;
    esac
}

# Runs the backend's import of the old settings, with the given variables set
# in the environment of that one command, and prints its JSON answer. The
# values travel through the environment rather than the command line, where
# other users of the host could read them.
run_import() {
    local args=() name
    for name in "$@"; do
        args+=(-e "$name")
    done
    compose exec -T ${args[@]+"${args[@]}"} php bin/console app:platform:import-env --format=json 2> /dev/null |
        grep '^{' | tail -n 1 || true
}

# Kept means the database had a value already, which is news only when the
# backend has not just taken the same one over on its start.
report_import() {
    local result="$1" with_kept="${2:-}" name
    if [ -n "$with_kept" ]; then
        for name in $(json_list kept "$result"); do
            note "     $(env_name_of "$name") was already set on the Platform page, which keeps its value."
        done
    fi
    for name in $(json_list invalid "$result"); do
        warn "$(env_name_of "$name") holds something DMARCo cannot take over. Set it on the Platform page instead."
    done
}

# Takes what an .env from 0.4 still holds into the database, which the backend
# already did when it started, and removes the lines that are taken care of.
settle_environment() {
    local result name key value removed=()
    local file="${INSTALL_DIR}/.env"

    for key in "${LEGACY_SETTINGS[@]}"; do
        if env_file_has "$key"; then
            removed+=("$key")
        fi
    done
    [ "${#removed[@]}" -gt 0 ] || return 0
    removed=()

    info "Moving settings from .env into the database"
    result="$(run_import)"
    if [ "$(json_string mode "$result")" != platform ]; then
        warn "The backend did not take the settings over, so .env keeps them. Run the installer again once the backend runs."
        return 0
    fi
    report_import "$result"

    for name in $(json_list settled "$result"); do
        key="$(env_name_of "$name")"
        env_file_has "$key" && removed+=("$key")
    done
    [ "${#removed[@]}" -gt 0 ] || return 0

    backup_env
    for key in "${removed[@]}"; do
        case "$key" in
            REPORT_DOMAIN)
                # The gateway still needs the domain, under a name the backend
                # does not read.
                value="$(env_file_value REPORT_DOMAIN)"
                if has_profile mail-gateway && ! env_file_has MAIL_GATEWAY_DOMAIN && [ -n "$value" ]; then
                    env_set MAIL_GATEWAY_DOMAIN "$value"
                    MAIL_GATEWAY_DOMAIN="$value"
                fi
                ;;
            WEBHOOK_SECRET)
                # The backend now has the secret from .env, and the gateway
                # reads it from this file, so the two have to agree.
                value="$(env_file_value WEBHOOK_SECRET)"
                if [ -n "$value" ] && [ "$(head -n 1 "${INSTALL_DIR}/secrets/webhook_secret.txt" 2> /dev/null)" != "$value" ]; then
                    printf '%s\n' "$value" > "${INSTALL_DIR}/secrets/webhook_secret.txt"
                    RESTART_PROCESSOR=1
                fi
                ;;
        esac
    done
    env_remove "${removed[@]}"
    ok "Moved into the database and removed from .env: ${removed[*]}"

    # The containers still carry the old values until they are recreated.
    compose up -d > /dev/null 2>&1 || warn "Could not restart the stack. Run: cd ${INSTALL_DIR} && docker compose up -d"
    if [ -n "${RESTART_PROCESSOR:-}" ] && has_profile mail-gateway; then
        compose restart processor > /dev/null 2>&1 || true
    fi
}

# The settings a new install was given, which go into the database the same
# way an upgrade's do, without passing through .env.
import_new_settings() {
    local names=() result
    (
        if [ -n "${INTAKE_GATEWAY:-}" ]; then
            export APP_DMARC_AGGREGATE_REPORT_EMAIL_RECEIVER_DOMAIN="$MAIL_GATEWAY_DOMAIN"
            export APP_INBOUND_REPORT_EMAIL_WEBHOOK_SECRET="$WEBHOOK_SECRET"
            names+=(APP_DMARC_AGGREGATE_REPORT_EMAIL_RECEIVER_DOMAIN APP_INBOUND_REPORT_EMAIL_WEBHOOK_SECRET)
        fi
        for name in MAILER_DSN APP_EMAIL_SENDER_ADDRESS APP_REPORT_RETENTION_DAYS APP_IP_LOOKUP_ENABLED; do
            if [ -n "${!name:-}" ]; then
                export "${name?}"
                names+=("$name")
            fi
        done
        [ "${#names[@]}" -gt 0 ] || exit 0

        info "Saving the settings in the database"
        result="$(run_import "${names[@]}")"
        if [ "$(json_string mode "$result")" != platform ]; then
            warn "The backend did not take the settings. Set them on the Platform page."
            exit 0
        fi
        report_import "$result" with-kept
        ok "Settings saved"
    )
}

add_mailbox() {
    local args=(--name="$IMAP_NAME" --host="$IMAP_HOST" --port="$IMAP_PORT"
        --security="$IMAP_SECURITY" --username="$IMAP_USERNAME" --folder="$IMAP_FOLDER" --test)
    [ -z "${IMAP_REPORT_ADDRESS:-}" ] || args+=(--report-address="$IMAP_REPORT_ADDRESS")

    info "Adding the mailbox"
    # The password goes through the environment, like the settings above.
    if (
        export DMARCO_MAILBOX_PASSWORD="$IMAP_PASSWORD"
        compose exec -T -e DMARCO_MAILBOX_PASSWORD php bin/console app:intake:mailbox:add "${args[@]}" 2>&1 |
            sed '/^[[:space:]]*$/d; s/^/     /'
    ); then
        MAILBOX_ADDED=1
    else
        warn "DMARCo is not reading the mailbox yet. Fix it under Report intake on the Platform page."
    fi
}

create_api_key() {
    info "Creating an API key for report uploads"
    API_KEY="$(compose exec -T php bin/console app:intake:api-key:create "install.sh" --enable-api --quiet-key 2> /dev/null |
        tr -d '\r' | grep '^dmarco_' | tail -n 1 || true)"
    if [ -n "$API_KEY" ]; then
        ok "API key, shown at the end, once"
    else
        warn "Could not create the key. Create one on the Platform page, under Report intake."
    fi
}

account_exists() {
    local count
    count="$(compose exec -T database psql --quiet --no-psqlrc -At \
        --username "${POSTGRES_USER:-dmarco}" --dbname "${POSTGRES_DB:-dmarco}" \
        -c 'SELECT count(*) FROM "user"' 2> /dev/null | tr -d '\r')" || return 1
    case "$count" in
        '' | *[!0-9]*) return 1 ;;
    esac
    [ "$count" -gt 0 ]
}

configure_application() {
    if [ -z "${BACKEND_READY:-}" ]; then
        warn "Skipping the JWT keys, the report intake, and the first account until the backend runs."
        return 0
    fi

    info "Generating JWT keys"
    if compose exec -T php sh -lc 'php bin/console lexik:jwt:generate-keypair --skip-if-exists --no-interaction' > /dev/null 2>&1; then
        ok "JWT keys"
    else
        warn "Could not generate JWT keys. Retry with: docker compose exec php bin/console lexik:jwt:generate-keypair --skip-if-exists"
        return 0
    fi

    settle_environment
    import_new_settings
    [ -z "${INTAKE_IMAP:-}" ] || add_mailbox
    [ -z "${INTAKE_API:-}" ] || create_api_key

    # DMARCo has one account, and an install over an earlier one has it already.
    if account_exists; then
        ACCOUNT_CREATED=1
        ok "Your account is already there"
        return 0
    fi

    if ! has_tty; then
        warn "No terminal available. Create your account with: docker compose exec php bin/console app:user:create"
        return 0
    fi

    printf '\n'
    if confirm "Create your DMARCo account now?"; then
        compose exec php bin/console app:user:create < /dev/tty || {
            warn "Account creation failed. Retry with: docker compose exec php bin/console app:user:create"
            return 0
        }
        ACCOUNT_CREATED=1
    fi
}

# ----------------------------------------------------------------- summary

print_summary() {
    local scheme="${APP_SCHEME:-https}"
    local url="${scheme}://${APP_DOMAIN}" step=1 gateway_domain report_domain volume old_volumes
    gateway_domain="${MAIL_GATEWAY_DOMAIN:-${REPORT_DOMAIN:-$APP_DOMAIN}}"
    SMTP_HOSTNAME="${SMTP_HOSTNAME:-$APP_DOMAIN}"

    if [ -n "${BACKEND_READY:-}" ]; then
        printf '\n%s%sDMARCo is running.%s\n' "$C_GREEN" "$C_BOLD" "$C_RESET"
    else
        printf '\n%s%sDMARCo is installed, but the backend is not running.%s\n' \
            "$C_YELLOW" "$C_BOLD" "$C_RESET"
        printf '%sFix what its log reports, then: cd %s && docker compose up -d%s\n' \
            "$C_DIM" "$INSTALL_DIR" "$C_RESET"
    fi

    cat <<EOF

  Dashboard      ${C_BOLD}${url}${C_RESET}
  Directory      ${INSTALL_DIR}

${C_BOLD}${step}. DNS records${C_RESET}

     ${APP_DOMAIN}.  A    <this server's IPv4 address>
EOF
    if has_profile mail-gateway; then
        printf '     %s.  MX   10 %s.\n' "$gateway_domain" "$SMTP_HOSTNAME"
        printf '     *._report._dmarc.%s.  TXT  "v=DMARC1"\n' "$gateway_domain"
        if [ "$SMTP_HOSTNAME" != "$APP_DOMAIN" ]; then
            printf '     %s.  A    %s\n' "$SMTP_HOSTNAME" "<this server's IPv4 address>"
        fi
        cat <<EOF

   For the mail gateway: port 25 must reach this server, and some hosting
   providers block it until asked. The TXT record lets other domains send
   their reports to ${gateway_domain}.
EOF
    fi
    step=$((step + 1))

    cat <<EOF

${C_BOLD}${step}. Point your domains at DMARCo${C_RESET}

EOF
    if [ -n "${INTAKE_IMAP:-}" ] && [ -n "${IMAP_REPORT_ADDRESS:-}" ]; then
        report_domain="${IMAP_REPORT_ADDRESS#*@}"
        cat <<EOF
   Each domain's DMARC record sends its reports to the mailbox:

     _dmarc.example.com.  TXT  "v=DMARC1; p=none; rua=mailto:${IMAP_REPORT_ADDRESS}"

   Mailbox providers send reports for a domain other than ${report_domain} only
   when ${report_domain} agrees, with this record on it:

     *._report._dmarc.${report_domain}.  TXT  "v=DMARC1"

EOF
    fi
    cat <<EOF
   Sign in and add a domain: DMARCo shows the record to publish, with the
   report addresses it can take reports at.
EOF
    if [ -n "${MAILBOX_ADDED:-}" ]; then
        printf '\n   DMARCo reads the mailbox within five minutes, and every 15 minutes after that.\n'
    fi
    step=$((step + 1))

    if [ -n "${API_KEY:-}" ]; then
        cat <<EOF

${C_BOLD}${step}. Upload reports${C_RESET}

   The API key, shown this once. Only a hash of it is kept:

     ${C_BOLD}${API_KEY}${C_RESET}

     curl --fail -X POST -H "Authorization: Bearer <key>" \\
       -H "Content-Type: application/octet-stream" \\
       --data-binary @report.xml.gz ${url}/api/v1/intake/reports
EOF
        step=$((step + 1))
    fi

    cat <<EOF

${C_BOLD}${step}. Everyday commands${C_RESET}

   cd ${INSTALL_DIR}
   docker compose ps
   docker compose logs -f
   bash install.sh upgrade  # upgrade
EOF

    if [ -z "${ACCOUNT_CREATED:-}" ]; then
        cat <<EOF

${C_BOLD}Create your account${C_RESET}

   docker compose exec php bin/console app:user:create
EOF
    fi

    if [ -n "${OBJECT_STORAGE_REMOVED:-}" ] && docker volume inspect "${COMPOSE_PROJECT_NAME:-dmarco}_minio_data" > /dev/null 2>&1; then
        cat <<EOF

${C_BOLD}MinIO's data${C_RESET} is no longer used. Once DMARCo works, delete it with:

   docker volume rm ${COMPOSE_PROJECT_NAME:-dmarco}_minio_data
EOF
    fi

    old_volumes=()
    if [ -n "${BROKER_REMOVED:-}" ]; then
        for volume in rabbitmq_data redis_data; do
            volume="${COMPOSE_PROJECT_NAME:-dmarco}_${volume}"
            docker volume inspect "$volume" > /dev/null 2>&1 && old_volumes+=("$volume")
        done
    fi
    if [ "${#old_volumes[@]}" -gt 0 ]; then
        cat <<EOF

${C_BOLD}RabbitMQ's and Redis's data${C_RESET} is no longer used: Valkey keeps the queues
and the cache now. Once DMARCo works, delete it with:

   docker volume rm ${old_volumes[*]}
EOF
    fi

    if [ -n "${ENV_BACKUP:-}" ]; then
        cat <<EOF

${C_BOLD}The previous .env${C_RESET} is saved as ${ENV_BACKUP}. It holds the
settings this run changed or removed, passwords among them. Delete it once
DMARCo works.
EOF
    fi

    cat <<EOF

${C_DIM}Mailboxes, API keys, outgoing email, and two-factor authentication are on the
dashboard: the first three on the Platform page, the last in your profile.
Full documentation: https://github.com/${REPO}${C_RESET}

EOF
}

main() {
    # A run that continues in the installer it just downloaded has said hello.
    if [ -z "${DMARCO_FETCHED:-}" ]; then
        printf '\n%s%sDMARCo installer%s\n%sSelf-hosted DMARC report aggregation%s\n\n' \
            "$C_BOLD" "$C_BLUE" "$C_RESET" "$C_DIM" "$C_RESET"
    fi

    local arg upgrade="${DMARCO_UPGRADE:-}"
    for arg in "$@"; do
        case "$arg" in
            upgrade | --upgrade) upgrade=1 ;;
            -h | --help)
                printf 'Usage: install.sh [upgrade]\n\n  upgrade  upgrade the install in this directory without asking\n'
                exit 0
                ;;
            *) die "Unknown option: ${arg}. See install.sh --help." ;;
        esac
    done
    # Upgrading asks nothing: every answer is already in .env.
    [ -z "$upgrade" ] || DMARCO_YES=1

    [ -n "${DMARCO_FETCHED:-}" ] || check_requirements

    # Run from a checkout of the recipe, the installer uses the stack next to
    # it as it is. Run from the copy it saved in an install directory, it is in
    # that install and fetches the current stack, itself included.
    local script_dir='' source_dir='' installed_copy=''
    if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [ -f "${script_dir}/compose.yaml" ] && [ -e "${script_dir}/.git" ]; then
            source_dir="$script_dir"
        elif [ -f "${script_dir}/compose.yaml" ] && [ -f "${script_dir}/.env" ]; then
            installed_copy="$script_dir"
            # The current version of this script, saved by the run that
            # started it, carries the upgrade steps this copy may not know.
            [ -z "${DMARCO_FETCHED:-}" ] || source_dir="$script_dir"
        fi
    fi

    if [ -n "$source_dir" ]; then
        INSTALL_DIR="$source_dir"
    elif [ -n "$installed_copy" ]; then
        INSTALL_DIR="$installed_copy"
    else
        INSTALL_DIR="${DMARCO_DIR:-}"
        # Run from inside an install, as the README says to upgrade, the
        # install is where it is.
        if [ -f "$(pwd)/compose.yaml" ] && [ -f "$(pwd)/.env" ]; then
            ask INSTALL_DIR "Install DMARCo into" "$(pwd)"
        else
            ask INSTALL_DIR "Install DMARCo into" "$(pwd)/dmarco"
        fi
        mkdir -p "$INSTALL_DIR"
        INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd)"
    fi
    [ -z "$upgrade" ] || [ -f "${INSTALL_DIR}/.env" ] ||
        die "There is no install to upgrade in ${INSTALL_DIR}: it has no .env. Run the installer without upgrade to install."

    fetch_stack "$source_dir"
    if [ -n "$installed_copy" ] && [ -z "${DMARCO_FETCHED:-}" ]; then
        info "Continuing with the installer just downloaded"
        DMARCO_FETCHED=1 exec bash "${INSTALL_DIR}/install.sh" "$@"
    fi
    cd "$INSTALL_DIR"

    if [ -f "${INSTALL_DIR}/.env" ]; then
        warn "${INSTALL_DIR}/.env already exists."
        if confirm "Keep it and upgrade or restart the stack?"; then
            # Every release that changes what an install needs adds its
            # upgrade step here, breaking changes above all. Each step checks
            # what is on disk rather than a version number and does nothing
            # once applied, so an install of any age reaches the new version
            # in one run, and a plain restart changes nothing.
            load_existing_configuration
            prepare_upgrade
            drain_object_storage_queue
            drain_message_broker
            ensure_encryption_key
            keep_gateway_running
        else
            confirm "Overwrite the existing configuration?" ||
                die "Nothing to do."
            ! gateway_in_use || GATEWAY_IN_USE=1
            prepare_upgrade
            drain_object_storage_queue
            drain_message_broker
            # The old file holds secrets the data depends on, and settings
            # that only reach the database once the new version runs.
            backup_env
            keep_existing_secrets
            collect_configuration
            write_configuration
        fi
    else
        report_existing_data
        collect_configuration
        write_configuration
    fi

    start_stack
    configure_application
    print_summary
}

main "$@"
