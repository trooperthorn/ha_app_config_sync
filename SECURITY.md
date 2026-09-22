# Security Policy

## Reporting a vulnerability

Do not open a public issue containing exploit details, credentials, private
addresses, or logs. Use GitHub's private vulnerability-reporting feature for
this repository (Security, then Report a vulnerability). Include the app
version from `config_sync/config.yaml`, the Home Assistant version, and the
steps that reproduce the problem.

## What is in scope

The app's own configuration and scripts: `config_sync/config.yaml`,
`config_sync/Dockerfile`, `config_sync/apparmor.txt`, everything under
`config_sync/rootfs/`, and the CI workflows. A weakness in git, OpenSSH, or
the Home Assistant base image belongs upstream; this repository tracks the
base image and rebuilds against it.

The default exclude list is a control in scope: a path that reaches the
repository and should not have is a bug here.

## Supported versions

The latest release only. The version is calendar-based (`YYYY.MM.DD.N`) and
the tag is the version with a `v` prefix.
