#!/usr/bin/env bash

set -o errexit
set -o pipefail
set -o nounset

IFS=$'\n\t'

__DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
__SCRIPT_PATH="${__DIRECTORY}/${BASH_SOURCE[0]##*/}"

__PRINT_USAGE() {
  printf '%s\n' \
    "Usage: rebase-stable-release.bash [--continue]" \
    "" \
    "Synchronize origin/main with upstream's latest stable release, then rebase the current feature stack." \
    "Exit code 20 means a rebase conflict requires resolution."
}

__FAIL() {
  local __ERROR_CODE="$1"
  local __ERROR_MESSAGE="$2"

  printf '[%s] %s\n' "${__ERROR_CODE}" "${__ERROR_MESSAGE}" >&2
  exit 1
}

__REQUIRE_ORIGIN_MAIN_PUSH_AUTHORIZATION() {
  if [[ "${MRROLL_REMOTE_WRITE_AUTHORIZED:-}" != "1" ]]; then
    __FAIL \
      "REBASE_STABLE_RELEASE_REMOTE_WRITE_NOT_AUTHORIZED" \
      "Explicit authorization is required to push synchronized main to origin/main."
  fi
}

__WRITE_STATE() {
  {
    printf '%s\n' "${__PHASE}"
    printf '%s\n' "${__ORIGINAL_FEATURE_BRANCH}"
    printf '%s\n' "${__EXPECTED_ORIGIN_MAIN_COMMIT}"
    printf '%s\n' "${__DID_CREATE_UNSIGNED_COMMIT}"
    printf '%s\n' "${__FEATURE_STACK_BASE_COMMIT}"
    printf '%s\n' "${__STABLE_RELEASE_TAG}"
    printf '%s\n' "${__STABLE_RELEASE_COMMIT}"
    printf '%s\n' "${__FORK_MAIN_BASE_COMMIT}"
    printf '%s\n' "${__GENERATED_RELEASE_COMMIT}"
  } >"${__STATE_PATH}"
}

__INSTALL_RESUME_SCRIPT() {
  cp "${__SCRIPT_PATH}" "${__RESUME_SCRIPT_PATH}"
  chmod +x "${__RESUME_SCRIPT_PATH}"
}

__CLEAR_OPERATION_FILES() {
  if [[ -f "${__STATE_PATH}" ]]; then
    trash "${__STATE_PATH}"
  fi
  if [[ -f "${__RESUME_SCRIPT_PATH}" ]]; then
    trash "${__RESUME_SCRIPT_PATH}"
  fi
}

__READ_STATE() {
  local __STATE_LINE_NUMBER=0
  local __STATE_LINE

  __PHASE=""
  __ORIGINAL_FEATURE_BRANCH=""
  __EXPECTED_ORIGIN_MAIN_COMMIT=""
  __DID_CREATE_UNSIGNED_COMMIT="false"
  __FEATURE_STACK_BASE_COMMIT=""
  __STABLE_RELEASE_TAG=""
  __STABLE_RELEASE_COMMIT=""
  __FORK_MAIN_BASE_COMMIT=""
  __GENERATED_RELEASE_COMMIT=""

  while IFS= read -r __STATE_LINE; do
    __STATE_LINE_NUMBER=$((__STATE_LINE_NUMBER + 1))
    case "${__STATE_LINE_NUMBER}" in
      1) __PHASE="${__STATE_LINE}" ;;
      2) __ORIGINAL_FEATURE_BRANCH="${__STATE_LINE}" ;;
      3) __EXPECTED_ORIGIN_MAIN_COMMIT="${__STATE_LINE}" ;;
      4) __DID_CREATE_UNSIGNED_COMMIT="${__STATE_LINE}" ;;
      5) __FEATURE_STACK_BASE_COMMIT="${__STATE_LINE}" ;;
      6) __STABLE_RELEASE_TAG="${__STATE_LINE}" ;;
      7) __STABLE_RELEASE_COMMIT="${__STATE_LINE}" ;;
      8) __FORK_MAIN_BASE_COMMIT="${__STATE_LINE}" ;;
      9) __GENERATED_RELEASE_COMMIT="${__STATE_LINE}" ;;
    esac
  done <"${__STATE_PATH}"
}

__RUN_GIT_WITH_SSH_RETRY() {
  local __COMMAND_OUTPUT
  local __COMMAND_EXIT_CODE

  set +o errexit
  __COMMAND_OUTPUT="$(git "$@" 2>&1)"
  __COMMAND_EXIT_CODE=$?
  set -o errexit
  printf '%s\n' "${__COMMAND_OUTPUT}"

  if [[ ${__COMMAND_EXIT_CODE} -eq 0 ]]; then
    return 0
  fi

  if [[ "${__COMMAND_OUTPUT}" == *"sign_and_send_pubkey:"* ]] &&
    [[ "${__COMMAND_OUTPUT}" == *"communication with agent failed"* ]]; then
    printf '%s\n' "[REBASE_STABLE_RELEASE_SSH_RETRY] Retrying the same Git command once." >&2
    git "$@"
    return $?
  fi

  return "${__COMMAND_EXIT_CODE}"
}

__HAS_REBASE_IN_PROGRESS() {
  local __REBASE_MERGE_PATH
  local __REBASE_APPLY_PATH

  __REBASE_MERGE_PATH="$(git rev-parse --git-path rebase-merge)"
  __REBASE_APPLY_PATH="$(git rev-parse --git-path rebase-apply)"
  [[ -d "${__REBASE_MERGE_PATH}" || -d "${__REBASE_APPLY_PATH}" ]]
}

__ACTIVE_REBASE_HEAD_NAME() {
  local __REBASE_HEAD_NAME_PATH
  local __REBASE_HEAD_NAME

  __REBASE_HEAD_NAME_PATH="$(git rev-parse --git-path rebase-merge/head-name)"
  if [[ ! -f "${__REBASE_HEAD_NAME_PATH}" ]]; then
    __REBASE_HEAD_NAME_PATH="$(git rev-parse --git-path rebase-apply/head-name)"
  fi
  if [[ ! -f "${__REBASE_HEAD_NAME_PATH}" ]]; then
    __FAIL \
      "REBASE_STABLE_RELEASE_REBASE_HEAD_MISSING" \
      "The active rebase does not identify its source branch."
  fi

  IFS= read -r __REBASE_HEAD_NAME <"${__REBASE_HEAD_NAME_PATH}"
  printf '%s\n' "${__REBASE_HEAD_NAME}"
}

__EXPECTED_REBASE_HEAD_NAME() {
  case "${__PHASE}" in
    rebase_fork_main_onto_stable_release)
      printf '%s\n' "refs/heads/main"
      ;;
    rebase_feature_stack_onto_main)
      printf 'refs/heads/%s\n' "${__ORIGINAL_FEATURE_BRANCH}"
      ;;
    *)
      __FAIL \
        "REBASE_STABLE_RELEASE_REBASE_PHASE_INVALID" \
        "Saved phase '${__PHASE}' cannot contain an active rebase."
      ;;
  esac
}

__VERIFY_ACTIVE_REBASE_BRANCH() {
  local __ACTIVE_REBASE_HEAD_NAME_VALUE
  local __EXPECTED_REBASE_HEAD_NAME_VALUE

  __ACTIVE_REBASE_HEAD_NAME_VALUE="$(__ACTIVE_REBASE_HEAD_NAME)"
  __EXPECTED_REBASE_HEAD_NAME_VALUE="$(__EXPECTED_REBASE_HEAD_NAME)"
  if [[ "${__ACTIVE_REBASE_HEAD_NAME_VALUE}" != "${__EXPECTED_REBASE_HEAD_NAME_VALUE}" ]]; then
    __FAIL \
      "REBASE_STABLE_RELEASE_REBASE_BRANCH_MISMATCH" \
      "The active rebase belongs to '${__ACTIVE_REBASE_HEAD_NAME_VALUE}', not '${__EXPECTED_REBASE_HEAD_NAME_VALUE}'."
  fi
}

__CAN_CREATE_UNSIGNED_FEATURE_COMMIT() {
  [[ "${__PHASE}" == "rebase_feature_stack_onto_main" ]]
}

__REPORT_CONFLICT() {
  printf '%s\n' \
    "[REBASE_STABLE_RELEASE_CONFLICT] Git stopped during phase '${__PHASE}'." \
    "Resolve and stage every conflicted file. Then continue with:" \
    "${__RESUME_SCRIPT_PATH} --continue" >&2
  git status --short
  exit 20
}

__CONTINUE_CURRENT_REBASE_UNSIGNED() {
  local __COMMAND_OUTPUT
  local __COMMAND_EXIT_CODE

  __DID_CREATE_UNSIGNED_COMMIT="true"
  __WRITE_STATE

  # Git 2.55 stores the rebase-level -S option here. Git rejects --no-gpg-sign with --continue.
  if [[ -f "${__REBASE_GPG_SIGN_OPTION_PATH}" ]]; then
    trash "${__REBASE_GPG_SIGN_OPTION_PATH}"
  fi

  set +o errexit
  __COMMAND_OUTPUT="$(
    GIT_EDITOR=true git -c commit.gpgsign=false rebase --continue 2>&1
  )"
  __COMMAND_EXIT_CODE=$?
  set -o errexit
  printf '%s\n' "${__COMMAND_OUTPUT}"

  if [[ ${__COMMAND_EXIT_CODE} -eq 0 ]]; then
    return 0
  fi
  if [[ -n "$(git diff --name-only --diff-filter=U)" ]]; then
    __REPORT_CONFLICT
  fi

  __FAIL \
    "REBASE_STABLE_RELEASE_UNSIGNED_CONTINUE_FAILED" \
    "Git could not continue the active rebase without commit signing."
}

__CONTINUE_CURRENT_REBASE() {
  local __COMMAND_OUTPUT
  local __COMMAND_EXIT_CODE

  set +o errexit
  __COMMAND_OUTPUT="$(GIT_EDITOR=true git rebase --continue 2>&1)"
  __COMMAND_EXIT_CODE=$?
  set -o errexit
  printf '%s\n' "${__COMMAND_OUTPUT}"

  if [[ ${__COMMAND_EXIT_CODE} -eq 0 ]]; then
    return 0
  fi

  if [[ -n "$(git diff --name-only --diff-filter=U)" ]]; then
    __REPORT_CONFLICT
  fi

  if __CAN_CREATE_UNSIGNED_FEATURE_COMMIT &&
    { [[ "${__COMMAND_OUTPUT}" == *"failed to sign"* ]] ||
      [[ "${__COMMAND_OUTPUT}" == *"signing failed"* ]] ||
      [[ "${__COMMAND_OUTPUT}" == *"failed to write commit object"* ]]; }; then
    printf '%s\n' \
      "[REBASE_STABLE_RELEASE_UNSIGNED_COMMIT] Commit signing is unavailable. Retrying unsigned." >&2
    __CONTINUE_CURRENT_REBASE_UNSIGNED
    return $?
  fi

  __FAIL "REBASE_STABLE_RELEASE_CONTINUE_FAILED" "Git could not continue the active rebase."
}

__REBASE_ONTO() {
  local __BASE_REFERENCE="$1"
  local __COMMAND_OUTPUT
  local __COMMAND_EXIT_CODE

  set +o errexit
  if [[ "${__PHASE}" == "rebase_feature_stack_onto_main" ]]; then
    __COMMAND_OUTPUT="$(
      git rebase \
        --update-refs \
        --onto "${__BASE_REFERENCE}" \
        "${__FEATURE_STACK_BASE_COMMIT}" 2>&1
    )"
  else
    __COMMAND_OUTPUT="$(
      git rebase \
        --onto "${__BASE_REFERENCE}" \
        "${__FORK_MAIN_BASE_COMMIT}" 2>&1
    )"
  fi
  __COMMAND_EXIT_CODE=$?
  set -o errexit
  printf '%s\n' "${__COMMAND_OUTPUT}"

  if [[ ${__COMMAND_EXIT_CODE} -eq 0 ]]; then
    return 0
  fi

  if [[ -n "$(git diff --name-only --diff-filter=U)" ]]; then
    __REPORT_CONFLICT
  fi

  if __HAS_REBASE_IN_PROGRESS && __CAN_CREATE_UNSIGNED_FEATURE_COMMIT &&
    { [[ "${__COMMAND_OUTPUT}" == *"failed to sign"* ]] ||
      [[ "${__COMMAND_OUTPUT}" == *"signing failed"* ]] ||
      [[ "${__COMMAND_OUTPUT}" == *"failed to write commit object"* ]]; }; then
    printf '%s\n' \
      "[REBASE_STABLE_RELEASE_UNSIGNED_COMMIT] Commit signing is unavailable. Retrying unsigned." >&2
    __CONTINUE_CURRENT_REBASE_UNSIGNED
    return $?
  fi

  __FAIL \
    "REBASE_STABLE_RELEASE_REBASE_FAILED" \
    "Git could not rebase '${__PHASE}' onto '${__BASE_REFERENCE}'."
}

__INSPECT_GITHUB_STACK() {
  local __STACK_OUTPUT
  local __STACK_EXIT_CODE

  set +o errexit
  __STACK_OUTPUT="$(gh stack view --json 2>&1)"
  __STACK_EXIT_CODE=$?
  set -o errexit

  if [[ ${__STACK_EXIT_CODE} -eq 0 ]]; then
    printf '%s\n' "[REBASE_STABLE_RELEASE_STACK_DETECTED] Rebasing the selected stack with --update-refs."
    return 0
  fi

  if [[ "${__STACK_OUTPUT}" == *"is not part of a stack"* ]]; then
    return 0
  fi

  printf '%s\n' "${__STACK_OUTPUT}" >&2
  __FAIL "REBASE_STABLE_RELEASE_STACK_CHECK_FAILED" "GitHub stack inspection failed."
}

__DERIVE_GITHUB_STACK_BRANCHES() {
  local __BRANCH_AT_COMMIT
  local __BRANCH_AT_COMMIT_COUNT
  local __COMMIT
  local __LAST_BRANCH_INDEX
  local __SELECTED_BRANCH_AT_COMMIT

  __GITHUB_STACK_BRANCHES=()
  while IFS= read -r __COMMIT; do
    __BRANCH_AT_COMMIT_COUNT=0
    __SELECTED_BRANCH_AT_COMMIT=""
    while IFS= read -r __BRANCH_AT_COMMIT; do
      if [[ "${__BRANCH_AT_COMMIT}" == "main" ]]; then
        continue
      fi
      __BRANCH_AT_COMMIT_COUNT=$((__BRANCH_AT_COMMIT_COUNT + 1))
      __SELECTED_BRANCH_AT_COMMIT="${__BRANCH_AT_COMMIT}"
    done < <(
      git for-each-ref \
        --points-at "${__COMMIT}" \
        --format='%(refname:short)' \
        refs/heads
    )

    if [[ ${__BRANCH_AT_COMMIT_COUNT} -gt 1 ]]; then
      __FAIL \
        "REBASE_STABLE_RELEASE_STACK_LAYER_AMBIGUOUS" \
        "More than one local branch points to feature commit '${__COMMIT}'."
    fi
    if [[ ${__BRANCH_AT_COMMIT_COUNT} -eq 1 ]]; then
      __GITHUB_STACK_BRANCHES[${#__GITHUB_STACK_BRANCHES[@]}]="${__SELECTED_BRANCH_AT_COMMIT}"
    fi
  done < <(git rev-list --reverse "main..${__ORIGINAL_FEATURE_BRANCH}")

  if [[ ${#__GITHUB_STACK_BRANCHES[@]} -eq 0 ]]; then
    __FAIL \
      "REBASE_STABLE_RELEASE_STACK_BRANCHES_MISSING" \
      "No local feature branches were found between main and '${__ORIGINAL_FEATURE_BRANCH}'."
  fi
  __LAST_BRANCH_INDEX=$((${#__GITHUB_STACK_BRANCHES[@]} - 1))
  if [[ "${__GITHUB_STACK_BRANCHES[${__LAST_BRANCH_INDEX}]}" != "${__ORIGINAL_FEATURE_BRANCH}" ]]; then
    __FAIL \
      "REBASE_STABLE_RELEASE_STACK_TOP_MISMATCH" \
      "The derived stack does not end at '${__ORIGINAL_FEATURE_BRANCH}'."
  fi
}

__GITHUB_STACK_MATCHES_LOCAL_BRANCHES() {
  local __ACTUAL_BRANCH
  local __ACTUAL_BRANCHES_OUTPUT
  local __ACTUAL_BASE_COMMIT
  local __ACTUAL_GITHUB_STACK_BASE_COMMITS=()
  local __ACTUAL_GITHUB_STACK_BRANCHES=()
  local __EXPECTED_BASE_COMMIT
  local __EXPECTED_BRANCH_INDEX=0
  local __STACK_OUTPUT="$1"

  if ! __ACTUAL_BRANCHES_OUTPUT="$(node -e '
const stack = JSON.parse(process.argv[1]);
if (!Array.isArray(stack.branches)) {
  process.exit(2);
}
for (const branch of stack.branches) {
  if (
    typeof branch !== "object" ||
    branch === null ||
    typeof branch.name !== "string" ||
    typeof branch.base !== "string"
  ) {
    process.exit(2);
  }
  process.stdout.write(branch.name + "\t" + branch.base + "\n");
}
' "${__STACK_OUTPUT}")"; then
    return 1
  fi

  while IFS=$'\t' read -r __ACTUAL_BRANCH __ACTUAL_BASE_COMMIT; do
    if [[ -n "${__ACTUAL_BRANCH}" ]]; then
      __ACTUAL_GITHUB_STACK_BRANCHES[${#__ACTUAL_GITHUB_STACK_BRANCHES[@]}]="${__ACTUAL_BRANCH}"
      __ACTUAL_GITHUB_STACK_BASE_COMMITS[${#__ACTUAL_GITHUB_STACK_BASE_COMMITS[@]}]="${__ACTUAL_BASE_COMMIT}"
    fi
  done <<<"${__ACTUAL_BRANCHES_OUTPUT}"

  if [[ ${#__ACTUAL_GITHUB_STACK_BRANCHES[@]} -ne ${#__GITHUB_STACK_BRANCHES[@]} ]]; then
    return 1
  fi
  while [[ ${__EXPECTED_BRANCH_INDEX} -lt ${#__GITHUB_STACK_BRANCHES[@]} ]]; do
    if [[ "${__ACTUAL_GITHUB_STACK_BRANCHES[${__EXPECTED_BRANCH_INDEX}]}" != "${__GITHUB_STACK_BRANCHES[${__EXPECTED_BRANCH_INDEX}]}" ]]; then
      return 1
    fi
    if [[ ${__EXPECTED_BRANCH_INDEX} -eq 0 ]]; then
      __EXPECTED_BASE_COMMIT="$(git rev-parse main)"
    else
      __EXPECTED_BASE_COMMIT="$(
        git rev-parse "${__GITHUB_STACK_BRANCHES[$((__EXPECTED_BRANCH_INDEX - 1))]}"
      )"
    fi
    if [[ "${__ACTUAL_GITHUB_STACK_BASE_COMMITS[${__EXPECTED_BRANCH_INDEX}]}" != "${__EXPECTED_BASE_COMMIT}" ]]; then
      return 1
    fi
    __EXPECTED_BRANCH_INDEX=$((__EXPECTED_BRANCH_INDEX + 1))
  done
  return 0
}

__ENSURE_GITHUB_STACK() {
  local __STACK_EXIT_CODE
  local __STACK_OUTPUT

  __DERIVE_GITHUB_STACK_BRANCHES
  set +o errexit
  __STACK_OUTPUT="$(gh stack view --json 2>&1)"
  __STACK_EXIT_CODE=$?
  set -o errexit

  if [[ ${__STACK_EXIT_CODE} -eq 0 ]] &&
    __GITHUB_STACK_MATCHES_LOCAL_BRANCHES "${__STACK_OUTPUT}"; then
    return 0
  fi

  if [[ ${__STACK_EXIT_CODE} -eq 0 ]]; then
    if ! gh stack unstack --local; then
      __FAIL \
        "REBASE_STABLE_RELEASE_STACK_LOCAL_REFRESH_FAILED" \
        "Could not remove stale local GitHub stack metadata."
    fi
  else
    if [[ "${__STACK_OUTPUT}" != *"is not part of a stack"* ]]; then
      printf '%s\n' "${__STACK_OUTPUT}" >&2
      __FAIL "REBASE_STABLE_RELEASE_STACK_CHECK_FAILED" "GitHub stack inspection failed."
    fi
  fi

  if ! gh stack init --base main "${__GITHUB_STACK_BRANCHES[@]}"; then
    __FAIL \
      "REBASE_STABLE_RELEASE_STACK_INIT_FAILED" \
      "Could not register the rebased feature branches as a GitHub stack."
  fi
  printf '%s\n' \
    "[REBASE_STABLE_RELEASE_STACK_INITIALIZED] Registered the rebased feature branches as a GitHub stack."
  if ! __STACK_OUTPUT="$(gh stack view --json)"; then
    __FAIL \
      "REBASE_STABLE_RELEASE_STACK_VERIFY_FAILED" \
      "Could not inspect the initialized GitHub stack."
  fi
  if ! __GITHUB_STACK_MATCHES_LOCAL_BRANCHES "${__STACK_OUTPUT}"; then
    __FAIL \
      "REBASE_STABLE_RELEASE_STACK_METADATA_MISMATCH" \
      "GitHub stack metadata does not match the local branch order and parent commits."
  fi
}

__SELECT_LATEST_STABLE_RELEASE_TAG() {
  local __REMOTE_TAG_REFERENCES="$1"
  local __LATEST_MAJOR=-1
  local __LATEST_MINOR=-1
  local __LATEST_PATCH=-1
  local __LATEST_TAG=""
  local __REFERENCE_LINE
  local __TAG_REFERENCE

  while IFS= read -r __REFERENCE_LINE; do
    __TAG_REFERENCE="${__REFERENCE_LINE#*$'\t'}"
    # Accept only stable semantic-version tags. Exclude nightly and preview suffixes.
    if [[ ! "${__TAG_REFERENCE}" =~ ^refs/tags/(v([0-9]+)\.([0-9]+)\.([0-9]+))$ ]]; then
      continue
    fi

    local __TAG="${BASH_REMATCH[1]}"
    local __MAJOR=$((10#${BASH_REMATCH[2]}))
    local __MINOR=$((10#${BASH_REMATCH[3]}))
    local __PATCH=$((10#${BASH_REMATCH[4]}))
    if (( __MAJOR > __LATEST_MAJOR )) ||
      { (( __MAJOR == __LATEST_MAJOR )) && (( __MINOR > __LATEST_MINOR )); } ||
      { (( __MAJOR == __LATEST_MAJOR )) && (( __MINOR == __LATEST_MINOR )) && (( __PATCH > __LATEST_PATCH )); }; then
      __LATEST_MAJOR="${__MAJOR}"
      __LATEST_MINOR="${__MINOR}"
      __LATEST_PATCH="${__PATCH}"
      __LATEST_TAG="${__TAG}"
    fi
  done <<<"${__REMOTE_TAG_REFERENCES}"

  if [[ -z "${__LATEST_TAG}" ]]; then
    __FAIL \
      "REBASE_STABLE_RELEASE_TAG_MISSING" \
      "Upstream has no stable vMAJOR.MINOR.PATCH tag."
  fi
  printf '%s\n' "${__LATEST_TAG}"
}

__RESOLVE_STABLE_RELEASE() {
  local __REMOTE_TAG_REFERENCES

  if ! __REMOTE_TAG_REFERENCES="$(__RUN_GIT_WITH_SSH_RETRY ls-remote --tags --refs upstream 'refs/tags/v*')"; then
    __FAIL \
      "REBASE_STABLE_RELEASE_TAG_LIST_FAILED" \
      "Could not list upstream stable release tags."
  fi
  __STABLE_RELEASE_TAG="$(__SELECT_LATEST_STABLE_RELEASE_TAG "${__REMOTE_TAG_REFERENCES}")"
  if ! __RUN_GIT_WITH_SSH_RETRY fetch upstream \
    "+refs/tags/${__STABLE_RELEASE_TAG}:refs/rebase-stable-release/upstream-tag"; then
    __FAIL \
      "REBASE_STABLE_RELEASE_TAG_FETCH_FAILED" \
      "Could not fetch upstream tag '${__STABLE_RELEASE_TAG}'."
  fi
  __STABLE_RELEASE_COMMIT="$(git rev-parse 'refs/rebase-stable-release/upstream-tag^{commit}')"
  if ! git merge-base --is-ancestor "${__STABLE_RELEASE_COMMIT}" upstream/main; then
    __FAIL \
      "REBASE_STABLE_RELEASE_TAG_NOT_ON_UPSTREAM_MAIN" \
      "Stable tag '${__STABLE_RELEASE_TAG}' is not an ancestor of upstream/main."
  fi
}

__FIND_GENERATED_RELEASE_COMMIT() {
  local __COMMIT
  local __SUBJECT

  while IFS=$'\t' read -r __COMMIT __SUBJECT; do
    # Match only commits generated by this workflow. The version remains variable.
    if [[ "${__SUBJECT}" =~ ^chore\(release\):\ pin\ package\ versions\ to\ v[0-9]+\.[0-9]+\.[0-9]+\ \[fork-generated\]$ ]]; then
      printf '%s\n' "${__COMMIT}"
      return 0
    fi
  done < <(git log --first-parent --format='%H%x09%s' origin/main)

  return 1
}

__CREATE_GENERATED_RELEASE_COMMIT() {
  local __CHANGED_FILE
  local __RELEASE_VERSION="${__STABLE_RELEASE_TAG#v}"

  if ! git branch --force main "${__STABLE_RELEASE_COMMIT}"; then
    __FAIL \
      "REBASE_STABLE_RELEASE_LOCAL_MAIN_UPDATE_FAILED" \
      "Could not make local main start at '${__STABLE_RELEASE_TAG}'."
  fi
  if ! git switch main; then
    __FAIL "REBASE_STABLE_RELEASE_MAIN_SWITCH_FAILED" "Could not switch to local main."
  fi
  if ! node - "${__RELEASE_VERSION}" <<'NODE'; then
const NodeFileSystem = require("node:fs");

const releaseVersion = process.argv[2];
const releasePackageFiles = [
  "apps/server/package.json",
  "apps/desktop/package.json",
  "apps/web/package.json",
  "packages/contracts/package.json",
];

for (const releasePackageFile of releasePackageFiles) {
  const packageJson = JSON.parse(NodeFileSystem.readFileSync(releasePackageFile, "utf8"));
  const releasePackageJson = { ...packageJson, version: releaseVersion };
  NodeFileSystem.writeFileSync(
    releasePackageFile,
    `${JSON.stringify(releasePackageJson, null, 2)}\n`,
  );
}
NODE
    __FAIL \
      "REBASE_STABLE_RELEASE_VERSION_UPDATE_FAILED" \
      "Could not align package versions with '${__STABLE_RELEASE_TAG}'."
  fi

  while IFS= read -r __CHANGED_FILE; do
    case "${__CHANGED_FILE}" in
      apps/server/package.json | apps/desktop/package.json | apps/web/package.json | packages/contracts/package.json) ;;
      *)
        __FAIL \
          "REBASE_STABLE_RELEASE_VERSION_UPDATE_SCOPE_INVALID" \
          "The release version update changed unexpected file '${__CHANGED_FILE}'."
        ;;
    esac
  done < <(git diff --name-only)

  git add -- \
    apps/server/package.json \
    apps/desktop/package.json \
    apps/web/package.json \
    packages/contracts/package.json
  if ! git commit \
    --allow-empty \
    -m "chore(release): pin package versions to ${__STABLE_RELEASE_TAG} [fork-generated]" \
    -m "Regenerated by the stable-release rebase workflow to match the version metadata used by official release CI."; then
    __FAIL \
      "REBASE_STABLE_RELEASE_VERSION_COMMIT_FAILED" \
      "Could not create the signed generated release commit."
  fi
  __GENERATED_RELEASE_COMMIT="$(git rev-parse HEAD)"
}

__START() {
  local __FORK_MAIN_COMMIT_COUNT
  local __GENERATED_RELEASE_COMMIT_ON_ORIGIN_MAIN=""
  local __GENERATED_RELEASE_COMMIT_PARENT=""
  local __GENERATED_RELEASE_COMMIT_SUBJECT=""
  local __LOCAL_MAIN_FEATURE_STACK_BASE_COMMIT
  local __LOCAL_MAIN_UNPUBLISHED_COMMIT_COUNT
  local __ORIGIN_MAIN_FEATURE_STACK_BASE_COMMIT
  local __WORKTREE_STATUS

  __REQUIRE_ORIGIN_MAIN_PUSH_AUTHORIZATION
  if [[ -e "${__STATE_PATH}" || -e "${__RESUME_SCRIPT_PATH}" ]]; then
    __FAIL \
      "REBASE_STABLE_RELEASE_STALE_OPERATION_FILES" \
      "A previous rebase-stable-release operation did not finish cleanly."
  fi
  __ORIGINAL_FEATURE_BRANCH="$(git branch --show-current)"
  if [[ -z "${__ORIGINAL_FEATURE_BRANCH}" ]]; then
    __FAIL "REBASE_STABLE_RELEASE_DETACHED_HEAD" "Check out a feature branch before running the script."
  fi
  if [[ "${__ORIGINAL_FEATURE_BRANCH}" == "main" ]]; then
    __FAIL "REBASE_STABLE_RELEASE_MAIN_SELECTED" "Run the script from the feature branch to rebase."
  fi

  __WORKTREE_STATUS="$(git status --porcelain)"
  if [[ -n "${__WORKTREE_STATUS}" ]]; then
    printf '%s\n' "${__WORKTREE_STATUS}" >&2
    __FAIL "REBASE_STABLE_RELEASE_DIRTY_WORKTREE" "Commit or stash worktree changes before rebasing."
  fi

  if __HAS_REBASE_IN_PROGRESS; then
    __FAIL "REBASE_STABLE_RELEASE_UNEXPECTED_REBASE" "An unrelated rebase is already in progress."
  fi

  git remote get-url origin >/dev/null
  git remote get-url upstream >/dev/null
  __INSPECT_GITHUB_STACK

  if ! __RUN_GIT_WITH_SSH_RETRY fetch origin main; then
    __FAIL "REBASE_STABLE_RELEASE_ORIGIN_FETCH_FAILED" "Could not fetch origin/main."
  fi
  if ! __RUN_GIT_WITH_SSH_RETRY fetch upstream main; then
    __FAIL "REBASE_STABLE_RELEASE_UPSTREAM_FETCH_FAILED" "Could not fetch upstream/main."
  fi
  __RESOLVE_STABLE_RELEASE

  __LOCAL_MAIN_UNPUBLISHED_COMMIT_COUNT="$(
    git rev-list --count main --not origin/main upstream/main
  )"
  if [[ "${__LOCAL_MAIN_UNPUBLISHED_COMMIT_COUNT}" != "0" ]]; then
    git log --oneline main --not origin/main upstream/main >&2
    __FAIL \
      "REBASE_STABLE_RELEASE_LOCAL_MAIN_UNPUBLISHED" \
      "Local main contains ${__LOCAL_MAIN_UNPUBLISHED_COMMIT_COUNT} commit(s) that are absent from both remotes."
  fi

  __INSTALL_RESUME_SCRIPT
  __EXPECTED_ORIGIN_MAIN_COMMIT="$(git rev-parse refs/remotes/origin/main)"
  __LOCAL_MAIN_FEATURE_STACK_BASE_COMMIT="$(
    git merge-base main "${__ORIGINAL_FEATURE_BRANCH}"
  )"
  __ORIGIN_MAIN_FEATURE_STACK_BASE_COMMIT="$(
    git merge-base origin/main "${__ORIGINAL_FEATURE_BRANCH}"
  )"
  if [[ -z "${__LOCAL_MAIN_FEATURE_STACK_BASE_COMMIT}" ]] ||
    [[ -z "${__ORIGIN_MAIN_FEATURE_STACK_BASE_COMMIT}" ]]; then
    __CLEAR_OPERATION_FILES
    __FAIL \
      "REBASE_STABLE_RELEASE_FEATURE_STACK_BASE_MISSING" \
      "Could not find the feature stack base on local main."
  fi
  if git merge-base --is-ancestor \
    "${__LOCAL_MAIN_FEATURE_STACK_BASE_COMMIT}" \
    "${__ORIGIN_MAIN_FEATURE_STACK_BASE_COMMIT}"; then
    __FEATURE_STACK_BASE_COMMIT="${__ORIGIN_MAIN_FEATURE_STACK_BASE_COMMIT}"
  else
    __FEATURE_STACK_BASE_COMMIT="${__LOCAL_MAIN_FEATURE_STACK_BASE_COMMIT}"
  fi

  if __GENERATED_RELEASE_COMMIT_ON_ORIGIN_MAIN="$(__FIND_GENERATED_RELEASE_COMMIT)"; then
    __FORK_MAIN_BASE_COMMIT="${__GENERATED_RELEASE_COMMIT_ON_ORIGIN_MAIN}"
  else
    __FORK_MAIN_BASE_COMMIT="$(git merge-base origin/main upstream/main)"
  fi
  if [[ -z "${__FORK_MAIN_BASE_COMMIT}" ]]; then
    __CLEAR_OPERATION_FILES
    __FAIL \
      "REBASE_STABLE_RELEASE_FORK_MAIN_BASE_MISSING" \
      "Could not identify the fork-only commits on origin/main."
  fi

  if [[ -n "${__GENERATED_RELEASE_COMMIT_ON_ORIGIN_MAIN}" ]]; then
    __GENERATED_RELEASE_COMMIT_SUBJECT="$(
      git show --no-patch --format='%s' "${__GENERATED_RELEASE_COMMIT_ON_ORIGIN_MAIN}"
    )"
    if [[ "${__GENERATED_RELEASE_COMMIT_SUBJECT}" == "chore(release): pin package versions to ${__STABLE_RELEASE_TAG} [fork-generated]" ]]; then
      __GENERATED_RELEASE_COMMIT_PARENT="$(
        git rev-parse "${__GENERATED_RELEASE_COMMIT_ON_ORIGIN_MAIN}^"
      )"
      if [[ "${__GENERATED_RELEASE_COMMIT_PARENT}" != "${__STABLE_RELEASE_COMMIT}" ]]; then
        __CLEAR_OPERATION_FILES
        __FAIL \
          "REBASE_STABLE_RELEASE_GENERATED_COMMIT_BASE_INVALID" \
          "The generated ${__STABLE_RELEASE_TAG} commit is not directly above its stable tag."
      fi
      __GENERATED_RELEASE_COMMIT="${__GENERATED_RELEASE_COMMIT_ON_ORIGIN_MAIN}"
      if ! git branch --force main refs/remotes/origin/main; then
        __CLEAR_OPERATION_FILES
        __FAIL \
          "REBASE_STABLE_RELEASE_LOCAL_MAIN_UPDATE_FAILED" \
          "Could not make local main match the existing stable fork main."
      fi
      __DID_CREATE_UNSIGNED_COMMIT="false"
      __PHASE="push_origin_main"
      __WRITE_STATE
      return 0
    fi
  fi

  __DID_CREATE_UNSIGNED_COMMIT="false"
  __PHASE="create_generated_release_commit"
  __WRITE_STATE
  __CREATE_GENERATED_RELEASE_COMMIT

  __FORK_MAIN_COMMIT_COUNT="$(
    git rev-list --count origin/main "^${__FORK_MAIN_BASE_COMMIT}"
  )"
  if [[ "${__FORK_MAIN_COMMIT_COUNT}" == "0" ]]; then
    __PHASE="push_origin_main"
    __WRITE_STATE
    return 0
  fi

  if ! git switch "${__ORIGINAL_FEATURE_BRANCH}"; then
    __FAIL \
      "REBASE_STABLE_RELEASE_FEATURE_SWITCH_FAILED" \
      "Could not return to '${__ORIGINAL_FEATURE_BRANCH}' before preparing fork main."
  fi
  if ! git branch --force main refs/remotes/origin/main; then
    __FAIL \
      "REBASE_STABLE_RELEASE_LOCAL_MAIN_RESTORE_FAILED" \
      "Could not restore local main from origin/main before rebasing fork-only commits."
  fi
  if ! git switch main; then
    __FAIL "REBASE_STABLE_RELEASE_MAIN_SWITCH_FAILED" "Could not switch to local main."
  fi
  __PHASE="rebase_fork_main_onto_stable_release"
  __WRITE_STATE
}

__RESUME() {
  if [[ ! -f "${__STATE_PATH}" ]]; then
    __FAIL "REBASE_STABLE_RELEASE_STATE_MISSING" "No saved rebase-stable-release operation exists."
  fi

  __READ_STATE
  if [[ "${__PHASE}" == "idle" || -z "${__ORIGINAL_FEATURE_BRANCH}" ]] ||
    [[ -z "${__FEATURE_STACK_BASE_COMMIT}" ]] ||
    [[ -z "${__STABLE_RELEASE_TAG}" ]] ||
    [[ -z "${__STABLE_RELEASE_COMMIT}" ]] ||
    [[ -z "${__FORK_MAIN_BASE_COMMIT}" ]] ||
    [[ -z "${__GENERATED_RELEASE_COMMIT}" ]]; then
    __FAIL "REBASE_STABLE_RELEASE_STATE_IDLE" "No rebase-stable-release operation needs continuation."
  fi
  if ! __HAS_REBASE_IN_PROGRESS; then
    __FAIL "REBASE_STABLE_RELEASE_REBASE_MISSING" "Git has no active rebase to continue."
  fi
  __VERIFY_ACTIVE_REBASE_BRANCH
  if [[ "${__PHASE}" != "rebase_feature_stack_onto_main" ]]; then
    __REQUIRE_ORIGIN_MAIN_PUSH_AUTHORIZATION
  fi
  if [[ -n "$(git diff --name-only --diff-filter=U)" ]]; then
    __REPORT_CONFLICT
  fi

  __CONTINUE_CURRENT_REBASE
  case "${__PHASE}" in
    rebase_fork_main_onto_stable_release)
      __PHASE="push_origin_main"
      ;;
    rebase_feature_stack_onto_main)
      __PHASE="verify_feature_stack"
      ;;
    *)
      __FAIL \
        "REBASE_STABLE_RELEASE_CONTINUED_PHASE_INVALID" \
        "Continued phase '${__PHASE}' cannot advance."
      ;;
  esac
  __WRITE_STATE
}

__RUN_REMAINING_PHASES() {
  local __FEATURE_COMMIT
  local __FEATURE_COMMIT_SIGNATURE_STATUS

  while true; do
    case "${__PHASE}" in
      rebase_fork_main_onto_stable_release)
        __REBASE_ONTO "${__GENERATED_RELEASE_COMMIT}"
        __PHASE="push_origin_main"
        __WRITE_STATE
        ;;
      push_origin_main)
        __REQUIRE_ORIGIN_MAIN_PUSH_AUTHORIZATION
        if ! __RUN_GIT_WITH_SSH_RETRY push \
          "--force-with-lease=refs/heads/main:${__EXPECTED_ORIGIN_MAIN_COMMIT}" \
          origin main:main; then
          __FAIL \
            "REBASE_STABLE_RELEASE_ORIGIN_MAIN_PUSH_FAILED" \
            "Could not update origin/main. The force-with-lease guard remains active."
        fi
        if [[ "$(git rev-parse refs/remotes/origin/main)" != "$(git rev-parse refs/heads/main)" ]]; then
          __FAIL "REBASE_STABLE_RELEASE_ORIGIN_MAIN_MISMATCH" "origin/main does not match local main."
        fi
        __PHASE="rebase_feature_stack_onto_main"
        __WRITE_STATE
        git switch "${__ORIGINAL_FEATURE_BRANCH}"
        ;;
      rebase_feature_stack_onto_main)
        __REBASE_ONTO main
        __PHASE="verify_feature_stack"
        __WRITE_STATE
        ;;
      verify_feature_stack)
        if ! git merge-base --is-ancestor main HEAD; then
          __FAIL \
            "REBASE_STABLE_RELEASE_FEATURE_BASE_MISMATCH" \
            "The feature branch does not contain the synchronized local main."
        fi
        if [[ -n "$(git status --porcelain)" ]]; then
          __FAIL "REBASE_STABLE_RELEASE_FINAL_WORKTREE_DIRTY" "The final worktree is not clean."
        fi
        __ENSURE_GITHUB_STACK
        __CLEAR_OPERATION_FILES
        printf '%s\n' \
          "[REBASE_STABLE_RELEASE_COMPLETE] origin/main reproduces ${__STABLE_RELEASE_TAG} with fork-only main commits." \
          "[REBASE_STABLE_RELEASE_COMPLETE] The GitHub stack through ${__ORIGINAL_FEATURE_BRANCH} is rebased onto local main."
        if [[ "${__DID_CREATE_UNSIGNED_COMMIT}" == "true" ]]; then
          while IFS=' ' read -r __FEATURE_COMMIT __FEATURE_COMMIT_SIGNATURE_STATUS; do
            if [[ "${__FEATURE_COMMIT_SIGNATURE_STATUS}" == "N" ]]; then
              printf '%s\n' \
                "[REBASE_STABLE_RELEASE_UNSIGNED_COMMIT] ${__FEATURE_COMMIT}" >&2
            fi
          done < <(git log --format='%H %G?' main..HEAD)
        fi
        return 0
        ;;
      *)
        __FAIL "REBASE_STABLE_RELEASE_STATE_INVALID" "Saved phase '${__PHASE}' is not valid."
        ;;
    esac
  done
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  __PRINT_USAGE
  exit 0
fi
if [[ $# -gt 1 ]]; then
  __PRINT_USAGE >&2
  exit 2
fi
if [[ $# -eq 1 && "$1" != "--continue" ]]; then
  __PRINT_USAGE >&2
  exit 2
fi
git -h >/dev/null
gh stack view --help >/dev/null
gh stack init --help >/dev/null
gh stack unstack --help >/dev/null
node --help >/dev/null
trash --help >/dev/null
chmod --help >/dev/null 2>&1 || true
cp --help >/dev/null 2>&1 || true

__REPOSITORY_ROOT="$(git rev-parse --show-toplevel)"
cd "${__REPOSITORY_ROOT}"
__GIT_DIRECTORY="$(git rev-parse --git-dir)"
__STATE_PATH="${__GIT_DIRECTORY}/rebase-stable-release-state"
__RESUME_SCRIPT_PATH="${__GIT_DIRECTORY}/rebase-stable-release-resume.bash"
__REBASE_GPG_SIGN_OPTION_PATH="$(git rev-parse --git-path rebase-merge/gpg_sign_opt)"
__PHASE=""
__ORIGINAL_FEATURE_BRANCH=""
__EXPECTED_ORIGIN_MAIN_COMMIT=""
__DID_CREATE_UNSIGNED_COMMIT="false"
__FEATURE_STACK_BASE_COMMIT=""
__STABLE_RELEASE_TAG=""
__STABLE_RELEASE_COMMIT=""
__FORK_MAIN_BASE_COMMIT=""
__GENERATED_RELEASE_COMMIT=""
__GITHUB_STACK_BRANCHES=()

if [[ "${1:-}" == "--continue" ]]; then
  __RESUME
else
  __START
fi

__RUN_REMAINING_PHASES
