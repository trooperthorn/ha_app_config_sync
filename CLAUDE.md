# ha_app_config_sync

Home Assistant app: two-way git sync of `/config` with a Forgejo repository,
running on the host. Rationale for every behaviour is in `docs/decisions.md`
(append-only, read it before assuming something is arbitrary) and
`docs/security.md`. User-facing changes go in `config_sync/CHANGELOG.md`
under a version heading. `config_sync/config.yaml` `version` and the s6 run
script's `APP_VERSION` must always match (`.release.json` lists both; the
Validate workflow enforces it). Bump both on every release-worthy change.

## Shape

- `config_sync/rootfs/usr/local/bin/config_sync.sh` is the engine: pure
  bash, everything from the environment, `once` or `loop`. The s6 run
  script only reads options and execs it. The smoke test runs the same
  binary with a local bare repository as the remote.
- Git directory in `/data/repo.git`, work tree `/homeassistant`
  (the `homeassistant_config` map with an explicit `path`). Excludes go
  to `info/exclude`, never into the configuration directory.
- Conflicts: `git merge -X theirs|ours` by `conflict_winner`; tree-level
  conflicts abort and report.

## Status as of 2026-09-22 (v2026.09.22.2), live

Installed on the owner's Home Assistant OS instance the same day it was
built and running since 16:30 UTC: first import pushed 190 files,
subsequent cycles commit and push host changes, the AppArmor profile and
both maps work on a live Supervisor (the 2026.09.22.1 note that they
were unverified is superseded). Interval on the live install is 60
minutes. Both Windows tasks of the previous workstation pipeline
(`ha-config-deploy`, `ha-config-capture`) are disabled.

The pull direction (repository edit written into `/config`) is proven by
the smoke test only. The owner does not edit in Forgejo: dashboards are
edited in Home Assistant through the `ha_int_dashboard_editor`
integration, which writes the YAML dashboard files on the host, and this
app commits those writes. That round-trip was seen working live on
2026-09-22 (cards moved between `dashboards/overview.yaml` and a shared
`!include` fragment, pushed in the next cycle).

Findings from the live install, each recorded in `docs/decisions.md` or
`docs/operations.md`:

- The first live cycle ran before the deploy key was in Forgejo. The
  first-run check treated the auth failure as "branch does not exist";
  fixed in 2026.09.22.2, with smoke scenarios 9 and 10.
- The deploy key belongs under the repository's Settings > Deploy keys
  (write access ticked), not the user's SSH keys page, which would grant
  the key every repository the user owns.
- The Supervisor does not notice a new release until it re-reads the app
  repository; `ha store reload` (or "Check for updates") makes the update
  appear immediately.
- The Advanced SSH & Web Terminal add-on cannot see the Supervisor's app
  data directory, so `/data/repo.git` and `status.json` are not
  inspectable over SSH; Forgejo's commit view is the way to see what was
  pushed.

Open items: the release-automation App private key is not set on this
repository (the Prepare release workflow will fail its credential check
until it is); the Forgejo mirror list in `~/workspace/forgejo-mirror`
does not include this repository yet.

## House rules

No em dashes, no attribution footers, no model names in committed files.
Complete sentences; say why. Label unverified things as unverified.
