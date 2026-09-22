#!/usr/bin/env bash
# Behavioural smoke test for the built image: runs the sync engine against
# a local bare repository standing in for Forgejo and proves the documented
# behaviour, in this order:
#
#   1. first run: the host's files are committed and pushed;
#   2. a change made in the repository is written to the host;
#   3. a change made on the host is pushed to the repository;
#   4. an excluded path never crosses in either direction;
#   5. a secret-looking file is left out of the commit;
#   6. a same-line conflict resolves to conflict_winner;
#   7. the repository's rename of a file removes the old name on the host;
#   8. no .git directory appears in the configuration directory.
#
#   scripts/smoke_test.sh <image-tag>
set -euo pipefail

IMAGE="${1:?image tag}"
WORK="$(mktemp -d)"
HOST="${WORK}/homeassistant"
DATA="${WORK}/data"
ADDON_CONFIG="${WORK}/addon_config"
REMOTE="${WORK}/remote.git"
CLONE="${WORK}/clone"
mkdir -p "${HOST}" "${DATA}" "${ADDON_CONFIG}"

cleanup() { [ "${KEEP:-0}" = 1 ] || rm -rf "${WORK}"; }
trap cleanup EXIT
fail() { echo "::error::$1"; exit 1; }
ok() { echo "  ok: $1"; }

git init -q --bare -b main "${REMOTE}"
git clone -q "${REMOTE}" "${CLONE}" 2>/dev/null
git -C "${CLONE}" config user.name tester
git -C "${CLONE}" config user.email tester@example.invalid

# The engine, once, with the same environment the s6 run script sets. It
# runs as the calling user so the files it writes into the bind mounts stay
# editable by this script; on a Supervisor it runs as root, like /config.
sync() {
    docker run --rm --user "$(id -u):$(id -g)" \
        -v "${HOST}:/homeassistant" -v "${DATA}:/data" -v "${ADDON_CONFIG}:/addon_config" -v "${REMOTE}:/remote.git" \
        -e SYNC_REMOTE_URL=/remote.git -e SYNC_BRANCH=main -e SYNC_CONFLICT_WINNER="${1:-remote}" \
        -e SYNC_SECRET_SCAN=true -e SYNC_LOG_LEVEL=debug -e SYNC_EXCLUDE_FILE=/data/exclude \
        --entrypoint /usr/local/bin/config_sync.sh "${IMAGE}" once
}

cat > "${DATA}/exclude" <<'XEOF'
secrets.yaml
*.db
.storage/core.restore_state
XEOF

echo "== 1. first run commits and pushes the host"
printf 'homeassistant:\n  name: Smoke\n' > "${HOST}/configuration.yaml"
mkdir -p "${HOST}/dashboards" "${HOST}/.storage"
printf 'title: Overview\nviews: []\n' > "${HOST}/dashboards/overview.yaml"
printf 'db_password: "hunter2hunter2hunter2"\n' > "${HOST}/secrets.yaml"
printf 'binary' > "${HOST}/home-assistant_v2.db"
sync
git -C "${CLONE}" pull -q origin main
[ -f "${CLONE}/configuration.yaml" ] || fail "configuration.yaml was not pushed"
[ -f "${CLONE}/dashboards/overview.yaml" ] || fail "dashboards/overview.yaml was not pushed"
[ ! -e "${CLONE}/secrets.yaml" ] || fail "secrets.yaml crossed to the repository"
[ ! -e "${CLONE}/home-assistant_v2.db" ] || fail "the database crossed to the repository"
ok "host committed, excludes held"

echo "== 2. repository change lands on the host"
printf 'title: Overview\nviews:\n  - title: Home\n' > "${CLONE}/dashboards/overview.yaml"
git -C "${CLONE}" add -A && git -C "${CLONE}" commit -q -m "edit in forgejo" && git -C "${CLONE}" push -q origin main
sync
grep -q 'title: Home' "${HOST}/dashboards/overview.yaml" || fail "repository edit did not reach the host"
grep -q '"state": *"ok"' "${DATA}/status.json" || fail "status.json is not ok: $(cat "${DATA}/status.json")"
ok "pull works"

echo "== 3. host change lands in the repository"
printf '{"version": 1, "data": {"items": []}}\n' > "${HOST}/.storage/lovelace.lovelace"
sync
git -C "${CLONE}" pull -q origin main
[ -f "${CLONE}/.storage/lovelace.lovelace" ] || fail "host storage change was not pushed"
ok "push works"

echo "== 4. an excluded path in the repository is not written to the host"
printf 'secret in repo' > "${CLONE}/secrets.yaml"
git -C "${CLONE}" add -A && git -C "${CLONE}" commit -q -m "add excluded file" && git -C "${CLONE}" push -q origin main
sync
grep -q 'db_password' "${HOST}/secrets.yaml" || fail "an excluded path was overwritten by a pull"
# And the host's copy still does not get pushed over the repository's.
sync
git -C "${CLONE}" pull -q origin main
grep -q 'secret in repo' "${CLONE}/secrets.yaml" || fail "the host's excluded copy was pushed"
ok "excluded path held in both directions"

echo "== 5. secret-looking file stays out of the commit"
printf 'api_token: "abcdefghijklmnopqrstuvwxyz0123"\n' > "${HOST}/looks_secret.yaml"
printf 'password: !secret db_password\n' > "${HOST}/fine.yaml"
sync 2>&1 | tee "${WORK}/step5.log" | sed 's/^/    /'
git -C "${CLONE}" pull -q origin main
[ ! -e "${CLONE}/looks_secret.yaml" ] || fail "a credential-looking file was pushed"
[ -f "${CLONE}/fine.yaml" ] || fail "a !secret reference was wrongly withheld"
grep -q "looks_secret.yaml" "${WORK}/step5.log" || fail "the secret scan did not name the file"
rm -f "${HOST}/looks_secret.yaml"
ok "secret scan"

echo "== 6. same-line conflict resolves to conflict_winner"
sync >/dev/null
git -C "${CLONE}" pull -q origin main
printf 'homeassistant:\n  name: FromRepo\n' > "${CLONE}/configuration.yaml"
git -C "${CLONE}" add -A && git -C "${CLONE}" commit -q -m "repo side" && git -C "${CLONE}" push -q origin main
printf 'homeassistant:\n  name: FromHost\n' > "${HOST}/configuration.yaml"
sync remote
grep -q 'name: FromRepo' "${HOST}/configuration.yaml" || fail "remote did not win the conflict: $(cat "${HOST}/configuration.yaml")"
git -C "${CLONE}" pull -q origin main
grep -q 'name: FromRepo' "${CLONE}/configuration.yaml" || fail "merge result was not pushed"
# And the other way.
printf 'homeassistant:\n  name: RepoAgain\n' > "${CLONE}/configuration.yaml"
git -C "${CLONE}" add -A && git -C "${CLONE}" commit -q -m "repo side 2" && git -C "${CLONE}" push -q origin main
printf 'homeassistant:\n  name: HostAgain\n' > "${HOST}/configuration.yaml"
sync host
grep -q 'name: HostAgain' "${HOST}/configuration.yaml" || fail "host did not win the conflict: $(cat "${HOST}/configuration.yaml")"
git -C "${CLONE}" pull -q origin main
grep -q 'name: HostAgain' "${CLONE}/configuration.yaml" || fail "host-wins merge result was not pushed"
ok "conflict policy"

echo "== 7. a rename in the repository removes the old name on the host"
git -C "${CLONE}" mv dashboards/overview.yaml dashboards/main.yaml
git -C "${CLONE}" commit -q -m "rename" && git -C "${CLONE}" push -q origin main
sync
[ -f "${HOST}/dashboards/main.yaml" ] || fail "renamed file missing on the host"
[ ! -e "${HOST}/dashboards/overview.yaml" ] || fail "old name still present on the host"
ok "rename"

echo "== 8. no .git in the configuration directory"
[ ! -e "${HOST}/.git" ] || fail ".git appeared in the configuration directory"
[ -d "${DATA}/repo.git" ] || fail "the git directory is not under /data"
ok "git directory placement"

echo "== 9. first run against a remote that already has history"
HOST2="${WORK}/host2"; DATA2="${WORK}/data2"; REMOTE2="${WORK}/remote2.git"; CLONE2="${WORK}/clone2"
mkdir -p "${HOST2}" "${DATA2}"
cp "${DATA}/exclude" "${DATA2}/exclude"
git init -q --bare -b main "${REMOTE2}"
git clone -q "${REMOTE2}" "${CLONE2}" 2>/dev/null
git -C "${CLONE2}" config user.name tester; git -C "${CLONE2}" config user.email tester@example.invalid
printf '# created in forgejo
' > "${CLONE2}/README.md"
git -C "${CLONE2}" add -A && git -C "${CLONE2}" commit -q -m "initial" && git -C "${CLONE2}" push -q origin main
printf 'homeassistant:
  name: Second
' > "${HOST2}/configuration.yaml"
docker run --rm --user "$(id -u):$(id -g)"     -v "${HOST2}:/homeassistant" -v "${DATA2}:/data" -v "${ADDON_CONFIG}:/addon_config" -v "${REMOTE2}:/remote.git"     -e SYNC_REMOTE_URL=/remote.git -e SYNC_BRANCH=main -e SYNC_LOG_LEVEL=debug -e SYNC_EXCLUDE_FILE=/data/exclude     --entrypoint /usr/local/bin/config_sync.sh "${IMAGE}" once 2>&1 | tee "${WORK}/step9.log" | sed 's/^/    /'
grep -q "adopting the history" "${WORK}/step9.log" || fail "existing remote history was not adopted"
git -C "${CLONE2}" pull -q origin main
grep -q 'name: Second' "${HOST2}/configuration.yaml" || fail "the host file was overwritten by the import"
[ -f "${CLONE2}/configuration.yaml" ] || fail "host file was not pushed on top of the remote history"
[ ! -e "${CLONE2}/README.md" ] || fail "a remote-only path survived the host's import commit"
[ "$(git -C "${CLONE2}" rev-list --count main)" -ge 2 ] || fail "remote history was replaced instead of extended"
ok "existing remote history adopted, host wins"

echo "== 10. two unrelated histories merge under the conflict policy"
# A root commit made locally before the remote was readable, then the
# remote turns out to have its own root commit.
HOST3="${WORK}/host3"; DATA3="${WORK}/data3"; REMOTE3="${WORK}/remote3.git"; CLONE3="${WORK}/clone3"; EMPTY3="${WORK}/empty3.git"
mkdir -p "${HOST3}" "${DATA3}"; cp "${DATA}/exclude" "${DATA3}/exclude"
git init -q --bare -b main "${EMPTY3}"
printf 'homeassistant:
  name: Third
' > "${HOST3}/configuration.yaml"
docker run --rm --user "$(id -u):$(id -g)"     -v "${HOST3}:/homeassistant" -v "${DATA3}:/data" -v "${ADDON_CONFIG}:/addon_config" -v "${EMPTY3}:/remote.git"     -e SYNC_REMOTE_URL=/remote.git -e SYNC_BRANCH=main -e SYNC_EXCLUDE_FILE=/data/exclude     --entrypoint /usr/local/bin/config_sync.sh "${IMAGE}" once >/dev/null
git init -q --bare -b main "${REMOTE3}"
git clone -q "${REMOTE3}" "${CLONE3}" 2>/dev/null
git -C "${CLONE3}" config user.name tester; git -C "${CLONE3}" config user.email tester@example.invalid
printf 'homeassistant:
  name: RepoRoot
' > "${CLONE3}/configuration.yaml"
printf 'x
' > "${CLONE3}/extra.yaml"
git -C "${CLONE3}" add -A && git -C "${CLONE3}" commit -q -m "other root" && git -C "${CLONE3}" push -q origin main
docker run --rm --user "$(id -u):$(id -g)"     -v "${HOST3}:/homeassistant" -v "${DATA3}:/data" -v "${ADDON_CONFIG}:/addon_config" -v "${REMOTE3}:/remote.git"     -e SYNC_REMOTE_URL=/remote.git -e SYNC_BRANCH=main -e SYNC_CONFLICT_WINNER=host -e SYNC_EXCLUDE_FILE=/data/exclude     --entrypoint /usr/local/bin/config_sync.sh "${IMAGE}" once 2>&1 | tee "${WORK}/step10.log" | sed 's/^/    /'
grep -q "shares no history" "${WORK}/step10.log" || fail "unrelated histories were not detected"
grep -q 'name: Third' "${HOST3}/configuration.yaml" || fail "host did not win the unrelated-history conflict"
[ -f "${HOST3}/extra.yaml" ] || fail "remote-only file from the unrelated history was not written"
git -C "${CLONE3}" pull -q origin main
grep -q 'name: Third' "${CLONE3}/configuration.yaml" || fail "unrelated-history merge was not pushed"
ok "unrelated histories"

echo "== all smoke checks passed"
