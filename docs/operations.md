# Operations

## First start

1. Set `remote_url` and start the app. With an empty `remote_url` it stays
   up doing nothing and says so in the log.
2. Read the log: the generated public key (add it to the repository's
   deploy keys with write access) and the pinned host key fingerprint
   (verify it against the server).
3. Restart the app. The first cycle imports and pushes.

## Registering the deploy key

The key goes under the repository's own Settings > Deploy keys, with
"Enable write access" ticked. Forgejo also has a user-level SSH keys page
under the avatar menu; a key placed there authenticates as that user with
access to every repository they can reach, which is more than this app
needs.

## Getting a new release onto the host

The Supervisor re-reads app repositories on its own schedule, so a fresh
release is not offered right away. On the host, `ha store reload` (or
"Check for updates" in the App store) makes it appear; then update as
usual. The app restarts on update and runs a cycle immediately.

## Forcing a cycle

Restart the app. The s6 run script logs "exited with code 256" for the
stop; that is the restart, not a failure.

## Reading the state

`/data/status.json` in the app's data directory (visible through a
terminal app that maps app data, or the Supervisor's file tooling; the
Advanced SSH & Web Terminal add-on does not see app data directories):

```json
{"state": "ok", "time": "...", "head": "abc1234", "remote": "...", "branch": "main",
 "last_error": "", "pulled_files_last_cycle": 0, "pushed_commits_last_cycle": 1,
 "app_version": "2026.09.22.1"}
```

`state` is `running`, `ok`, or `error`; `last_error` carries git's own
message. `log_level: debug` lists every file a merge wrote.

## A path was tracked and is now excluded

Adding a pattern to `exclude` stops new changes to that path from being
committed, but the path stays tracked and a merge can still write it. To
stop tracking it, commit its removal from the repository side:

```bash
git rm --cached path/to/file
git commit -m "stop tracking path/to/file"
git push
```

The next cycle merges that removal; because the path is excluded, the
engine's `git add -A` will not re-add the host's copy, and the host's copy
stays on disk.

## Merge could not be completed

The log and `status.json` name the paths. Resolve in the repository
(rename, delete, or pick one version), push, and the next cycle merges
cleanly. The host's own commits keep pushing meanwhile.

## Re-pinning the host key

Delete `/data/ssh/known_hosts` and restart. The new fingerprint is logged.

## Rotating the deploy key

Delete `/data/ssh/id_ed25519` and `id_ed25519.pub`, restart, add the new
public key in Forgejo, remove the old one.

## Moving to a different remote or branch

Change the option and restart. The git directory keeps its history; the
next cycle fetches the new branch and merges as usual (first-run rules
apply if the local branch has no commits yet).

## Rebuilding the git directory

Stop the app, delete `/data/repo.git`, start. The next cycle adopts the
remote history and commits the host's current state on top of it (see
"first run" in DOCS.md). Nothing on the host is touched by this.

## AppArmor denials

Settings > System > Logs > Host, filter for `DENIED` and `config_sync`. A
denial names the path and the operation; add it to `apparmor.txt` and
release.

## Release process

Merge to `main`. The Release workflow validates the version lockstep
(`config.yaml` and the run script's `APP_VERSION`, both listed in
`.release.json`), tags, and publishes a GitHub Release. The Prepare release
workflow then opens a CalVer bump PR when `main` carries unpublished
changes under `config_sync/`. Supervisor builds the image from the tagged
tree when the repository is added; there is no registry image.
