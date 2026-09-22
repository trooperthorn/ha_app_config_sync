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

## Status as of 2026-09-22 (v2026.09.22.1)

Built to replace the `ha-config-deploy` workstation tasks (see that
repository's README for the loop they formed). Smoke test passes locally
in WSL Docker. Not yet installed on a live Supervisor: AppArmor profile,
the two maps, and the first import against the real `/config` are
unverified. First-run plan and the Forgejo repository steps are in
`config_sync/DOCS.md`.

## House rules

No em dashes, no attribution footers, no model names in committed files.
Complete sentences; say why. Label unverified things as unverified.
