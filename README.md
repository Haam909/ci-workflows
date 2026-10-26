# ci-workflows

Shared CI/CD for the org's ~30 repositories. Each repo contributes a component
manifest and four thin wrappers.

```
.github/workflows/
  reusable-verify-pull-request.yml      reusable — PR gate
  reusable-deploy-to-test.yml           reusable — merge to main: test, build, deploy to test
  reusable-release.yml                  reusable — manual: version, build, SBOM, sign, tag, release
  reusable-deploy-to-production.yml     reusable — manual: ship a release
  self-test.yml                         this repo's own test, on PRs and main
actions/
  install-toolchain/           toolchain + locked dependency install
  run-tests/                   unit + integration tests in CI, with local/bin/ci
  build-artifact/              build + version stamp + package
  generate-sbom/               CycloneDX SBOM for a release build
  deliver-artifact/            deploy or publish to feed
  derive-version/              semver from branch prefixes
    prefixes                   the branch prefixes and their bumps; the one list
  check-branch-name/           PR gate: the branch has a prefix from that list
SETUP-GITHUB.md                step-by-step setup, no prior CI experience assumed
SETUP-ACCOUNTS.md              Azure DevOps, Azure Artifacts, Entra; the enterprise trials
LOCAL-GATE.md                  pre-push hook, local unit tests, signoff
tests/                         self-test manifest and fixture projects
local/                         bin/ci, bin/signoff, pre-push hook to copy into a repo
examples/.github/              copy into a consuming repo as-is
  components.yml               the manifest
  workflows/
    trigger-pull-request.yml
    trigger-merge-to-main.yml
    trigger-release.yml
    trigger-deploy.yml
```

The flow, end to end:

| Stage | Trigger | Human? |
|---|---|---|
| PR gate | pull request | two signoffs from developer machines |
| Test | merge to main | no: tests run, every component deploys to test |
| Release (version, SBOM, sign, tag) | Actions → Release, pick a commit | yes, running it |
| Production | Actions → Deploy, pick a release | yes, running it |

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

| | `app-service` | `function` | `container` | `package` | `none` |
|---|---|---|---|---|---|
| `dotnet` | `publish` → zip | `publish` → zip | image | `pack` → `.nupkg` | `publish` → zip |
| `node` | build + prod `node_modules` → zip | same | image | `npm pack` → `.tgz` | same as app-service |
| `python` | source + lock → zip (Oryx installs) | deps into `.python_packages` → zip | image | `.whl` + sdist | same as app-service |

`none` is for a repo with nowhere to deploy: the component is built, versioned,
signed and attached to the GitHub Release, and the merge and deploy steps
deliver nothing. It needs no Azure configuration. Use it for the versioning
and release flow on its own.

`container` pushes its image to ACR when the repo sets `ACR_NAME`, and the
merge and Deploy point a Container App at it. Without `ACR_NAME`, on
github.com, the merge run and the Release push the image to
`ghcr.io/<owner>/<repo>/<component>` with the workflow token, signed by
digest at release, and nothing is deployed; it needs no Azure configuration
either. The Release trigger needs `packages: write` for that push
(`examples/` grants it). A dotnet component has no `path`, so its image is
built from the repo root; a root `.dockerignore` keeps that context to what
the Dockerfile copies.

That route, with no Azure, has been run on github.com for a Python and a .NET
container and for TypeScript, Python and .NET apps at `none`: pre-push hook,
pull request, merge run, Release and Deploy (RideAlong 30, 31).

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
- **python** — `ruff`, `pytest` and `mypy` must be installed in the python
  `bin/ci` runs (activate the venv first); `bin/ci` doesn't install them. They
  run as modules (`python -m ruff`), so they needn't be on `PATH`. mypy runs
  whenever it's installed and prints "mypy not installed; skipped" otherwise.
  A component with only a `pyproject.toml` installs as `pip install -e '.[dev]'`.
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
a stable version exists. For services it's just a build label; the release
gets the clean `1.4.0` from `reusable-release.yml`.

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

Running **Release** marks a commit. It deploys nothing.

1. `resolve` picks the commit. With the `sha` input set, it's that commit;
   left blank, it's the last **successful** `test` deployment (warned if over
   14 days old). Either way the commit must be an ancestor of `main` and must
   **contain** the latest release — not at or behind it, and not on a branch
   that forked before it. Sign-off happens outside CI, so nothing else is
   required of a chosen commit. `components.yml` is read **from that commit**,
   not from `main`, so an older commit is built with its own manifest.
2. Derives the version from the branches merged up to that commit; anything
   merged after it doesn't count.
3. Builds every component from that commit stamped with the version,
   generates CycloneDX SBOMs, signs with keyless cosign, attests provenance.
   Container images are pushed to the registry now and signed by digest.
4. Creates the GitHub Release as a draft with every asset, pushes the tag,
   then publishes the release. A failed upload leaves no orphan tag.

Running the workflow is the approval; it waits at no environment gate. If it
fails before the tag, nothing exists and you run it again. If it fails after
(the publish step), the release is a draft with its tag: **Re-run failed
jobs** finishes it.

## Shipping a release

Running **Deploy** with a tag ships that release. Nothing is rebuilt: the
assets are downloaded from the release and checked against its `SHA256SUMS`,
so what was signed is what ships. The manifest is read from the tagged
commit. Then, per component: App Services and Functions deploy to the
staging slot, smoke test, swap, verify, and swap back if production fails
its health check. Containers get a new revision pointing at the image the
release pushed. Packages publish the stable version to their feed. `none`
components are skipped. Each component's `production` deployment is recorded
against the released commit (`<component> v<version>`, then `success` or
`failure`).

Shipping an older release than the latest is allowed, with a warning. A
failed component is re-run with **Re-run failed jobs**, or the whole thing
is dispatched again with the same tag. A version already on the Feed is
reported as a warning and skipped, on every runtime.

**Checking a release's provenance.** The attestation is signed by this repo's
release workflow, not by the consuming repo, so name both:

```bash
gh release download vX.Y.Z -R OWNER/REPO
gh attestation verify api-X.Y.Z.zip -R OWNER/REPO --signer-repo Haam909/ci-workflows
```

Without `--signer-repo` it fails with `verifying with issuer "sigstore.dev"`.
`SHA256SUMS` in the release covers every asset: `sha256sum -c SHA256SUMS`.

## Onboarding a repo

1. Copy `examples/.github/` into the repo root. Keep the `permissions:` block
   in each trigger: a repo whose default token is read-only (the default for
   new repos) otherwise fails at startup with "The workflow is requesting …
   but is only allowed …", because a called workflow can't raise permissions.
2. Edit `.github/components.yml` to describe the components.
3. Install the local gate (LOCAL-GATE.md). The PR gate fails without two
   `local/ci` signoffs, the author's and a reviewer's (`signoffs: 1` on the
   trigger for a one-person repo).
4. Environments: none to create. The merge run names `test` and Deploy names
   `production`; GitHub creates both on first use with no rules. Add required
   reviewers to `production` only if a second person must approve a deploy
   someone else started.
5. Tag the starting version (`v0.1.0`) **before** the merge trigger reaches
   `main`; until a tag exists every merge builds `0.1.0-alpha.0`.
6. Lock files (below).
7. Only if a component deploys to Azure, or publishes to or installs from
   Azure Artifacts: repo variables `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
   `AZURE_SUBSCRIPTION_ID`, `AZURE_RESOURCE_GROUP`, plus `ACR_NAME` for a
   `container` that deploys to a Container App; and federated credentials on the app that accept the repo's
   tokens for the `test` and `production` environments and for
   `ref:refs/heads/main`. The Release build runs under no environment, from
   `main`, and with `AZURE_CLIENT_ID` set it logs in to Azure in every job, so
   every such repo needs the `main` one. SETUP-ACCOUNTS.md steps 9 to 11 add two
   flexible credentials that cover every repo of the owner whose name starts
   with a chosen prefix; a repo named that way needs nothing new in Entra.
   A repo whose only Azure use is publishing to or installing from Azure
   Artifacts needs just `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and the
   credentials: those logins ask for no subscription.

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
| GitHub Packages on the repo's Host (`nuget.pkg.github.com`, `npm.pkg.github.com`; `nuget.<tenant>.ghe.com`, `npm.<tenant>.ghe.com` on GHE.com) | `dotnet`, `node` | `GITHUB_TOKEN` |
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
deploys to the Azure DevOps organisation as a user (**Stakeholder** access is
enough for Azure Artifacts), and give it **Feed Publisher (Contributor)** on
the feed. No PAT is created or stored. The repo also needs the
`AZURE_CLIENT_ID` and `AZURE_TENANT_ID` variables and the federated
credentials from "Onboarding a repo", because the token comes from
`azure/login`. It needs `AZURE_SUBSCRIPTION_ID` only if a component also
deploys to Azure. SETUP-ACCOUNTS.md walks through the Azure DevOps organization,
the Feed, the app registration and the credentials from nothing.

Publishing has been run end to end for dotnet and node to GitHub Packages and
for all three runtimes to an org-scoped and a project-scoped Azure Artifacts
Feed, including a Deploy re-run of the same tag on all three (RideAlong 20),
and a Deploy whose one refused publish was finished with **Re-run failed jobs**
(RideAlong 24).

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
public. From a private and from an internal repo in a GitHub Enterprise Cloud
organization, the NuGet package came out **private**, the internal repo's too
(#6 story 26); npm wasn't tried there.

The repo needs **Write** on the package under the package's **Manage Actions
access** settings; with Read, the publish fails with
`403 … permission_denied: write_package`.

### Installing from a Feed

A component can depend on a package on GitHub Packages on the repo's Host or
on an Azure Artifacts Feed. Name the Feed where the package tool already
looks (ADR 0002); there is no manifest key:

- **dotnet** — a `nuget.config` in the project's folder or a parent up to the
  repo root, with a `<packageSources>` entry for
  `https://nuget.pkg.github.com/OWNER/index.json` or
  `https://pkgs.dev.azure.com/ORG[/PROJECT]/_packaging/FEED/nuget/v3/index.json`.
  NuGet merges every one of those files, so a component can add a Feed in its
  own folder on top of the root's sources. Keep `nuget.org` if anything else
  comes from there. NuGet asks every source for every package, so the Feed
  is asked about nuget.org's packages too. The source's name must not
  contain spaces.
- **node** — an `.npmrc` beside the component's `package.json`, with
  `@OWNER:registry=https://npm.pkg.github.com/` or
  `@SCOPE:registry=https://pkgs.dev.azure.com/ORG[/PROJECT]/_packaging/FEED/npm/registry/`.
  npm reads no other project file: an `.npmrc` at the repo root is not read
  for a component in a subfolder, and the workflows don't read it either.
- **python** — an `--index-url`, `-i` or `--extra-index-url` line with
  `https://pkgs.dev.azure.com/ORG[/PROJECT]/_packaging/FEED/pypi/simple/` in
  the component's `requirements*.txt`. pip reads no config file from the work
  tree, so a `pip.conf` in the repo names nothing. GitHub Packages has no
  Python registry. Without `requirements.lock.txt` the install warns that it
  is not hash-pinned. With `--extra-index-url` pip looks in PyPI and the Feed
  alike for every requirement, so pin the version.

Commit no token in any of them. The install picks the entries out by host
(GitHub Packages on the repo's Host; `pkgs.dev.azure.com` or
`*.visualstudio.com` for Azure Artifacts) and supplies the credential, outside
the work tree: NuGet's `NuGetPackageSourceCredentials_<source name>`, a
user-level npmrc for npm, and a netrc for pip (`NETRC`). Other feeds in those
files (npmjs.org, Artifactory) get no credential from the workflows.

- **In CI**, `install-toolchain` uses the workflow token for GitHub Packages
  and an Entra token from the Azure CLI for Azure Artifacts. The merge run and
  the Release build run "Azure login for package Feeds" (`azure/login`,
  `allow-no-subscriptions`) before the install whenever the repo variable
  `AZURE_CLIENT_ID` is set; a repo without it gets no login step. That needs
  the repo variables `AZURE_CLIENT_ID` and
  `AZURE_TENANT_ID`, federated credentials for the `test` environment and
  for `ref:refs/heads/main` (the Release build runs under no environment),
  and the service principal in the Azure DevOps organization with a role on
  the Feed (onboarding step 7). Microsoft's Feed Reader role covers
  "Download/install/restore packages"; saving a package from an upstream
  source takes Feed and Upstream Reader (Collaborator). Tested only with
  Feed Publisher (Contributor).
  The Azure targets' and the container push's own logins are unchanged.
- **On a laptop**, `bin/ci --install`, and the locked restore a plain `bin/ci`
  runs, use the token of your `gh` login on the Host and of your `az` login.
  Without the login a Feed needs, or if the `gh` token lacks
  `read:packages`, `bin/ci` stops and prints the command:

  ```bash
  gh auth login --hostname github.com --scopes read:packages
  az login --allow-no-subscriptions
  ```

A repo whose files name neither kind of Feed installs exactly as before:
`bin/ci` calls neither `gh` nor `az`, and the merge run and Release build skip
the Azure login.

The Release trigger needs `packages: read` (in `examples/` since `47b7bfd`)
for GitHub Packages. Without any `packages` permission the Release build's
restore fails with `error NU1301: … 403 (Forbidden)`. The merge trigger's
`packages: write` already covers it. Both triggers already grant
`id-token: write` for the Azure login.

Installing has been run for dotnet and node from GitHub Packages (RideAlong
21) and for dotnet, node and python from an org-scoped Azure Artifacts Feed
(RideAlong 22), in the merge run, the Release build and `bin/ci --install`
on a laptop; the pre-push hook's locked restore ran for the dotnet
components. A GitHub Packages package owned by the same account, public, installed with no
**Manage Actions access** entry for the installing repo. GitHub documents that
the `GITHUB_TOKEN` "can be used if the repository is granted read access to
the package"; for a private package, add the installing repo there with
**Read**.

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

**On tags.** Target `v*`, **Restrict creations**, bypass only for a GitHub
App that the release pushes its tag as. Stops anyone tagging a release from a
laptop. GitHub Actions itself can't be a bypass actor, on a personal account
or in an organization ("must be part of the ruleset source or owner
organization"), so the release takes a token from the app when
`RELEASE_APP_CLIENT_ID` is set (SETUP-GITHUB.md 8c). On a free **personal**
account Evaluate mode is refused too ("upgrade to Enterprise"). In a GitHub
Enterprise Cloud organization, a `v0.1.0` pushed from a laptop was refused
("Cannot create ref due to creations being restricted.") and the release's own
push went through on the app's bypass (#6 story 23). Without a bypass, an
active rule blocks the release's own tag push.

## Versioning this repo

Change this repo through a pull request. `self-test.yml` tests that branch,
not `@v2`, in two ways, and needs no consumer repo or Azure:

- It builds each fixture in `tests/components.yml` with the actions alone and
  checks the artifact's name and contents and the SBOM's root version and
  component list. That covers every runtime with the `app-service`,
  `function` and `package` targets, and a Python and a .NET `container`
  pushed to a registry service container on `localhost:5000`.
- It runs the reusable workflows themselves over `tests/workflows.yml`: the
  merge run, the release with `dry-run` (it builds, signs and attests, but
  pushes no tag and publishes no release), and the PR gate with no signoffs
  required. Each gets the permissions its trigger in `examples/` grants, the
  release `contents: read`. The components are apps at `none` and a Python
  and a .NET `container`, pushed to `ghcr.io/haam909/ci-workflows`. Something
  new that the workflows handle gets a component there.

Not covered: Deploy (`reusable-deploy-to-production.yml`), which needs a
published release; the release's tag push and publish; and deriving a version
from merged PRs, since this repo has no release tags (`v1` and `v2` aren't).
Move `v2` only after self-test passes on `main`.

Consumers pin `@v2`. Move `v2` forward for compatible changes; cut `v3` for
anything needing manifest changes — thirty repos means a breaking change here
is thirty PRs, so prefer additive keys with defaults.

The reusable workflows run the actions from the commit that defines them:
each job checks out `job.workflow_repository` at `job.workflow_sha` into
`.ci-workflows` and calls `./.ci-workflows/actions/...`. So a branch runs its
own actions, moving `v2` or cutting `v3` takes them along, and the workflows
name no account. That checkout uses the calling repo's `GITHUB_TOKEN`, which
can read no other private repo, so this repo has to be public (SETUP-GITHUB.md
step 1). A container built from the repo root has `.ci-workflows` in its
context unless the root `.dockerignore` leaves it out, as one that starts with
`*` does.

The `Haam909/ci-workflows/...@v2` references in the examples point at the
account this copy was set up under. Substitute your org name when moving it
(SETUP-GITHUB.md step 2).

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
- Deploy's `production` job records its deployments by hand against the
  released commit, because GitHub's automatic record would name the commit
  the run was dispatched from. Any environment rule on `production` still
  applies to the job.
- Version derivation reads PR branch names via `commits/{sha}/pulls`. It
  worked on a public repo without `pull-requests: read`, and on a private and
  an internal repo with it: a `feature/` PR took each from `v0.1.0` to
  `v0.2.0` (#6 story 26). A failure there is silent: every commit falls back
  to patch.
