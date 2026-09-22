# Changelog

## 2026.09.22.1

First release. Two-way git synchronization of the configuration directory
with a remote repository, running on the Home Assistant host: host changes
are committed and pushed every interval, remote changes are merged into the
configuration directory, conflicts resolve to the configured side, excluded
paths never cross in either direction, a heuristic secret scan keeps
credential-looking files out of commits, SSH deploy key generated on first
start, host key pinned on first use, optional homeassistant.reload_all
after a pull.
