# Security

## Trust boundaries

| Boundary | What crosses it | Control |
| --- | --- | --- |
| App to remote repository | git objects over SSH or HTTPS | Deploy key scoped to one repository; host key pinned; token never on disk (askpass from environment); private CA supplied by the operator, not disabled verification |
| Remote repository to `/config` | Files written by merge | Exclude list; same-line conflicts by explicit policy; tree conflicts abort; nothing executed from the repository |
| `/config` to remote repository | Files committed | Exclude list (credentials, auth stores, config entries, keys); heuristic secret scan withholds credential-looking files |
| App to Home Assistant Core | One service call, `homeassistant.reload_all`, only when `reload_after_pull` is set and a pull changed files | Supervisor token, no `hassio_api` |
| Operator files | SSH key, known_hosts, CA certificate | Read from the app's own config directory; copied to mode 0600 in `/data` |

## What the repository can do to the host

Anything a file in `/config` can do. A malicious commit to the repository
becomes a malicious `configuration.yaml`, automation, or shell_command
within one interval. The deploy key is write-scoped to the repository, so
protecting the repository (who can push, branch protection on the synced
branch) is the control. This app does not sign or verify commits; that is
a documented gap.

## What the host can leak to the repository

Anything under `/config` not on the exclude list. The defaults cover the
paths known to hold credentials on a Home Assistant OS install as of
2026-09 (see `config.yaml`); a new integration that stores a token in an
unlisted `.storage/` file will be committed unless the secret scan catches
it. Review the first import in Forgejo before sharing the repository, and
keep the repository private.

## Container

Runs as root inside the container (the base image's s6 requires it, and
`/config` is root-owned on the host). No `full_access`, no `privileged`,
no `host_network`, no ports, no ingress, no `docker_api`, no `hassio_api`.
`map` is the configuration directory read-write and the app's own config
directory. Custom AppArmor profile: no capabilities, TCP and UDP only,
writes limited to the work tree, `/data`, `/tmp`, and s6's runtime
directories. Every BusyBox network applet other than what git and ssh need
is removed from the PATH and CI asserts they stay absent.

## Security rating

Expected Supervisor rating: base 5, +1 for the AppArmor profile, -1 for
`homeassistant_api`, no other adjustments in the documented table. Not
verified on a live installation.

## Out of scope

Vulnerabilities in git, OpenSSH, or the Alpine base image (tracked by the
weekly image scan and Dependabot's base image bumps). Forgejo's own access
control.
