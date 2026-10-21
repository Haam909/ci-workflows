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
   accepting the invitation." Not run yet.
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
   type `ci / gate`, `ci / branch-name` and `local/ci` by hand. A typed check
   has no source, and "Any person or integration with write permissions to a
   repository can set the state of any status check". This prints
   `["non_fast_forward","pull_request","required_status_checks","required_linear_history"]`:

   ```bash
   gh api orgs/<org>/rulesets/<id> --jq '[.rules[].type]'
   ```

   [Creating rulesets for repositories in your organization](https://docs.github.com/en/enterprise-cloud@latest/organizations/managing-organization-settings/creating-rulesets-for-repositories-in-your-organization),
   [Available rules for rulesets](https://docs.github.com/en/enterprise-cloud@latest/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets)

## GHE.com trial with managed users and Entra ID

Not written yet: Haam909/ci-workflows#30. It will cover starting the trial,
provisioning a test user, and a federated credential for the tenant's own
OIDC issuer on its own app registration.
