# Security Policy

This repository is a **generic, public infrastructure template** for installing
OpenShift on Azure (UPI) with optional Multus secondary networking. It contains
**no live credentials, secrets, or customer data** — those are supplied locally
by each operator and are kept out of git by `.gitignore` and
`scripts/sanitize-check.sh`.

## Reporting a vulnerability

If you discover a security issue in this repository — for example a script that
could leak credentials, an insecure default, or sensitive data accidentally
committed — please report it privately:

- Preferred: open a **private security advisory** via the repository's
  **Security → Report a vulnerability** tab on GitHub.
- Do **not** open a public issue for anything that could expose secrets or
  identifiers.

Please include the affected file/line, a description of the impact, and steps to
reproduce. We aim to acknowledge reports promptly and will coordinate a fix and
disclosure timeline with you.

## Handling secrets in this repo

- Never commit real credentials, kubeconfigs, pull secrets, SSH/TLS private
  keys, Terraform state, or tenant identifiers (subscription/tenant IDs,
  internal IPs, resource-group names, UPNs/emails).
- Before pushing, run `bash scripts/sanitize-check.sh`. Configure your own
  lab/tenant identifiers in a gitignored `.sanitize-patterns.local`
  (see `.sanitize-patterns.example`).
- All credential material produced by an install belongs in the gitignored
  `secrets/` directory (see `docs/credential-backup.md`).
