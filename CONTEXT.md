# ci-workflows

Shared CI/CD that consuming repos call through thin trigger workflows. This glossary also covers the configurations the workflows are tested against.

## Language

**Host**:
The GitHub instance a repo lives on: `github.com`, or one `<tenant>.ghe.com` data-residency tenant. It decides hostnames for the API, the package registry, and the OIDC issuer.
_Avoid_: GHE, enterprise (as a host), server

**Plan**:
The account type that owns a repo: a personal account, a free organization, or an organization in an enterprise account (GHEC). It decides which features exist (org rulesets, internal repos, attestations on private repos), not hostnames.
_Avoid_: tier, enterprise (as a host)

**Feed**:
The package registry a `package` component publishes to, and that other components may install from: GitHub Packages on the component's host, or Azure Artifacts.
_Avoid_: registry, repository, source

**Consuming repo**:
A repo that calls ci-workflows through the trigger workflows and holds a component manifest.
_Avoid_: consumer, client repo

## Testing

**Row**:
One configuration in the onboard harness, run end to end on a Sandbox from onboarding to a release.
_Avoid_: case, scenario

**Sandbox**:
A reusable test repo from the harness's pool, reset before each Row runs in it.
_Avoid_: test repo, fixture repo

**Publish row**:
A Row whose release publishes a package to a Feed.

**Install row**:
A Row with a component that installs a package from a Feed, filled earlier by a Publish row.
_Avoid_: consumer row

**Probe**:
A one-off workflow run on a new Host to find which capabilities (Feeds, attestation, signing, Azure login, cross-host calls) work there before any Rows target it.
