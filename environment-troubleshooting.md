# Environment Troubleshooting Notes

Updated: 2026-10-11

## Current Status

- The Azure environment is a disposable sandbox with a maximum lifetime of three hours. Keep Azure provisioning focused and verify cloud resources are cleaned up before the sandbox expires; deleting the local Kind cluster alone does not delete Azure resources.
- The old Kind cluster was deleted successfully, then recreated by `setup/00-intro.sh` on 2026-10-11.
- The first setup attempt installed Crossplane 2.4.2 and stopped because legacy package Compositions were unhealthy. The setup script was pinned to Crossplane 1.20.13.
- The next setup attempt installed Crossplane 1.20.13 and all three tutorial configurations became Healthy. It stopped because the AKS Composition transform added an invalid `input` to a function pipeline step.
- The transform was corrected to modify only the `patch-and-transform` step and applied to the current cluster. Setup was resumed without deleting the cluster or re-entering credentials. The cluster is Ready, all tutorial configurations are Healthy, Argo CD's `a-team` Application is Synced/Healthy, and no Azure claims have been applied.
- Docker is available (`29.1.3`). Nix and `nix-shell` are installed.
- Kind and the other project tools were not initially available on the host `PATH`; they were available through the Nix shell.
- The current `.env` was observed to contain only `export HYPERSCALER=azure`.
- Both `azure-creds.json` and `setup/azure-creds.json` were empty when checked. No credential contents were recorded here.

## Cause of the Kind Failure

The Kind control-plane container was running, but its Kubernetes API server repeatedly exited because etcd could not start. The etcd log identified the cause:

```text
failed to find database snapshot file
/var/lib/etcd/member/snap/000000000001d4ce.snap.db
failed to recover v3 backend from snapshot
```

The etcd data referred to snapshot index `120014`, but the corresponding database snapshot file was missing. As a result, etcd crashed and the API server could not connect to `127.0.0.1:2379`. This was local Kind/etcd state corruption or incompleteness; Azure credentials were not involved.

## Nix Notes

`NIXPKGS_ALLOW_UNFREE=1` allows Nix to evaluate the `upbound` package in `shell.nix`, which Nix classifies as unfree. It is an environment setting for that Nix invocation, not a service, and it does not affect the running cluster.

Start the setup script from the repository with:

```bash
NIXPKGS_ALLOW_UNFREE=1 nix-shell --run 'bash setup/00-intro.sh'
```

The Nix shell supplied newer versions than those pinned in `devbox.json` during the assessment (including Helm 4 and Crossplane CLI 2). Devbox was not installed at that time.

## Before Running Setup

`setup/00-intro.sh` asks for confirmation and then removes the existing `.env`, creates a Kind cluster from `kind.yaml`, installs ingress-nginx and Crossplane, and prompts for a cloud provider. Its Azure branch prompts for tenant ID, subscription ID, sandbox resource-group name, Azure region, application/client ID, and a hidden client secret. It writes provider credentials to the ignored `azure-creds.json` file with owner-only permissions, creates/updates the Kubernetes Secret, and applies the ProviderConfig. It does not run `az login` or create an Owner-assigned service principal. It updates the local SQL schema/composition and patches the installed AKS claim schema/composition so both target the supplied resource group and region.

The Azure branch writes the claims to `examples/azure-intro.yaml`; it does not apply that file. Argo CD is configured to watch `a-team/`, which was empty when checked. After setup, first verify the local foundation:

```bash
kubectl get nodes -o wide
kubectl get providers.pkg.crossplane.io
kubectl get applications -n argocd
```

Only when ready to create Azure resources, place the generated claims in the watched directory and push them to the configured Git remote:

```bash
cp examples/azure-intro.yaml a-team/intro.yaml
git add a-team/intro.yaml
git commit -m "Deploy Azure intro claims"
git push
```

That GitOps change requests an AKS cluster with a minimum of three nodes, an Azure PostgreSQL database, and the demo app. Before pushing, confirm the app's RBAC scope matches the supplied resource group, and that the Azure sandbox has enough time and quota; this can create billable resources. Azure AKS creates a separate Azure-managed node resource group even when the cluster resource uses the supplied group. Then monitor Argo CD and Crossplane claims/managed resources. During cleanup, verify Azure resources are actually deleted before the sandbox expires; deleting Kind alone is not cloud cleanup.

After pushing the claims, monitor reconciliation:

```bash
kubectl get applications -n argocd
kubectl get clusterclaims,sqlclaims,appclaims -A
kubectl get managed
```

## Latest Setup Attempt

On 2026-10-11, the Azure sandbox denied the script's attempt to create an Owner role assignment (`Microsoft.Authorization/roleAssignments/write`). `azure-creds.json` was confirmed to be 0 bytes, but the script continued and created the `azure-creds` Kubernetes Secret and Azure ProviderConfig. The Secret therefore cannot authenticate Crossplane. Do not push the Azure claims to `a-team/` until a usable Azure identity with sufficient permissions is configured.

Sandbox login credentials and an application client secret were subsequently shared in a screenshot. Treat both as compromised: ask the sandbox provider to invalidate/reissue them (or rotate the app secret and account password through the approved sandbox workflow) before further use. No secret values are recorded here.

The Azure sandbox was later ended, and its login is no longer available. Treat that environment and its credentials as expired; request a fresh sandbox and newly issued credentials from the provider before continuing. Confirm with the provider whether sandbox resources were deleted at termination and whether any cleanup or billing follow-up is needed.

## Crossplane Package Compatibility Failure

On 2026-10-11, setup installed Crossplane 2.4.2 because the Helm command used the latest chart. The tutorial's pinned `dot-sql:v0.8.77` and `dot-application:v0.5.45` packages contain legacy Resources-mode compositions; Crossplane 2 interpreted these as Pipeline mode and marked the packages unhealthy (for example, `local-k8s-postgresql`: an array of pipeline steps is required). The setup script now pins Crossplane 1.20.13, which satisfies the packages' declared `>=v1.14.0` constraint. A later setup attempt found a separate yq bug: the AKS Composition transform modified function steps that have no `input`. The script now scopes the transform to the `patch-and-transform` step, leaving function steps intact.

## Azure Application Permissions

The application/client ID identifies the app; the corresponding service principal (enterprise application) must also be present in the subscription's Entra tenant and have Azure RBAC assignments. For this demo, ask the sandbox provider for a preconfigured service principal with **Contributor** at the subscription scope, or at a dedicated resource-group scope if the required resource groups are pre-created and the compositions are adjusted to use them. The current SQL composition creates a Resource Group, PostgreSQL server, and firewall rule; the intro claims also request an AKS cluster. Entra directory roles such as Cloud Application Administrator are not substitutes for Azure subscription RBAC.

Contributor can manage resources but cannot grant Azure RBAC roles. In the previous setup attempt, `az ad sp create-for-rbac --role Owner` failed because the interactive sandbox user could not write role assignments. The updated setup instead accepts a provider-issued app identity, which must already have the required Azure RBAC. If AKS reports a specific role-assignment permission failure, ask the provider whether a narrowly scoped `Role Based Access Control Administrator` or `User Access Administrator` assignment is needed; do not request Owner by default. Required credential fields are tenant ID, subscription ID, application/client ID, and client secret. Never commit or share the secret.

The lab can use a provider-issued service principal if it has the needed RBAC and Crossplane is configured with its credentials. The updated intro setup configures the SQL and AKS cluster resources to target the supplied group and region. Azure AKS still creates a separate managed node resource group by design. Check the app's effective permissions for the supplied group and any AKS-specific managed-resource-group requirement; if Azure reports a missing permission, request only the specific additional permission at the narrowest workable scope.

The script installed Argo CD and created the `a-team` Application. The Azure demo claims were later applied, then removed when the sandbox expired; the Application is currently Healthy and Synced to an empty `a-team/` directory. The chart configures the server for HTTP, so the UI can be port-forwarded with:

```bash
NIXPKGS_ALLOW_UNFREE=1 nix-shell --run 'kubectl port-forward service/argocd-server -n argocd 8080:80'
```

Then open `http://localhost:8080`. `kubectl` is available in the Nix shell, not on the host `PATH`.

## Azure Playground Policy Results

The deployment manifest was pushed as commit `f89bce2`, then updated to a two-node AKS claim in commit `540376e`. Argo CD created the AKS, SQL, and app claims. The Azure sandbox rejected the initial AKS request because its VM size, node count, and monitoring settings did not meet policy. The claim and setup transform were changed to use the allowed `Standard_D2s_v3` SKU, a maximum of two nodes, and no monitoring add-ons. At sandbox expiry, AKS was `Synced=True`, `Ready=Creating`; PostgreSQL remained denied by policy.

The PostgreSQL Server and FirewallRule requests still fail with Azure `RequestDisallowedByPolicy` 403 errors. The server error names `Azure_playground` standards but does not report the specific noncompliant property; the firewall error says its location is disallowed while listing `eastus` among allowed regions. Do not claim the application is deployed or ready. Ask the sandbox provider for the exact policy requirements for PostgreSQL Server and FirewallRule before changing those compositions or retrying. The app claim remains unready until its database and AKS connection are available.

The pinned `dot-application:v0.5.45` package and `c8n.io/vfarcic/silly-demo:1.4.52` image are PostgreSQL-specific: source uses Go `pgx`, PostgreSQL connection URLs, and `$1` placeholders; the packaged backend Composition also supplies PostgreSQL settings, including port 5432. A standalone SQL Server-compatible backend has been added at `apps/azure-sql-demo/`; it preserves the video endpoints, uses Microsoft's TDS driver and SQL Server parameters, and creates its `dbo.videos` table on startup. Unit tests pass and the Docker image builds locally. `.github/workflows/publish-azure-sql-demo.yml` publishes it to GHCR on a qualifying push.

The Azure SQL path is now wired locally: `providers/dot-sql.yaml` includes the v2.8 Azure SQL provider, `compositions/sql-v10/azure-sql.yaml` creates an MSSQL Server, Basic database, and Azure-services firewall rule in the supplied group, and `setup/00-intro.sh` prompts for a hidden SQL admin password and creates the AppClaim connection Secret outside Git. The generated SQLClaim selects `db: mssql` and the AppClaim uses the new image. The provider and Composition are registered in the current local cluster, but no claims have been submitted and Azure provisioning has not been tested. Push the image source to run the GHCR workflow; make its package public or configure an AKS image-pull secret before deploying claims.

## Expired Sandbox Cleanup

When the Azure sandbox expired, the GitOps claims were removed and pushed in commit `0aa2523`; Argo CD is Synced to the empty `a-team/` path. Local `.env` and the ignored generated root `azure-creds.json` were deleted, and the old `azure-creds` Secret was deleted from `crossplane-system`. The tracked empty `setup/azure-creds.json` template was preserved. The setup script prompts for fresh tenant, subscription, resource group, region, client ID, and hidden client secret on the next run.

The sandbox provider confirmed that cloud cleanup had completed. Crossplane still had six deletion-blocked local managed-resource records because the expired app identity was rejected with `AADSTS700016` and the old AKS endpoint no longer resolved. After that confirmation, their finalizers were removed. Verification showed no managed resources, claims, or composites remain in the local cluster.

The setup script now reuses an existing Kind cluster and applies the `a-team` namespace idempotently, so it can be rerun to enter fresh sandbox details without first deleting the local cluster.

## Azure SQL Demo Deployment

On 2026-10-12, the SQL Server-compatible backend image was published to GHCR and pulled anonymously. The Azure SQL provider `v2.8.0` and `azure-sqlserver` Composition were installed; the SQL Server, firewall rule, and database were provisioned in the supplied resource group. The database uses Standard `S0`, Local backup redundancy, and a 2 GB size to satisfy sandbox policy. The AppClaim uses the SQL Server demo image and a Kubernetes Secret with endpoint, username, password, and port keys.

The ClusterClaim, SQLClaim, AppClaim, and all composed managed resources are Ready. The backend Pod is Running. Live checks through a temporary port-forward returned HTTP 200 from `/healthz` and `/videos` (empty list). The SQL connection Secret password was rotated after a diagnostic command exposed its base64 representation; setup and cluster Secret now contain the rotated value. No credential values are stored in this document.
