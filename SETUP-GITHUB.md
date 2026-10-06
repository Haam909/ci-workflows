# Setting up the GitHub side

A from-zero guide. It assumes you've used git and GitHub but never set up CI.
Azure is not covered here — everything below works without it.

Work through it in order. Steps 1–6 get a pull request running checks, which
is the useful milestone. Steps 7–9 add releases.

---

## The words you'll see

**Workflow** — a YAML file in `.github/workflows/` that GitHub runs for you
when something happens. "Something happens" is the `on:` block: a push, a
pull request, a button click.

**Job** — one chunk of a workflow. Jobs run on separate machines, in parallel
unless you say otherwise. Each job gets a fresh Ubuntu VM that is destroyed
afterwards.

**Step** — one command or one action inside a job. Steps run in order on the
same machine.

**Action** — a reusable step someone else wrote, pulled in with `uses:`.
`actions/checkout@v4` is the one that copies your code onto the machine.

**Reusable workflow** — a workflow living in *another* repo that your repo
calls. That's what this project is. Instead of 30 copies of the same 300
lines, each repo has an 8-line file that says "run the shared one".

**Composite action** — several steps bundled together so they can be called
as one. The five folders under `actions/` are these.

**Runner** — the throwaway VM. `ubuntu-latest` is GitHub's, free for public
repos, with a monthly allowance for private ones.

**`GITHUB_TOKEN`** — a password GitHub creates automatically for each run and
throws away after. You never create or store it. It's how a workflow is
allowed to publish a package or create a release.

**Environment** — a named gate (`test`, `release`, `production`) you can put
rules on, like "a human must approve before this job runs".

**Ruleset** — repo rules, like "branches must be named a certain way" or
"main needs a pull request".

---

## How these pieces fit together

```
your-app repo                      ci-workflows repo
─────────────                      ─────────────────
.github/components.yml    ──────►  describes what's in your repo
.github/workflows/
  trigger-pull-request.yml ─uses─► reusable-verify-pull-request.yml
  trigger-merge-to-main.yml ─uses─► reusable-deploy-to-test.yml
  trigger-release.yml      ─uses─► reusable-release-to-production.yml
                                     │
                                     └─ uses ─► actions/install-toolchain
                                                actions/build-artifact
                                                actions/deliver-artifact
                                                actions/derive-version
```

The `trigger-*` files say **when**. The `reusable-*` files say **what**.
`components.yml` says **which pieces your repo contains**.

---

## Step 1 — Create the shared repo

On GitHub, create a new repository called `ci-workflows`.

**Make it public.** Not because the code is special, but because a private
repo can only be called by repos you've explicitly granted access to, and
that's one more thing to get wrong on day one. There are no secrets in it.

Unzip this project into it and push:

```bash
git init
git add -A
git commit -m "ci: shared workflows"
git branch -M main
git remote add origin https://github.com/YOURNAME/ci-workflows.git
git push -u origin main
```

## Step 2 — Put your own name in it

The files ship with a placeholder org called `org`. Replace it:

```bash
grep -rl 'Haam909/ci-workflows' . | xargs sed -i 's#Haam909/ci-workflows#YOURNAME/ci-workflows#g'
git commit -am "ci: point at this account"
git push
```

On macOS use `sed -i ''` instead of `sed -i`.

Check it worked — this should print your name, not `org`:

```bash
grep -rn 'uses: .*/ci-workflows' .github/workflows | head -3
```

## Step 3 — Tag it `v1`

Your other repos will refer to `@v1`. That tag has to exist or every run
fails immediately with "unable to resolve action".

```bash
git tag -a v1 -m "v1"
git push origin v1
```

While you're still changing things, move the tag rather than making new ones:

```bash
git tag -f v1 && git push -f origin v1
```

Forgetting this is the single most common reason a change "doesn't do
anything" — your app repo is still running the old tagged version.

## Step 4 — Set up your app repo

In the repo you want to build, copy the `examples/.github/` folder from this
project to your repo root. You should end up with:

```
.github/components.yml
.github/workflows/trigger-pull-request.yml
.github/workflows/trigger-merge-to-main.yml
.github/workflows/trigger-release.yml
```

Edit all four to replace `Haam909/ci-workflows` with `YOURNAME/ci-workflows`.

**To start with, delete `trigger-merge-to-main.yml` and
`trigger-release.yml`.** Get pull request checks working first. Add them back
in step 7.

## Step 5 — Describe your repo in `components.yml`

This is the only file you'll really edit. Delete every example component and
describe what you actually have. A C# API and a TypeScript front end:

```yaml
components:
  - name: api
    runtime: dotnet
    target: app-service
    project: src/Api/Api.csproj
    test-project: tests/Api.Tests/Api.Tests.csproj

  - name: web
    runtime: node
    target: app-service
    path: src/web
```

- `name` — anything; it shows up as the job name.
- `runtime` — `dotnet`, `node` (TypeScript *or* JavaScript), or `python`.
- `target` — where it eventually ships. Ignore this for now; it doesn't
  affect pull request checks.
- `project` — for dotnet, the path to the `.csproj`.
- `path` — for node and python, the folder containing `package.json` or
  `requirements.txt`. Leave it out if that's the repo root.

Each component becomes its own parallel job.

## Step 6 — Things your repo needs before checks will pass

The gate runs lint, typecheck, tests and a vulnerability scan. Some of that
needs files you may not have yet.

**C#** needs a lock file, which NuGet doesn't create unless you ask. Add to
each `.csproj`:

```xml
<PropertyGroup>
  <RestorePackagesWithLockFile>true</RestorePackagesWithLockFile>
</PropertyGroup>
```

then generate and commit it:

```bash
dotnet restore --use-lock-file
git add '**/packages.lock.json' && git commit -m "ci: lock files"
```

Without this, every run fails at restore.

**Node** needs `package-lock.json` committed — you almost certainly have it.
If `lint` or `test` scripts are missing from `package.json`, those steps are
skipped with a warning rather than failing, so you can add them later.

**Python** needs a hash-pinned lock file. If you only have
`requirements.txt`, it'll work but print a warning:

```bash
pip install pip-tools
pip-compile --generate-hashes -o requirements.lock.txt requirements.txt
git add requirements.lock.txt && git commit -m "ci: lock file"
```

Now push a branch and open a pull request:

```bash
git switch -c fix/try-ci
git commit --allow-empty -m "fix: testing ci"
git push -u origin fix/try-ci
```

Open the PR on GitHub and click the **Actions** tab. You should see a job per
component plus a `branch-name` job. If something's red, jump to
Troubleshooting at the bottom — that's expected on a first run.

The branch had to start with `fix/` — see step 8 for why.

---

Everything below is for releases. Skip it until checks are green.

## Step 7 — Create the environments

Repo **Settings → Environments → New environment**. Create three, named
exactly:

- `test`
- `release`
- `production`

On `release` only, tick **Required reviewers** and add yourself. This is the
gate: the release pauses there and waits for a human to click Approve. That's
the "ship it" decision, and it's the only one left in the whole pipeline.

Leave `test` and `production` with no rules. `production` doesn't need a gate
because `release` already gated it.

**Important on a personal account:** required reviewers only work on **public**
repos under GitHub Free. On a private personal repo the environment still
exists but won't pause for approval. If you're just testing, that's fine —
it'll run straight through.

Now restore the two trigger files you deleted in step 4.

## Step 8 — Rulesets

Repo **Settings → Rules → Rulesets → New ruleset**. You'll make three.

### 8a. Branch names

Version numbers are worked out from branch names, so they have to follow the
pattern. `feature/…` means the minor number goes up, `fix/…` means the patch
number goes up. A branch called `my-changes` tells the system nothing.

- New **branch** ruleset, name it "branch naming"
- Enforcement status: **Active**
- Target branches → **Include by pattern** → `**/*`
- Then **Exclude by pattern**, once each, for: `main`, `feature/**`,
  `feat/**`, `fix/**`, `hotfix/**`, `bugfix/**`, `breaking/**`, `chore/**`,
  `docs/**`, `refactor/**`, `test/**`, `ci/**`, `build/**`, `perf/**`,
  `deps/**`, `dependabot/**`
- Under Rules, tick **Restrict creations**

Read that as: "everything is blocked, except these." Pushing a badly named
branch is now rejected by the server.

There's also a `branch-name` job in the checks workflow doing the same test.
Belt and braces — the ruleset stops the push, the job stops the merge.

### 8b. Protect `main`

- New branch ruleset, "main"
- Target branches → **Include default branch**
- Tick **Require a pull request before merging**
- Tick **Require status checks to pass**, then search for and add each check.
  They're named `ci / <component name>` — `ci / api`, `ci / web` — plus
  `ci / branch-name`.
- Tick **Require branches to be up to date before merging**

Checks only appear in that search box *after* they've run at least once, so
do this after your first pull request, not before.

### 8c. Protect tags

Tags are the version history. Only the release workflow should create them.

- New **tag** ruleset, "release tags"
- Target tags → **Include by pattern** → `v*`
- Tick **Restrict creations**

The release workflow pushes tags using `GITHUB_TOKEN`, and rulesets apply to
that too. If the release fails with a 403 on `git push origin v1.4.0`, add
GitHub Actions to the ruleset's **Bypass list**. If you can't find it there,
set this ruleset to **Evaluate** while testing and switch it to Active once
everything works.

## Step 9 — Your first release

The version comes from tags, and derivation needs a starting point. With no
`v*` tag at all, the first release is just `0.1.0` regardless of what you
merged. Set the starting point by hand — the only tag you'll ever create
yourself:

```bash
git tag -a v0.1.0 -m "starting point"
git push origin v0.1.0
```

Then:

1. Merge a `fix/…` or `feature/…` branch into main. `trigger-merge-to-main`
   runs and records a deployment to the `test` environment.
2. Go to **Actions → Release → Run workflow**. Leave the major checkbox
   unticked. Leave **sha** blank to ship what's in test, or paste the commit
   you've signed off on. Click the green button.
3. It works out which commit to ship and what version it should be, then
   stops at the `release` gate. Open the run and click **Review deployments
   → Approve**.
4. It tags, builds, signs, and publishes a GitHub Release.

You never supply a version number, and the commit is optional. If you merged one `feature/` and
two `fix/` branches, it resolves to `0.2.0` — the biggest bump wins.

## Step 10 — Publishing packages (optional)

If any component has `target: package`, it publishes to GitHub Packages by
default using `GITHUB_TOKEN`. Two rules:

- **npm** package names must be scoped to your account:
  `"name": "@yourname/thing"` in `package.json`.
- **NuGet** needs `<RepositoryUrl>https://github.com/YOURNAME/REPO</RepositoryUrl>`
  in the `.csproj` so GitHub can link the package to the repo.

Python can't use GitHub Packages — there's no Python registry there. Those
need a `feed:` pointing elsewhere; see the Package feeds section in README.md.

---

## Troubleshooting

**"unable to resolve action … repository not found"**
The `v1` tag doesn't exist in `ci-workflows`, or the org name wasn't replaced,
or the repo is private and hasn't granted access. Check step 2 and step 3.

**"workflow was not found"**
Same causes. Also check the filename in the `uses:` line matches exactly —
it's `reusable-verify-pull-request.yml`, not `checks.yml`.

**My change to ci-workflows did nothing**
You didn't move the `v1` tag. `git tag -f v1 && git push -f origin v1`.

**"Dependencies lock file is not found"**
`package-lock.json` is missing, or `path:` in `components.yml` points at the
wrong folder.

**NU1004, or "packages.lock.json … is inconsistent"**
The C# lock file is missing or stale. `dotnet restore --use-lock-file`, then
commit the result.

**"Resource not accessible by integration"**
The token wasn't allowed to do something. Check **Settings → Actions →
General → Workflow permissions**, and make sure your trigger file has
`secrets: inherit`.

**"No successful deployment to test found"**
You ran Release before ever merging to main. The release only ships what's
already in test, so merge something first.

**The branch-name job failed**
Your branch doesn't start with an allowed prefix. Rename it:
`git branch -m fix/my-thing`.

**Nothing runs at all when I push**
Check the **Actions** tab is enabled for the repo, and that your workflow
files are in `.github/workflows/` exactly — a typo in that path means GitHub
never sees them.

**A pull request from a fork has no checks**
Expected. Forked pull requests don't get access to secrets. Use branches in
the repo itself.
