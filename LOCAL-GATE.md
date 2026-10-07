# The local gate

Unit tests run on the developer's machine, before the push. A commit status
records that they passed, pinned to the exact commit. CI checks that status
instead of re-running the tests, and separately confirms the branch is still
current with main.

The idea is from Basecamp, by way of Rails 8.1, which now generates a `bin/ci`
and `config/ci.rb` by default. Their argument is that a suite only runnable in
the cloud can't be shaped or sped up, and modern hardware makes the cloud
unnecessary for most suites.

## The flow

```
  you                                          GitHub
  ───                                          ──────
  git push
   └─ pre-push hook
       ├─ is my root current with main?  ──── fetch origin/main
       ├─ bin/ci  (lint, typecheck, unit, integration)
       └─ push proceeds ──────────────────────► objects land
           └─ bin/signoff --wait ─────────────► status local/ci = success
                                                  pinned to that SHA
  open (or update) a PR ─────────────────────► pull_request run
                                               gate job
                                                ├─ is main still an ancestor?
                                                └─ is local/ci green on this SHA?
                                               branch-name job
                                                └─ does the branch have a known prefix?
```

The PR checks run on `pull_request` only, not on every branch push — a push
trigger as well would report each check twice per commit, with a skipped
`branch-name` that counts as passed.

The staleness check happens twice on purpose. Locally it's advice and can be
skipped. In CI it's enforcement, because main can move between your push and
your merge.

## What runs where

| | Local pre-push | PR | Merge to main |
|---|---|---|---|
| Up to date with main | advisory | enforced | — |
| Lint, typecheck | ✓ | — | — |
| Unit tests | ✓ | — | — |
| Integration tests | ✓ | — | — |
| Signoff present | — | enforced | — |
| Build + deploy to test | — | — | ✓ |

Vulnerable dependencies are handled by GitHub's own Dependabot alerts, on by
default — no workflow needed. Turn them on under Settings → Code security.

Integration tests run locally because they are the checks most likely to
catch a real defect — deferring them to a server after the merge defeats the
point of gating. Testcontainers drives the local Docker daemon, so `bin/ci`
refuses to run rather than silently skipping them when Docker is down.

Podman works too. On Windows, the Podman machine serves the Docker API on
`\\.\pipe\docker_engine`, which is where Testcontainers looks by default, so
nothing needs configuring. Elsewhere, point `DOCKER_HOST` at Podman's socket.

Vulnerability scanning is deliberately not on the gate. A CVE published
overnight has nothing to do with the code you are pushing, and blocking an
unrelated push on it is how people learn to ignore CI.

CI does not re-run the checks at all. That is the whole point: the per-runtime
check logic lives in `bin/ci` and nowhere else, so there is one copy to keep
correct rather than two that drift.

## Installing it in a repo

`local/bin/onboard init` does all of this section (README.md, "Onboarding a
repo"). By hand:

Copy `local/bin/ci`, `local/bin/signoff` and `local/githooks/pre-push` into
the repo as `bin/ci`, `bin/signoff` and `.githooks/pre-push`, then:

```bash
chmod +x bin/ci bin/signoff .githooks/pre-push
git config core.hooksPath .githooks
```

On Windows `chmod` doesn't reach git, so record the executable bit directly.
`update-index` only works on files git already tracks, so add them first;
otherwise it fails with "cannot add to the index - missing --add option?":

```bash
git add bin .githooks
git update-index --chmod=+x bin/ci bin/signoff .githooks/pre-push
```

In a .NET repo, `git add bin` fails with "The following paths are ignored by
one of your .gitignore files". The .NET `.gitignore` (`dotnet new gitignore`)
has `[Bb]in/`, which ignores every `bin/` folder, this one included.
Re-include the top-level one; build output stays ignored:

```
# Local CI gate scripts
!/bin/
```

and keep the scripts' LF line endings — with `core.autocrlf=true` a CRLF
checkout breaks them under Git Bash. A `.gitattributes` line does it:

```
* text=auto eol=lf
```

`core.hooksPath` is per-clone, so each developer runs that line once. Put it
in your setup script. Hooks are never installed by cloning — that would be a
remote code execution hole, and git won't do it.

Requirements: `bash`, `yq`, `gh` (authenticated with `gh auth login`), Docker
or Podman running if the manifest mentions integration tests (see README.md), plus
whatever toolchains the repo's components use. On Windows the hook runs under
Git Bash, which ships with Git for Windows, and `yq` installs with
`winget install --id MikeFarah.yq -e --source winget` — open a new terminal
afterwards so it's on `PATH`.

From PowerShell, `bash` can resolve to WSL (`C:\Windows\System32\bash.exe`)
rather than Git Bash, so run `bin/ci` by hand with
`& "C:\Program Files\Git\bin\bash.exe" bin/ci` or from a Git Bash window.
`git push` from PowerShell is fine: git runs the hook with its own bash.

## Using it

```bash
bin/ci                  # the gate: lint, typecheck, unit, integration
bin/ci --quick          # unit tests only — fast loop while coding
bin/ci --install        # restore dependencies first, after a pull
bin/ci --only api       # one component
bin/ci --fail-fast      # stop at the first failure
```

A plain `bin/ci` is what the signoff attests to. The commit status records no
flags, so CI cannot tell `--quick` from a full run — which is exactly why the
hook always runs the full set, and why `--quick` is for iterating only.

`bin/ci` reads `.github/components.yml` — the same manifest the workflows
read — so adding a component adds it here too, and a `commands:` override
applies in both places.

Pushing normally triggers the hook. To skip it:

```bash
git push --no-verify
```

Nothing is lost by skipping: there's no signoff status, so the CI gate fails
and tells you to run `bin/ci`. The hook is a convenience, not the control.

If the background signoff misses — a slow push, a dropped connection — post
it by hand:

```bash
bin/signoff              # HEAD
bin/signoff <sha>        # a specific commit
```

The gate doesn't re-check by itself when the status arrives. If it already
failed with "No green 'local/ci' status", re-run it after signing off:
**Re-run failed jobs** on the run, or `gh run rerun <run-id> --failed`.

## Branch protection

Add `local/ci` as a required status check on main, alongside `ci / gate` and
`ci / branch-name` — those three are the whole list. With them required,
**Require branches to be up to
date before merging** becomes available, since that setting is a sub-option
of required status checks rather than something you can turn on alone.

That gives belt and braces: the strict setting blocks a stale branch at the
merge button, and the gate job explains why with a commit count.

## Honest limits

**It's weak enforcement, deliberately.** Anyone can run `bin/signoff` without
running `bin/ci`. Brandur's take on Basecamp's version is that a pattern of
bad signoffs is a workplace problem you deal with like any other, and that
even mandatory checks usually have a bypass someone can abuse. If your threat
model needs more than that, don't use this.

**Green locally isn't green everywhere.** A developer on a different SDK
patch, a different Python version, or with stale dependencies can sign off on
a run that would fail on a clean machine. `bin/ci --install` before signing
off reduces it (for dotnet the locked restore runs on every `bin/ci`, so a
stale `packages.lock.json` always fails locally); running `bin/ci` in CI as well would remove it, at the cost
of runner time. That isn't set up.

**Status is per-SHA.** Amend a commit, rebase, or push one more fix and the
signoff is gone, because it was attached to the old SHA. That's the correct
behaviour and it will still annoy people the first few times.

**The scripts are copies.** Each repo has its own `bin/ci`, so thirty repos
means thirty copies that can drift from the version here. Re-copy them when
you move the `v1` tag.

**Pre-push can't post the status.** The API rejects a status for a commit
GitHub hasn't seen, and git has no post-push hook, so the hook spawns a short
retry in the background. It usually lands within a couple of seconds (it
does under Git Bash on Windows too). When it doesn't, `bin/signoff <sha>` is
the fallback.
