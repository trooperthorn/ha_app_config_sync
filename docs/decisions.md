# Decisions

Append-only. Each entry says what was decided, why, and what it cost.

## 2026-09-22: sync runs on the Home Assistant host, not on a workstation

The previous arrangement was two Windows scheduled tasks in
`trooperthorn/ha-config-deploy`: one captured `/config` over SSH into the
repository hourly, the other polled the repository every ten minutes and
pushed its copy of the dashboards and packages back over SSH whenever the
branch moved. Every capture commit moved the branch, so every hour the
deploy task rewrote the dashboards from the repository copy, reverting any
edit made on the host, while the capture task's exclude list made sure
those same paths were never captured. The pipeline depended on a
workstation being on, a stored password, an inbound SSH add-on, and two
scripts agreeing about which paths belonged to whom.

Here one process on the host owns both directions with one merge. No
inbound access to the host is needed, and the host being the work tree
means there is no second copy to disagree with.

## 2026-09-22: git directory outside the configuration directory

`git --git-dir=/data/repo.git --work-tree=/homeassistant`. A `.git` inside
`/config` would be included in every Home Assistant backup (the object
store can be hundreds of megabytes), would be visible to every app that
maps the configuration directory, and would make `/config` look like a
checkout to any tool that walks up looking for one. The exclude list lives
in the git directory's `info/exclude` for the same reason: nothing of the
sync's own appears in the configuration.

Cost: `/data/repo.git` is excluded from backups (`backup_exclude`) and is
rebuilt from the remote on a fresh install.

## 2026-09-22: on first run against a non-empty remote, the host wins

The remote's history is adopted (`update-ref` to the remote branch, index
reset to it, work tree untouched) and the host's current files become the
next commit. This never overwrites a file on the host during the import.
Paths present in the repository but absent on the host are removed in
that commit; they remain in history. The alternative, checking the remote
out over the host, is exactly the overwrite this app exists to stop.

## 2026-09-22: conflicts resolve by option, tree conflicts abort

`git merge -X theirs` (repository wins) or `-X ours` (host wins) resolves
same-line conflicts without leaving conflict markers in a file Home
Assistant is about to parse. Non-overlapping changes merge cleanly either
way. A tree-level conflict (file versus directory, both sides changed a
binary) cannot be resolved by a rule that keeps both YAML files valid, so
the merge is aborted, reported in the log and `status.json`, and retried
next cycle; the host's own commits still push in that cycle.

The default is `remote`: the repository is where deliberate edits are
made, and a registry file Home Assistant rewrote a moment ago will be
rewritten again by Home Assistant if the merge takes the remote's version.

## 2026-09-22: excluded paths are excluded in both directions

gitignore patterns in `info/exclude` keep a path out of `git add -A`.
That alone is one-way: git writes every tracked path on merge whatever
the ignore rules say, and the first version of the smoke test proved it
(a `secrets.yaml` added on the repository side replaced the host's). The
fix is a non-cone sparse checkout built from the same patterns
(`/*` followed by each exclude negated) in `info/sparse-checkout`. Paths
matching an exclude are marked skip-worktree: a merge neither writes nor
deletes them, and `git add -A` does not stage them, so the host's copy of
an excluded path is untouched in both directions. The smoke test asserts
both halves. The operations document says what to do when a path was
tracked before it was excluded, because the sparse rules only take effect
on paths a later merge touches.

## 2026-09-22: secret scan withholds, never deletes

A heuristic scan of staged text files (private key blocks, credential-named
keys with a literal value of at least twelve characters that is not a
`!secret` reference or a template) resets the file out of the index and
names it in the log. The file stays on the host untouched and stays out
of every commit until it is excluded or fixed. Deleting or rewriting a
file in `/config` on a heuristic would be worse than the leak it guards
against.

## 2026-09-22: SSH deploy key generated in the container, host key pinned on first use

Generating the ed25519 key inside `/data` means the private key never
travels: the operator copies the public key into Forgejo's deploy keys.
The host key is fetched with `ssh-keyscan` once, written to
`/data/ssh/known_hosts`, and every later connection is strict. The
fingerprint is logged as a warning so it is seen. An operator who wants no
trust-on-first-use places a `known_hosts` file in the app's config
directory and names it. Both files can be supplied instead of generated.

## 2026-09-22: `homeassistant_api` for one call, no `hassio_api`

`reload_after_pull: reload_all` posts to
`http://supervisor/core/api/services/homeassistant/reload_all` with the
Supervisor token the app already receives. That is the only use of the
token. The Supervisor API itself is not requested: restarting Core after a
pull is a decision the operator should make, not something a merge should
trigger.

## 2026-09-22: engine and s6 wrapper are separate programs

The s6 run script reads the options with bashio and execs the engine with
everything in the environment. The engine is what the smoke test runs, with
a local bare repository as the remote, so CI exercises the same code path
as production without a Supervisor.

## 2026-09-22: AppArmor profile enumerated, enforced, unverified

The profile follows the shape the HA SOC Terminal profile settled on after
three live failures (boot chain with `r` and `ix`, directory listings
everywhere, no capabilities). Writes are limited to `/homeassistant`,
`/data`, `/tmp` and s6's runtime directories. It has not been loaded on a
live Supervisor yet; the CI smoke test cannot attach a profile.
