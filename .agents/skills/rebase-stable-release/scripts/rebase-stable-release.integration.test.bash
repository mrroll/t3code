#!/usr/bin/env bash

set -o errexit
set -o pipefail
set -o nounset

IFS=$'\n\t'

if [[ "${REBASE_STABLE_RELEASE_GH_STUB_MODE:-}" == "unstacked" ]]; then
  if [[ $# -eq 3 && "$1" == "stack" ]] &&
    { [[ "$2" == "view" ]] || [[ "$2" == "init" ]] || [[ "$2" == "unstack" ]]; } &&
    [[ "$3" == "--help" ]]; then
    exit 0
  fi
  __GH_STUB_STATE_PATH="$(git rev-parse --git-dir)/rebase-stable-release-test-stack"
  if [[ $# -eq 3 && "$1" == "stack" && "$2" == "view" && "$3" == "--json" ]]; then
    if [[ ! -f "${__GH_STUB_STATE_PATH}" ]]; then
      printf '%s\n' "current branch is not part of a stack" >&2
      exit 1
    fi
    node -e '
const NodeFileSystem = require("node:fs");
const branches = NodeFileSystem.readFileSync(process.argv[1], "utf8")
  .trim()
  .split("\n")
  .map((line) => {
    const [name, base] = line.split("\t");
    return { name, base };
  });
process.stdout.write(JSON.stringify({ branches }));
' "${__GH_STUB_STATE_PATH}"
    exit 0
  fi
  if [[ $# -ge 5 && "$1" == "stack" && "$2" == "init" && "$3" == "--base" && "$4" == "main" ]]; then
    shift 4
    __GH_STUB_BASE_BRANCH="main"
    : >"${__GH_STUB_STATE_PATH}"
    for __GH_STUB_BRANCH in "$@"; do
      printf '%s\t%s\n' \
        "${__GH_STUB_BRANCH}" \
        "$(git rev-parse "${__GH_STUB_BASE_BRANCH}")" >>"${__GH_STUB_STATE_PATH}"
      __GH_STUB_BASE_BRANCH="${__GH_STUB_BRANCH}"
    done
    exit 0
  fi
  if [[ $# -eq 3 && "$1" == "stack" && "$2" == "unstack" && "$3" == "--local" ]]; then
    mv "${__GH_STUB_STATE_PATH}" "${__GH_STUB_STATE_PATH}.stale"
    exit 0
  fi
  exit 1
fi

__DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
__SCRIPT_PATH="${__DIRECTORY}/${BASH_SOURCE[0]##*/}"
cd "${__DIRECTORY}"

git -h >/dev/null
trash --help >/dev/null
chmod --help >/dev/null 2>&1 || true
cp --help >/dev/null 2>&1 || true
mkdir --help >/dev/null 2>&1 || true
mktemp --help >/dev/null 2>&1 || true
__TEST_ROOT="$(mktemp -d)"
trap 'trash "${__TEST_ROOT}"' EXIT
__STUB_DIRECTORY="${__TEST_ROOT}/bin"
mkdir -p "${__STUB_DIRECTORY}"
cp "${__SCRIPT_PATH}" "${__STUB_DIRECTORY}/gh"
chmod +x "${__STUB_DIRECTORY}/gh"
PATH="${__STUB_DIRECTORY}:${PATH}"
REBASE_STABLE_RELEASE_GH_STUB_MODE="unstacked"
export PATH
export REBASE_STABLE_RELEASE_GH_STUB_MODE

__CONFIGURE_REPOSITORY() {
  git config user.name "Rebase Skill Test"
  git config user.email "rebase-skill-test@example.invalid"
  git config commit.gpgsign false
}

__CREATE_STABLE_RELEASE_BASE() {
  mkdir -p apps/server apps/desktop apps/web packages/contracts
  for __PACKAGE_FILE in \
    apps/server/package.json \
    apps/desktop/package.json \
    apps/web/package.json \
    packages/contracts/package.json; do
    printf '%s\n' '{"name":"release-test","version":"0.9.0"}' >"${__PACKAGE_FILE}"
  done
  git add apps packages conflict.txt
  git commit --no-gpg-sign -m "test: add stable release base" >/dev/null
  git tag v1.0.0
}

__ENABLE_UNAVAILABLE_COMMIT_SIGNING() {
  git config commit.gpgsign true
  git config gpg.format openpgp
  git config rebase.gpgSign true
  git config user.signingkey "rebase-skill-test-missing-key"
}

__COPY_SCRIPT_TO_REPOSITORY() {
  local __REPOSITORY_PATH="$1"

  cp "${__DIRECTORY}/rebase-stable-release.bash" "${__REPOSITORY_PATH}/rebase-stable-release.bash"
  chmod +x "${__REPOSITORY_PATH}/rebase-stable-release.bash"
  git add rebase-stable-release.bash
  git commit --no-gpg-sign -m "test: add rebase script" >/dev/null
}

__WRITE_CONFLICT_CONTENT() {
  local __CONTENT="$1"

  printf '%s\n' "${__CONTENT}" >conflict.txt
}

__RUN_EXPECTING_CONFLICT() {
  local __EXPECTED_PHASE="$1"
  local __COMMAND_OUTPUT
  local __COMMAND_EXIT_CODE

  set +o errexit
  __COMMAND_OUTPUT="$(MRROLL_REMOTE_WRITE_AUTHORIZED=1 ./rebase-stable-release.bash 2>&1)"
  __COMMAND_EXIT_CODE=$?
  set -o errexit

  if [[ ${__COMMAND_EXIT_CODE} -ne 20 ]]; then
    printf '%s\n' "Expected rebase conflict exit code 20." >&2
    printf '%s\n' "${__COMMAND_OUTPUT}" >&2
    exit 1
  fi
  if [[ "${__COMMAND_OUTPUT}" != *"Git stopped during phase '${__EXPECTED_PHASE}'"* ]]; then
    printf '%s\n' "Expected conflict phase '${__EXPECTED_PHASE}'." >&2
    printf '%s\n' "${__COMMAND_OUTPUT}" >&2
    exit 1
  fi
}

__VERIFY_COMPLETED_FEATURE_BRANCH() {
  local __EXPECTED_FEATURE_BRANCH="$1"
  local __RESUME_SCRIPT_PATH
  local __STATE_PATH

  if [[ "$(git branch --show-current)" != "${__EXPECTED_FEATURE_BRANCH}" ]]; then
    printf '%s\n' "The script did not return to '${__EXPECTED_FEATURE_BRANCH}'." >&2
    exit 1
  fi
  git merge-base --is-ancestor main HEAD
  __STATE_PATH="$(git rev-parse --git-dir)/rebase-stable-release-state"
  __RESUME_SCRIPT_PATH="$(git rev-parse --git-dir)/rebase-stable-release-resume.bash"
  if [[ -e "${__STATE_PATH}" ]]; then
    printf '%s\n' "Completed operation state still exists." >&2
    exit 1
  fi
  if [[ -e "${__RESUME_SCRIPT_PATH}" ]]; then
    printf '%s\n' "Completed resume script still exists." >&2
    exit 1
  fi
  if [[ -n "$(git status --porcelain)" ]]; then
    git status --short >&2
    exit 1
  fi
  if ! gh stack view --json >/dev/null; then
    printf '%s\n' "The completed feature branch is not registered as a GitHub stack." >&2
    exit 1
  fi
}

__TEST_MAIN_REBASE_CONFLICT() {
  local __CASE_ROOT="${__TEST_ROOT}/main-conflict"
  local __WORK_REPOSITORY="${__CASE_ROOT}/work"
  local __COMMAND_OUTPUT
  local __COMMAND_EXIT_CODE
  local __RESUME_SCRIPT_PATH

  mkdir -p "${__CASE_ROOT}"
  git init --bare "${__CASE_ROOT}/origin.git" >/dev/null
  git init --bare "${__CASE_ROOT}/upstream.git" >/dev/null
  git init --initial-branch=main "${__WORK_REPOSITORY}" >/dev/null
  cd "${__WORK_REPOSITORY}"
  __CONFIGURE_REPOSITORY
  __WRITE_CONFLICT_CONTENT "base"
  __CREATE_STABLE_RELEASE_BASE
  git remote add origin "${__CASE_ROOT}/origin.git"
  git remote add upstream "${__CASE_ROOT}/upstream.git"
  git push --quiet origin main
  git push --quiet upstream main v1.0.0

  for __PACKAGE_FILE in \
    apps/server/package.json \
    apps/desktop/package.json \
    apps/web/package.json \
    packages/contracts/package.json; do
    printf '%s\n' '{"name":"release-test","version":"1.0.0"}' >"${__PACKAGE_FILE}"
  done
  git add apps packages
  git commit \
    --no-gpg-sign \
    -m "chore(release): pin package versions to v1.0.0 [fork-generated]" >/dev/null

  git switch --quiet --create origin-main-update
  __WRITE_CONFLICT_CONTENT "origin main"
  git commit --all --no-gpg-sign -m "test: change origin main" >/dev/null
  git push --quiet origin HEAD:main

  git switch --quiet --create feature-main-conflict
  __WRITE_CONFLICT_CONTENT "feature after origin main"
  git commit --all --no-gpg-sign -m "test: change feature after origin main" >/dev/null

  git switch --quiet --create upstream-main-update v1.0.0
  __WRITE_CONFLICT_CONTENT "upstream main"
  git commit --all --no-gpg-sign -m "test: change upstream main" >/dev/null
  git tag v1.1.0
  git push --quiet upstream HEAD:main
  git push --quiet upstream v1.1.0
  git switch --quiet feature-main-conflict
  __COPY_SCRIPT_TO_REPOSITORY "${__WORK_REPOSITORY}"

  __RUN_EXPECTING_CONFLICT "rebase_fork_main_onto_stable_release"
  __RESUME_SCRIPT_PATH="$(git rev-parse --git-dir)/rebase-stable-release-resume.bash"
  __WRITE_CONFLICT_CONTENT "resolved main"
  git add conflict.txt

  set +o errexit
  __COMMAND_OUTPUT="$("${__RESUME_SCRIPT_PATH}" --continue 2>&1)"
  __COMMAND_EXIT_CODE=$?
  set -o errexit
  if [[ ${__COMMAND_EXIT_CODE} -ne 1 ]] ||
    [[ "${__COMMAND_OUTPUT}" != *"REBASE_STABLE_RELEASE_REMOTE_WRITE_NOT_AUTHORIZED"* ]]; then
    printf '%s\n' "Expected main-phase continuation to require authorization." >&2
    printf '%s\n' "${__COMMAND_OUTPUT}" >&2
    exit 1
  fi

  set +o errexit
  __COMMAND_OUTPUT="$(
    MRROLL_REMOTE_WRITE_AUTHORIZED=1 "${__RESUME_SCRIPT_PATH}" --continue 2>&1
  )"
  __COMMAND_EXIT_CODE=$?
  set -o errexit
  if [[ ${__COMMAND_EXIT_CODE} -ne 20 ]] ||
    [[ "${__COMMAND_OUTPUT}" != *"rebase_feature_stack_onto_main"* ]]; then
    printf '%s\n' "Expected the operation to reach a feature-branch conflict." >&2
    printf '%s\n' "${__COMMAND_OUTPUT}" >&2
    exit 1
  fi

  __WRITE_CONFLICT_CONTENT "resolved feature after main"
  git add conflict.txt
  set +o errexit
  __COMMAND_OUTPUT="$("${__RESUME_SCRIPT_PATH}" --continue 2>&1)"
  __COMMAND_EXIT_CODE=$?
  set -o errexit
  if [[ ${__COMMAND_EXIT_CODE} -ne 0 ]]; then
    printf '%s\n' "Expected feature-stack continuation to complete." >&2
    printf '%s\n' "${__COMMAND_OUTPUT}" >&2
    exit 1
  fi
  __VERIFY_COMPLETED_FEATURE_BRANCH "feature-main-conflict"
}

__TEST_FEATURE_REBASE_CONFLICT() {
  local __CASE_ROOT="${__TEST_ROOT}/feature-conflict"
  local __WORK_REPOSITORY="${__CASE_ROOT}/work"
  local __RESUME_SCRIPT_PATH

  mkdir -p "${__CASE_ROOT}"
  git init --bare "${__CASE_ROOT}/origin.git" >/dev/null
  git init --bare "${__CASE_ROOT}/upstream.git" >/dev/null
  git init --initial-branch=main "${__WORK_REPOSITORY}" >/dev/null
  cd "${__WORK_REPOSITORY}"
  __CONFIGURE_REPOSITORY
  __WRITE_CONFLICT_CONTENT "base"
  __CREATE_STABLE_RELEASE_BASE
  git remote add origin "${__CASE_ROOT}/origin.git"
  git remote add upstream "${__CASE_ROOT}/upstream.git"
  git push --quiet origin main
  git push --quiet upstream main v1.0.0

  git switch --quiet --create feature-conflict
  __WRITE_CONFLICT_CONTENT "feature"
  git commit --all --no-gpg-sign -m "test: change feature" >/dev/null

  git switch --quiet --create origin-main-update main
  __WRITE_CONFLICT_CONTENT "fork main"
  git commit --all --no-gpg-sign -m "test: change fork main" >/dev/null
  git push --quiet origin HEAD:main
  git switch --quiet feature-conflict
  git branch --force main feature-conflict~1
  __COPY_SCRIPT_TO_REPOSITORY "${__WORK_REPOSITORY}"

  __RUN_EXPECTING_CONFLICT "rebase_feature_stack_onto_main"
  __RESUME_SCRIPT_PATH="$(git rev-parse --git-dir)/rebase-stable-release-resume.bash"
  __WRITE_CONFLICT_CONTENT "resolved feature"
  git add conflict.txt
  __ENABLE_UNAVAILABLE_COMMIT_SIGNING
  printf '%s\n' "-S" >"$(git rev-parse --git-path rebase-merge/gpg_sign_opt)"
  __COMMAND_OUTPUT="$("${__RESUME_SCRIPT_PATH}" --continue 2>&1)"
  if [[ "${__COMMAND_OUTPUT}" != *"REBASE_STABLE_RELEASE_UNSIGNED_COMMIT"* ]]; then
    printf '%s\n' "Expected the feature branch to report its unsigned fallback." >&2
    printf '%s\n' "${__COMMAND_OUTPUT}" >&2
    exit 1
  fi
  __VERIFY_COMPLETED_FEATURE_BRANCH "feature-conflict"
}

__TEST_MAIN_REBASE_CONFLICT
__TEST_FEATURE_REBASE_CONFLICT
printf '%s\n' "Main and feature conflict continuations passed."
