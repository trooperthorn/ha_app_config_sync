#!/usr/bin/env python3
"""Validate the shipped version for this app.

Reads `.release.json` (see release_config.py). `validate_versions` is the
independent reader the release gate relies on; the writer is
set_version.py. This repository has no zip archive to build: apps are not
distributed through HACS, and Supervisor builds this app's image from the
tagged source tree when the repository is added, so there is nothing to
attach to the GitHub Release beyond the tag itself (see release.yml).

Usage:
    python scripts/build_release_artifacts.py --validate-only
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parent))

from release_config import load, validate_versions  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--validate-only", action="store_true", help="print the version and exit")
    args = parser.parse_args()
    config = load(args.repository)
    if not args.validate_only:
        parser.error("this repository ships from the tagged tree; only --validate-only is supported")
    print(validate_versions(config))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
