# Changelog

## 2026.10.10.1

Excluding a path the repository already tracked could delete it from the
host. On a live install, `ha_soc/crash-*/` and `ha_soc/heartbeat.json` were
added to `exclude` while tracked, and a workstation commit untracked them.
The next merge was refused (the heartbeat had changed on the host and the
repository deleted it), and the failure path's `git reset --merge` applied
the new sparse checkout and removed the tracked crash dumps from disk.

Now every cycle marks tracked files that match `exclude` skip-worktree
before anything else runs, takes the repository's deletion of such a file
as a local untrack before merging (so the merge cannot unlink it), aborts
only a merge that actually started, and sets
`sparse.expectFilesOutsideOfPatterns` so git keeps those marks. Excluded
paths the repository still has keep their repository copy, as before.
Smoke test scenario 12 replays the live sequence and fails on 2026.09.29.1.

## 2026.09.29.1

After a host migration `/data/repo.git` came back as a directory git did
not recognise, and every cycle failed with "first run: could not read
origin/main: fatal: not a git repository". The engine only created the
git directory when the path was missing, so it never recovered. Now a git
directory that is not a repository is moved aside to
`repo.git.invalid-<UTC time>` (kept, not deleted) and rebuilt; the
first-run path then adopts the remote's history and commits the host's
files on top. Smoke test scenario 11 covers it.

## 2026.09.22.2

First live run showed the first-run check treating an authentication
failure as "remote branch does not exist" and making a root commit
anyway. Now a fetch failure other than a missing branch stops the cycle
with the error (nothing is committed until the remote is readable), and
a merge between two histories with no common commit proceeds under the
conflict policy instead of failing. Smoke test covers both.

## 2026.09.22.1

First release. Two-way git synchronization of the configuration directory
with a remote repository, running on the Home Assistant host: host changes
are committed and pushed every interval, remote changes are merged into the
configuration directory, conflicts resolve to the configured side, excluded
paths never cross in either direction, a heuristic secret scan keeps
credential-looking files out of commits, SSH deploy key generated on first
start, host key pinned on first use, optional homeassistant.reload_all
after a pull.
