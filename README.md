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

Everything runs on your own machine, and no third-party service receives your
reports. DMARCo does look up the IP addresses that send mail as you, at
ipwho.is and the regional internet registries, to show who owns them and where
they are. You can turn that off on the Platform page.

```text
mailbox you already have  --IMAP-->  DMARCo  ->  dashboard
```

## What you get

- A dashboard of report volume, pass rates, blocked threats, and the trend
  behind each one
- Top senders, top offenders, reporting organizations, and source countries
- Per-domain pages with the published DMARC record, a protection level, and
  DKIM and SPF alignment
- Report browsing with filtering, sorting, record details, and the raw XML
- Reports read from the mailboxes they already arrive in, over IMAP, from as
  many mailboxes as you like
- Optional report uploads through the API, with revocable keys
- A blocklist for reporters you do not care about
- One account for you, with optional two-factor authentication by authenticator
  app
- Optional email notifications: a weekly overview and sign-in alerts
- Automatic deletion of reports past the retention window

## How it works

```text
mailbox -> IMAP -> worker -> PostgreSQL -> dashboard
```

The worker signs in to each mailbox you add, every 15 minutes unless you choose
otherwise, and stores the reports it finds. Reports can also be uploaded through
the API, or arrive at the [mail gateway](#mail-gateway), the older way in, which
runs a mail server on port `25`.

One `docker compose` stack runs all of it:

| Part | What it does |
| --- | --- |
| `caddy` | Serves the dashboard and the API on one domain, with automatic HTTPS |
| `dashboard` | The web UI |
| `php`, `worker` | API, mailbox reading, and background report processing |
| `database`, `redis`, `rabbitmq` | Storage and queues |
| `postfix`, `processor`, `clamav` | The mail gateway, only with the `mail-gateway` profile |

## Requirements

- A Linux server with [Docker](https://docs.docker.com/engine/install/) and
  Docker Compose v2, on x86-64 or ARM64
- Two CPU cores and 4 GB of memory are enough for a handful of domains
- A public IPv4 address, with ports `80` and `443` reaching the server
- A domain you can add DNS records to
- A mailbox for your DMARC reports that DMARCo can reach over IMAP, with TLS or
  STARTTLS. A dedicated one, such as `dmarc@example.com`, keeps the reports
  apart from other mail. Uploads through the API and the mail gateway need
  none
- Optional: an SMTP account for outgoing mail, if you want the notification
  emails. Any provider works, including a free tier

## Install

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/dmarcoapp/dmarcoapp/main/install.sh)"
```

The installer checks your Docker setup, asks for your domain and how reports
should come in: from a mailbox over IMAP, through uploads with an API key, from
the mail gateway, or several of them. It asks for what the choice needs, such as
the mailbox's server and password, and checks that DMARCo can sign in. It
generates every password and secret, starts the stack, and creates your
account. It takes a couple of minutes, most of it spent pulling images.

Outgoing email, report retention, and IP lookups are set afterwards, on the
dashboard's Platform page.

Prefer to read before you run? The script is [install.sh](install.sh), and the
manual route is below.

### Manual install

```bash
git clone https://github.com/dmarcoapp/dmarcoapp.git dmarco
cd dmarco
cp .env.example .env
nano .env
```

Fill in the domains. Replace `generated` in `APP_SECRET`, `POSTGRES_PASSWORD`,
and `RABBITMQ_PASSWORD` with a long random string each, for example from
`openssl rand -hex 24`, and in `APP_ENCRYPTION_KEY` with the 64 characters of
`openssl rand -hex 32`. Now start everything:

```bash
docker compose up -d --wait
docker compose exec php bin/console lexik:jwt:generate-keypair --skip-if-exists
docker compose exec php bin/console app:user:create
```

`--wait` returns once every container reports healthy, which on the first run
means waiting for the database migrations. Sign in and add your mailbox on the
Platform page, under Report Intake.

## DNS records

The dashboard needs one record:

| Type | Name | Value |
| --- | --- | --- |
| `A` | `dmarc.example.com` | your server's IPv4 address |

The mail gateway needs more, see [Mail gateway](#mail-gateway).

## Point a domain at DMARCo

Put the address of the mailbox your reports go to in the domain's DMARC record:

```text
_dmarc.example.com.  TXT  "v=DMARC1; p=none; rua=mailto:dmarc@example.com"
```

Sign in and add a domain, and DMARCo shows this record with the addresses it
takes reports at: the report address of each mailbox, and the mail gateway's.

`p=none` only asks for reports and changes nothing about how your mail is
delivered. Providers send them once every 24 hours, so the first numbers appear
a day or two after the record goes live.

Once you can see who sends mail as you, and everything legitimate passes, you
can move the policy to `p=quarantine` and then `p=reject`.

### The `_report._dmarc` record

A domain may not send its DMARC reports to an address on someone else's domain
unless that domain agrees to it. With reports going to `dmarc@example.com`,
watching `example.net` needs this record on `example.com`:

| Type | Name | Value |
| --- | --- | --- |
| `TXT` | `example.net._report._dmarc.example.com` | `v=DMARC1` |

Without it, every provider that follows the spec, which is all the large ones,
quietly stops sending you reports for `example.net`. A wildcard,
`*._report._dmarc.example.com`, covers every domain at once. It also lets
strangers aim their reports at the mailbox, which costs a little wasted
processing and nothing else.

You need no record when the watched domain and the report address sit under
the same registered domain, such as watching `example.com` with reports going to
`dmarc@example.com` or to `dmarc.example.com`. For the same reason, the report
address has to be on a domain you can add records to: reports for your domains
cannot go to an address at a mail provider's domain.

## Report intake

Mailboxes, API keys, and the mail gateway's settings are on the dashboard's
Platform page, under Report Intake. Any of them can carry reports for any of
your domains, side by side.

### Mailboxes over IMAP

Add a mailbox with its server, username, and password, an app password where
the provider offers one. DMARCo stores the password encrypted with
`APP_ENCRYPTION_KEY` and never shows it again.

- It connects with TLS or STARTTLS only, and checks the server's certificate.
- It reads every 15 minutes by default. The first read goes back 30 days.
- It fetches messages without marking them read, and leaves every message
  without a report attached as it was.
- Once a report is stored, its email is marked read, moved to another folder,
  marked deleted, or left alone, as you choose. DMARCo never expunges.
- At most 100 messages per read, none over 10 MB, one report attachment each.
- After five failed reads in a row, the mailbox is tried hourly until a read
  works again.

The Test button signs in and lists the folders, and the log shows what each read
found and skipped. The same is available on the server:

```bash
docker compose exec php bin/console app:intake:mailbox:list
docker compose exec php bin/console app:intake:mailbox:test <name>
docker compose exec php bin/console app:intake:mailbox:poll <name>
```

### Upload endpoint

On the Platform page, under Report Intake, switch on the API and its upload
endpoint, create a key, and send each report file, as XML or the gzip or zip it
came in, up to 10 MB:

```bash
curl --fail -X POST \
  -H "Authorization: Bearer $DMARCO_API_KEY" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @report.xml.gz \
  https://dmarc.example.com/api/v1/intake/reports
```

The answer is `202` when the report is stored, `200` when it was stored before,
and `422` with the reason when the file is not a report. Each address may make
600 requests an hour. Only a hash of each key is kept, so a lost key is revoked
and replaced. While the API or the upload endpoint is off, it answers `404`.

### Mail gateway

The older way in, which is being retired. Postfix receives report email on port
`25` for a domain whose `MX` record points here, ClamAV scans each attachment,
and the reports are posted to the backend with a signed webhook. It needs port
`25` reaching the server, which many providers block until asked, and ClamAV
holds roughly 1.5 GB of memory.

The gateway runs only with `mail-gateway` in `COMPOSE_PROFILES`. To set it up
by hand, add to `.env`:

```bash
COMPOSE_PROFILES=mail-gateway
MAIL_GATEWAY_DOMAIN=dmarc.example.com
SMTP_HOSTNAME=dmarc.example.com
```

On the Platform page, under Report Intake, switch on the API and its webhook,
set the report domain to the same `MAIL_GATEWAY_DOMAIN`, and generate a webhook
secret. Put that secret where the gateway reads it, then start the
gateway:

```bash
mkdir -p secrets && chmod 700 secrets
printf '%s\n' '<the webhook secret>' > secrets/webhook_secret.txt
chmod 644 secrets/webhook_secret.txt
docker compose up -d
```

Docker mounts the file into the container keeping the owner and mode it has
here, and the gateway's processor runs as an unprivileged user that is not you,
so `0600` would lock it out. The `0700` directory is what keeps other users on
the host away from the file. The installer does all of this when you pick the
mail gateway.

The gateway needs these DNS records, with `MAIL_GATEWAY_DOMAIN` and
`SMTP_HOSTNAME` both `dmarc.example.com`:

| Type | Name | Value |
| --- | --- | --- |
| `MX` | `dmarc.example.com` | `10 dmarc.example.com.` |
| `TXT` | `*._report._dmarc.dmarc.example.com` | `v=DMARC1` |

Use a domain or subdomain that receives no other email. The gateway's `MX`
record replaces whatever was there, and it accepts DMARC reports only, so
anything else sent to `MAIL_GATEWAY_DOMAIN` is rejected. If `SMTP_HOSTNAME`
differs from `APP_DOMAIN`, it needs an `A` record as well.

To switch the gateway off, take `mail-gateway` out of `COMPOSE_PROFILES`, then
remove its containers, which Compose otherwise leaves running:

```bash
docker compose --profile mail-gateway rm --stop --force postfix processor clamav
```

Also remove the webhook secret on the Platform page.

#### Turning off virus scanning

`CLAMAV_SCAN_ENABLED=false` skips the scan but keeps the scanner running, and
ClamAV holds its signature database in memory either way. To drop the container
as well on a small server, create `compose.override.yaml` next to
`compose.yaml`:

```yaml
services:
  processor:
    depends_on: !reset null
  clamav:
    profiles: !override ["disabled"]
```

`!override` needs Docker Compose 2.24 or newer. Then set
`CLAMAV_SCAN_ENABLED=false` in `.env` and remove the `clamav` container as
above. Attachments are still size-checked, extension-checked, and
schema-validated, but no longer scanned for malware.

#### A publicly trusted certificate for the gateway

By default Postfix presents a self-signed certificate. Sending servers use
opportunistic TLS, so they accept it, and report email is not secret. If you
would rather serve a real certificate, and your DNS is on Cloudflare, put an
API token that can edit DNS records for `SMTP_HOSTNAME` in
`secrets/cloudflare_token.txt`, with the same modes as the webhook secret, then
set in `.env`:

```bash
COMPOSE_PROFILES=mail-gateway,letsencrypt
SMTP_TLS_MODE=real
```

Run `docker compose up -d` to apply it. With a certificate from elsewhere, set
`SMTP_TLS_MODE=external` and mount the chain file, which must hold the private
key followed by the full certificate chain, using a `compose.override.yaml`:

```yaml
services:
  postfix:
    volumes:
      - /etc/ssl/mx/chain.pem:/certs/smtp.pem:ro
```

Use `SMTP_TLS_CHAIN_FILE` in `.env` if you would rather mount it elsewhere.
Postfix reads the file at startup, so restart it after a renewal.

## Configuration

`.env` holds the infrastructure. Change a setting, then run `docker compose up
-d` to apply it.

| Setting | What it is |
| --- | --- |
| `APP_DOMAIN` | Domain the dashboard and API are served on |
| `ACME_EMAIL` | Address for your Let's Encrypt account |
| `CORS_ALLOW_ORIGIN` | Browser origins allowed to call the API, as a regular expression |
| `CADDY_SITE_SCHEME` | How Caddy listens, `http` when something else terminates TLS |
| `APP_ENCRYPTION_KEY` | Encrypts the passwords and secrets kept in the database |
| `COMPOSE_PROFILES` | `mail-gateway` to run the mail gateway |
| `MAIL_GATEWAY_DOMAIN`, `SMTP_HOSTNAME`, `SMTP_TLS_MODE`, `CLAMAV_SCAN_ENABLED` | The mail gateway's domain, hostname, certificate, and virus scanning |
| `BACKEND_VERSION`, `DASHBOARD_VERSION`, `MAIL_INBOUND_VERSION` | Image tags, pin these for reproducible upgrades |

Everything else is on the dashboard's Platform page and kept in the database:
report retention, IP lookups, outgoing email and its sender address, mailboxes,
the API switches, API keys, and the webhook's domain and secret. Outgoing email
is optional, and the page sends a test email to check it.

Keep `APP_ENCRYPTION_KEY` with your backups. Without it, the stored passwords
cannot be read, and each has to be entered again.

### Your account

DMARCo has no sign-up page. Accounts are made on the server, which is also
where you fix one:

```bash
docker compose exec php bin/console app:user:create              # create it
docker compose exec php bin/console app:user:reset-password      # forgot the password
docker compose exec php bin/console app:user:disable-two-factor  # lost the authenticator app
```

None of this needs outgoing mail. Two-factor authentication is off until you
turn it on in your profile, with any authenticator app.

### Behind a proxy or a tunnel

If something in front of DMARCo already terminates TLS, an existing nginx or
Traefik, a load balancer, or a tunnel such as Cloudflare's, then Caddy should
neither bind ports `80` and `443` nor ask for a certificate of its own.

In `.env`, tell Caddy to serve plain HTTP, and leave the address browsers use
alone:

```bash
CADDY_SITE_SCHEME=http
```

`APP_SCHEME` stays `https`, because that is what browsers reach. The backend is
told the same, so it keeps marking cookies secure.

Then bind Caddy to a local port instead of `80` and `443`, in a
`compose.override.yaml` next to `compose.yaml`:

```yaml
services:
  caddy:
    ports: !override
      - "127.0.0.1:8080:80"
```

`!override` replaces the published ports instead of adding to them, and needs
Docker Compose 2.24 or newer. Run `docker compose up -d` to apply it, then point
your proxy at `http://127.0.0.1:8080`. A proxy that runs in Docker itself can
skip the published port and join this stack's network instead, where the whole
application answers as `caddy:80`.

Caddy serves only the site that matches `APP_DOMAIN`, so the proxy has to pass
that name through. Traefik and most tunnels do so without being asked, while
nginx needs `proxy_set_header Host $host;`, because it otherwise sends the
address of the upstream.

With the mail gateway, port `25` still has to reach this server directly,
because no HTTP proxy or tunnel carries SMTP.

## Running it

```bash
cd dmarco

docker compose ps                 # what is running
docker compose logs -f            # follow everything
docker compose logs -f worker     # follow mailbox reading and report processing
docker compose restart php        # restart one part
docker compose down               # stop, keeping all data
```

### Upgrading

```bash
docker compose pull
docker compose up -d --remove-orphans
```

`--remove-orphans` stops the parts a newer recipe no longer has. Database
migrations run automatically on start. Pin the `*_VERSION` settings in `.env`
to release tags if you would rather decide when new versions land.

#### From 0.4 or earlier

From 0.5, outgoing email, report retention, IP lookups, the report domain, and
the webhook secret live in the database, the mail gateway runs only with the
`mail-gateway` profile, and DMARCo serves one account. Run the installer again
in the install directory and keep the existing `.env`:

```bash
cd dmarco
bash -c "$(curl -fsSL https://raw.githubusercontent.com/dmarcoapp/dmarcoapp/main/install.sh)"
```

Before the new version starts, it:

- Lets the previous version process the reports still queued for MinIO, on an
  install from 0.3 or earlier, then removes the MinIO settings and secrets
- Offers to raise `BACKEND_VERSION` and `DASHBOARD_VERSION` when they are
  pinned below 0.5
- Stops when the database holds more than one account, lists them, and prints
  the command that deletes one with the previous version

Then it saves the old `.env` next to it, adds `APP_ENCRYPTION_KEY`, keeps the
mail gateway on, starts the new version, and removes the lines whose settings
the database took over. `REPORT_DOMAIN` becomes `MAIL_GATEWAY_DOMAIN`, which the
gateway still reads. Delete the saved copy once everything works, because it
holds those settings, passwords among them. The installer can be run again at
any point, and does each step only once.

By hand, get the new `compose.yaml` and add to `.env`:

```bash
APP_ENCRYPTION_KEY=<the output of openssl rand -hex 32>
COMPOSE_PROFILES=mail-gateway
```

Then upgrade as above. The backend takes the settings over on its first start
with the key, and the Platform page lists the lines of `.env` that can go. Once
`REPORT_DOMAIN` is gone, set `MAIL_GATEWAY_DOMAIN` to its value. Until there is
a key, the backend keeps reading those lines, as 0.4 did, and offers no
mailboxes or API keys.

Up to 0.3, a report went to a MinIO object store first, and the message queued
for the backend only pointed at it, so those messages have to be processed
before the switch. By hand, stop the gateway and wait for the queue to empty:

```bash
docker compose stop postfix processor
docker compose exec rabbitmq rabbitmqctl list_queues name messages
```

Once `messages` shows `0`, continue as above. Mail that arrives in the meantime
is retried by the servers sending it. Afterwards, remove what MinIO left behind:

```bash
docker volume rm dmarco_minio_data
rm -f secrets/s3_access_key.txt secrets/s3_secret_key.txt
```

### Backups

Everything durable lives in Docker volumes. The database is the part you cannot
rebuild:

```bash
docker compose exec -T database pg_dump -U dmarco dmarco | gzip > dmarco-$(date +%F).sql.gz
```

Keep a copy of `.env` and `secrets/` with it, because restoring needs both, and
`APP_ENCRYPTION_KEY` in `.env` is what reads the passwords in the dump. To
restore into an empty stack:

```bash
docker compose up -d database
gunzip -c dmarco-2026-01-31.sql.gz | docker compose exec -T database psql -U dmarco dmarco
docker compose up -d
```

## Troubleshooting

**No reports arrive from a mailbox.** Open the mailbox on the Platform page and
press Test, then look at its log. A sign-in that fails names the reason, and the
log names every message that was skipped and why. If reports arrive for some
domains only, check [the `_report._dmarc` record](#the-_report_dmarc-record) on
the report address's domain:

```bash
dig +short TXT '*._report._dmarc.example.com'
```

It should print `"v=DMARC1"`.

**No reports arrive at the mail gateway.** Check the authorization record as
above, on `MAIL_GATEWAY_DOMAIN`. Then check that port `25` reaches the server,
from another machine: `nc -vz dmarc.example.com 25`. Providers often block it by
default. Finally look at `docker compose logs postfix processor`.

**The gateway's reports stopped after a configuration change.** When the
backend refuses report email for a reason that waiting cannot fix, such as a
webhook secret that differs between the Platform page and
`secrets/webhook_secret.txt`, the processor keeps each refused report instead
of dropping it. So does a report that still fails after about five days of
retries, which is what happens while the webhook is switched off. `docker
compose logs processor` names the cause. Fix it, then send the kept reports
through again:

```bash
docker compose exec processor npm run replay-dead-letter
```

**No notification emails arrive.** DMARCo sends mail only when outgoing email
is set up on the Platform page. Send a test email from there, which shows the
mail server's answer, and look for errors with `docker compose logs worker`.

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
- [`dmarcoapp/backend`](https://github.com/dmarcoapp/backend): API, workers, mailbox reading, and report processing
- [`dmarcoapp/mail-inbound`](https://github.com/dmarcoapp/mail-inbound): the mail gateway, being retired

## License

Licensed under the Apache License, Version 2.0. See [`LICENSE`](LICENSE) and
[`NOTICE`](NOTICE).
