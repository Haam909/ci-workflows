# tests/onboard

Proves that `local/bin/onboard` and the reusable workflows work on repos that
aren't shaped like the one they were written against. Each row of the matrix
is a real GitHub repo, configured one way, onboarded, and taken through the
whole path:

1. `onboard init`, the scaffolded `components.yml` compared with what the seed
   should produce, the markers removed, a developer setup (venv,
   `bin/ci --install`), `onboard apply` (twice or more where the default
   branch only takes PRs), `onboard check`;
2. a `feature/…` PR pushed through the pre-push hook, whose `ci / gate`,
   `ci / branch-name` and `local/ci` must all be green, then merged with a
   method the repo allows;
3. `trigger-release.yml` dispatched for that merge, the `release` gate
   approved, `production` turned away so nothing is delivered from a sandbox;
4. the draft release's assets: one artifact per component of the right kind,
   its cosign bundle, an SBOM whose root is `<name>@<version>`,
   `sha256sum -c SHA256SUMS`, and `gh attestation verify`.

A row that expects onboard to stop (`stop_at`) passes only if it stops with
that message.

```bash
tests/onboard/run --list
tests/onboard/run L1 C4            # some rows
KEEP_GOING=1 tests/onboard/run --all
```

Rows are in `rows.sh`: `L*` vary the code layout (each runtime and target,
and a multi-component repo), `C*` vary the repo around the multi-component
layout (default branch, visibility, protection, merge methods, existing tags
and files, leftover branches, a branch that moves mid-onboarding, CRLF
checkouts). Seeds are assembled from `parts/`.

Rows share a pool of public sandboxes, `<you>/ciw-sbx-01` to `-10` (`POOL`),
and private rows a pool of private ones, `<you>/ciw-sbx-p01` to `-p02`
(`PRIVATE_POOL`). A sandbox keeps the visibility it was created with: GitHub
refuses git access to a repo for a while after its visibility changes. Each is
created on first use and reset before each row; GitHub limits how fast an account can
create repos, so they're reused rather than made per row. Several `run`s can go
at once: each row waits for a free sandbox. Nothing is deleted except inside
a sandbox: its rulesets, protection, environments, releases, tags and branches. The result is
`results/<row>.md`: every check the harness made, with the run URLs.

## Testing a change before v1 moves

The sandboxes' triggers call ci-workflows at a ref, and the reusable workflows
call this repo's actions at `@v1`. To test a commit end to end:

```bash
REF="$(tests/onboard/stage)"                 # pushes test/stage-<sha>
CIW_REF="${REF}" KEEP_GOING=1 tests/onboard/run --all
tests/onboard/stage --delete                 # afterwards
```

`stage` pushes HEAD to `test/stage-<sha>` with one extra commit that points
the internal action references at that branch. It never reaches main.

## What a single account can't test

- Team reviewers need an organization; `--reviewer team:ORG/SLUG` is only
  exercised once one exists.
- Approvals: a PR author can't approve their own PR, so rows with a required
  approval check that onboard stops and says so (C4, C5), and the `b`
  variants then lower the requirement, as an admin would, to test the rest.
- Org-level rulesets (GitHub Enterprise) and internal repos (Enterprise
  Cloud) aren't available on github.com plans below that. `onboard` reads the
  effective rules on the branch, so org rulesets are honoured the same way.
- Container targets need Azure Container Registry in a release, so the
  container rows check that the build stops at `azure/login`. The image build
  itself is covered by the self-test (`tests/components.yml`).

Needs bash, git, gh (`repo` and `workflow` scopes), yq, jq, dotnet, node and
python. Runs on Linux, macOS and Git Bash.
