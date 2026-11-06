# Security policy

## Reporting a vulnerability

Please **do not open a public issue** for security problems. Report them privately using
GitHub's private vulnerability reporting (enabled on this repository): go to the repository's **Security** tab and choose
**Report a vulnerability** (a private security advisory). Include:

- what the problem is and which component it affects,
- steps or a script to reproduce it, plus the Godot version and OS,
- the impact you think it has.

You will get an answer as soon as the maintainer can, and we will work with you on a fix and
on coordinated disclosure. Eldmark is a young project maintained by volunteers, so there is
no guaranteed response time and no bug bounty.

## Scope

In scope:

- **Zone server** (`scripts/server/`, and `scripts/shared/` as run by the headless server):
  anything a malicious client can do to bypass server authority, such as speed or position
  cheating, forged hits or abilities, crashes or resource exhaustion from malformed packets,
  and weaknesses in the DTLS or authentication handshake.
- **Platform service** (`platform/`, written in Go): accounts, sessions, authentication,
  authorization, SQL injection, secrets handling and the zone-to-platform channel.
- **Client** (`scripts/client/`): issues that let a server or another player harm the
  player's machine or leak their data.

Out of scope: vulnerabilities in Godot Engine itself or in third-party addons (report them
upstream), denial of service by raw network flooding, and social engineering.

## Test keys and development passwords

The private keys in `tests/fixtures/dtls/` and the fixed passwords in `platform/deploy/dev.sh`
exist only for automated tests and local development. They are not secrets. Never reuse them
in a real deployment.
