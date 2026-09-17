#!/usr/bin/env bash
#
# DMARCo installer.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/dmarcoapp/dmarcoapp/main/install.sh)"
#
# Downloads the Compose stack, asks for the handful of settings DMARCo needs,
# generates secrets and starts everything. Answers can also be supplied as
# environment variables, in which case the installer does not ask for them:
#
#   APP_DOMAIN=dmarc.example.com ACME_EMAIL=you@example.com ./install.sh
#
set -euo pipefail

REPO="${DMARCO_REPO:-dmarcoapp/dmarcoapp}"
REF="${DMARCO_REF:-main}"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/${REF}"
STACK_FILES=(compose.yaml Caddyfile .env.example clamav/clamd.conf clamav/freshclam.conf)

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
    local var="$1" text="$2" default="${3:-}" answer
    if [ -n "${!var:-}" ]; then
        return 0
    fi
    while true; do
        if [ -n "$default" ]; then
            printf '%s%s%s [%s]: ' "$C_BOLD" "$text" "$C_RESET" "$default" >&2
        else
            printf '%s%s%s: ' "$C_BOLD" "$text" "$C_RESET" >&2
        fi
        if ! IFS= read -r answer < "$INPUT"; then
            answer=''
        fi
        answer="${answer:-$default}"
        if [ -n "$answer" ]; then
            printf -v "$var" '%s' "$answer"
            return 0
        fi
        warn "A value is required."
    done
}

ask_secret() {
    local var="$1" text="$2" answer
    if [ -n "${!var:-}" ]; then
        return 0
    fi
    printf '%s%s%s: ' "$C_BOLD" "$text" "$C_RESET" >&2
    IFS= read -rs answer < "$INPUT" || answer=''
    printf '\n' >&2
    printf -v "$var" '%s' "$answer"
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

generate_secret() {
    if command -v openssl > /dev/null 2>&1; then
        openssl rand -hex 24
    else
        LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 48
        printf '\n'
    fi
}

# Percent-encodes a string for use inside a URL, so passwords containing
# characters such as @ or / do not break the mailer DSN.
urlencode() {
    # LC_ALL=C makes the loop walk bytes, which is what percent-encoding needs.
    local LC_ALL=C string="$1" index char out=''
    for ((index = 0; index < ${#string}; index++)); do
        char="${string:index:1}"
        case "$char" in
            [a-zA-Z0-9.~_-]) out+="$char" ;;
            *) out+="$(printf '%%%02X' "'$char")" ;;
        esac
    done
    printf '%s' "$out"
}

# Escapes a hostname for use inside the CORS origin regular expression.
regex_escape() {
    # shellcheck disable=SC2016  # the sed expression is intentionally literal
    printf '%s' "$1" | sed -e 's/[.[\*^$()+?{}|\\]/\\&/g'
}

# Looks up existing MX records, so the installer can warn before a domain that
# already receives email is pointed at DMARCo.
existing_mx() {
    local domain="$1"
    # No records is the normal case, so never fail the caller.
    if command -v dig > /dev/null 2>&1; then
        dig +short +timeout=3 MX "$domain" 2> /dev/null | grep -v '^$' | head -n 3 || true
    elif command -v host > /dev/null 2>&1; then
        host -t MX -W 3 "$domain" 2> /dev/null | grep 'mail is handled by' | head -n 3 || true
    fi
}

download() {
    local url="$1" target="$2"
    mkdir -p "$(dirname "$target")"
    if command -v curl > /dev/null 2>&1; then
        curl -fsSL "$url" -o "$target"
    else
        wget -qO "$target" "$url"
    fi
}

compose() {
    docker compose "$@"
}

wait_for_service() {
    local service="$1" timeout="${2:-300}" waited=0 id state
    while [ "$waited" -lt "$timeout" ]; do
        id="$(compose ps -q "$service" 2> /dev/null | head -n 1)"
        if [ -n "$id" ]; then
            state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2> /dev/null || printf 'unknown')"
            case "$state" in
                healthy | running) return 0 ;;
                exited | dead) return 1 ;;
            esac
        fi
        sleep 3
        waited=$((waited + 3))
    done
    return 1
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
    for port in 25 80 443; do
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
        info "Using the Compose stack from ${source_dir}"
        return 0
    fi

    info "Downloading the Compose stack"
    for file in "${STACK_FILES[@]}"; do
        download "${RAW_BASE}/${file}" "${INSTALL_DIR}/${file}"
        ok "$file"
    done
}

collect_configuration() {
    info "Configuration"
    printf '%sDMARCo needs a domain that points to this server, and an SMTP account\nfor account emails such as verification and two-factor codes.%s\n\n' "$C_DIM" "$C_RESET"

    ask APP_DOMAIN "Domain for the dashboard and API" ""
    ask ACME_EMAIL "Email address for Let's Encrypt" ""
    ask REPORT_DOMAIN "Domain your DMARC reports are sent to, which must not receive other email" "$APP_DOMAIN"
    check_report_domain
    ask SMTP_HOSTNAME "Public hostname of this mail server" "$APP_DOMAIN"
    ask APP_EMAIL_SENDER_ADDRESS "Sender address for DMARCo emails" "no-reply@${APP_DOMAIN}"

    if [ -z "${MAILER_DSN:-}" ]; then
        printf '\n'
        ask MAIL_HOST "SMTP server for outgoing email" ""
        ask MAIL_PORT "SMTP port" "587"
        ask MAIL_USER "SMTP username" ""
        ask_secret MAIL_PASSWORD "SMTP password"
        MAILER_DSN="smtp://$(urlencode "$MAIL_USER"):$(urlencode "$MAIL_PASSWORD")@${MAIL_HOST}:${MAIL_PORT}"
    fi

    APP_SCHEME="${APP_SCHEME:-https}"
    CORS_ALLOW_ORIGIN="${CORS_ALLOW_ORIGIN:-^${APP_SCHEME}://$(regex_escape "$APP_DOMAIN")$}"

    APP_SECRET="${APP_SECRET:-$(generate_secret)}"
    WEBHOOK_SECRET="${WEBHOOK_SECRET:-$(generate_secret)}"
    POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-$(generate_secret)}"
    RABBITMQ_PASSWORD="${RABBITMQ_PASSWORD:-$(generate_secret)}"
    S3_ACCESS_KEY="${S3_ACCESS_KEY:-$(generate_secret)}"
    S3_SECRET_KEY="${S3_SECRET_KEY:-$(generate_secret)}"
}

check_report_domain() {
    local mx=''
    mx="$(existing_mx "$REPORT_DOMAIN")" || true
    [ -n "$mx" ] || return 0

    warn "${REPORT_DOMAIN} already has MX records:"
    printf '%s\n' "$mx" | sed 's/^/       /' >&2
    warn "DMARCo replaces them and accepts only DMARC reports, so any other email sent to ${REPORT_DOMAIN} would be lost."
    warn "Use a dedicated domain or subdomain instead, such as dmarc.${REPORT_DOMAIN}."

    confirm "Use ${REPORT_DOMAIN} anyway?" ||
        die "Run the installer again with a domain that does not receive other email."
}

write_configuration() {
    info "Writing configuration"

    umask 077
    cat > "${INSTALL_DIR}/.env" <<- EOF
		# Generated by install.sh on $(date -u '+%Y-%m-%d %H:%M:%S UTC').
		# See .env.example for what every setting does.

		APP_DOMAIN=${APP_DOMAIN}
		ACME_EMAIL=${ACME_EMAIL}
		CORS_ALLOW_ORIGIN=${CORS_ALLOW_ORIGIN}
		APP_SCHEME=${APP_SCHEME}

		REPORT_DOMAIN=${REPORT_DOMAIN}
		SMTP_HOSTNAME=${SMTP_HOSTNAME}
		SMTP_TLS_MODE=${SMTP_TLS_MODE:-self-signed}

		MAILER_DSN=${MAILER_DSN}
		APP_EMAIL_SENDER_ADDRESS=${APP_EMAIL_SENDER_ADDRESS}

		APP_SECRET=${APP_SECRET}
		WEBHOOK_SECRET=${WEBHOOK_SECRET}
		POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
		RABBITMQ_PASSWORD=${RABBITMQ_PASSWORD}
		S3_ACCESS_KEY=${S3_ACCESS_KEY}
		S3_SECRET_KEY=${S3_SECRET_KEY}

		APP_REGISTRATION_ENABLED=${APP_REGISTRATION_ENABLED:-false}
		DASHBOARD_DISABLE_REGISTRATION=${DASHBOARD_DISABLE_REGISTRATION:-true}
		APP_REPORT_RETENTION_DAYS=${APP_REPORT_RETENTION_DAYS:-365}
		CLAMAV_SCAN_ENABLED=${CLAMAV_SCAN_ENABLED:-true}

		BACKEND_VERSION=${BACKEND_VERSION:-latest}
		DASHBOARD_VERSION=${DASHBOARD_VERSION:-latest}
		MAIL_INBOUND_VERSION=${MAIL_INBOUND_VERSION:-latest}
	EOF
    chmod 600 "${INSTALL_DIR}/.env"
    ok ".env"

    mkdir -p "${INSTALL_DIR}/secrets"
    chmod 700 "${INSTALL_DIR}/secrets"
    printf '%s\n' "$WEBHOOK_SECRET" > "${INSTALL_DIR}/secrets/webhook_secret.txt"
    printf '%s\n' "$S3_ACCESS_KEY" > "${INSTALL_DIR}/secrets/s3_access_key.txt"
    printf '%s\n' "$S3_SECRET_KEY" > "${INSTALL_DIR}/secrets/s3_secret_key.txt"
    # Only used when SMTP_TLS_MODE=real, see the README.
    [ -f "${INSTALL_DIR}/secrets/cloudflare_token.txt" ] ||
        printf 'unused\n' > "${INSTALL_DIR}/secrets/cloudflare_token.txt"
    chmod 600 "${INSTALL_DIR}"/secrets/*.txt
    ok "secrets/"
    umask 022
}

start_stack() {
    info "Pulling images, this takes a few minutes on the first run"
    compose pull --quiet ||
        die "Could not pull the images. Check the network connection and run the installer again."

    info "Starting DMARCo"
    compose up -d ||
        die "Could not start the stack. See what went wrong with: cd ${INSTALL_DIR} && docker compose logs"

    info "Waiting for the application to become ready"
    if wait_for_service php 300; then
        ok "Backend is up"
    else
        warn "The backend did not report healthy in time. Check: docker compose logs php"
    fi
}

configure_application() {
    info "Generating JWT keys"
    if compose exec -T php sh -lc 'php bin/console lexik:jwt:generate-keypair --skip-if-exists --no-interaction' > /dev/null 2>&1; then
        ok "JWT keys"
    else
        warn "Could not generate JWT keys. Retry with: docker compose exec php bin/console lexik:jwt:generate-keypair --skip-if-exists"
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

print_summary() {
    local scheme="${APP_SCHEME:-https}"
    local url="${scheme}://${APP_DOMAIN}"
    REPORT_DOMAIN="${REPORT_DOMAIN:-$APP_DOMAIN}"
    SMTP_HOSTNAME="${SMTP_HOSTNAME:-$APP_DOMAIN}"

    cat <<- EOF

		${C_GREEN}${C_BOLD}DMARCo is running.${C_RESET}

		  Dashboard      ${C_BOLD}${url}${C_RESET}
		  Directory      ${INSTALL_DIR}

		${C_BOLD}1. DNS records${C_RESET}

		     ${APP_DOMAIN}.  A    <this server's IPv4 address>
		     ${REPORT_DOMAIN}.  MX   10 ${SMTP_HOSTNAME}.
		     *._report._dmarc.${REPORT_DOMAIN}.  TXT  "v=DMARC1"
	EOF

    if [ "$SMTP_HOSTNAME" != "$APP_DOMAIN" ]; then
        printf '     %s.  A   %s\n' "$SMTP_HOSTNAME" "<this server's IPv4 address>"
    fi

    cat <<- EOF

		   The TXT record is what lets other domains send their reports here.
		   Without it, providers stop sending reports for every domain that is
		   not under ${REPORT_DOMAIN}.

		   Port 25 must reach this server. Some hosting providers block it by
		   default and unblock it on request.

		${C_BOLD}2. Point your domains at DMARCo${C_RESET}

		   Sign in, add a domain, and DMARCo gives you the address to put in its
		   DMARC record, for example:

		     _dmarc.example.com.  TXT  "v=DMARC1; p=none; rua=mailto:<address>@${REPORT_DOMAIN}"

		${C_BOLD}3. Everyday commands${C_RESET}

		   cd ${INSTALL_DIR}
		   docker compose ps
		   docker compose logs -f
		   docker compose pull && docker compose up -d     # upgrade
	EOF

    if [ -z "${ACCOUNT_CREATED:-}" ]; then
        cat <<- EOF

			${C_BOLD}Create your account${C_RESET}

			   docker compose exec php bin/console app:user:create
		EOF
    fi

    cat <<- EOF

		${C_DIM}New accounts have to confirm their email address, and every sign-in sends a
		two-factor code by email, so check that DMARCo can send mail. Full
		documentation: https://github.com/${REPO}${C_RESET}

	EOF
}

main() {
    printf '\n%s%sDMARCo installer%s\n%sSelf-hosted DMARC report aggregation%s\n\n' \
        "$C_BOLD" "$C_BLUE" "$C_RESET" "$C_DIM" "$C_RESET"

    check_requirements

    local script_dir='' source_dir=''
    if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [ -f "${script_dir}/compose.yaml" ]; then
            source_dir="$script_dir"
        fi
    fi

    if [ -n "$source_dir" ]; then
        INSTALL_DIR="$source_dir"
    else
        INSTALL_DIR="${DMARCO_DIR:-}"
        ask INSTALL_DIR "Install DMARCo into" "$(pwd)/dmarco"
        mkdir -p "$INSTALL_DIR"
        INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd)"
    fi

    fetch_stack "$source_dir"
    cd "$INSTALL_DIR"

    if [ -f "${INSTALL_DIR}/.env" ]; then
        warn "${INSTALL_DIR}/.env already exists."
        if confirm "Keep it and only restart the stack?"; then
            set -a
            # shellcheck disable=SC1091
            . "${INSTALL_DIR}/.env"
            set +a
        else
            confirm "Overwrite the existing configuration?" ||
                die "Nothing to do."
            collect_configuration
            write_configuration
        fi
    else
        collect_configuration
        write_configuration
    fi

    start_stack
    configure_application
    print_summary
}

main "$@"
