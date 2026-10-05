# ci-workflows

Shared CI/CD for the org's ~30 repositories. Each repo contributes a component
manifest and three thin wrappers.

```
.github/workflows/
  reusable-verify-pull-request.yml      reusable — PR gate
  reusable-deploy-to-test.yml           reusable — merge to main
  reusable-release-to-production.yml    reusable — manual release
actions/
  install-toolchain/           toolchain + locked dependency install
  build-artifact/              build + version stamp + package
  deliver-artifact/            deploy or publish to feed
  derive-version/              semver from branch prefixes
SETUP-GITHUB.md                step-by-step setup, no prior CI experience assumed
LOCAL-GATE.md                  pre-push hook, local unit tests, signoff
local/                         bin/ci, bin/signoff, pre-push hook to copy into a repo
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

`node` covers TypeScript and plain JavaScript. Each runtime has defaults;
the manifest's `commands.<step>` overrides any of them.

| | `dotnet` | `node` | `python` |
|---|---|---|---|
| install | `dotnet restore --locked-mode` on every declared project | `npm ci` | lock file → `requirements.txt` → `pyproject.toml` |
| lint | `dotnet format --verify-no-changes` | `npm run lint` | `ruff check` + `ruff format --check` |
| typecheck | `dotnet build -warnaserror` | `tsc --noEmit` | `mypy .` |
| test | `dotnet test <test-project>` | `npm test` with `CI=true` | `pytest -m "not integration"` |
| integration | `dotnet test --filter Category=Integration` | `npm run test:integration` | `pytest -m integration` |
| audit | `dotnet list package --vulnerable` | `npm audit --audit-level=high` | `pip-audit` on the pinned requirements |

Steps that don't apply are skipped with a visible annotation rather than
failing:

- **node** — no `tsconfig.json` means plain JavaScript, so typecheck is
  skipped. No `lint` or `test` script in `package.json` skips that step with a
  warning. `CI=true` makes Jest and Vitest run once instead of watching.
- **python** — `ruff`, `pytest` and `mypy` are installed if the repo doesn't
  provide them. Typecheck only runs when mypy is configured (`mypy.ini`,
  `[tool.mypy]`, or `[mypy]` in `setup.cfg`), since mypy on an untyped
  codebase fails on day one. pytest collecting no unit tests is a warning.
- **dotnet** — no `test-project` declared skips unit tests with a warning.

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

1. `resolve` queries the deployments API for the last **successful** `test`
   deployment, confirms that commit is an ancestor of `main`, warns if it's
   over 14 days old. There is no commit input.
2. Derives the version.
3. Waits at the `release` environment gate. This is the ship decision, and the
   only judgment left in the pipeline.
4. Rebuilds every component from that commit stamped with the version,
   generates CycloneDX SBOMs, signs with keyless cosign, attests provenance.
   Container images are signed by digest in the registry.
5. Creates the GitHub Release as a **draft with assets**, then pushes the tag,
   then publishes. A failed upload leaves no orphan tag.
6. Promotes. App Services and Functions deploy to the staging slot, smoke
   test, swap, verify, and swap back automatically if production fails its
   health check. Containers get a new revision. Packages publish the stable
   version.

## Onboarding a repo

1. Copy `examples/.github/` into the repo root.
2. Edit `.github/components.yml` to describe the components.
3. Environments `test`, `release` (required reviewers), `production`.
4. Lock files (below).
5. Only if a component deploys to Azure or publishes to Azure Artifacts:
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
**Contributor** on the feed. No PAT is created or stored.

**Other feeds** (npmjs.org, PyPI, Artifactory, Nexus) can't use OIDC, so put
the token in a repository secret and name it on the component:

```yaml
    feed: https://registry.npmjs.org
    feed-token-secret: NPMJS_TOKEN
```

GitHub Packages has no Python registry, so a Python package must always name
its feed. npm packages on GitHub Packages must be scoped to the org
(`"name": "@contoso/sdk"`).

## Integration tests

Testcontainers, not service containers. `services:` must be declared in
workflow YAML and takes no expressions, so it can't be made conditional —
which would force repo-specific workflow files. Testcontainers puts the
database in test code, so the same tests run on a dev machine, and this repo
needs no per-repo config.

A component with no `integration-tests` key simply isn't in the integration
job's matrix. For dotnet the key's value is the test project path. For node
and python the default command (`npm run test:integration`, `pytest -m
integration`) ignores the value, so the key acts purely as a flag — set
`integration-tests: true`.

## Rulesets

Set these at org level so they cover every repo. On a personal account the
same settings exist per repo instead.

**Branch naming.** Target `**/*`, exclude `main` and each allowed prefix
(`feature/**`, `fix/**`, `breaking/**`, `chore/**`, `docs/**`, `refactor/**`,
`test/**`, `ci/**`, `build/**`, `perf/**`, `deps/**`, `dependabot/**`). Enable
**Restrict creations**. `reusable-verify-pull-request.yml` has a branch-name job as a backstop.

Keep that list in sync with the `case` block in `actions/derive-version/action.yml` — a
prefix the ruleset allows but the action doesn't know falls through to patch
with a warning.

**On `main`.** Require a PR, require status checks, require up to date.

**On tags.** Target `v*`, **Restrict creations**, bypass only for the Actions
app. Stops anyone tagging a release from a laptop.

## Versioning this repo

Consumers pin `@v1`. Move `v1` forward for compatible changes; cut `v2` for
anything needing manifest changes — thirty repos means a breaking change here
is thirty PRs, so prefer additive keys with defaults.

Note the `Haam909/ci-workflows/...@v1` references inside the workflows and the
README need your real org name substituted.

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
- `pip-audit` has no severity threshold, so Python fails on any known
  vulnerability while node and dotnet fail on High/Critical only.
