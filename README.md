<p align="center">
  <img src=".github/logo.svg" alt="" width="80" height="80">
</p>

<h1 align="center">DMARCo</h1>

<p align="center">
  Self-hosted DMARC report aggregation. Point your domains at your own server
  and find out who is sending email as you.
</p>

<p align="center">
  <a href="LICENSE"><img alt="License: Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-blue.svg"></a>
  <a href="https://github.com/dmarcoapp/dmarcoapp/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/dmarcoapp/dmarcoapp/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://github.com/dmarcoapp/dmarcoapp/issues"><img alt="Issues" src="https://img.shields.io/github/issues/dmarcoapp/dmarcoapp.svg"></a>
</p>

> [!IMPORTANT]
> **Start here.** This repository installs all of DMARCo with one command, and
> it is the issue tracker for the whole project. Whatever goes wrong, whichever
> component it comes from, report it here:
> [open an issue](https://github.com/dmarcoapp/dmarcoapp/issues/new/choose).

DMARC reports tell you which servers send mail using your domain, and whether
that mail passes SPF and DKIM. Mailbox providers send those reports as XML
attachments, every day, from every provider, for every domain. DMARCo collects
them, parses them, and turns them into something you can actually read: senders,
volumes, authentication results, and the traffic you did not expect.

Everything runs on your own machine. No third-party service ever sees your
report data.

```text
DMARC reports (email)  ->  DMARCo  ->  dashboard
```

## What you get

- A dashboard of report volume, pass rates, blocked threats, and the trend
  behind each one
- Top senders, top offenders, reporting organizations, and source countries
- Per-domain pages with the published DMARC record, a protection level, and
  DKIM and SPF alignment
- Report browsing with filtering, sorting, record details, and the raw XML
- A blocklist for reporters you do not care about
- Accounts with email verification, two-factor authentication, and password reset
- Automatic deletion of reports past the retention window

## How it works

```text
report email -> Postfix -> virus scan -> object storage -> backend -> PostgreSQL -> dashboard
```

One `docker compose` stack runs all of it:

| Part | What it does |
| --- | --- |
| `caddy` | Serves the dashboard and the API on one domain, with automatic HTTPS |
| `dashboard` | The web UI |
| `php`, `worker` | API and background report processing |
| `postfix`, `processor`, `clamav` | Receives report email, scans it, extracts the reports |
| `database`, `redis`, `rabbitmq`, `minio` | Storage and queues |

## Requirements

- A Linux server with [Docker](https://docs.docker.com/engine/install/) and
  Docker Compose v2, on x86-64 or ARM64
- Two CPU cores and 4 GB of memory are enough for a handful of domains
- A public IPv4 address, with ports `80`, `443`, and `25` reaching the server.
  Many providers block port `25` in both directions until you ask them to open
  it
- A domain you can add DNS records to
- An SMTP account for outgoing mail. DMARCo emails verification links and
  two-factor codes, so sign-in does not work without one. Any provider works,
  including a free tier

## Install

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/dmarcoapp/dmarcoapp/main/install.sh)"
```

The installer checks your Docker setup, asks for your domain and SMTP details,
generates every password and secret, starts the stack, and creates your
account. It takes a couple of minutes, most of it spent pulling images.

Prefer to read before you run? The script is [install.sh](install.sh), and the
manual route is below.

### Manual install

```bash
git clone https://github.com/dmarcoapp/dmarcoapp.git dmarco
cd dmarco
cp .env.example .env
nano .env
```

Fill in the domains and the mailer DSN, and replace every `generated` value with
a long random string, for example from `openssl rand -hex 24`. Then write the
secrets the mail gateway reads from files:

```bash
mkdir -p secrets && chmod 700 secrets
printf '%s\n' "$(grep '^WEBHOOK_SECRET=' .env | cut -d= -f2-)" > secrets/webhook_secret.txt
printf '%s\n' "$(grep '^S3_ACCESS_KEY=' .env | cut -d= -f2-)" > secrets/s3_access_key.txt
printf '%s\n' "$(grep '^S3_SECRET_KEY=' .env | cut -d= -f2-)" > secrets/s3_secret_key.txt
printf 'unused\n' > secrets/cloudflare_token.txt
chmod 644 secrets/*.txt
```

Docker mounts those files into the containers keeping the owner and mode they
have here, and the mail processor runs as an unprivileged user that is not you,
so `0600` would lock it out. The `0700` directory is what keeps other users on
the host away from the files.

Now start everything:

```bash
docker compose up -d --wait
docker compose exec php bin/console lexik:jwt:generate-keypair --skip-if-exists
docker compose exec php bin/console app:user:create --simple
```

`--wait` returns once every container reports healthy, which on the first run
means waiting for the database migrations.

## DNS records

With `APP_DOMAIN` and `REPORT_DOMAIN` both set to `dmarc.example.com`:

| Type | Name | Value |
| --- | --- | --- |
| `A` | `dmarc.example.com` | your server's IPv4 address |
| `MX` | `dmarc.example.com` | `10 dmarc.example.com.` |
| `TXT` | `*._report._dmarc.dmarc.example.com` | `v=DMARC1` |

The `A` record serves the dashboard. The `MX` record is what makes report email
arrive. If you split the two, for example a UI on `dmarc.example.com` and
reports on `reports.example.com`, add an `A` record for the value of
`SMTP_HOSTNAME` as well.

Use a domain or subdomain that receives no other email. DMARCo's `MX` record
replaces whatever was there, and it accepts DMARC reports only, so anything else
sent to `REPORT_DOMAIN` is rejected. A dedicated subdomain such as
`dmarc.example.com` leaves the mail setup of `example.com` untouched.

### Why the `_report._dmarc` record

A domain may not send its DMARC reports to an address on someone else's domain
unless that domain agrees to it, and the `TXT` record above is that agreement.
Without it, every provider that follows the spec, which is all the large ones,
quietly stops sending you reports for domains outside `REPORT_DOMAIN`.

The wildcard covers every domain you will ever add. To be more restrictive,
publish one record per monitored domain instead:

| Type | Name | Value |
| --- | --- | --- |
| `TXT` | `example.net._report._dmarc.dmarc.example.com` | `v=DMARC1` |

You can skip the record only when the monitored domain and `REPORT_DOMAIN` sit
under the same registered domain, such as watching `example.com` with reports
arriving at `dmarc.example.com`.

The wildcard also lets strangers aim their reports at your server. They cannot
read anything of yours, and mail to an address that belongs to no account is
discarded, so the cost is a little wasted processing.

## Point a domain at DMARCo

Sign in, add a domain, and DMARCo shows you the mailbox address for it. Put
that address in the domain's DMARC record:

```text
_dmarc.example.com.  TXT  "v=DMARC1; p=none; rua=mailto:<address>@dmarc.example.com"
```

If the domain is not a subdomain of `REPORT_DOMAIN`, it also needs the
[`_report._dmarc` authorization](#why-the-_report_dmarc-record), which the
wildcard record already covers.

`p=none` only asks for reports and changes nothing about how your mail is
delivered. Providers send them once every 24 hours, so the first numbers appear
a day or two after the record goes live.

Once you can see who sends mail as you, and everything legitimate passes, you
can move the policy to `p=quarantine` and then `p=reject`.

## Configuration

All settings live in `.env`. Change one, then run `docker compose up -d` to
apply it.

| Setting | What it is |
| --- | --- |
| `APP_DOMAIN` | Domain the dashboard and API are served on |
| `ACME_EMAIL` | Address for your Let's Encrypt account |
| `CORS_ALLOW_ORIGIN` | Browser origins allowed to call the API, as a regular expression |
| `REPORT_DOMAIN` | Domain reports are sent to, the one with the `MX` record |
| `SMTP_HOSTNAME` | Public hostname of this mail server |
| `SMTP_TLS_MODE` | Certificate for inbound SMTP: `self-signed`, `real`, `external`, or `disabled` |
| `MAILER_DSN` | SMTP account used for outgoing mail |
| `APP_EMAIL_SENDER_ADDRESS` | Sender address of DMARCo's own emails |
| `APP_REGISTRATION_ENABLED`, `DASHBOARD_DISABLE_REGISTRATION` | Public sign-up, off by default |
| `APP_REPORT_RETENTION_DAYS` | How long processed reports are kept, `0` to keep them forever |
| `S3_RETENTION_DAYS` | How long the raw report emails are kept in object storage, `0` to keep them forever |
| `CLAMAV_SCAN_ENABLED` | Virus scanning of attachments |
| `BACKEND_VERSION`, `DASHBOARD_VERSION`, `MAIL_INBOUND_VERSION` | Image tags, pin these for reproducible upgrades |

### Accounts

Public registration is off by default, which is usually what you want on your
own server. Add people from the command line:

```bash
docker compose exec php bin/console app:user:create --simple
```

To open registration instead, set `APP_REGISTRATION_ENABLED=true` and
`DASHBOARD_DISABLE_REGISTRATION=false`.

### Turning off virus scanning

`CLAMAV_SCAN_ENABLED=false` skips the scan but keeps the scanner running, and
ClamAV holds roughly 1.5 GB of signature database in memory either way. To drop
the container as well on a small server, create `compose.override.yaml` next to
`compose.yaml`:

```yaml
services:
  processor:
    depends_on: !reset null
  clamav:
    profiles: ["disabled"]
```

Then set `CLAMAV_SCAN_ENABLED=false` in `.env` and run `docker compose up -d
--remove-orphans`. Attachments are still size-checked, extension-checked, and
schema-validated, but no longer scanned for malware.

### A publicly trusted certificate for inbound mail

By default Postfix presents a self-signed certificate. Sending servers use
opportunistic TLS, so they accept it, and report email is not secret. If you
would rather serve a real certificate, and your DNS is on Cloudflare, put an
API token that can edit DNS records for `SMTP_HOSTNAME` in
`secrets/cloudflare_token.txt`, then:

```bash
echo 'COMPOSE_PROFILES=letsencrypt' >> .env
sed -i 's/^SMTP_TLS_MODE=.*/SMTP_TLS_MODE=real/' .env
docker compose up -d
```

With a certificate from elsewhere, set `SMTP_TLS_MODE=external` and mount the
chain file, which must hold the private key followed by the full certificate
chain, using a `compose.override.yaml`:

```yaml
services:
  postfix:
    volumes:
      - /etc/ssl/mx/chain.pem:/certs/smtp.pem:ro
```

Use `SMTP_TLS_CHAIN_FILE` in `.env` if you would rather mount it elsewhere.
Postfix reads the file at startup, so restart it after a renewal.

## Running it

```bash
cd dmarco

docker compose ps                 # what is running
docker compose logs -f            # follow everything
docker compose logs -f processor  # follow report processing
docker compose restart php        # restart one part
docker compose down               # stop, keeping all data
```

### Upgrading

```bash
docker compose pull
docker compose up -d
```

Database migrations run automatically on start. Pin the `*_VERSION` settings in
`.env` to release tags if you would rather decide when new versions land.

### Backups

Everything durable lives in Docker volumes. The database is the part you cannot
rebuild:

```bash
docker compose exec -T database pg_dump -U dmarco dmarco | gzip > dmarco-$(date +%F).sql.gz
```

Keep a copy of `.env` and `secrets/` with it, because restoring needs both. To
restore into an empty stack:

```bash
docker compose up -d database
gunzip -c dmarco-2026-01-31.sql.gz | docker compose exec -T database psql -U dmarco dmarco
docker compose up -d
```

## Troubleshooting

**No reports arrive.** First check the authorization record, the most common
cause when only some domains report in:

```bash
dig +short TXT '*._report._dmarc.dmarc.example.com'
```

It should print `"v=DMARC1"`. Then check that port `25` reaches the server, from
another machine: `nc -vz dmarc.example.com 25`. Providers often block it by
default. Finally look at `docker compose logs postfix processor`.

**I never got the verification email.** DMARCo can only send mail if
`MAILER_DSN` is right. Look for errors with `docker compose logs worker`, fix
`.env`, run `docker compose up -d`, and resend:

```bash
docker compose exec php bin/console app:user:verification-email:resend
```

**The site does not load over HTTPS.** Caddy needs ports `80` and `443` free,
and `APP_DOMAIN` has to resolve to this server before it can get a certificate.
`docker compose logs caddy` says which of the two went wrong.

**`password authentication failed for user "dmarco"`.** The database still has
the password of an earlier install. Postgres reads `POSTGRES_PASSWORD` only when
it creates its data directory, and Docker volumes outlive the directory you
installed into, so a reinstall with fresh secrets cannot sign in to the data it
finds. Running `install.sh` again sets the stored passwords from `.env`. By
hand, with the values from `.env`:

```bash
docker compose exec database psql -U dmarco -d postgres \
  -c "ALTER ROLE dmarco WITH PASSWORD 'POSTGRES_PASSWORD from .env'"
docker compose exec rabbitmq \
  rabbitmqctl change_password dmarco 'RABBITMQ_PASSWORD from .env'
docker compose up -d
```

**Something else.** `docker compose ps` shows any container that is unhealthy,
and `docker compose logs <name>` shows why.

## Help and issues

Something broken, unclear, or missing? Open an issue here, in this repository:

- [Report a problem](https://github.com/dmarcoapp/dmarcoapp/issues/new/choose):
  installation, upgrades, mail delivery, the dashboard, the API, anything
- [Suggest a feature](https://github.com/dmarcoapp/dmarcoapp/issues/new/choose)

Include the output of `docker compose ps` and the relevant `docker compose
logs`, and leave out anything sensitive.

Found a security vulnerability? Please do not open a public issue. See
[`SECURITY.md`](SECURITY.md) instead.

Want to contribute code? See [`CONTRIBUTING.md`](CONTRIBUTING.md).

## What this repository is

The installer and the Compose stack. The application itself is developed in
three repositories, and this stack runs their published images:

- [`dmarcoapp/dashboard`](https://github.com/dmarcoapp/dashboard): the web UI
- [`dmarcoapp/backend`](https://github.com/dmarcoapp/backend): API, workers, and report processing
- [`dmarcoapp/mail-inbound`](https://github.com/dmarcoapp/mail-inbound): the inbound mail gateway

## License

Licensed under the Apache License, Version 2.0. See [`LICENSE`](LICENSE) and
[`NOTICE`](NOTICE).
