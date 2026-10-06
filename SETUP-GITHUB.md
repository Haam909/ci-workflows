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
as one. The four folders under `actions/` are these.

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

The files reference `Haam909/ci-workflows`, the account this copy was set up
under. If you're setting it up anywhere else, replace it:

```bash
grep -rl 'Haam909/ci-workflows' --exclude-dir=.git . | xargs sed -i 's#Haam909/ci-workflows#YOURNAME/ci-workflows#g'
git commit -am "ci: point at this account"
git push
```

On macOS use `sed -i ''` instead of `sed -i`.

Check it worked — this should print your name:

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

If you renamed the account in step 2, the copies already have your name;
otherwise edit all four to replace `Haam909/ci-workflows` with
`YOURNAME/ci-workflows`.

Leave the `permissions:` block in each trigger file alone. New repos give
workflows a read-only token by default, and a shared workflow can't ask for
more than its caller grants, so without it the run fails before any job starts.

**To start with, delete `trigger-merge-to-main.yml` and
`trigger-release.yml`.** Get pull request checks working first. Add them back
in step 7 (copy them from `examples/` again).

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

Each component becomes its own parallel job when building and deploying.
Pull request checks don't depend on it.

## Step 6 — Things your repo needs before checks will pass

The checks — lint, typecheck, unit and integration tests — run **on your
machine** through `bin/ci`, before each push. CI doesn't re-run them; the PR
gate checks two things: the branch is current with `main`, and the commit has a
green `local/ci` signoff from your machine.

**Install the local gate first** — the PR gate fails without it. Follow
"Installing it in a repo" in LOCAL-GATE.md (copy three scripts, mark them
executable, `git config core.hooksPath .githooks`). Then run `bin/ci` once by
hand; it needs some files you may not have yet.

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
A missing `lint` script is fine (the step reports as passed). A missing `test`
script fails `bin/ci`, so add one — `"test": "node --test"` is enough to start.

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

The push runs the hook: it checks you're current with `main`, runs `bin/ci`,
and posts the signoff once the push lands. Nothing runs on GitHub yet — the
checks start when the pull request exists.

Open the PR on GitHub. You should see two checks, `ci / gate` and
`ci / branch-name`, plus the `local/ci` status from your machine. If
something's red, jump to Troubleshooting at the bottom — that's expected on a
first run.

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

Now restore the two trigger files you deleted in step 4 — but set the starting
version **first**, in the same go. The version comes from tags; with no `v*`
tag at all, every merge builds `0.1.0-alpha.0` and the first release is
`0.1.0` regardless of what you merged. And the commit that adds
`trigger-merge-to-main.yml` would itself run a deploy to test. So: commit the
restored triggers with `[skip ci]`, and tag that commit as the starting point —
the only tag you'll ever create yourself:

```bash
cp <ci-workflows>/examples/.github/workflows/trigger-merge-to-main.yml \
   <ci-workflows>/examples/.github/workflows/trigger-release.yml .github/workflows/
git add .github/workflows
git commit -m "ci: restore merge and release triggers [skip ci]"
git push
git tag -a v0.1.0 -m "starting point"
git push origin v0.1.0
```

Do this before step 8 — once `main` is protected, it can only change through a
pull request.

## Step 8 — Rulesets

Repo **Settings → Rules → Rulesets → New ruleset**. You'll make three.

### 8a. Branch names

Version numbers are worked out from branch names, so they have to follow the
pattern. `feature/…` means the minor number goes up, `fix/…` means the patch
number goes up. A branch called `my-changes` tells the system nothing.

- New **branch** ruleset, name it "branch naming"
- Enforcement status: **Active**
- Target branches → **Include all branches**
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
- Tick **Require a pull request before merging**. Working alone, set required
  approvals to **0** — GitHub won't let you approve your own pull request.
- Tick **Require status checks to pass**, then search for and add each check:
  `ci / gate`, `ci / branch-name` and `local/ci`. (There are no
  per-component checks.)
- Tick **Require branches to be up to date before merging**
- Tick **Require linear history**. Pull requests then merge by squash or
  rebase only; a merge commit is refused ("Merge commits are not allowed on
  this repository"). It keeps a branch that forked before a release from
  landing after it.

Checks only appear in that search box *after* they've run at least once, so
do this after your first pull request, not before.

### 8c. Protect tags

Tags are the version history. Only the release workflow should create them.

- New **tag** ruleset, "release tags"
- Target tags → **Include by pattern** → `v*`
- Tick **Restrict creations**

The release workflow pushes tags using `GITHUB_TOKEN`, and rulesets apply to
that too, so add **GitHub Actions** to the ruleset's **Bypass list** — without
it every release fails at `git push origin vX.Y.Z`.

**On a personal account, skip 8c.** GitHub refuses the Actions bypass there
("Actor GitHub Actions integration must be part of the ruleset source or owner
organization"), and the Evaluate fallback needs Enterprise ("Enforcement
evaluate option is not supported on this plan"). The rule needs repos owned by
an organization.

## Step 9 — Your first release

You tagged the starting point in step 7. Then:

1. Merge a `fix/…` or `feature/…` branch into main. `trigger-merge-to-main`
   runs and records a deployment to the `test` environment.
2. Go to **Actions → Release → Run workflow**. Leave the major checkbox
   unticked. Leave **sha** blank to ship what's in test, or paste the commit
   you've signed off on (any commit on `main` after the last release). Click
   the green button.
3. It works out which commit to ship and what version it should be, then
   stops at the `release` gate. Open the run and click **Review deployments
   → Approve**.
4. It builds and signs, creates the tag and a **draft** GitHub Release,
   promotes, and only then publishes the release.

If promotion fails, the release stays a draft. Fix the cause and click
**Re-run failed jobs** on the run — see "What a release does" in README.md.

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

**Check the package's visibility after the first publish.** Published from a
public repo, the package came out **public**, and that can't be reversed.
If it must stay private, publish from a private repo or to a private feed.

The repo needs **Write** on the package: package page → **Package settings**
(`https://github.com/users/YOURNAME/packages/npm/PACKAGE/settings` for an npm
package on a personal account) → **Manage Actions access**.

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

**The run fails instantly with "This run likely failed because of a workflow file issue"**
That's all `gh run view` says. Open the run page in the browser for the real
error. The common one is "The workflow is requesting 'pull-requests: read,
statuses: read', but is only allowed 'pull-requests: none, statuses: none'":
the trigger file is missing its `permissions:` block. Copy it again from
`examples/`.

**"Resource not accessible by integration"**
The token wasn't allowed to do something. Check the trigger file's
`permissions:` block matches the one in `examples/`, and that it has
`secrets: inherit`.

**"No successful deployment to test found"**
You ran Release with **sha** blank before ever merging to main. Merge
something first, or pass the commit you want in **sha**.

**"… is already included in vX.Y.Z. Choose a commit after it."**
The commit you passed in **sha** was already released. Versions only move
forward.

**"… does not contain vX.Y.Z: it branched off before that release."**
The commit sits on a branch that forked before the latest release. Releasing
it would ship without that release's changes. Choose a commit on `main` after
the release.

**`403 … permission_denied: write_package` when publishing**
The repo has only Read on the package. Package settings → **Manage Actions
access** → set the repo to **Write**, then **Re-run failed jobs**.

**My pull request shows no checks after a push**
If the PR has merge conflicts, GitHub doesn't start `pull_request` runs at
all. Rebase onto `main` and push again.

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
