# ci-workflows

Shared CI/CD for the org's ~30 repositories. Each repo contributes a component
manifest and three thin wrappers.

```
.github/workflows/
  reusable-verify-pull-request.yml      reusable — PR gate
  reusable-deploy-to-test.yml           reusable — merge to main
  reusable-release-to-production.yml    reusable — manual release
  self-test.yml                         this repo's own test, on PRs and main
actions/
  install-toolchain/           toolchain + locked dependency install
  build-artifact/              build + version stamp + package
  generate-sbom/               CycloneDX SBOM for a release build
  deliver-artifact/            deploy or publish to feed
  derive-version/              semver from branch prefixes
SETUP-GITHUB.md                step-by-step setup, no prior CI experience assumed
LOCAL-GATE.md                  pre-push hook, local unit tests, signoff
tests/                         self-test manifest and fixture projects
local/                         bin/ci, bin/signoff, pre-push hook to copy into a repo;
                               bin/onboard, which sets a repo up
examples/.github/              copy into a consuming repo as-is
  components.yml               the manifest
  workflows/
    trigger-pull-request.yml
    trigger-merge-to-main.yml
    trigger-release.yml
```

Want tests to run on your machine instead of waiting on a runner? See
**LOCAL-GATE.md**.

New to CI/CD? Start with **SETUP-GITHUB.md**, which walks through the GitHub
side from scratch.

Composite actions must be named `action.yml`, so each action's directory is
its name. `reusable-*` workflows live here and do the work. `trigger-*` workflows go
in each consuming repo and only decide when to call them.

## Two axes, not one

`runtime` decides how a component is built. `target` decides how it ships.
They're independent — a Python Function and a C# Function deploy identically,
and a Go binary would only need a new runtime, not a new delivery path.

| | `app-service` | `function` | `container` | `package` |
|---|---|---|---|---|
| `dotnet` | `publish` → zip | `publish` → zip | image | `pack` → `.nupkg` |
| `node` | build + prod `node_modules` → zip | same | image | `npm pack` → `.tgz` |
| `python` | source + lock → zip (Oryx installs) | deps into `.python_packages` → zip | image | `.whl` + sdist |

Adding a runtime touches `install-toolchain`, `build-artifact` and `bin/ci`.
Adding a target touches `deliver-artifact`. Nothing else.

`uses:` can't take expressions, so there's still an `if:`/`case` chain
selecting toolchains — but it's confined to those composite actions rather
than spread across three workflows.

## Default commands and overrides

Checks run on the developer's machine through `bin/ci` (see LOCAL-GATE.md);
CI doesn't re-run them. `install` is also what CI uses before building.
`node` covers TypeScript and plain JavaScript. Each runtime has defaults;
the manifest's `commands.<step>` overrides any of them, in `bin/ci` and CI
alike.

| | `dotnet` | `node` | `python` |
|---|---|---|---|
| install | `dotnet restore --locked-mode` on every declared project | `npm ci` | lock file → `requirements.txt` → `pyproject.toml` |
| lint | `dotnet format --verify-no-changes` | `npm run lint --if-present` | `ruff check` + `ruff format --check` |
| typecheck | `dotnet build -warnaserror` | `tsc --noEmit` | `mypy .` |
| test | `dotnet test <test-project>` | `npm test` with `CI=true` | `pytest -m "not integration"` |
| integration | `dotnet test --filter Category=Integration` | `npm run test:integration` | `pytest -m integration` |

There is no audit step; vulnerable dependencies are left to Dependabot alerts
(LOCAL-GATE.md explains why).

Steps that don't apply:

- **node** — no `tsconfig.json` means plain JavaScript, so typecheck prints
  "no tsconfig; skipped". No `lint` script means `--if-present` does nothing
  and the step reports as **passed**, not skipped. `CI=true` makes Jest and
  Vitest run once instead of watching.
- **python** — `ruff`, `pytest` and `mypy` must be installed by the repo
  (e.g. `requirements-dev.txt`); `bin/ci` doesn't install them. mypy runs
  whenever it's installed and prints "mypy not installed; skipped" otherwise.
- **dotnet** — no `test-project` declared skips that component's unit **and**
  integration tests, with a message.
- **dotnet** — a plain `bin/ci` (no `--install`) still starts with a locked
  restore of every declared project, the same one CI runs, and the test steps
  use `--no-restore`. Otherwise `dotnet test`'s own unlocked restore would
  quietly rewrite a stale `packages.lock.json` and pass, and the merge would
  fail with NU1004.

```yaml
commands:
  test: pytest -m "not integration" --cov
  install: uv sync --frozen
```

## Versioning

Derived, never typed. The branch prefix of each PR merged since the last `v*`
tag decides the bump; the highest wins.

| Prefix | Bump |
|---|---|
| `breaking/` | major |
| `feature/`, `feat/` | minor |
| `fix/`, `hotfix/`, `bugfix/` | patch |
| all other allowed prefixes | patch |

Branch names come from the GitHub API (`commits/{sha}/pulls`), not commit
messages, so squash and rebase merges behave the same as merge commits.

`reusable-deploy-to-test.yml` builds prereleases — `1.4.0-alpha.12`, where 12 is the commit count
since the tag. For packages that's the point: consumers try the change before
a stable version exists. For services it's just a build label; production gets
the clean `1.4.0` from `reusable-release-to-production.yml`.

Python gets `1.4.0a12` instead, since PEP 440 rejects the semver spelling.
It's written into the static `version` field of `pyproject.toml` (PEP 621 or
Poetry) by `actions/build-artifact/stamp-python-version.py`; projects using
setuptools-scm or hatch-vcs pick it up from `SETUPTOOLS_SCM_PRETEND_VERSION`.

Major is also a checkbox on the release workflow, for breaks not visible in a
branch name.

With no `v*` tag in the repo, derivation is skipped and the first version is
`0.1.0` regardless of what merged. Tag the starting point by hand if you want
to begin somewhere else — that's the only manual tag in the system.

## What a release does

1. `resolve` picks the commit. With the `sha` input set, it's that commit;
   left blank, it's the last **successful** `test` deployment (warned if over
   14 days old). Either way the commit must be an ancestor of `main` and must
   **contain** the latest release — not at or behind it, and not on a branch
   that forked before it. Sign-off happens outside CI, so nothing else is
   required of a chosen commit. `components.yml` is read **from that commit**,
   not from `main`, so an older commit is built with its own manifest.
2. Derives the version from the branches merged up to that commit; anything
   merged after it doesn't count.
3. Waits at the `release` environment gate. This is the ship decision, and the
   only judgment left in the pipeline.
4. Rebuilds every component from that commit stamped with the version,
   generates CycloneDX SBOMs, signs with keyless cosign, attests provenance.
   Container images are signed by digest in the registry.
5. Creates the GitHub Release as a **draft with assets**, then pushes the tag.
   A failed upload leaves no orphan tag.
6. Promotes. App Services and Functions deploy to the staging slot, smoke
   test, swap, verify, and swap back automatically if production fails its
   health check. Containers get a new revision. Packages publish the stable
   version. Each component's `production` deployment is recorded against the
   **released** commit (`<component> v<version>`, then `success` or
   `failure`). GitHub's automatic record would use the commit the run was
   dispatched from — `main`'s head — so it's turned off (`deployment: false`;
   environment protection rules still apply).
7. Publishes the draft release, only once every component promoted.

**When promote fails** — a rejected environment rule, a feed refusing the
publish, a failed health check — the tag exists, the release stays a
**draft**, and nothing has been announced. Fix the cause, then **Re-run failed
jobs** (`gh run rerun <run-id> --failed`): that re-runs promote and the
publish step that depended on it. The `release` approval isn't asked again,
because the job behind the gate already passed, and the tag isn't pushed twice.
The failed attempt keeps its `failure` deployment record; the re-run adds a
new one.

**Checking a release's provenance.** The attestation is signed by this repo's
release workflow, not by the consuming repo, so name both:

```bash
gh release download vX.Y.Z -R OWNER/REPO
gh attestation verify api-X.Y.Z.zip -R OWNER/REPO --signer-repo Haam909/ci-workflows
```

Without `--signer-repo` it fails with `verifying with issuer "sigstore.dev"`.
`SHA256SUMS` in the release covers every asset: `sha256sum -c SHA256SUMS`.

## Onboarding a repo

`local/bin/onboard` does steps 1–6 below and the two rulesets ("Rulesets"),
drafting step 2's `components.yml` for you to review. Run it from the repo's
clone, on a `main` that nobody has protected yet:

```bash
../ci-workflows/local/bin/onboard init    # files, gate, lock files; drafts components.yml
#   review .github/components.yml, delete each "# onboard: check this" marker
../ci-workflows/local/bin/onboard apply   # bin/ci, commit to main [skip ci], v0.1.0,
                                          # environments, both rulesets, then check
../ci-workflows/local/bin/onboard check   # any time: what's missing or different
```

`--reviewer LOGIN` sets who approves releases (default: you).
`--no-deploy-to-test` leaves out the merge trigger, for a repo with nowhere to
deploy yet; pass it to `check` too. It's safe to re-run. It adds what's
missing and never overwrites an existing workflow, environment or ruleset;
`check` names any that differ. Azure (step 7) stays manual.

By hand:

1. Copy `examples/.github/` into the repo root. Keep the `permissions:` block
   in each trigger: a repo whose default token is read-only (the default for
   new repos) otherwise fails at startup with "The workflow is requesting …
   but is only allowed …", because a called workflow can't raise permissions.
2. Edit `.github/components.yml` to describe the components.
3. Install the local gate (LOCAL-GATE.md). The PR gate fails without a
   `local/ci` signoff.
4. Environments `test`, `release` (required reviewers), `production`.
5. Tag the starting version (`v0.1.0`) **before** the merge trigger reaches
   `main`; until a tag exists every merge builds `0.1.0-alpha.0`.
6. Lock files (below).
7. Only if a component deploys to Azure or publishes to Azure Artifacts:
   repo variables `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
   `AZURE_SUBSCRIPTION_ID`, `AZURE_RESOURCE_GROUP`, plus `ACR_NAME` for
   `container`; and federated credentials for
   `repo:ORG/REPO:environment:{test,release,production}`.

A repo whose components are all `package` on GitHub Packages needs no Azure
configuration at all — `azure/login` is skipped.

## Lock file requirements

Determinism is what makes the release rebuild safe, so it's enforced per
runtime rather than checked afterwards.

**dotnet** — NuGet writes a lock file only when you opt in:

```xml
<PropertyGroup>
  <RestorePackagesWithLockFile>true</RestorePackagesWithLockFile>
</PropertyGroup>
```

Commit `packages.lock.json`. All restores use `--locked-mode`.

**node** — `npm ci` already requires `package-lock.json`.

**python** — pip has no lock file at all, so generate one and commit it:

```bash
pip-compile --generate-hashes -o requirements.lock.txt requirements.in
```

Without it the action falls back to `requirements.txt` with a warning, which
is not deterministic. `uv`/`poetry` users override the install command.

## Package feeds

Set `feed` on a package component to publish anywhere. Credentials are worked
out from the feed's host, so the common cases need no stored token:

| Feed | Default for | Auth |
|---|---|---|
| Azure Artifacts (`pkgs.dev.azure.com`) | — | Entra token from the workflow's OIDC login |
| GitHub Packages | `dotnet`, `node` | `GITHUB_TOKEN` |
| Anything else | — | secret named by `feed-token-secret` |

```yaml
  - name: contracts
    runtime: dotnet
    target: package
    project: src/Contracts/Contracts.csproj
    feed: https://pkgs.dev.azure.com/contoso/_packaging/internal/nuget/v3/index.json
```

Feed URLs differ per runtime — NuGet wants `.../nuget/v3/index.json`, npm
`.../npm/registry/`, Python `.../pypi/upload/`.

**Azure Artifacts setup.** Add the same service principal used for the Azure
deploys to the Azure DevOps organisation as a user, and give it
**Contributor** on the feed. No PAT is created or stored. The repo also needs
the `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID` variables
and the federated credentials from "Onboarding a repo", because the token
comes from `azure/login`.

This path hasn't been run end to end yet. Publishing to GitHub Packages has,
for npm and NuGet; the first Azure Artifacts publish is the test of it.

**Other feeds** (npmjs.org, PyPI, Artifactory, Nexus) can't use OIDC, so put
the token in a repository secret and name it on the component:

```yaml
    feed: https://registry.npmjs.org
    feed-token-secret: NPMJS_TOKEN
```

GitHub Packages has no Python registry, so a Python package must always name
its feed. npm packages on GitHub Packages must be scoped to the org
(`"name": "@contoso/sdk"`).

**Visibility on GitHub Packages.** A package published by this workflow from a
**public** repo came out **public** in testing (npm and NuGet both), even though GitHub documents
new personal-account packages as private by default. Making a package public
can't be undone. Check the package's visibility after its first publish, and
publish from a private repo (or a private feed) if the package must not be
public.

The repo needs **Write** on the package under the package's **Manage Actions
access** settings; with Read, the publish fails with
`403 … permission_denied: write_package`.

## Integration tests

Testcontainers, not service containers. `services:` must be declared in
workflow YAML and takes no expressions, so it can't be made conditional —
which would force repo-specific workflow files. Testcontainers puts the
database in test code, so the same tests run on a dev machine, and this repo
needs no per-repo config.

They run in `bin/ci`, on the developer's machine; CI has no integration job.
A component with no `integration-tests` key (and no
`commands.integration-test`) skips them. For dotnet the key's value is the
test project path. For node and python the default command (`npm run
test:integration`, `pytest -m integration`) ignores the value, so the key acts
purely as a flag — set `integration-tests: true`.

`bin/ci` refuses to run without Docker or Podman if the word `integration` appears
**anywhere** in `components.yml` — including comments and a
`pytest -m "not integration"` override — not only when a component declares
integration tests.

## Rulesets

Set these at org level so they cover every repo. On a personal account the
same settings exist per repo instead.

**Branch naming.** Target all branches, exclude `main` and each allowed prefix
(`feature/**`, `feat/**`, `fix/**`, `hotfix/**`, `bugfix/**`, `breaking/**`,
`chore/**`, `docs/**`, `refactor/**`, `test/**`, `ci/**`, `build/**`,
`perf/**`, `deps/**`, `dependabot/**`). Enable **Restrict creations**.
`reusable-verify-pull-request.yml` has a branch-name job as a backstop.

Keep that list in sync with the `case` block in `actions/derive-version/action.yml` — a
prefix the ruleset allows but the action doesn't know falls through to patch
with a warning.

**On `main`.** Require a PR, require status checks, require up to date,
require linear history (squash or rebase merges only — with merge commits, a
branch that forked before a release can land after it). The
required checks are `ci / gate`, `ci / branch-name` and `local/ci` — there are
no per-component PR checks. The PR checks run on `pull_request` only: a push
trigger as well would report each check twice per commit, and its skipped
`branch-name` job counts as passed for a required check.

**On tags.** Target `v*`, **Restrict creations**, bypass only for the Actions
app. Stops anyone tagging a release from a laptop. On a free **personal**
account the Actions bypass is refused ("must be part of the ruleset source or
owner organization") and so is Evaluate mode ("upgrade to Enterprise"), so
this rule needs org-owned repos; that setup is untested. Without the bypass,
an active rule blocks the release's own tag push.

## Versioning this repo

Change this repo through a pull request. `self-test.yml` builds each fixture
in `tests/components.yml` with the actions from that branch (not `@v1`) and
checks the artifact's name and contents and the SBOM's root version and
component list. It covers every runtime with the `app-service` and `package`
targets, and needs no consumer repo, release or Azure. Move `v1` only after it
passes on `main`. Container builds aren't covered: they need a registry.

Consumers pin `@v1`. Move `v1` forward for compatible changes; cut `v2` for
anything needing manifest changes — thirty repos means a breaking change here
is thirty PRs, so prefer additive keys with defaults.

The `Haam909/ci-workflows/...@v1` references inside the workflows and the
examples point at the account this copy was set up under. Substitute your org
name when moving it (SETUP-GITHUB.md step 2).

## Known limits

- One API call per commit since the last tag during version derivation. Fine
  for tens of commits; use GraphQL if a release spans hundreds.
- A commit pushed directly to main has no PR to read, so it's treated as a
  patch with a warning. The `main` ruleset should prevent it.
- Packages have no rollback. Feeds are immutable: unlist and ship a patch.
- Containers are rebuilt at release rather than promoted by digest. Promoting
  the tested digest would be true build-once, but then the version inside the
  image stays the prerelease. Rebuilding keeps versions consistent across all
  four targets at the cost of that guarantee.
- `resolve` pins the target SHA when it runs, so a merge landing while you're
  at the approval gate isn't included — correct, but the tag briefly points at
  something that isn't the newest thing in test.
- Consumption-plan Function Apps have limited slot support; Premium or
  Dedicated is needed for swap-based promotion.
- `yq` and `jq` are preinstalled on `ubuntu-latest` and both are relied on.
  Worth re-checking if you pin runner images.
- Python on App Service ships source and lets Oryx install dependencies,
  since App Service doesn't read `.python_packages`. The build hands Oryx the
  hash-pinned lock as `requirements.txt`. Set
  `SCM_DO_BUILD_DURING_DEPLOYMENT=true` on those apps. Python Functions do
  prebuild into `.python_packages`.
- Node services ship the built tree plus production `node_modules`, and start
  from `package.json`'s `start` script. A static SPA with no server belongs in
  Static Web Apps or a container, not an App Service zip.
- npm only. `setup-node`'s cache needs `package-lock.json`; yarn and pnpm
  repos need `commands.install` and a lock file npm can read.
- The `release` environment's automatic deployment record (the approval) is
  stamped with the dispatch commit, not the released one. Only `production`
  records are written explicitly.
- Version derivation reads PR branch names via `commits/{sha}/pulls`. It
  worked on a public repo without `pull-requests: read`; private repos are
  untested. A failure there is silent: every commit falls back to patch.
