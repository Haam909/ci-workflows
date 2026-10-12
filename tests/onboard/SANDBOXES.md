# Setting up the Sandboxes' accounts

Everything the onboard harness needs outside GitHub, built from nothing. Do
the steps in order; each ends with the documentation page it comes from.
`SETUP-GITHUB.md` stays about Consuming repos.

## Azure DevOps, Azure Artifacts and Entra

Azure Artifacts Rows publish to two Feeds, one scoped to the organization and
one to a project, because the two have different URLs. They log in through an
Entra app with one flexible federated credential that matches every Sandbox
in any environment. Exact-match credentials would need one per Sandbox per
environment (`test`, `release`, `production`) against a limit of 20 per app,
and would break whenever a Sandbox is recreated: repos created after
15 July 2026 carry their owner and repo IDs in the token's subject,
`repo:<owner>@<owner-id>/<repo>@<repo-id>:environment:<env>`.

1. Have an Azure subscription in the tenant you'll use. Creating an Azure
   DevOps organization needs one, even though the free tier covers what the
   Rows use. In the Azure portal, **Subscriptions** lists yours; if it's
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
   **Project**.
   [Create a feed](https://learn.microsoft.com/en-us/azure/devops/artifacts/feeds/project-scoped-feeds?view=azure-devops#create-a-feed)

6. Check both Feeds' scope from their URLs. For each, select **Connect to
   feed** > **dotnet** and read the `index.json` URL. The org-scoped one is
   `https://pkgs.dev.azure.com/<org>/_packaging/<feed>/nuget/v3/index.json`;
   the project-scoped one has the project after the organization,
   `https://pkgs.dev.azure.com/<org>/<project>/_packaging/<feed>/nuget/v3/index.json`.
   A Feed with the wrong scope has to be deleted (**Feed Settings** > **Delete
   feed**) and created again; its name stays taken until it's permanently
   deleted from the **Deleted Feeds** tab.
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

9. Find the subject prefix GitHub gives a Sandbox, and your owner ID. The
   prefix shows whether the repo uses the ID-bearing subject; the owner ID is
   the immutable claim the credential must also match.

   ```powershell
   gh api repos/<owner>/ciw-sbx-01/actions/oidc/customization/sub
   gh api users/<owner> --jq .id
   ```

   The first prints `"sub_claim_prefix":"repo:<owner>@<owner-id>/ciw-sbx-01@<repo-id>"`.
   [OpenID Connect reference: customizing the subject claims](https://docs.github.com/en/actions/reference/security/oidc),
   [Immutable subject claims for GitHub Actions OIDC tokens](https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/)

10. Add the flexible federated credential. It's in preview, and `az ad app
    federated-credential` can neither create nor read one, so it goes through
    Microsoft Graph `beta` with `az rest`. Save this as a `.ps1` file, set the
    three values at the top, and run it. The body goes in a file because
    `az.cmd` mangles brackets and quotes passed from PowerShell. A wrong
    expression is accepted here and only fails at login.

    ```powershell
    $ErrorActionPreference = 'Stop'
    $app = '<client-id>'
    $owner = '<owner>'
    $ownerId = '<owner-id>'
    $objectId = az ad app show --id $app --query id -o tsv
    $body = @{
      name                     = 'ciw-sandboxes'
      issuer                   = 'https://token.actions.githubusercontent.com'
      audiences                = @('api://AzureADTokenExchange')
      subject                  = $null
      claimsMatchingExpression = @{
        value           = "claims['sub'] matches 'repo:${owner}@${ownerId}/ciw-sbx-*:environment:*' and claims['repository_owner_id'] eq '$ownerId'"
        languageVersion = 1
      }
    } | ConvertTo-Json -Depth 3
    $tmp = New-TemporaryFile
    try {
      [IO.File]::WriteAllText($tmp, $body)
      az rest --method post --url "https://graph.microsoft.com/beta/applications/$objectId/federatedIdentityCredentials" --headers 'Content-Type=application/json' --body "@$tmp" --query name -o tsv
      if ($LASTEXITCODE -ne 0) { throw 'create failed' }
    } finally {
      Remove-Item $tmp
    }
    ```

    It prints `ciw-sandboxes`.
    [Flexible federated identity credentials](https://learn.microsoft.com/en-us/entra/workload-id/workload-identities-flexible-federated-identity-credentials)

11. Check the credential. This prints the expression back.

    ```powershell
    az rest --method get --url "https://graph.microsoft.com/beta/applications/$objectId/federatedIdentityCredentials" --query "value[].claimsMatchingExpression.value" -o tsv
    ```

    [Flexible federated identity credentials: Azure CLI](https://learn.microsoft.com/en-us/entra/workload-id/workload-identities-flexible-federated-identity-credentials#azure-cli-azure-powershell-and-terraform-providers)

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

15. Let it publish to both Feeds. For each Feed, open **Artifacts**, pick the
    Feed, select the gear icon for **Feed settings** > **Permissions** >
    **Add users/groups**, add the service principal with the **Feed Publisher
    (Contributor)** role, and select **Save**. Leave yourself **Feed Owner**:
    only an owner can delete packages, and the harness deletes each
    Sandbox's earlier test packages as you.
    [Manage permissions: feed settings](https://learn.microsoft.com/en-us/azure/devops/artifacts/feeds/feed-permissions?view=azure-devops#feed-settings),
    [Feed roles and permissions](https://learn.microsoft.com/en-us/azure/devops/artifacts/feeds/feed-permissions?view=azure-devops#feed-roles-and-permissions)

16. Run the Azure Artifacts rows. `az` stays signed in from step 8; the
    harness calls the Feed through `az rest` as you. Set the org and the
    org-scoped Feed from steps 2 and 4, and the IDs from step 7:

    ```bash
    AZDO_ORG=<org> AZDO_FEED=<feed> AZURE_CLIENT_ID=<client-id> AZURE_TENANT_ID=<tenant-id> \
      tests/onboard/run P3 P4
    ```

    `run` stops before any row if a setting is missing or `az` can't get an
    Azure DevOps token.
    [az rest](https://learn.microsoft.com/en-us/cli/azure/reference-index?view=azure-cli-latest#az-rest)
