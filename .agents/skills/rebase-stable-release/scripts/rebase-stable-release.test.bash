#!/usr/bin/env bash

set -o errexit
set -o pipefail
set -o nounset

IFS=$'\n\t'

if [[ "${REBASE_STABLE_RELEASE_GH_STUB_MODE:-}" == "stacked" ]]; then
  if [[ $# -eq 3 && "$1" == "stack" ]] &&
    { [[ "$2" == "view" ]] || [[ "$2" == "init" ]] || [[ "$2" == "unstack" ]]; } &&
    [[ "$3" == "--help" ]]; then
    exit 0
  fi
  if [[ $# -eq 3 && "$1" == "stack" && "$2" == "view" && "$3" == "--json" ]]; then
    if [[ ! -f "${REBASE_STABLE_RELEASE_GH_STATE_PATH}" ]]; then
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
' "${REBASE_STABLE_RELEASE_GH_STATE_PATH}"
    exit 0
  fi
  if [[ $# -ge 5 && "$1" == "stack" && "$2" == "init" && "$3" == "--base" && "$4" == "main" ]]; then
    shift 4
    __GH_STUB_BASE_BRANCH="main"
    : >"${REBASE_STABLE_RELEASE_GH_STATE_PATH}"
    for __GH_STUB_BRANCH in "$@"; do
      printf '%s\t%s\n' \
        "${__GH_STUB_BRANCH}" \
        "$(git rev-parse "${__GH_STUB_BASE_BRANCH}")" >>"${REBASE_STABLE_RELEASE_GH_STATE_PATH}"
      __GH_STUB_BASE_BRANCH="${__GH_STUB_BRANCH}"
    done
    exit 0
  fi
  if [[ $# -eq 3 && "$1" == "stack" && "$2" == "unstack" && "$3" == "--local" ]]; then
    mv "${REBASE_STABLE_RELEASE_GH_STATE_PATH}" "${REBASE_STABLE_RELEASE_GH_STATE_PATH}.stale"
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
__WORK_REPOSITORY="${__TEST_ROOT}/work"
mkdir -p "${__STUB_DIRECTORY}"
cp "${__SCRIPT_PATH}" "${__STUB_DIRECTORY}/gh"
chmod +x "${__STUB_DIRECTORY}/gh"

PATH="${__STUB_DIRECTORY}:${PATH}"
REBASE_STABLE_RELEASE_GH_STUB_MODE="stacked"
REBASE_STABLE_RELEASE_GH_STATE_PATH="${__TEST_ROOT}/github-stack-branches"
export PATH
export REBASE_STABLE_RELEASE_GH_STUB_MODE
export REBASE_STABLE_RELEASE_GH_STATE_PATH

git init --bare "${__TEST_ROOT}/origin.git" >/dev/null
git init --bare "${__TEST_ROOT}/upstream.git" >/dev/null
git init --initial-branch=main "${__WORK_REPOSITORY}" >/dev/null
cd "${__WORK_REPOSITORY}"
git config user.name "Rebase Skill Test"
git config user.email "rebase-skill-test@example.invalid"
mkdir -p apps/server apps/desktop apps/web packages/contracts
for __PACKAGE_FILE in \
  apps/server/package.json \
  apps/desktop/package.json \
  apps/web/package.json \
  packages/contracts/package.json; do
  printf '%s\n' '{"name":"release-test","version":"0.9.0"}' >"${__PACKAGE_FILE}"
done
git add apps packages
git commit --no-gpg-sign -m "test: add stable release base" >/dev/null
git tag v1.0.0
git remote add origin "${__TEST_ROOT}/origin.git"
git remote add upstream "${__TEST_ROOT}/upstream.git"
git push --quiet origin main
git push --quiet upstream main v1.0.0

printf '%s\n' "fork main" >fork-main.txt
git add fork-main.txt
git commit --no-gpg-sign -m "test: add fork-only main commit" >/dev/null
git push --quiet origin main
git switch --quiet --create feat/stable-release-rebase-workflow
printf '%s\n' "skill" >skill.txt
git add skill.txt
git commit --no-gpg-sign -m "test: add skill branch" >/dev/null
__ORIGINAL_SKILL_COMMIT="$(git rev-parse HEAD)"
git switch --quiet --create fix/codex-project-skills
printf '%s\n' "feature" >feature.txt
git add feature.txt
git commit --no-gpg-sign -m "test: add feature branch" >/dev/null

git switch --quiet --create upstream-update v1.0.0
printf '%s\n' "upstream" >upstream.txt
git add upstream.txt
git commit --no-gpg-sign -m "test: update upstream main" >/dev/null
git push --quiet upstream HEAD:main
git tag v1.1.0-nightly.1
git push --quiet upstream v1.1.0-nightly.1
git switch --quiet fix/codex-project-skills

set +o errexit
__COMMAND_OUTPUT="$(
  MRROLL_REMOTE_WRITE_AUTHORIZED=1 "${__DIRECTORY}/rebase-stable-release.bash" 2>&1
)"
__COMMAND_EXIT_CODE=$?
set -o errexit

if [[ ${__COMMAND_EXIT_CODE} -ne 0 ]]; then
  printf '%s\n' "Expected the stacked workflow to complete." >&2
  printf '%s\n' "${__COMMAND_OUTPUT}" >&2
  exit 1
fi
if [[ "${__COMMAND_OUTPUT}" != *"REBASE_STABLE_RELEASE_STACK_INITIALIZED"* ]]; then
  printf '%s\n' "Expected the workflow to initialize GitHub stack metadata." >&2
  printf '%s\n' "${__COMMAND_OUTPUT}" >&2
  exit 1
fi
__FIRST_STACK_LAYER="$(sed -n '1p' "${REBASE_STABLE_RELEASE_GH_STATE_PATH}")"
__SECOND_STACK_LAYER="$(sed -n '2p' "${REBASE_STABLE_RELEASE_GH_STATE_PATH}")"
if [[ "${__FIRST_STACK_LAYER%%$'\t'*}" != "feat/stable-release-rebase-workflow" ]] ||
  [[ "${__SECOND_STACK_LAYER%%$'\t'*}" != "fix/codex-project-skills" ]]; then
  printf '%s\n' "Expected the workflow to register branches from bottom to top." >&2
  exit 1
fi
if [[ "$(git branch --show-current)" != "fix/codex-project-skills" ]]; then
  printf '%s\n' "Expected the workflow to return to the top feature branch." >&2
  exit 1
fi
if [[ "$(git rev-parse feat/stable-release-rebase-workflow)" == "${__ORIGINAL_SKILL_COMMIT}" ]]; then
  printf '%s\n' "Expected --update-refs to rewrite the lower skill branch." >&2
  exit 1
fi
git merge-base --is-ancestor main feat/stable-release-rebase-workflow
git merge-base --is-ancestor feat/stable-release-rebase-workflow fix/codex-project-skills
if [[ "$(git rev-parse main)" != "$(git rev-parse origin/main)" ]]; then
  printf '%s\n' "Expected origin/main to match local main." >&2
  exit 1
fi
__GENERATED_RELEASE_COMMIT="$(git log main --format='%H' --grep='^chore(release): pin package versions to v1.0.0 \[fork-generated\]$')"
if [[ -z "${__GENERATED_RELEASE_COMMIT}" ]]; then
  printf '%s\n' "Expected a generated stable release commit." >&2
  exit 1
fi
if [[ "$(git rev-parse "${__GENERATED_RELEASE_COMMIT}^")" != "$(git rev-parse v1.0.0)" ]]; then
  printf '%s\n' "Expected the generated release commit directly above v1.0.0." >&2
  exit 1
fi
if [[ ! -f fork-main.txt ]] || [[ -f upstream.txt ]]; then
  printf '%s\n' "Expected main to keep fork-only commits and exclude post-release upstream commits." >&2
  exit 1
fi
if [[ "$(node -p "require('./apps/desktop/package.json').version")" != "1.0.0" ]]; then
  printf '%s\n' "Expected package versions to match the stable release tag." >&2
  exit 1
fi
__FIRST_SYNCHRONIZED_MAIN_COMMIT="$(git rev-parse main)"
__SECOND_STACK_LAYER="$(sed -n '2p' "${REBASE_STABLE_RELEASE_GH_STATE_PATH}")"
printf '%s\t%s\n%s\n' \
  "feat/stable-release-rebase-workflow" \
  "0000000000000000000000000000000000000000" \
  "${__SECOND_STACK_LAYER}" >"${REBASE_STABLE_RELEASE_GH_STATE_PATH}"
set +o errexit
__COMMAND_OUTPUT="$(
  MRROLL_REMOTE_WRITE_AUTHORIZED=1 "${__DIRECTORY}/rebase-stable-release.bash" 2>&1
)"
__COMMAND_EXIT_CODE=$?
set -o errexit
if [[ ${__COMMAND_EXIT_CODE} -ne 0 ]]; then
  printf '%s\n' "Expected the repeated workflow to complete." >&2
  printf '%s\n' "${__COMMAND_OUTPUT}" >&2
  exit 1
fi
if [[ "$(git rev-parse main)" != "${__FIRST_SYNCHRONIZED_MAIN_COMMIT}" ]]; then
  printf '%s\n' "Expected a repeated workflow to reuse the generated release commit." >&2
  exit 1
fi
if [[ "${__COMMAND_OUTPUT}" != *"REBASE_STABLE_RELEASE_STACK_INITIALIZED"* ]]; then
  printf '%s\n' "Expected the repeated workflow to refresh stale GitHub stack metadata." >&2
  printf '%s\n' "${__COMMAND_OUTPUT}" >&2
  exit 1
fi
__FIRST_STACK_LAYER="$(sed -n '1p' "${REBASE_STABLE_RELEASE_GH_STATE_PATH}")"
if [[ "${__FIRST_STACK_LAYER#*$'\t'}" != "$(git rev-parse main)" ]]; then
  printf '%s\n' "Expected refreshed stack metadata to record the current main commit." >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  git status --short >&2
  exit 1
fi

printf '%s\n' "Stacked branch workflow passed."
