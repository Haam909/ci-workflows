# Setting up the accounts outside a Consuming repo

Everything a Consuming repo needs that isn't in GitHub's repo settings, built
from nothing. Do the steps in order; each ends with the documentation page it
comes from. `SETUP-GITHUB.md` stays about the repo itself.

Recovered on 2026-10-16 from `tests/onboard/SANDBOXES.md` at `93cd2a7`, which
was written for the deleted onboard harness, and brought in line with the
credentials the proof repos log in with.

## Azure DevOps, Azure Artifacts and Entra

A `package` component with a `feed` on `pkgs.dev.azure.com` publishes with an
Entra token that `azure/login` gets through OIDC, so there is no PAT. The repo
needs an Azure DevOps organization with a Feed, an Entra app registration
that Azure DevOps knows, and federated credentials that accept the repo's
GitHub OIDC tokens.

The credentials here are two flexible federated credentials that accept every
repo of one owner whose name starts with a chosen prefix, so a new Consuming
repo needs no change in Entra. Exact-match credentials would need two or three
per repo against a limit of 20 per app, and a new subject every time a repo is
recreated, because GitHub's subject now carries the repo's ID.

1. Have an Azure subscription in the tenant you'll use. Creating an Azure
   DevOps organization needs one, even though the free tier covers what a
   Feed uses. In the Azure portal, **Subscriptions** lists yours; if it's
   empty, **+ Add** creates one.
   [Create an organization: prerequisites](https://learn.microsoft.com/en-us/azure/devops/organizations/accounts/create-organization?view=azure-devops#prerequisites),
   [Create a subscription](https://learn.microsoft.com/en-us/azure/cost-management-billing/manage/create-subscription)

2. Create the Azure DevOps organization. In the Azure portal, search for
   **Azure DevOps organizations** and open it, then select **New
   organization**. (Signing in from `dev.azure.com` can land you back in the
   portal instead.) Give it a name of letters, numbers and hyphens, pick a
   hosting geography and the subscription from step 1, and select
   **Continue**. It lives at `https://dev.azure.com/<org>`.
   [Create an organization](https://learn.microsoft.com/en-us/azure/devops/organizations/accounts/create-organization?view=azure-devops#create-an-organization)

3. Create a project. At `https://dev.azure.com/<org>`, select **New project**,
   give it a name, leave it **Private**, and select **Create**.
   [Create a project](https://learn.microsoft.com/en-us/azure/devops/organizations/projects/create-project?view=azure-devops)

4. Create the org-scoped Feed. In the project, select **Artifacts** >
   **Create Feed**, give it a name, tick **Include packages from common
   public sources**, set **Scope** to **Organization**, and select **Create**.
   Scope can't be changed afterwards.
   [Create a feed](https://learn.microsoft.com/en-us/azure/devops/artifacts/feeds/project-scoped-feeds?view=azure-devops#create-a-feed)

5. Create the project-scoped Feed the same way, with **Scope** set to
   **Project**. Skip this if you only need one Feed; the two exist here
   because they have different URLs and both have to be proven.
   [Create a feed](https://learn.microsoft.com/en-us/azure/devops/artifacts/feeds/project-scoped-feeds?view=azure-devops#create-a-feed)

6. Check each Feed's scope from its URL. Select **Connect to feed** >
   **dotnet** and read the `index.json` URL. The org-scoped one is
   `https://pkgs.dev.azure.com/<org>/_packaging/<feed>/nuget/v3/index.json`;
   the project-scoped one has the project after the organization,
   `https://pkgs.dev.azure.com/<org>/<project>/_packaging/<feed>/nuget/v3/index.json`.
   A Feed with the wrong scope has to be deleted (**Feed Settings** > **Delete
   feed**) and created again; its name stays taken until it's permanently
   deleted from the **Deleted Feeds** tab. This URL, with `nuget/v3/index.json`
   swapped for `npm/registry/` or `pypi/upload/` per runtime, is the
   component's `feed` (README.md, Package feeds).
   [Project-scoped vs organization-scoped feeds](https://learn.microsoft.com/en-us/azure/devops/artifacts/feeds/project-scoped-feeds?view=azure-devops#project-scoped-vs-organization-scoped-feeds),
   [Delete a feed](https://learn.microsoft.com/en-us/azure/devops/artifacts/concepts/feeds?view=azure-devops#delete-a-feed)

7. Register the Entra app. In the [Microsoft Entra admin
   center](https://entra.microsoft.com), in the same tenant as the
   subscription, go to **Entra ID** > **App registrations** > **New
   registration**. Name it, choose **Single tenant only**, leave **Redirect
   URI** empty, and select **Register**. From **Overview**, note the
   **Application (client) ID** (`AZURE_CLIENT_ID`) and the **Directory
   (tenant) ID** (`AZURE_TENANT_ID`).
   [Register an application](https://learn.microsoft.com/en-us/entra/identity-platform/quickstart-register-app#register-an-application)

8. Sign `az` in to that tenant. Name the tenant: a sign-in that tries every
   tenant fails on the one that wants multifactor authentication. Allow no
   subscriptions, so the sign-in works for directory commands whatever
   subscription you can see. `az login --help` documents
   `--allow-no-subscriptions` as "useful to run tenant-level commands, such
   as 'az ad'".

   ```powershell
   az config set core.login_experience_v2=off
   az login --tenant <tenant-id> --allow-no-subscriptions
   ```

   Run it on its own, not pasted together with the next step: `az login`
   reads what follows it as input.
   [Sign in with a different tenant](https://learn.microsoft.com/en-us/cli/azure/authenticate-azure-cli-interactively#sign-in-with-a-different-tenant)

9. Choose the prefix and read the IDs. Every Consuming repo that logs in to
   Azure must be named `<prefix>…`; the proof repos use `ciw-sbx-`. The
   credential binds to the owner's numeric ID, which survives a rename of
   the account:

   ```powershell
   gh api users/<owner> --jq .id
   gh api repos/<owner>/<repo>/actions/oidc/customization/sub --jq .sub_claim_prefix
   ```

   The first works for a user and an organization alike; `Haam909` prints
   `35454030`. The second shows the subject format of a repo:
   `Haam909/ciw-sbx-feeds` prints
   `repo:Haam909@35454030/ciw-sbx-feeds@1422200050`, the immutable format,
   which every repo created, renamed or transferred from 15 July 2026 gets.
   A repo that prints `repo:<owner>/<repo>` still has the name-based format
   and needs `repo:<owner>/` in place of `repo:<owner>@<owner-id>/` in
   step 10.
   [Flexible federated identity credentials: GitHub](https://learn.microsoft.com/en-us/entra/workload-id/workload-identities-flexible-federated-identity-credentials#issuer-urls-supported-claims-and-operators-by-platform)
   ("Starting July 15, 2026, GitHub applies the immutable format
   automatically to repositories that are created, renamed, or transferred.
   Existing repositories keep the name-based format until you opt in."),
   [Immutable subject claims for GitHub Actions OIDC tokens](https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/)

10. Add the two flexible credentials. The merge run logs in under
    `environment: test` and Deploy under `environment: production`. The
    Release build runs under no environment, from `main`, and logs in there
    for package Feeds and for a `container` push. So one credential matches
    any environment and one matches `main`:

    | Name | `sub` must match | Used by |
    |---|---|---|
    | `<name>` | `repo:<owner>@<owner-id>/<prefix>*:environment:*` | merge run, Deploy |
    | `<name>-main` | `repo:<owner>@<owner-id>/<prefix>*:ref:refs/heads/main` | Release build |

    The `*` after the prefix also matches the `@<repo-id>` that follows the
    repo name. Each expression also requires `repository_owner_id` to be the
    owner's ID: for GitHub a flexible credential "must match the `sub` claim
    and one or both of the following immutable claims", `repository_id` and
    `repository_owner_id`. That keeps out other owners, not other repos of
    this owner: anyone who can create a `<prefix>…` repo under the owner can
    log in as the app. To bind one repo instead, put `<repo>@<repo-id>` in
    place of `<prefix>*` and add `and claims['repository_id'] eq '<repo-id>'`.

    `az ad app federated-credential` can't create these ("Explicit flexible
    federated identity credential support doesn't yet exist within Azure
    CLI, Azure PowerShell, or Terraform providers"), so they go through
    Microsoft Graph `beta` with `az rest`. Save this as a `.ps1` file, set the
    five values at the top, and run it. The body goes in a file because
    `az.cmd` mangles brackets and quotes passed from PowerShell.

    ```powershell
    $ErrorActionPreference = 'Stop'
    $app     = '<client-id>'
    $owner   = '<owner>'
    $ownerId = '<owner-id>'
    $prefix  = '<prefix>'
    $name    = '<name>'
    $objectId = az ad app show --id $app --query id -o tsv
    $subjects = [ordered]@{
      $name         = 'environment:*'
      "$name-main"  = 'ref:refs/heads/main'
    }
    foreach ($n in $subjects.Keys) {
      $body = @{
        name                     = $n
        issuer                   = 'https://token.actions.githubusercontent.com'
        audiences                = @('api://AzureADTokenExchange')
        subject                  = $null
        claimsMatchingExpression = @{
          value           = "claims['sub'] matches 'repo:${owner}@${ownerId}/${prefix}*:$($subjects[$n])' and claims['repository_owner_id'] eq '$ownerId'"
          languageVersion = 1
        }
      } | ConvertTo-Json -Depth 3
      $tmp = New-TemporaryFile
      try {
        [IO.File]::WriteAllText($tmp, $body)
        az rest --method post --url "https://graph.microsoft.com/beta/applications/$objectId/federatedIdentityCredentials" --headers 'Content-Type=application/json' --body "@$tmp" --query name -o tsv
        if ($LASTEXITCODE -ne 0) { throw "creating $n failed" }
      } finally {
        Remove-Item $tmp
      }
    }
    ```

    It prints the two names. `subject` is null because "If
    `claimsMatchingExpression` is defined, `subject` must be set to null",
    and `languageVersion` "should always be set to 1".
    [Flexible federated identity credentials](https://learn.microsoft.com/en-us/entra/workload-id/workload-identities-flexible-federated-identity-credentials),
    [Azure CLI, Azure PowerShell, and Terraform providers](https://learn.microsoft.com/en-us/entra/workload-id/workload-identities-flexible-federated-identity-credentials#azure-cli-azure-powershell-and-terraform-providers)

11. Check the credentials. `az ad app federated-credential list` shows their
    names but not their expressions, so read them through Graph. The app's
    object ID is what `az ad app show --id <client-id> --query id -o tsv`
    prints.

    ```powershell
    az rest --method get --url "https://graph.microsoft.com/beta/applications/<object-id>/federatedIdentityCredentials" --query "value[].{name:name, expression:claimsMatchingExpression.value}" -o table
    ```

    Each row shows an expression from step 10 with your values in it.
    [Flexible federated identity credential properties](https://learn.microsoft.com/en-us/entra/workload-id/workload-identities-flexible-federated-identity-credentials#flexible-federated-identity-credential-properties)

12. Connect the Azure DevOps organization to the tenant. An organization
    created while signed in with a personal Microsoft account isn't
    connected to any directory, and then it refuses the Entra tokens that
    `az` and `azure/login` get ("Identity … has not been materialized"), and
    no service principal can be added to it. Check which directory it's
    connected to; all zeros means none:

    ```powershell
    (Invoke-WebRequest https://dev.azure.com/<org>/_apis/connectionData -MaximumRedirection 0 -SkipHttpErrorCheck -ErrorAction SilentlyContinue).Headers['X-VSS-ResourceTenant']
    ```

    If it isn't `<tenant-id>`, go to **Organization settings** > **Microsoft
    Entra ID** > **Connect directory**, pick the directory from step 7, select
    **Connect**, then **Sign out**. Sign back in with the tenant's identity,
    and under **Organization settings** > **Users**, **Resolve** your old
    Microsoft account to it so you stay the organization's owner and the
    Feeds' owner. Run the check again; it prints `<tenant-id>`.
    [Connect your organization to Microsoft Entra ID](https://learn.microsoft.com/en-us/azure/devops/organizations/accounts/connect-organization-to-azure-ad?view=azure-devops#connect-your-organization-to-microsoft-entra-id),
    [Service principals: prerequisites](https://learn.microsoft.com/en-us/azure/devops/integrate/get-started/authentication/service-principal-managed-identity?view=azure-devops#prerequisites)

13. Find the app's service principal. Azure DevOps adds it by the service
    principal's Object ID, which is not the one under **App registrations**.
    In the Microsoft Entra admin center, go to **Entra ID** > **Enterprise
    applications**, open the app from step 7, and note its **Object ID**.
    [Use service principals and managed identities: create a service principal](https://learn.microsoft.com/en-us/azure/devops/integrate/get-started/authentication/service-principal-managed-identity?view=azure-devops#create-a-service-principal)

14. Add the service principal to the Azure DevOps organization. At
    `https://dev.azure.com/<org>`, go to **Organization settings** >
    **Users** > **Add users**, enter the app's display name, choose
    **Stakeholder** access (it includes Azure Artifacts, and costs nothing),
    add it to the project from step 3, and select **Add**. No invitation is
    sent.
    [Add the identity to Azure DevOps](https://learn.microsoft.com/en-us/azure/devops/integrate/get-started/authentication/service-principal-managed-identity?view=azure-devops#add-the-identity-to-azure-devops),
    [Access levels: Artifacts](https://learn.microsoft.com/en-us/azure/devops/organizations/security/access-levels?view=azure-devops#supported-access-levels)

15. Let it publish to the Feed. Open **Artifacts**, pick the Feed, select the
    gear icon for **Feed settings** > **Permissions** > **Add users/groups**,
    add the service principal with the **Feed Publisher (Contributor)**
    role, and select **Save**. Leave yourself **Feed Owner**: only an owner
    can delete packages, and a proof repo's throwaway versions are deleted
    by hand afterwards.
    [Manage permissions: feed settings](https://learn.microsoft.com/en-us/azure/devops/artifacts/feeds/feed-permissions?view=azure-devops#feed-settings),
    [Feed roles and permissions](https://learn.microsoft.com/en-us/azure/devops/artifacts/feeds/feed-permissions?view=azure-devops#feed-roles-and-permissions)

16. Configure the Consuming repo. Set the repo variables `AZURE_CLIENT_ID`
    and `AZURE_TENANT_ID` from step 7; `AZURE_SUBSCRIPTION_ID` only if a
    component also deploys to Azure, since a `package` component's
    `azure/login` runs with `allow-no-subscriptions`. Put the Feed URL from
    step 6 on the component as `feed:`. The repo's name must start with the
    prefix from step 9: once `AZURE_CLIENT_ID` is set, every job of the merge
    run and the Release build logs in to Azure, and fails if no credential
    matches. The next merge to `main` publishes a prerelease to the Feed; the
    first Deploy publishes the stable version.

    ```bash
    gh variable set AZURE_CLIENT_ID -R <owner>/<repo> --body <client-id>
    gh variable set AZURE_TENANT_ID -R <owner>/<repo> --body <tenant-id>
    ```

    [Use variables: creating configuration variables for a repository](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-variables#creating-configuration-variables-for-a-repository),
    [gh variable set](https://cli.github.com/manual/gh_variable_set),
    [azure/login: Login without subscription](https://github.com/Azure/login/blob/master/README.md)

## GitHub Enterprise Cloud trial

The Enterprise Plan proofs need an organization on GitHub Enterprise Cloud:
org rulesets, a team as required reviewer, a `v*` tag ruleset with a bypass,
internal repos and attestations on private repos. A trial gives one with no
payment method. "The trial lasts for 30 days", with up to 50 licenses and
3,000 minutes of standard GitHub-hosted runners. Run on 2026-10-21 as
enterprise `haamtesting`, organization `HaamTesting`, team `HaamTesting` and
app `haamtestingapp`.

1. Start the trial. Signed in as the account that will own the enterprise,
   select **Set up a trial of GitHub Enterprise Cloud** on the trial page and
   choose an enterprise with **personal accounts**, not managed users; the
   managed-users trial is the GHE.com section below. Only managed users are
   asked where to host it ("If you choose an enterprise with managed users,
   you'll also choose whether to create your trial on GitHub.com or
   GHE.com"). The enterprise lives at `https://github.com/enterprises/<slug>`.
   [Setting up a trial of GitHub Enterprise Cloud](https://docs.github.com/en/enterprise-cloud@latest/admin/overview/setting-up-a-trial-of-github-enterprise-cloud),
   [Choosing an enterprise type](https://docs.github.com/en/enterprise-cloud@latest/admin/concepts/enterprise-fundamentals/choose-an-enterprise-type)

2. Create the organization. On the enterprise's page, select
   **Organizations** > **New organization**, name it, select **Create
   organization**, leave **Invite owners** empty and select **Finish**. Pick
   a name you'll keep: "Organizations created during the trial cannot be
   removed from the enterprise account until you purchase GitHub
   Enterprise." Check it's on the Plan; `HaamTesting` prints `enterprise 50`:

   ```bash
   gh api orgs/<org> --jq '"\(.plan.name) \(.plan.seats)"'
   ```

   [Adding organizations to your enterprise](https://docs.github.com/en/enterprise-cloud@latest/admin/managing-accounts-and-repositories/managing-organizations-in-your-enterprise/adding-organizations-to-your-enterprise),
   [Setting up a trial of GitHub Enterprise Cloud](https://docs.github.com/en/enterprise-cloud@latest/admin/overview/setting-up-a-trial-of-github-enterprise-cloud)

3. Create the team. In the organization, select **Teams** > **New team**,
   name it, leave **Parent team** empty and select **Create team**. Its
   creator is its maintainer; this prints `maintainer`:

   ```bash
   gh api orgs/<org>/teams/<team-slug>/memberships/<you> --jq .role
   ```

   [Creating a team](https://docs.github.com/en/enterprise-cloud@latest/organizations/organizing-members-into-teams/creating-a-team)

4. Add a second person to the team, so that a Deploy can be approved by a
   team member who didn't start it. Select **People** > **Invite member**,
   enter their username, choose **Member**, select the team and select
   **Send invitation**. They accept from the email within seven days, and
   "Users that you invite must enable two-factor authentication before
   accepting the invitation." Not run: the two accounts created for this
   were suspended by GitHub before either could accept (the second,
   `astrongarms6677`, at its first sign-in after the invitation on
   2026-10-22), and #6 story 22 is parked. Invite an established account.
   [Inviting users to join your organization](https://docs.github.com/en/enterprise-cloud@latest/organizations/managing-membership-in-your-organization/inviting-users-to-join-your-organization)

5. Let `gh` read the organization's rulesets. Without `admin:org`, `gh api
   orgs/<org>/rulesets` answers 'This API operation needs the "admin:org"
   scope', and that scope is "Fully manage the organization and its teams,
   projects, and memberships":

   ```bash
   gh auth refresh -h github.com -s admin:org
   ```

   [Scopes for OAuth apps](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps)

6. The "branch naming" ruleset. In the organization, select **Settings** >
   **Repository** > **Rulesets** > **New ruleset** > **New branch ruleset**
   and fill it in as SETUP-GITHUB.md 8a, with **Target repositories** set to
   **All repositories**. A new ruleset starts with **Restrict deletions** and
   **Block force pushes** ticked ("This rule is selected by default"); untick
   both, so **Restrict creations** is the only rule. The second command
   prints `16 ["creation"]`:

   ```bash
   gh api orgs/<org>/rulesets --jq '.[] | "\(.id) \(.name)"'
   gh api orgs/<org>/rulesets/<id> --jq '"\(.conditions.ref_name.exclude | length) \([.rules[].type])"'
   ```

   [Creating rulesets for repositories in your organization](https://docs.github.com/en/enterprise-cloud@latest/organizations/managing-organization-settings/creating-rulesets-for-repositories-in-your-organization),
   [Available rules for rulesets](https://docs.github.com/en/enterprise-cloud@latest/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets)

7. The GitHub App the release pushes its tag as. GitHub Actions can't be a
   ruleset's bypass actor in an organization either ("Actor GitHub Actions
   integration must be part of the ruleset source or owner organization"),
   so do SETUP-GITHUB.md 8c steps 1 to 4 in this organization. **Install
   App** is in the app's own settings: **Developer settings** > **GitHub
   Apps** > **Edit** next to the app. Give the variable and the secret
   **All repositories** access, since the proof repos are public. The checks
   print `haamtestingapp all {"contents":"write","metadata":"read"}`, then
   `RELEASE_APP_CLIENT_ID all` and `RELEASE_APP_PRIVATE_KEY all`:

   ```bash
   gh api orgs/<org>/installations --jq '.installations[] | "\(.app_slug) \(.repository_selection) \(.permissions)"'
   gh api orgs/<org>/actions/variables --jq '.variables[] | "\(.name) \(.visibility)"'
   gh api orgs/<org>/actions/secrets --jq '.secrets[] | "\(.name) \(.visibility)"'
   ```

   [Registering a GitHub App](https://docs.github.com/en/apps/creating-github-apps/registering-a-github-app/registering-a-github-app),
   [Installing your own GitHub App](https://docs.github.com/en/apps/using-github-apps/installing-your-own-github-app),
   [Making authenticated API requests with a GitHub App in a GitHub Actions workflow](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/making-authenticated-api-requests-with-a-github-app-in-a-github-actions-workflow)

8. The "release tags" ruleset. Select **New ruleset** > **New tag ruleset**,
   name it `release tags`, set it **Active**, target **All repositories**,
   add **Include by pattern** `v*`, and leave **Restrict creations** as the
   only rule. Under **Bypass list** select **Add bypass**, pick the app and
   select **Add Selected**. Here the saved ruleset still had no bypass actor,
   so read it back, and if it prints `[]`, add the app through the API with
   the ID that `gh api apps/<app-slug> --jq .id` prints:

   ```bash
   gh api orgs/<org>/rulesets/<id> --jq .bypass_actors
   echo '{"bypass_actors":[{"actor_id":<app-id>,"actor_type":"Integration","bypass_mode":"always"}]}' | gh api -X PUT orgs/<org>/rulesets/<id> --input -
   ```

   Read back, it prints the app's ID with `"bypass_mode":"always"`.
   [Creating rulesets for repositories in your organization](https://docs.github.com/en/enterprise-cloud@latest/organizations/managing-organization-settings/creating-rulesets-for-repositories-in-your-organization),
   [Update an organization repository ruleset](https://docs.github.com/en/enterprise-cloud@latest/rest/orgs/rules?apiVersion=2022-11-28#update-an-organization-repository-ruleset)

9. The "main" ruleset. Select **New ruleset** > **New branch ruleset**, name
   it `main`, set it **Active**, target **All repositories** and **Include
   default branch**, and fill in the rules as SETUP-GITHUB.md 8b. Untick
   **Restrict deletions**; leave **Block force pushes**. No repo in the
   organization has run the checks yet, so the search doesn't list them:
   type `ci / gate`, `ci / branch-name` and `local/ci` by hand. Tick **Do
   not require status checks on creation**: without it a new repo's first
   push to `main` is refused ("3 of 3 required status checks are expected"),
   and `gh repo create --add-readme` leaves the repo empty. This prints
   `["non_fast_forward","pull_request","required_status_checks","required_linear_history"]`
   and then `true`:

   ```bash
   gh api orgs/<org>/rulesets/<id> --jq '[.rules[].type]'
   gh api orgs/<org>/rulesets/<id> --jq '.rules[] | select(.type=="required_status_checks") | .parameters.do_not_enforce_on_create'
   ```

   A typed check has no source, and "Any person or integration with write
   permissions to a repository can set the state of any status check", so
   a fake `ci / gate` would pass. The search still didn't list the checks
   after a PR in the organization had run them, so pin `ci / gate` and
   `ci / branch-name` to GitHub Actions (app ID 15368) through the API.
   `local/ci` keeps no source, since people post it. The second command
   prints the two checks with `"integration_id":15368`:

   ```bash
   gh api orgs/<org>/rulesets/<id> --jq '{rules: [.rules[] | if .type=="required_status_checks" then .parameters.required_status_checks |= map(if .context=="local/ci" then . else . + {integration_id: 15368} end) else . end]}' > rules.json
   gh api -X PUT orgs/<org>/rulesets/<id> --input rules.json --jq '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks'
   ```

   [Creating rulesets for repositories in your organization](https://docs.github.com/en/enterprise-cloud@latest/organizations/managing-organization-settings/creating-rulesets-for-repositories-in-your-organization),
   [Available rules for rulesets](https://docs.github.com/en/enterprise-cloud@latest/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets)

10. The organization's own copy of ci-workflows. The triggers pass secrets
    with `secrets: inherit`, and only "Workflows that call reusable
    workflows in the same organization or enterprise can use the `inherit`
    keyword". Called from `Haam909/ci-workflows`, the release's **Token for
    the tag push** step failed with "The 'private-key' input must be set to
    a non-empty string". Moving `v2` on `Haam909` doesn't move the copy's.

    First take `ci-workflows` out of the "release tags" and "main"
    rulesets: "release tags" refuses the `v2` push, and "main" requires
    `ci / gate` and `ci / branch-name`, which only a consuming repo's
    `reusable-verify-pull-request.yml` run posts. The UI's **Exclude by
    pattern** is under **Repositories matching a name**, not **All
    repositories**, so use the API. Run it for
    both rulesets' IDs; each prints
    `{"exclude":["ci-workflows"],"include":["~ALL"]}`:

    ```bash
    gh api orgs/<org>/rulesets/<id> --jq '{conditions: (.conditions | .repository_name.exclude = ["ci-workflows"])}' | gh api -X PUT orgs/<org>/rulesets/<id> --input - --jq .conditions.repository_name
    ```

    Then do SETUP-GITHUB.md Steps 1 to 3 with `<org>` for `YOURNAME`. On
    Windows, `git add` records every file without its executable bit, so
    before the commit run:

    ```bash
    git update-index --chmod=+x local/bin/ci local/bin/signoff local/githooks/pre-push
    ```

    Turn off `mirror-images` in the copy. It copies images to
    `ghcr.io/haam909`, which the organization can't write to ("denied:
    permission_denied: The requested installation does not exist."), and
    the copy's `self-test` reads them from there. The checks print `100755`
    three times, the same commit for `main` and `v2^{}`, and
    `disabled_manually`:

    ```bash
    gh workflow disable mirror-images -R <org>/ci-workflows
    git ls-files -s local/bin/ci local/bin/signoff local/githooks/pre-push
    git ls-remote origin main 'v2^{}'
    gh workflow list -R <org>/ci-workflows --all --json name,state --jq '.[] | select(.name=="mirror-images") | .state'
    ```

    A consuming repo in the organization then follows SETUP-GITHUB.md Step
    4 onwards; triggers copied from the copy already call
    `<org>/ci-workflows`.
    [Reuse workflows](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows),
    [Creating rulesets for repositories in your organization](https://docs.github.com/en/enterprise-cloud@latest/organizations/managing-organization-settings/creating-rulesets-for-repositories-in-your-organization),
    [Update an organization repository ruleset](https://docs.github.com/en/enterprise-cloud@latest/rest/orgs/rules?apiVersion=2022-11-28#update-an-organization-repository-ruleset),
    [git update-index](https://git-scm.com/docs/git-update-index),
    [Disabling and enabling a workflow](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/disable-and-enable-workflows)

## A GHE.com tenant

An enterprise on GHE.com, at `<tenant>.ghe.com`, with no Azure: apps at
`none`, packages on the tenant's GitHub Packages, and containers in the
tenant's Container registry. **None of this section has been run on a
tenant yet.** Each step says what to check, and steps 5 and 6 say what the
first runs show. Starting a trial tenant with managed users and Entra ID is
Haam909/ci-workflows#30, not written yet.

What's different from github.com:

- There are no public repos: "Notably, these include gists and public
  repositories." So the tenant's copy of ci-workflows is internal or
  private, and a calling repo's `GITHUB_TOKEN` can't check it out. The
  release's GitHub App does that instead (steps 2 and 4).
- "A `GITHUB_TOKEN` within a workflow run for your enterprise on GHE.com
  does not grant access to resources on GitHub.com", so the tenant's repos
  call a copy inside the tenant, not `Haam909/ci-workflows`
  (`docs/adr/0001-copy-per-ghe-tenant.md`).
- "The Container registry is located at
  `https://containers.SUBDOMAIN.ghe.com`." A `container` with no `ACR_NAME`
  pushes to `containers.<tenant>.ghe.com/<org>/<repo>/<component>`.
- GitHub Packages is at `nuget.<tenant>.ghe.com` and `npm.<tenant>.ghe.com`;
  the workflows and `bin/ci` work that out from the repo's Host (README.md,
  Package feeds).
- Every repo is private or internal, so the release writes no cosign
  bundles (the **Sign** step runs for public repos only) and relies on
  GitHub's attestation, which hasn't been tried on a tenant. A container
  image gets neither: the attestation step skips containers. Released images
  on a tenant are pushed by digest but not signed.

[Feature overview for GitHub Enterprise Cloud with data residency](https://docs.github.com/en/enterprise-cloud@latest/admin/data-residency/feature-overview-for-github-enterprise-cloud-with-data-residency),
[Working with the Container registry](https://docs.github.com/en/enterprise-cloud@latest/packages/working-with-a-github-packages-registry/working-with-the-container-registry)

1. Sign `gh` in to the tenant, and point this shell's `gh` at it. Add
   `--scopes read:packages` if a component installs from the tenant's GitHub
   Packages. `bin/ci` and `bin/signoff` take the Host from the clone's
   `origin`, so every developer and reviewer needs the login but not
   `GH_HOST`.

   ```bash
   gh auth login --hostname <tenant>.ghe.com
   export GH_HOST=<tenant>.ghe.com
   ```

   [gh auth login](https://cli.github.com/manual/gh_auth_login),
   [gh environment](https://cli.github.com/manual/gh_help_environment)

2. The organization's rulesets and the release's GitHub App. Do the GitHub
   Enterprise Cloud trial steps 5 to 9 above in the tenant's organization,
   with `-h <tenant>.ghe.com` in step 5's `gh auth refresh`. Two
   differences:

   - Install the app from step 7 on **All repositories**, or on
     `ci-workflows` as well as the repos that release: the workflows read
     the copy with it (step 4). Give the variable and the secret access to
     every repo; on a tenant none of them is public:

     ```bash
     gh variable set RELEASE_APP_CLIENT_ID --org <org> --visibility all --body <client-id>
     gh secret set RELEASE_APP_PRIVATE_KEY --org <org> --visibility all < <app>.pem
     ```

   - Step 9 pins `ci / gate` and `ci / branch-name` to app ID 15368, which is
     GitHub Actions on github.com. Read the tenant's from a check run once a
     PR has run them, and use that ID instead:

     ```bash
     gh api repos/<org>/<repo>/commits/<sha>/check-runs --jq '.check_runs[] | "\(.name) \(.app.id)"'
     ```

   [gh variable set](https://cli.github.com/manual/gh_variable_set),
   [gh secret set](https://cli.github.com/manual/gh_secret_set),
   [List check runs for a Git reference](https://docs.github.com/en/enterprise-cloud@latest/rest/checks/runs#list-check-runs-for-a-git-reference)

3. The organization's copy of ci-workflows. Do GitHub Enterprise Cloud trial
   step 10 above, with these differences:

   - Create the repo **internal**, not public as SETUP-GITHUB.md step 1
     says. A private copy's workflows "can be shared with other private
     repositories" only, so an internal Consuming repo couldn't call it.
   - Its remote is `https://<tenant>.ghe.com/<org>/ci-workflows.git`.

   The check prints `internal`:

   ```bash
   gh api repos/<org>/ci-workflows --jq .visibility
   ```

   [Creating a new repository](https://docs.github.com/en/enterprise-cloud@latest/repositories/creating-and-managing-repositories/creating-a-new-repository)

4. Let the organization's repos use the copy. A Consuming repo calls the
   copy's reusable workflows, which GitHub allows once the copy's **Access**
   setting does. In the copy, go to **Settings** > **Actions** > **General**,
   under **Access** choose **Accessible from repositories in the '<org>'
   organization**, and select **Save**. The workflows then check out the
   copy's actions with a token from the release's app (step 2), whenever
   `RELEASE_APP_CLIENT_ID` is visible to the calling repo. The check prints
   `organization`:

   ```bash
   gh api repos/<org>/ci-workflows/actions/permissions/access --jq .access_level
   ```

   [Managing GitHub Actions settings for a repository: allowing access to components in an internal repository](https://docs.github.com/en/enterprise-cloud@latest/repositories/managing-your-repositorys-settings-and-features/enabling-features-for-your-repository/managing-github-actions-settings-for-a-repository#allowing-access-to-components-in-an-internal-repository),
   [Get the level of access for workflows outside of the repository](https://docs.github.com/en/enterprise-cloud@latest/rest/actions/permissions#get-the-level-of-access-for-workflows-outside-of-the-repository)

5. Read the copy's own `self-test`. The push in step 3 starts it, and its
   `merge`, `release` and `pull-request` jobs run the reusable workflows over
   `tests/workflows.yml`. That's the first run on the tenant, before any
   Consuming repo exists. It reads the copy with the copy's own
   `GITHUB_TOKEN`, so step 4's token isn't tried until step 6. In its log:

   - Every `.ci-workflows` checkout shows `repository: <org>/ci-workflows`
     and `ref:` with a 40-character SHA. An empty `ref:` means the tenant has
     no `job.workflow_sha`; GitHub documents it as missing only on GitHub
     Enterprise Server.
   - `merge / py-container -> test` pushes to
     `containers.<tenant>.ghe.com/<org>/ci-workflows/py-container`.
   - `release / build ts-app` and the other non-container builds either
     attest or warn "no attestation".
   - The `build` job's two container fixtures use a registry image from
     `ghcr.io/haam909`. Whether a tenant's runner can pull it is untested;
     if they fail there, the rest of the run still answers the above.

   [Contexts reference: job context](https://docs.github.com/en/enterprise-cloud@latest/actions/reference/workflows-and-actions/contexts#job-context)

6. The first Consuming repo. Follow SETUP-GITHUB.md Step 4 onwards, copying
   `examples/.github/` from the copy so the triggers call `<org>/ci-workflows`.
   Skip step 7's tag while the "release tags" ruleset applies, as step 7
   says. On its first pull request:

   - The `branch-name` job's **Token for the ci-workflows checkout** step
     succeeds, and the checkout after it shows `repository:
     <org>/ci-workflows`. If the step was skipped, the repo can't see
     `RELEASE_APP_CLIENT_ID`; if it failed, the app isn't installed on the
     copy or the key is wrong. Either way the checkout then fails, because
     `GITHUB_TOKEN` can't read the copy.
   - A `local/ci` status from the author's push appears on the PR, posted by
     `bin/signoff` to the tenant.

   Then the merge run pushes any container to
   `containers.<tenant>.ghe.com/<org>/<repo>/<component>`, and the Release's
   notes say what wasn't signed.
