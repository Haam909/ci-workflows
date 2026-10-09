# A GHE.com tenant calls its own copy of ci-workflows

Repos on a `<tenant>.ghe.com` Host call a copy of ci-workflows that lives inside that tenant, with its `Haam909/ci-workflows/...@v1` references rewritten to the tenant's owner. They do not call the github.com repo. A `GITHUB_TOKEN` on GHE.com "does not grant access to resources on GitHub.com" (GitHub Docs, *Feature overview for GitHub Enterprise Cloud with data residency*). A data-residency customer also won't want its pipeline depending on a public repo on another host.

## Considered Options

- **Call the github.com copy directly.** Rejected even if the GHE.com Probe shows it works, for the residency reason above.

## Consequences

- Moving `v1` on github.com does not reach tenant copies. Each tenant's copy has to be updated separately.
