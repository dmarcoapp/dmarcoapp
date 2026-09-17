# Contributing

Thanks for wanting to help. DMARCo is small, so the process is short.

## Where things live

This repository holds the installer, the Compose stack, and the user-facing
documentation. The application itself is developed in three repositories:

- [`dmarcoapp/backend`](https://github.com/dmarcoapp/backend): API, workers,
  report processing
- [`dmarcoapp/dashboard`](https://github.com/dmarcoapp/dashboard): web UI
- [`dmarcoapp/mail-inbound`](https://github.com/dmarcoapp/mail-inbound):
  inbound mail gateway

Open the pull request against the repository that holds the code you are
changing. **Issues, however, all belong here**, in
[`dmarcoapp/dmarcoapp`](https://github.com/dmarcoapp/dmarcoapp/issues), so
nobody has to guess which component a problem comes from.

## Before you start

For anything larger than a fix, open an issue first and describe what you have
in mind. It is a small project; a short conversation saves a large rewrite.

## Pull requests

- Branch from `main`, keep the change focused, and describe what it does and why.
- Follow the conventions already in the file you are editing. Each repository
  has an `AGENTS.md` with its coding standards.
- Run the checks that repository's CI runs before you push:
  - backend: `vendor/bin/phpunit`, `vendor/bin/php-cs-fixer fix --dry-run
    --diff`, `bin/console cache:warmup && vendor/bin/psalm`
  - dashboard: `npm run lint`, `npm run build`
  - mail-inbound: `npm run lint`, `npm test`, `npm run coverage`
  - this repository: `docker compose config --quiet`, `shellcheck install.sh`
- Update the documentation in the same pull request when behavior changes.
- New configuration must reach the installed stack: add it to `.env.example`,
  `compose.yaml`, and the README table here as well.

## Commits

Write commit subjects in the imperative mood, explaining the change rather than
the file that moved: `Reject reports larger than the configured limit`, not
`update processor.js`.

## License

By contributing you agree that your contribution is licensed under the Apache
License 2.0, the same license as the project.
