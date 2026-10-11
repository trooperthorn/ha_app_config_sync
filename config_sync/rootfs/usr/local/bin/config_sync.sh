#!/usr/bin/env bash
# Config Sync engine. One cycle is:
#
#   1. commit what Home Assistant (or anyone with file access) changed in the
#      work tree, minus excluded paths and, when secret_scan is on, files
#      that look like they carry a credential;
#   2. fetch the remote branch and merge it into the work tree, letting the
#      configured side win where the same lines changed on both;
#   3. push the result.
#
# The git directory lives in /data/repo.git and the work tree is the
# configuration directory itself, so no .git appears in the configuration
# directory or in backups, and the exclude list lives in the git directory
# (info/exclude), never as a file in the configuration.
#
# Everything comes from the environment (set by the s6 run script, or by
# the smoke test). `config_sync.sh once` runs one cycle and exits non-zero
# on failure; `config_sync.sh loop` runs forever on the interval.
set -o errexit -o pipefail -o nounset

MODE="${1:-once}"

WORK_TREE="${SYNC_WORK_TREE:-/homeassistant}"
DATA_DIR="${SYNC_DATA_DIR:-/data}"
ADDON_CONFIG_DIR="${SYNC_ADDON_CONFIG_DIR:-/addon_config}"
GIT_DIR_PATH="${DATA_DIR}/repo.git"
STATUS_FILE="${DATA_DIR}/status.json"
SSH_DIR="${DATA_DIR}/ssh"
REMOTE_URL="${SYNC_REMOTE_URL:?SYNC_REMOTE_URL is required}"
BRANCH="${SYNC_BRANCH:-main}"
INTERVAL_MINUTES="${SYNC_INTERVAL_MINUTES:-10}"
CONFLICT_WINNER="${SYNC_CONFLICT_WINNER:-remote}"
AUTHOR_NAME="${SYNC_AUTHOR_NAME:-Home Assistant}"
AUTHOR_EMAIL="${SYNC_AUTHOR_EMAIL:-config-sync@home-assistant.local}"
SSH_KEY_FILE="${SYNC_SSH_KEY_FILE:-}"
KNOWN_HOSTS_FILE="${SYNC_KNOWN_HOSTS_FILE:-}"
CA_FILE="${SYNC_CA_FILE:-}"
SECRET_SCAN="${SYNC_SECRET_SCAN:-true}"
RELOAD_AFTER_PULL="${SYNC_RELOAD_AFTER_PULL:-none}"
EXCLUDE_FILE="${SYNC_EXCLUDE_FILE:-${DATA_DIR}/exclude}"
LOG_LEVEL="${SYNC_LOG_LEVEL:-info}"
APP_VERSION="${SYNC_APP_VERSION:-dev}"

# ---------------------------------------------------------------- logging
_ts() { date -u '+%Y-%m-%d %H:%M:%S'; }
log_debug()   { if [ "${LOG_LEVEL}" = "debug" ]; then printf '[%s] DEBUG: %s\n' "$(_ts)" "$1"; fi; }
log_info()    { case "${LOG_LEVEL}" in warning|error) ;; *) printf '[%s] INFO: %s\n' "$(_ts)" "$1" ;; esac; }
log_warning() { [ "${LOG_LEVEL}" = "error" ] || printf '[%s] WARNING: %s\n' "$(_ts)" "$1" >&2; }
log_error()   { printf '[%s] ERROR: %s\n' "$(_ts)" "$1" >&2; }

# ---------------------------------------------------------------- git wrapper
g() { git --git-dir="${GIT_DIR_PATH}" --work-tree="${WORK_TREE}" "$@"; }

# ---------------------------------------------------------------- status file
LAST_ERROR=""
PULLED_FILES=0
PUSHED_COMMITS=0
write_status() {
    local state="$1"
    local head; head="$(g rev-parse --short HEAD 2>/dev/null || echo none)"
    jq -n \
        --arg state "$state" \
        --arg time "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --arg head "$head" \
        --arg remote "$REMOTE_URL" \
        --arg branch "$BRANCH" \
        --arg error "$LAST_ERROR" \
        --arg version "$APP_VERSION" \
        --argjson pulled "$PULLED_FILES" \
        --argjson pushed "$PUSHED_COMMITS" \
        '{state: $state, time: $time, head: $head, remote: $remote, branch: $branch,
          last_error: $error, pulled_files_last_cycle: $pulled, pushed_commits_last_cycle: $pushed,
          app_version: $version}' > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "${STATUS_FILE}"
}

# ---------------------------------------------------------------- transport
setup_transport() {
    export GIT_TERMINAL_PROMPT=0
    export GIT_CONFIG_NOSYSTEM=1
    export HOME="${DATA_DIR}"

    case "${REMOTE_URL}" in
        ssh://*|git@*|*@*:*)
            setup_ssh ;;
        https://*)
            setup_https ;;
        file://*|/*)
            # Local remotes are for the smoke test only.
            log_debug "local remote, no transport setup" ;;
        *)
            log_error "remote_url scheme not recognised: ${REMOTE_URL}"
            return 1 ;;
    esac
}

setup_ssh() {
    mkdir -p "${SSH_DIR}"
    chmod 700 "${SSH_DIR}"
    local key known_hosts strict
    if [ -n "${SSH_KEY_FILE}" ]; then
        key="${ADDON_CONFIG_DIR}/${SSH_KEY_FILE}"
        if [ ! -r "${key}" ]; then
            log_error "ssh_key_file ${SSH_KEY_FILE} is not readable under the app's config directory."
            return 1
        fi
        # OpenSSH refuses a key with loose permissions; copy it into a mode we control.
        install -m 0600 "${key}" "${SSH_DIR}/operator_key"
        key="${SSH_DIR}/operator_key"
    else
        key="${SSH_DIR}/id_ed25519"
        if [ ! -s "${key}" ]; then
            ssh-keygen -q -t ed25519 -N "" -C "config-sync@home-assistant" -f "${key}"
            log_info "Generated a deploy key. Add this public key to the repository's deploy keys with write access:"
            log_info "$(cat "${key}.pub")"
        fi
    fi
    log_debug "ssh key: ${key}"

    if [ -n "${KNOWN_HOSTS_FILE}" ]; then
        known_hosts="${ADDON_CONFIG_DIR}/${KNOWN_HOSTS_FILE}"
        if [ ! -r "${known_hosts}" ]; then
            log_error "ssh_known_hosts_file ${KNOWN_HOSTS_FILE} is not readable under the app's config directory."
            return 1
        fi
        strict="yes"
    else
        known_hosts="${SSH_DIR}/known_hosts"
        touch "${known_hosts}"
        chmod 600 "${known_hosts}"
        if [ ! -s "${known_hosts}" ]; then
            # Trust on first use: fetch the host key once, pin it, and say
            # what was pinned. Every later connection is strict.
            local host port
            host="$(printf '%s' "${REMOTE_URL}" | sed -E 's#^(ssh://)?([^@]+@)?([^:/]+).*#\3#')"
            port="$(printf '%s' "${REMOTE_URL}" | sed -nE 's#^ssh://[^/]*:([0-9]+)/.*#\1#p')"
            ssh-keyscan -T 10 ${port:+-p "$port"} "${host}" > "${known_hosts}.tmp" 2>/dev/null || true
            if [ ! -s "${known_hosts}.tmp" ]; then
                rm -f "${known_hosts}.tmp"
                log_error "Could not fetch the SSH host key of ${host}${port:+:$port}; is the remote reachable?"
                return 1
            fi
            mv "${known_hosts}.tmp" "${known_hosts}"
            log_warning "Pinned the SSH host key of ${host}${port:+:$port} on first use: $(ssh-keygen -lf "${known_hosts}" | tr '\n' ' '). Verify this fingerprint against the server; delete /data/ssh/known_hosts to re-pin."
        fi
        strict="yes"
    fi
    export GIT_SSH_COMMAND="ssh -i ${key} -o IdentitiesOnly=yes -o UserKnownHostsFile=${known_hosts} -o StrictHostKeyChecking=${strict} -o BatchMode=yes -o ConnectTimeout=20"
}

setup_https() {
    export GIT_ASKPASS=/usr/local/bin/config_sync_askpass
    if [ -z "${SYNC_HTTPS_TOKEN:-}" ]; then
        log_warning "https remote without https_token: only a public repository can be read, and nothing can be pushed."
    fi
    if [ -n "${CA_FILE}" ]; then
        local ca="${ADDON_CONFIG_DIR}/${CA_FILE}"
        if [ ! -r "${ca}" ]; then
            log_error "ca_certificate_file ${CA_FILE} is not readable under the app's config directory."
            return 1
        fi
        export GIT_SSL_CAINFO="${ca}"
    fi
}

# ---------------------------------------------------------------- repository
ensure_repository() {
    if [ ! -d "${WORK_TREE}" ]; then
        log_error "work tree ${WORK_TREE} does not exist."
        return 1
    fi
    # A directory that is not a repository (seen after a host migration: the
    # path came back but git no longer recognised it) would otherwise fail
    # every cycle with "not a git repository", because the directory's
    # existence alone skips the init below. Move it aside rather than delete
    # it, then start over: the first-run path adopts the remote's history and
    # commits the host's files on top, so nothing on the host is lost.
    if [ -d "${GIT_DIR_PATH}" ] && ! git --git-dir="${GIT_DIR_PATH}" rev-parse --git-dir >/dev/null 2>&1; then
        local aside; aside="${GIT_DIR_PATH}.invalid-$(date -u '+%Y%m%dT%H%M%SZ')"
        log_warning "${GIT_DIR_PATH} is not a git repository; moving it to ${aside} and starting over."
        mv "${GIT_DIR_PATH}" "${aside}"
    fi
    if [ ! -d "${GIT_DIR_PATH}" ]; then
        log_info "Creating the git directory at ${GIT_DIR_PATH} for work tree ${WORK_TREE}."
        git init -q --bare "${GIT_DIR_PATH}"
        g config core.bare false
        g config core.worktree "${WORK_TREE}"
        g symbolic-ref HEAD "refs/heads/${BRANCH}"
    fi
    g config user.name "${AUTHOR_NAME}"
    g config user.email "${AUTHOR_EMAIL}"
    g config core.autocrlf false
    g config core.safecrlf false
    g config core.filemode false
    g config gc.auto 0
    g config merge.renamelimit 0
    g config advice.detachedHead false
    # git refuses a repository owned by another user unless it is listed as
    # safe. The configuration directory is root-owned on the host and this
    # container has one user, so every path is safe by construction.
    git config --global --replace-all safe.directory '*' 2>/dev/null || true

    if g remote get-url origin >/dev/null 2>&1; then
        [ "$(g remote get-url origin)" = "${REMOTE_URL}" ] || g remote set-url origin "${REMOTE_URL}"
    else
        g remote add origin "${REMOTE_URL}"
    fi
    # Excluded paths, both directions. info/exclude keeps them out of
    # `git add -A`. That alone is not enough: git writes every tracked path
    # on merge whatever the ignore rules say, so a path the repository has
    # and the host excludes would still be written. A non-cone sparse
    # checkout built from the same patterns (everything, minus each
    # exclude) marks those paths skip-worktree: never written, never
    # deleted, never staged. .git itself is excluded so a stray checkout
    # inside the configuration is not swallowed.
    mkdir -p "${GIT_DIR_PATH}/info"
    { grep -Ev '^[[:space:]]*(#|$)' "${EXCLUDE_FILE}" 2>/dev/null || true; echo ".git/"; } > "${GIT_DIR_PATH}/info/exclude"
    g config core.sparseCheckout true
    g config core.sparseCheckoutCone false
    # Without this, git 2.37 and later clear skip-worktree on any such file
    # that exists on disk, which would undo protect_tracked_excluded.
    g config sparse.expectFilesOutsideOfPatterns true
    {
        echo "/*"
        while IFS= read -r pattern; do
            case "${pattern}" in
                "!"*) echo "${pattern#!}" ;;
                *) echo "!${pattern}" ;;
            esac
        done < "${GIT_DIR_PATH}/info/exclude"
    } > "${GIT_DIR_PATH}/info/sparse-checkout"
}

# On the very first cycle the local branch has no commits. If the remote
# branch exists, its history is adopted and the host's current files become
# the next commit on top of it, so nothing on the host is ever overwritten
# by the initial import; paths the remote has and the host does not are
# removed in that commit (they stay in history). If the remote branch does
# not exist, the host's files become the first commit.
adopt_remote_if_first_run() {
    if g rev-parse --verify --quiet "refs/heads/${BRANCH}" >/dev/null; then
        return 0
    fi
    if g fetch --quiet origin "${BRANCH}" 2>"${DATA_DIR}/fetch.err"; then
        log_info "First run: adopting the history of origin/${BRANCH}; the host's files become the next commit."
        g update-ref "refs/heads/${BRANCH}" "refs/remotes/origin/${BRANCH}"
        # Index at the remote, work tree untouched.
        g reset -q --mixed "refs/heads/${BRANCH}" -- . 2>/dev/null || g reset -q --mixed "refs/heads/${BRANCH}"
    elif grep -q "couldn't find remote ref" "${DATA_DIR}/fetch.err"; then
        log_info "First run: origin/${BRANCH} does not exist yet; the host's files become the first commit."
    else
        # Authentication or connectivity, not an empty remote. Committing a
        # root commit now would leave two unrelated histories to reconcile
        # once the remote is reachable, so stop this cycle instead.
        LAST_ERROR="first run: could not read origin/${BRANCH}: $(tr '\n' ' ' < "${DATA_DIR}/fetch.err")"
        log_error "${LAST_ERROR}"
        return 1
    fi
}

# ---------------------------------------------------------------- secret scan
# Heuristics only: a private key block, or a yaml/json key that names a
# credential with a literal value at least 12 characters long that is not
# a !secret reference or a template. A hit keeps the file out of this
# commit and names it; nothing is deleted or rewritten.
SECRET_PATTERN='(-----BEGIN [A-Z ]*PRIVATE KEY-----)|(^[[:space:]]*"?(password|passwd|api_key|apikey|api_token|access_token|refresh_token|client_secret|secret|token|private_key)"?[[:space:]]*[:=][[:space:]]*"?[^"[:space:]!{$][^"[:space:]]{11,})'
scan_staged_for_secrets() {
    [ "${SECRET_SCAN}" = "true" ] || return 0
    local hits=0 path
    while IFS= read -r -d '' path; do
        # Only text files that are added or modified in this commit.
        if g show ":${path}" 2>/dev/null | grep -Iq . \
            && g show ":${path}" | grep -Eiq "${SECRET_PATTERN}"; then
            log_warning "secret_scan: '${path}' looks like it holds a credential and was left out of the commit. Add it to exclude or move the value to secrets.yaml."
            g reset -q -- "${path}" 2>/dev/null || true
            hits=$((hits + 1))
        fi
    done < <(g diff --cached --name-only --diff-filter=AM -z)
    [ "${hits}" -eq 0 ] || log_warning "secret_scan left ${hits} file(s) uncommitted."
}

# ---------------------------------------------------------------- tracked and excluded
# A path that is tracked and also matches exclude is not protected by the
# sparse checkout alone. If it is not marked skip-worktree, the next command
# that rewrites the index from the work tree (a merge, `reset --merge`,
# `read-tree -u`) applies the sparse rules and deletes the file from disk.
# That happens when the owner excludes a path the host already committed,
# and when the repository adds a path the host already has (scenario 4).
# Marking every such path skip-worktree before anything else runs keeps the
# host's file untouched: never committed, never overwritten, never deleted.
# The repository's copy, if any, stays in the repository; when the
# repository deletes it, the merge drops the index entry and the host's
# file stays where it is.
protect_tracked_excluded() {
    g rev-parse --verify --quiet HEAD >/dev/null || return 0
    local list="${DATA_DIR}/protect.lst" entry n=0
    : > "${list}"
    # -t tags each tracked path: "H" for a normal entry, "S" for skip-worktree.
    while IFS= read -r -d '' entry; do
        case "${entry}" in
            "H "*) printf '%s\0' "${entry#H }" >> "${list}"; n=$((n + 1)) ;;
        esac
    done < <(g ls-files -z -t -c -i --exclude-from="${GIT_DIR_PATH}/info/exclude" 2>/dev/null)
    [ "${n}" -gt 0 ] || return 0
    g update-index -z --skip-worktree --stdin < "${list}"
    log_info "Protected ${n} tracked file(s) that match exclude; the host's copies are no longer committed, overwritten or deleted."
}

# ---------------------------------------------------------------- the cycle
commit_host_changes() {
    g add -A -- . 2>/dev/null
    scan_staged_for_secrets
    if g diff --cached --quiet 2>/dev/null && g rev-parse --verify --quiet HEAD >/dev/null; then
        log_debug "no host changes"
        return 0
    fi
    if ! g rev-parse --verify --quiet HEAD >/dev/null && g diff --cached --quiet 2>/dev/null; then
        # Nothing to commit and no history: an empty configuration directory.
        log_debug "nothing to commit on first run"
        return 0
    fi
    local n; n="$(g diff --cached --name-only | wc -l | tr -d ' ')"
    g commit -q -m "host: $(date -u '+%Y-%m-%dT%H:%M:%SZ') (${n} files)"
    log_info "Committed ${n} changed file(s) from the host."
}

# A merge that applies the repository's deletion of a tracked path removes
# the file from disk, skip-worktree or not. For a path that matches exclude
# the host's file must stay, so the deletion is taken here first: the path is
# untracked in a local commit, both sides then agree it is gone, and the
# merge leaves the file alone.
untrack_excluded_deleted_by_remote() {
    local remote="$1" list="${DATA_DIR}/untrack.lst" path n=0
    : > "${list}"
    while IFS= read -r -d '' path; do
        if g ls-files -c -i --exclude-from="${GIT_DIR_PATH}/info/exclude" -- ":(literal)${path}" 2>/dev/null | grep -q .; then
            printf '%s\0' "${path}" >> "${list}"
            n=$((n + 1))
        fi
    done < <(g diff -z --name-only --no-renames --diff-filter=D HEAD "${remote}" 2>/dev/null)
    [ "${n}" -gt 0 ] || return 0
    g --literal-pathspecs rm -q --cached --sparse --pathspec-from-file="${list}" --pathspec-file-nul
    g commit -q -m "host: untrack ${n} excluded file(s) that origin/${BRANCH} deleted"
    log_info "origin/${BRANCH} deleted ${n} file(s) that match exclude; untracked them here first so the host's copies stay."
}

merge_remote() {
    PULLED_FILES=0
    if ! g fetch --quiet origin "${BRANCH}" 2>"${DATA_DIR}/fetch.err"; then
        if grep -q "couldn't find remote ref" "${DATA_DIR}/fetch.err"; then
            log_debug "remote branch ${BRANCH} does not exist yet"
            return 0
        fi
        LAST_ERROR="fetch failed: $(tr '\n' ' ' < "${DATA_DIR}/fetch.err")"
        log_error "${LAST_ERROR}"
        return 1
    fi
    local remote local_head
    remote="$(g rev-parse "refs/remotes/origin/${BRANCH}")"
    local_head="$(g rev-parse HEAD 2>/dev/null || echo "")"
    if [ -z "${local_head}" ]; then
        # No local commits at all: adopt the remote outright.
        g update-ref "refs/heads/${BRANCH}" "${remote}"
        g read-tree -m -u HEAD
        PULLED_FILES="$(g ls-files | wc -l | tr -d ' ')"
        log_info "Adopted origin/${BRANCH} into an empty configuration (${PULLED_FILES} files)."
        return 0
    fi
    if [ "${remote}" = "${local_head}" ] || g merge-base --is-ancestor "${remote}" HEAD; then
        log_debug "remote has nothing new"
        return 0
    fi
    untrack_excluded_deleted_by_remote "${remote}"
    local strategy
    case "${CONFLICT_WINNER}" in
        host) strategy="ours" ;;
        *) strategy="theirs" ;;
    esac
    local before; before="$(g rev-parse HEAD)"
    # Two histories with no common commit (a root commit made here before
    # the remote was readable, or a remote re-created from scratch) merge
    # like any other pair under the same conflict policy.
    local unrelated=()
    if ! g merge-base HEAD "${remote}" >/dev/null 2>&1; then
        unrelated=(--allow-unrelated-histories)
        log_warning "origin/${BRANCH} shares no history with the local branch; merging the two histories with ${CONFLICT_WINNER} winning conflicts."
    fi
    if g merge -q --no-edit "${unrelated[@]}" -X "${strategy}" -m "sync: merge origin/${BRANCH} (${CONFLICT_WINNER} wins conflicts)" "${remote}" 2>"${DATA_DIR}/merge.err"; then
        PULLED_FILES="$(g diff --name-only "${before}" HEAD | wc -l | tr -d ' ')"
        log_info "Merged origin/${BRANCH}: ${PULLED_FILES} file(s) written to the host."
        if [ "${LOG_LEVEL}" = "debug" ]; then g diff --name-status "${before}" HEAD | sed 's/^/  /'; fi
    else
        # -X resolves content conflicts; what is left is a tree-level
        # conflict (file vs directory, both added a binary). Back out and say so.
        LAST_ERROR="merge of origin/${BRANCH} could not be completed automatically: $(tr '\n' ' ' < "${DATA_DIR}/merge.err")"
        log_error "${LAST_ERROR}"
        # Abort only a merge that started. A refused merge changed nothing,
        # and a `reset --merge` here would apply the sparse checkout and
        # remove tracked files that match exclude from the host.
        if g rev-parse --verify --quiet MERGE_HEAD >/dev/null; then
            g merge --abort 2>/dev/null || true
        fi
        return 1
    fi
}

push_local() {
    PUSHED_COMMITS=0
    if ! g rev-parse --verify --quiet HEAD >/dev/null; then
        return 0
    fi
    local ahead
    if g rev-parse --verify --quiet "refs/remotes/origin/${BRANCH}" >/dev/null; then
        ahead="$(g rev-list --count "refs/remotes/origin/${BRANCH}..HEAD")"
    else
        ahead="$(g rev-list --count HEAD)"
    fi
    if [ "${ahead}" -eq 0 ]; then
        log_debug "nothing to push"
        return 0
    fi
    if g push --quiet origin "HEAD:refs/heads/${BRANCH}" 2>"${DATA_DIR}/push.err"; then
        PUSHED_COMMITS="${ahead}"
        log_info "Pushed ${ahead} commit(s) to origin/${BRANCH}."
    else
        LAST_ERROR="push failed: $(tr '\n' ' ' < "${DATA_DIR}/push.err")"
        log_error "${LAST_ERROR}"
        return 1
    fi
}

reload_core() {
    [ "${RELOAD_AFTER_PULL}" = "reload_all" ] || return 0
    [ "${PULLED_FILES}" -gt 0 ] || return 0
    if [ -z "${SUPERVISOR_TOKEN:-}" ]; then
        log_warning "reload_after_pull is set but no Supervisor token is present; not reloading."
        return 0
    fi
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' -X POST \
        -H "Authorization: Bearer ${SUPERVISOR_TOKEN}" -H "Content-Type: application/json" \
        -d '{}' "http://supervisor/core/api/services/homeassistant/reload_all" 2>/dev/null || echo 000)"
    if [ "${code}" = "200" ]; then
        log_info "Asked Home Assistant to reload its YAML configuration (homeassistant.reload_all)."
    else
        log_warning "homeassistant.reload_all returned HTTP ${code}."
    fi
}

sync_once() {
    LAST_ERROR=""
    write_status "running"
    # Under `sync_once || ...` errexit is off inside this function, so each
    # preparatory step's failure is checked explicitly.
    setup_transport || { write_status "error"; return 1; }
    ensure_repository || { write_status "error"; return 1; }
    adopt_remote_if_first_run || { write_status "error"; return 1; }
    protect_tracked_excluded
    commit_host_changes
    local rc=0
    merge_remote || rc=1
    # A failed merge or fetch must not stop a push of what the host already
    # committed; a failed push is reported and retried next cycle.
    push_local || rc=1
    reload_core
    if [ "${rc}" -eq 0 ]; then
        write_status "ok"
    else
        write_status "error"
    fi
    return "${rc}"
}

case "${MODE}" in
    once)
        sync_once ;;
    loop)
        while true; do
            sync_once || log_warning "Cycle finished with an error; retrying in ${INTERVAL_MINUTES} min."
            sleep "$(( INTERVAL_MINUTES * 60 ))"
        done ;;
    *)
        echo "usage: config_sync.sh once|loop" >&2
        exit 2 ;;
esac
