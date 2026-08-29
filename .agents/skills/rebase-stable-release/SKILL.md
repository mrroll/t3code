---
name: rebase-stable-release
description: Synchronize a fork's origin/main with upstream's latest stable release artifact, then rebase the current feature stack onto the synchronized local main. Use when the user asks to reproduce stable with branch changes, update the fork main branch to stable, rebase a branch stack onto stable, or repeat the repository's standard stable-release rebase workflow.
---

# Rebase Stable Release

Use the deterministic script for the complete workflow. Do not reproduce its normal Git steps manually.

## Get authorization

The script force-updates `origin/main`. This is a remote write. Before each invocation that can push, get explicit authorization from the user for that exact push.

After authorization, run:

```bash
MRROLL_REMOTE_WRITE_AUTHORIZED=1 .agents/skills/rebase-stable-release/scripts/rebase-stable-release.bash
```

The script performs these operations:

1. Verify that the current top feature branch and worktree are safe to rebase.
2. Check the GitHub stack topology.
3. Fetch `origin/main`, `upstream/main`, and resolve upstream's highest stable `vMAJOR.MINOR.PATCH` tag.
4. Stop unless the stable tag is an ancestor of `upstream/main`.
5. Identify fork-only main commits. On the first run, compare `origin/main` with `upstream/main`. On later runs, use the generated release commit marker.
6. Make local `main` start at the stable tag.
7. Apply the same package-version JSON rewrite as release CI and create a signed generated commit without requiring installed dependencies.
8. Rebase fork-only main commits onto the generated release commit.
9. Push local `main` to `origin/main` with an exact force-with-lease guard.
10. Return to the original top feature branch.
11. Rebase the feature stack onto local `main` with `--update-refs`.
12. Derive the feature branch order from local branch tips.
13. Initialize missing GitHub stack metadata with `main` as the trunk.
14. Verify the final stack order, refs, and worktree.

The generated main commit has this subject:

```text
chore(release): pin package versions to vMAJOR.MINOR.PATCH [fork-generated]
```

The script drops this commit and regenerates it when a newer stable release exists. It never rebases the old generated commit.

The built-in JSON rewrite mirrors `scripts/update-release-package-versions.ts`. Re-check this workflow if release CI changes that script to do more than update the four package manifest versions.

A newer official stable release replaces a running fork build through the stable updater. Run this workflow again to rebuild the fork changes on the new stable release.

The generated release commit and the project pnpm policy are fork-only history. Before opening an upstream pull request, rebase the contribution onto `upstream/main` without those commits.

The script retries one Git SSH command once when 1Password reports `sign_and_send_pubkey: ... communication with agent failed`. If the retry fails, ask the user to unlock 1Password. Do not run another retry.

## Resolve conflicts

Exit code `20` means Git left a rebase conflict. Only conflict resolution belongs outside the script.

1. Inspect the rebase phase and conflicted files.
2. Resolve each conflict while preserving the intent of both sides.
3. Stage the resolved files with `git add`.
4. If the conflict phase names local `main`, get explicit authorization again for the exact `origin/main` push because the continuation is a new shell command. Then continue with the authorization marker:

   ```bash
   MRROLL_REMOTE_WRITE_AUTHORIZED=1 "$(git rev-parse --git-path rebase-stable-release-resume.bash)" --continue
   ```

5. If the conflict phase names the feature stack, `origin/main` is already updated. Continue without the authorization marker:

   ```bash
   "$(git rev-parse --git-path rebase-stable-release-resume.bash)" --continue
   ```

Repeat only when Git reports another conflict. Do not call `git rebase --continue` directly.

The script never disables commit signing while it updates local or remote `main`. It can retry without signing only while it rebases the feature branch. If it reports unsigned commits, tell the user which commit identifiers it reports.

## Stop conditions

Do not bypass a dirty worktree, detached `HEAD`, missing remote, missing stable tag, unexpected Git error, changed remote lease, or GitHub stack inspection failure. Report the script's error code and details to the user.

Initializing GitHub stack metadata is local. The workflow does not push the feature branches or create pull requests.

Do not push the feature branch unless the user separately authorizes that remote write.
