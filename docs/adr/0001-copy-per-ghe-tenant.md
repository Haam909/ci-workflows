# A GHE.com tenant calls its own copy of ci-workflows

Repos on a `<tenant>.ghe.com` Host call a copy of ci-workflows that lives inside that tenant, with its `Haam909/ci-workflows/...@v1` references rewritten to the tenant's owner. They do not call the github.com repo. A `GITHUB_TOKEN` on GHE.com "does not grant access to resources on GitHub.com" (GitHub Docs, *Feature overview for GitHub Enterprise Cloud with data residency*). A data-residency customer also won't want its pipeline depending on a public repo on another host.

## Considered Options

- **Call the github.com copy directly.** Rejected even if the GHE.com Probe shows it works, for the residency reason above.

## Consequences

- Moving `v1` on github.com does not reach tenant copies. Each tenant's copy has to be updated separately.
- A tenant's copy can't run as it stands. The reusable workflows check out their own actions with the calling repo's `GITHUB_TOKEN` (`job.workflow_sha`, #52), and that token's "permissions are limited to the repository that contains your workflow" (GitHub Docs, *GITHUB_TOKEN*). A tenant's copy can't be public: "Because Enterprise Managed Users is the only option for identity management on GHE.com", features it lacks are lacking there too, "Notably, these include gists and public repositories." (GitHub Docs, *Feature overview for GitHub Enterprise Cloud with data residency*). So the checkout needs a token that can read the copy, unless an internal copy turns out to be readable with `GITHUB_TOKEN` (untested). Whether GHE.com has the `job.workflow_*` properties is untested too; GitHub Enterprise Server doesn't.
