# Install feeds come from the repo's own package config, not the manifest

A component that installs packages from a Feed names that Feed in the repo's own `nuget.config`, `.npmrc` or pip index configuration. CI and `bin/ci` only supply credentials, picking them by the Feed's host: GitHub Packages on the repo's Host, or Azure Artifacts. Developers need those files to install locally anyway. Not adding a manifest key also keeps the change additive, so it ships by moving `v1` instead of requiring a manifest PR in every Consuming repo.

## Considered Options

- **A manifest key listing the Feeds.** Rejected: it duplicates what the package tools already read, and it would have to be kept in sync with those files by hand.
