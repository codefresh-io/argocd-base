#!/bin/bash

#setup ingress in docker-for-mac
#kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v0.43.0/deploy/static/provider/cloud/deploy.yaml

echo
echo "Do you want to install Codefresh Argo? [Y/n]" && read PROCEED

export PROCEED=$(echo $PROCEED | tr '[:upper:]' '[:lower:]')

if [[ ! -z "$PROCEED" && "$PROCEED" != "y" ]]; then
  echo
  echo "You are making a terrible mistake"
  exit
fi

export IP=$(kubectl get svc ingress-nginx-controller -ningress-nginx -o=jsonpath='{.status.loadBalancer.ingress[0].ip}')
export SOURCE_ORG=noam-codefresh
export SOURCE_REPO=argocd-template
export ENV_NAME=production

if [[ -z "$IP" ]]; then
  export IP=127.0.0.1
fi

echo
echo "Which Git provider are you using? [GITHUB]" && read GIT_PROVIDER

export GIT_PROVIDER=$(echo $GIT_PROVIDER | tr '[:upper:]' '[:lower:]')

if [[ ! -z "$GIT_PROVIDER" && "$GIT_PROVIDER" != "github" ]]; then
  echo
  echo "We currently support only GitHub"
  exit
fi

export REPO_OWNER=$(gh api graphql -f query='
  query {
    viewer {
      login
    }
  }
' | jq -r '.data.viewer.login')

echo
echo "Please enter the name of the GitOps organization/owner [$REPO_OWNER]" && read REPO_ORG

if [[ -z "$REPO_ORG" ]]; then
  export REPO_ORG=$REPO_OWNER
fi

echo
echo "Please enter the name of the GitOps repository that will act as a source of truth [cf-argo-production]" && read REPO_NAME

if [[ -z "$REPO_NAME" ]]; then
  export REPO_NAME=cf-argo-production
fi

echo
echo "Please enter your GitHub token" && read GIT_TOKEN

if [[ -z "$GIT_TOKEN" ]]; then
  echo
  echo "Must provide GitHub token"
  exit
fi

echo
echo "Please enter the Argo CD host [argo-cd.${IP}.xip.io]" && read ARGO_CD_HOST

if [[ -z "$ARGO_CD_HOST" ]]; then
  export ARGO_CD_HOST=argo-cd.${IP}.xip.io
fi

echo
echo "Please enter the Argo Workflows host [argo-workflows.${IP}.xip.io]" && read ARGO_WORKFLOWS_HOST

if [[ -z "$ARGO_WORKFLOWS_HOST" ]]; then
  export ARGO_WORKFLOWS_HOST=argo-workflows.${IP}.xip.io
fi

echo "creating repo $REPO_ORG/$REPO_NAME"

# TODO: Change `--public` to `--private`
gh repo create $REPO_ORG/$REPO_NAME --confirm --description "Production" --public --template $SOURCE_ORG/$SOURCE_REPO

cd $REPO_NAME
git pull
BRANCH=$(gh api graphql -f repositoryOwner="$REPO_ORG" -f repositoryName="$REPO_NAME" -f query='
  query getDefaultBranch($repositoryOwner: String!, $repositoryName: String!) {
    repository(owner: $repositoryOwner, name: $repositoryName) {
      defaultBranchRef {
        name
      }
    }
  }
' | jq -r '.data.repository.defaultBranchRef.name')
echo "Default branch is $BRANCH"

git checkout $BRANCH

mv apps $ENV_NAME
mv apps.yaml $ENV_NAME.yaml

echo "patching files"
sed -i "" \
    -e "s@{{.EnvName}}@$ENV_NAME@g" \
    -e "s@{{.RepoOwner}}@$REPO_ORG@g" \
    -e "s@{{.RepoName}}@$REPO_NAME@g" \
    $ENV_NAME/argo-cd.yaml
sed -i "" \
    -e "s@GIT_TOKEN@$GIT_TOKEN@g" \
    argo-cd/overlays/$ENV_NAME/kustomization.yaml
sed -i "" -e "s@{{.RepoOwner}}@$REPO_ORG@g" \
    argo-cd/overlays/$ENV_NAME/repository.credentials
sed -i "" -e "s@acme.com@$ARGO_CD_HOST@g" \
    argo-cd/overlays/$ENV_NAME/ingress_patch.json

sed -i "" \
    -e "s@{{.EnvName}}@$ENV_NAME@g" \
    -e "s@{{.RepoOwner}}@$REPO_ORG@g" \
    -e "s@{{.RepoName}}@$REPO_NAME@g" \
    $ENV_NAME/argo-events.yaml

sed -i "" \
    -e "s@{{.EnvName}}@$ENV_NAME@g" \
    -e "s@{{.RepoOwner}}@$REPO_ORG@g" \
    -e "s@{{.RepoName}}@$REPO_NAME@g" \
    $ENV_NAME/argo-workflows.yaml
sed -i "" -e "s@acme.com@$ARGO_WORKFLOWS_HOST@g" \
    argo-workflows/overlays/$ENV_NAME/ingress_patch.json

sed -i "" \
    -e "s@{{.EnvName}}@$ENV_NAME@g" \
    -e "s@{{.RepoOwner}}@$REPO_ORG@g" \
    -e "s@{{.RepoName}}@$REPO_NAME@g" \
    $ENV_NAME/sealed-secrets.yaml

sed -i "" \
    -e "s@{{.EnvName}}@$ENV_NAME@g" \
    -e "s@{{.RepoOwner}}@$REPO_ORG@g" \
    -e "s@{{.RepoName}}@$REPO_NAME@g" \
    $ENV_NAME.yaml

git add .

git commit -m "Client's customizations"

git push --set-upstream origin ${BRANCH}

echo
echo "Please confirm that you want to install Argo CD in your cluster? [Y/n]" && read PROCEED

export PROCEED=$(echo $PROCEED | tr '[:upper:]' '[:lower:]')

if [[ ! -z "$PROCEED" && "$PROCEED" != "y" ]]; then
  echo
  echo You are making a terrible mistake
  exit
fi

echo "Installing Argo CD"

kustomize build argo-cd/overlays/$ENV_NAME/ \
    | kubectl apply --filename -

kubectl --namespace argocd \
    rollout status \
    deployment argocd-server

export PASS=$(kubectl \
    --namespace argocd \
    get secret argocd-initial-admin-secret \
    --output jsonpath="{.data.password}" \
    | base64 --decode)

argocd login \
    --insecure \
    --username admin \
    --password $PASS \
    --grpc-web \
    $ARGO_CD_HOST

echo
echo "The password for accessing Argo CD UI is $PASS"
echo "You can open it through http://$ARGO_CD_HOST"

echo
echo "Please confirm that you want to deploy Argo CD application that will syncronize the Git repo with the cluster? [Y/n]" && read PROCEED

export PROCEED=$(echo $PROCEED | tr '[:upper:]' '[:lower:]')

if [[ ! -z "$PROCEED" && "$PROCEED" != "y" ]]; then
  echo
  echo "You are making a terrible mistake"
  exit
fi

kubectl apply \
    --filename $ENV_NAME.yaml

echo
echo "We are finished. Enjoy!"
