# Config Sync (Forgejo) for Home Assistant

A Home Assistant app repository with one app: two-way git synchronization
of the configuration directory with a Forgejo (or any git) repository,
running on the Home Assistant host.

It replaces a workstation-side pipeline (a scheduled task that pushed a
repository's copy of the dashboards over SSH, and a second task that
captured the host's configuration into the same repository). That pair
formed a loop: each capture commit moved the branch, the deploy task saw
the branch move and re-pushed the dashboards, and any edit made on the
host was reverted within the hour. Here there is one repository, one
process, and both directions are the same merge.

## Adding this repository

In Home Assistant, go to Settings, then Apps (App store), then the
three-dot menu, then Repositories, and add:

```
https://github.com/trooperthorn/ha_app_config_sync
```

Then install "Config Sync (Forgejo)" from the Local apps section and follow
the setup in [config_sync/DOCS.md](config_sync/DOCS.md).

## How it works

| Direction | Mechanism |
| --- | --- |
| Host to repository | Every interval, everything under `/config` that changed is committed (excluded paths and credential-looking files left out) and pushed. |
| Repository to host | The remote branch is fetched and merged into `/config`. Same-line conflicts resolve to `conflict_winner` (repository by default). |
| Excluded paths | gitignore patterns; never committed, never written by a pull. Defaults cover credentials, caches, databases, logs, media, and HACS-managed trees. |
| Git directory | In the app's `/data`, not in `/config`; no `.git` in the configuration or backups. |
| Transport | SSH with a deploy key generated on first start and a host key pinned on first use, or HTTPS with a token and an optional private CA. |
| Reload | Optional `homeassistant.reload_all` after a pull that changed files. |

## Privileges

`homeassistant_config` mapped read-write (it is the work tree),
`addon_config` for operator-supplied key and certificate files,
`homeassistant_api` for the optional reload call. No ingress, no ports, no
host network, no Supervisor API, no privileged capabilities, custom
AppArmor profile. See [docs/security.md](docs/security.md).

## Verification status

The behavioural smoke test in `scripts/smoke_test.sh` runs the engine
against a local bare repository and proves the documented behaviour
(first import, pull, push, exclusions, secret scan, conflict policy,
rename, git directory placement). The AppArmor profile and the Supervisor
mounts have not yet been exercised on a live installation; see
[docs/decisions.md](docs/decisions.md).

## Repository layout

- `config_sync/`: the app (config.yaml, Dockerfile, DOCS.md, CHANGELOG.md, apparmor.txt, translations, rootfs).
- `scripts/`: release version scripts shared with the other trooperthorn apps, and the smoke test.
- `docs/`: decisions, operations, security.
- `.github/workflows/`: Test, Validate, Security, Release, Prepare release.

## License

MIT.
