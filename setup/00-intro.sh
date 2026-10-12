#!/usr/bin/env bash
set -e

gum style \
	--foreground 212 --border-foreground 212 --border double \
	--margin "1 2" --padding "2 4" \
	'Setup for the Introduction chapter'

gum confirm '
Are you ready to start?
Select "Yes" only if you did NOT follow the story from the start (if you jumped straight into this chapter).
Feel free to say "No" and inspect the script if you prefer setting up resources manually.
' || exit 0

echo "
## You will need following tools installed:
|Name            |Required             |More info                                          |
|----------------|---------------------|---------------------------------------------------|
|Linux Shell     |Yes                  |Use WSL if you are running Windows                 |
|Docker          |Yes                  |'https://docs.docker.com/engine/install'           |
|kind CLI        |Yes                  |'https://kind.sigs.k8s.io/docs/user/quick-start/#installation'|
|kubectl CLI     |Yes                  |'https://kubernetes.io/docs/tasks/tools/#kubectl'  |
|crossplane CLI  |Yes                  |'https://docs.crossplane.io/latest/cli'            |
|yq CLI          |Yes                  |'https://github.com/mikefarah/yq#install'          |
|Google Cloud account with admin permissions|If using Google Cloud|'https://cloud.google.com'|
|Google Cloud CLI|If using Google Cloud|'https://cloud.google.com/sdk/docs/install'        |
|AWS account with admin permissions|If using AWS|'https://aws.amazon.com'                  |
|AWS CLI         |If using AWS         |'https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html'|
|Azure sandbox subscription and application credentials with resource permissions|If using Azure|'https://azure.microsoft.com'|
|az CLI          |Optional; this intro setup uses supplied app credentials directly|'https://learn.microsoft.com/cli/azure/install-azure-cli'|

If you are running this script from **Nix shell**, most of the requirements are already set with the exception of **Docker** and the **hyperscaler account**.
" | gum format

gum confirm "
Do you have those tools installed?
" || exit 0

rm -f .env

#########################
# Control Plane Cluster #
#########################

if kind get clusters | grep --fixed-strings --line-regexp kind >/dev/null; then
  echo 'Reusing existing Kind cluster "kind".'
else
  kind create cluster --config kind.yaml
fi

kubectl apply \
   --server-side --force-conflicts --validate=false --filename https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml

##############
# Crossplane #
##############

helm upgrade --install crossplane crossplane \
    --repo https://charts.crossplane.io/stable \
  --version 1.20.13 \
    --namespace crossplane-system --create-namespace --wait

kubectl apply \
    --filename providers/provider-kubernetes-incluster.yaml

kubectl apply --validate=false --filename providers/provider-helm-incluster.yaml

kubectl apply --validate=false --filename providers/dot-kubernetes.yaml

kubectl apply --validate=false --filename providers/dot-sql.yaml

kubectl apply --validate=false --filename providers/dot-app.yaml

gum spin --spinner dot \
    --title "Waiting for Crossplane providers..." -- sleep 60

kubectl wait --for=condition=healthy provider.pkg.crossplane.io \
    --all --timeout=1800s

kubectl wait --for=condition=healthy configuration.pkg.crossplane.io/crossplane-k8s --timeout=1800s
kubectl wait --for=condition=healthy configuration.pkg.crossplane.io/crossplane-sql --timeout=1800s
kubectl wait --for=condition=healthy configuration.pkg.crossplane.io/crossplane-app --timeout=1800s

echo "## Which Hyperscaler do you want to use?" | gum format

HYPERSCALER=$(gum choose "google" "aws" "azure")

echo "export HYPERSCALER=$HYPERSCALER" >> .env

if [[ "$HYPERSCALER" == "google" ]]; then

    gcloud auth login

    PROJECT_ID=dot-$(date +%Y%m%d%H%M%S)

    echo "export PROJECT_ID=$PROJECT_ID" >> .env

    gcloud projects create ${PROJECT_ID}

    echo "## Open https://console.cloud.google.com/billing/linkedaccount?project=$PROJECT_ID and link a billing account" \
        | gum format

    gum input --placeholder "Press the enter key to continue."

    echo "## Open https://console.cloud.google.com/marketplace/product/google/container.googleapis.com?project=$PROJECT_ID and *ENABLE* the API" \
        | gum format

    gum input --placeholder "Press the enter key to continue."

    echo "## Open https://console.cloud.google.com/apis/library/sqladmin.googleapis.com?project=$PROJECT_ID and *ENABLE* the API" \
        | gum format

    gum input --placeholder "Press the enter key to continue."

    export SA_NAME=devops-toolkit

    export SA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

    gcloud iam service-accounts create $SA_NAME \
        --project $PROJECT_ID

    export ROLE=roles/admin

    gcloud projects add-iam-policy-binding \
        --role $ROLE $PROJECT_ID --member serviceAccount:$SA

    gcloud iam service-accounts keys create gcp-creds.json \
        --project $PROJECT_ID --iam-account $SA

    kubectl --namespace crossplane-system \
        create secret generic gcp-creds \
        --from-file creds=./gcp-creds.json

    echo "
apiVersion: gcp.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  projectID: $PROJECT_ID
  credentials:
    source: Secret
    secretRef:
      namespace: crossplane-system
      name: gcp-creds
      key: creds" | kubectl apply --filename -

elif [[ "$HYPERSCALER" == "aws" ]]; then

    AWS_ACCESS_KEY_ID=$(gum input --placeholder "AWS Access Key ID" --value "$AWS_ACCESS_KEY_ID")
    echo "export AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID" >> .env
    
    AWS_SECRET_ACCESS_KEY=$(gum input --placeholder "AWS Secret Access Key" --value "$AWS_SECRET_ACCESS_KEY" --password)
    echo "export AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY" >> .env

    AWS_ACCOUNT_ID=$(gum input --placeholder "AWS Account ID" --value "$AWS_ACCOUNT_ID")
    echo "export AWS_ACCOUNT_ID=$AWS_ACCOUNT_ID" >> .env

    echo "[default]
aws_access_key_id = $AWS_ACCESS_KEY_ID
aws_secret_access_key = $AWS_SECRET_ACCESS_KEY
" >aws-creds.conf

    kubectl --namespace crossplane-system \
        create secret generic aws-creds \
        --from-file creds=./aws-creds.conf

    kubectl apply --filename providers/aws-config.yaml

else

    AZURE_TENANT_ID=$(gum input --placeholder "Azure Tenant ID" --value "$AZURE_TENANT_ID")
    AZURE_SUBSCRIPTION_ID=$(gum input --placeholder "Azure Subscription ID" --value "$AZURE_SUBSCRIPTION_ID")
    AZURE_RESOURCE_GROUP=$(gum input --placeholder "Sandbox Resource Group" --value "$AZURE_RESOURCE_GROUP")
    AZURE_LOCATION=$(gum input --placeholder "Azure region (for example, eastus)" --value "${AZURE_LOCATION:-eastus}")
    AZURE_CLIENT_ID=$(gum input --placeholder "Application (Client) ID" --value "$AZURE_CLIENT_ID")
    AZURE_CLIENT_SECRET=$(gum input --placeholder "Application Client Secret" --password)
    AZURE_SQL_ADMIN_USERNAME=$(gum input --placeholder "Azure SQL admin username" --value "${AZURE_SQL_ADMIN_USERNAME:-sqladmin}")
    AZURE_SQL_ADMIN_PASSWORD=$(gum input --placeholder "Azure SQL admin password" --password)

    AZURE_TENANT_ID=$(printf '%s' "$AZURE_TENANT_ID" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    AZURE_SUBSCRIPTION_ID=$(printf '%s' "$AZURE_SUBSCRIPTION_ID" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    AZURE_RESOURCE_GROUP=$(printf '%s' "$AZURE_RESOURCE_GROUP" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    AZURE_LOCATION=$(printf '%s' "$AZURE_LOCATION" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    AZURE_CLIENT_ID=$(printf '%s' "$AZURE_CLIENT_ID" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    AZURE_SQL_ADMIN_USERNAME=$(printf '%s' "$AZURE_SQL_ADMIN_USERNAME" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    if [[ -z "$AZURE_TENANT_ID" || -z "$AZURE_SUBSCRIPTION_ID" || -z "$AZURE_RESOURCE_GROUP" || -z "$AZURE_LOCATION" || -z "$AZURE_CLIENT_ID" || -z "$AZURE_CLIENT_SECRET" || -z "$AZURE_SQL_ADMIN_USERNAME" || -z "$AZURE_SQL_ADMIN_PASSWORD" ]]; then
      echo "Azure tenant, subscription, resource group, location, app credentials, and SQL admin credentials are all required." >&2
      exit 1
    fi

    printf 'export AZURE_TENANT_ID=%q\n' "$AZURE_TENANT_ID" >> .env
    printf 'export AZURE_SUBSCRIPTION_ID=%q\n' "$AZURE_SUBSCRIPTION_ID" >> .env
    printf 'export AZURE_RESOURCE_GROUP=%q\n' "$AZURE_RESOURCE_GROUP" >> .env
    printf 'export AZURE_LOCATION=%q\n' "$AZURE_LOCATION" >> .env
    printf 'export AZURE_CLIENT_ID=%q\n' "$AZURE_CLIENT_ID" >> .env
    printf 'export AZURE_SQL_ADMIN_USERNAME=%q\n' "$AZURE_SQL_ADMIN_USERNAME" >> .env
    export SUBSCRIPTION_ID="$AZURE_SUBSCRIPTION_ID"

    (umask 077 && jq -n \
      --arg clientId "$AZURE_CLIENT_ID" \
      --arg clientSecret "$AZURE_CLIENT_SECRET" \
      --arg subscriptionId "$AZURE_SUBSCRIPTION_ID" \
      --arg tenantId "$AZURE_TENANT_ID" \
      '{environmentName: "AzureCloud", clientId: $clientId, clientSecret: $clientSecret, subscriptionId: $subscriptionId, tenantId: $tenantId}' \
      > azure-creds.json)
    chmod 600 azure-creds.json
    unset AZURE_CLIENT_SECRET

    kubectl --namespace crossplane-system create secret generic azure-creds \
      --from-file creds=./azure-creds.json --dry-run=client -o yaml \
      | kubectl apply --filename -

    kubectl apply --filename providers/azure-config.yaml

  kubectl apply --filename compositions/sql-v10/definition.yaml
  kubectl apply --filename compositions/sql-v10/azure-sql.yaml

  kubectl get composition cluster-azure --output yaml \
    | yq 'del(.spec.pipeline[] | select(.step == "patch-and-transform").input.resources[] | select(.name == "aks").base.spec.forProvider.defaultNodePool[0].enableAutoScaling) | (.spec.pipeline[] | select(.step == "patch-and-transform").input.resources[] | select(.name == "aks").base.spec.forProvider.defaultNodePool[0].autoScalingEnabled) = true | (.spec.pipeline[] | select(.step == "patch-and-transform").input.resources[] | select(.name == "aks").base.spec.forProvider.defaultNodePool[0].maxCount) = 2 | (.spec.pipeline[] | select(.step == "patch-and-transform").input.resources[] | select(.name == "aks").patches[] | select(.toFieldPath == "spec.forProvider.defaultNodePool[0].vmSize").transforms[] | select(.type == "map").map.small) = "Standard_D2s_v3" | (.spec.pipeline[] | select(.step == "patch-and-transform").input.resources[] | select(.name == "aks").patches[] | select(.toFieldPath == "spec.forProvider.resourceGroupName").fromFieldPath) = "metadata.annotations[tutorial.crossplane.io/azure-resource-group]" | (.spec.pipeline[] | select(.step == "patch-and-transform").input.resources[] | select(.name == "aks").patches) += [{"fromFieldPath": "metadata.annotations[tutorial.crossplane.io/azure-location]", "toFieldPath": "spec.forProvider.location"}] | del(.spec.pipeline[] | select(.step == "patch-and-transform").input.resources[] | select(.name == "resourcegroup")) | del(.metadata.creationTimestamp, .metadata.generation, .metadata.managedFields, .metadata.resourceVersion, .metadata.uid, .status)' \
    | kubectl apply --filename -

  echo "The Azure SQL Server and AKS compositions now target the supplied resource group and region. AKS will still create its Azure-managed node resource group separately." | gum format

    DB_NAME=silly-demo-db-$(date +%Y%m%d%H%M%S)

    echo "---
apiVersion: devopstoolkitseries.com/v1alpha1
kind: ClusterClaim
metadata:
  name: cluster-01
  annotations:
    tutorial.crossplane.io/azure-resource-group: $AZURE_RESOURCE_GROUP
    tutorial.crossplane.io/azure-location: $AZURE_LOCATION
spec:
  id: cluster01
  compositionSelector:
    matchLabels:
      provider: azure
      cluster: aks
  parameters:
    nodeSize: small
    minNodeCount: 2
---
apiVersion: devopstoolkitseries.com/v1alpha1
kind: SQLClaim
metadata:
  name: silly-demo-db
  annotations:
    tutorial.crossplane.io/azure-resource-group: $AZURE_RESOURCE_GROUP
    tutorial.crossplane.io/azure-location: $AZURE_LOCATION
    tutorial.crossplane.io/azure-database-name: silly-demo
spec:
  id: $DB_NAME
  compositionSelector:
    matchLabels:
      provider: azure
      db: mssql
  parameters:
    version: \"12.0\"
    size: small
---
apiVersion: devopstoolkitseries.com/v1alpha1
kind: AppClaim
metadata:
  name: silly-demo
spec:
  id: silly-demo
  compositionSelector:
    matchLabels:
      type: backend-db
      location: remote
  parameters:
    namespace: production
    image: ghcr.io/jymck/crossplane-tutorial/azure-sql-demo:latest
    port: 8080
    host: silly-demo.acme.com
    dbSecret:
      name: silly-demo-db
      namespace: a-team
    kubernetesProviderConfigName: cluster01" \
    | tee examples/azure-intro.yaml

fi

kubectl create namespace a-team --dry-run=client -o yaml | kubectl apply --filename -

if [[ "$HYPERSCALER" == "azure" ]]; then
  SQL_APP_CREDENTIALS_FILE=$(mktemp)
  chmod 600 "$SQL_APP_CREDENTIALS_FILE"
  printf 'endpoint=%s.database.windows.net\nusername=%s\npassword=%s\nport=1433\n' \
    "$DB_NAME" "$AZURE_SQL_ADMIN_USERNAME" "$AZURE_SQL_ADMIN_PASSWORD" \
    > "$SQL_APP_CREDENTIALS_FILE"
  kubectl --namespace a-team create secret generic silly-demo-db \
    --from-env-file="$SQL_APP_CREDENTIALS_FILE" --dry-run=client -o yaml \
    | kubectl apply --filename -
  rm -f "$SQL_APP_CREDENTIALS_FILE"
  unset AZURE_SQL_ADMIN_PASSWORD
fi

###########
# Argo CD #
###########

REPO_URL=$(git config --get remote.origin.url)
# workaround to avoid setting up SSH key in ArgoCD
REPO_URL=$(echo $REPO_URL | sed 's/git@github.com:/https:\/\/github.com\//') # replace git@github.com: to https://github.com/

yq --inplace ".spec.source.repoURL = \"$REPO_URL\"" argocd/apps.yaml

helm upgrade --install argocd argo-cd \
    --repo https://argoproj.github.io/argo-helm \
    --namespace argocd --create-namespace \
    --values argocd/helm-values.yaml --wait

kubectl apply --filename argocd/apps.yaml
