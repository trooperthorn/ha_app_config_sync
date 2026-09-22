# Config Sync (Forgejo)

Keeps the Home Assistant configuration directory and a git repository the
same, in both directions, from the Home Assistant host itself.

Every `interval_minutes`:

1. Whatever changed in `/config` (dashboards edited in the UI, registries
   Home Assistant rewrote, a file you edited with the File editor) is
   committed, except excluded paths and files the secret scan flags.
2. The remote branch is fetched and merged into `/config`. Where the same
   lines changed on both sides, `conflict_winner` decides. Changes to
   different files or different lines merge without loss.
3. The result is pushed.

The git directory lives in the app's `/data`, not inside `/config`, so no
`.git` folder appears in your configuration or your backups.

## Setup with Forgejo

1. In Forgejo, create an empty repository (no README) under the organization
   you want, for example `SecretSquirrel/ha-config`. A pull mirror cannot be
   pushed to; it must be an ordinary repository.
2. Install and start this app with `remote_url` set to the SSH clone URL of
   that repository using Forgejo's built-in SSH port, for example
   `ssh://git@truenas.example:30143/SecretSquirrel/ha-config.git`.
3. Read the app log. The first start prints a generated public key. In
   Forgejo, open the repository, Settings, Deploy keys, add it, and tick
   "Enable write access".
4. The log also prints the fingerprint of the SSH host key it pinned on
   first contact. Compare it with the server's (on Forgejo,
   `ssh-keygen -lf` on the host key file, or the fingerprint the Forgejo
   admin page shows). To pin it in advance instead, place a `known_hosts`
   file in `/addon_configs/<slug>/` and name it in `ssh_known_hosts_file`.
5. Restart the app. The first cycle imports the whole configuration and
   pushes it. From then on, edit in either place.

For an https URL, set `https_token` to a Forgejo access token with write
access, and for a private CA put the CA certificate (PEM) in
`/addon_configs/<slug>/` and name it in `ca_certificate_file`.

## Editing in the repository

Change a file in Forgejo's web editor or push from a clone. Within one
interval it is written into `/config`. YAML-mode dashboards reload on the
next open of that dashboard (Home Assistant checks the top-level dashboard
file's modification time, so a change in an included file needs the
including file touched too). Packages, automations, scripts and templates
need a YAML reload: set `reload_after_pull` to `reload_all` to have the
app request it, or reload by hand. Changes to `configuration.yaml`'s
integrations and to the `dashboards:` list in `lovelace.yaml` need a
restart of Home Assistant Core.

## Editing in Home Assistant

Dashboards in storage mode, helpers, areas, the entity registry: Home
Assistant writes them under `.storage/`, and they are committed on the next
cycle like any other file. Nothing needs to be done.

## What is excluded

The default `exclude` list keeps out credentials (`secrets.yaml`, auth
stores, cloud tokens, integration config entries, private keys), caches
and state (`core.restore_state`, traces, databases, logs), media, and trees
another tool owns (`custom_components/` and `www/community/` belong to
HACS). Add to it freely; remove from it only after checking what the path
contains. Excluded paths are never written by a pull either, so an excluded
path that exists in the repository stays as it is on the host.

## First run against a repository that already has content

The host's files win. The remote history is adopted and the host's current
state becomes the next commit on top of it, so nothing on the host is
overwritten by the import. Paths present in the repository but not on the
host are removed in that commit (they remain in history).

## Status

`/data/status.json` (visible through the Supervisor's file tooling or a
terminal app) records the state of the last cycle: `ok`, `error` with the
message, the current commit, and how many files the last pull wrote and
the last push sent.

## Limits

- Merges are file-content merges. A file replaced by a directory, or a
  binary file changed on both sides, stops the cycle with an error until it
  is resolved in the repository.
- The secret scan is a heuristic (private key blocks, credential-named keys
  with a literal value). It is a safety net for the exclude list, not a
  replacement for it.
- The host key pinned on first use is only as trustworthy as the network at
  that moment; verify the logged fingerprint.
