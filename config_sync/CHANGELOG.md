# Changelog

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
