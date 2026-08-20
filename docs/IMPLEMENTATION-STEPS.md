# Implementation runbook

Written as the work actually happened - use this as your step-by-step to
reproduce, extend, or tear down this setup. Cluster: kubeadm, 3 nodes
(`ai-poc-master-01` control-plane, `ai-poc-worker-01`, `ai-poc-worker-02`),
k8s v1.28.15, containerd. SSH: `ec2-user@34.238.167.145` (master, has
passwordless sudo and `admin.conf` at `/etc/kubernetes/admin.conf`).

## 0. Cluster discovery (read-only, done first)

```bash
mkdir -p ~/.kube
sudo cp /etc/kubernetes/admin.conf ~/.kube/config
sudo chown ec2-user:ec2-user ~/.kube/config
kubectl get nodes -o wide
kubectl get ns
helm list -A
kubectl get pods -A | grep ingress
kubectl get ingress -A -o wide
kubectl get svc -n ingress-nginx ingress-nginx-controller -o wide
kubectl top nodes
```

Findings that shaped the design:
- `ingress-nginx` (Helm) is `NodePort` (80→30366, 443→31083) with
  `spec.externalIPs` pinned to the Elastic IP `34.204.251.107` on worker-02.
- TLS secret `ingress-tls` / `ai-poc-ingress-tls` is a **single-host** cert
  (`CN=ai-poc-ingress`, SAN `DNS:ai-poc-ingress, IP:34.204.251.107`), copied
  manually into every namespace that needs it. Every existing app
  (`ai-copilot-backend`, `grafana`, `prometheus`, `minio`) shares host
  `ai-poc-ingress` and differs only by context path
  (`nginx.ingress.kubernetes.io/rewrite-target: /$2`,
  `path: /<name>(/|$)(.*)`). We follow the same convention.
- `regcred` (Docker Hub, `kubernetes.io/dockerconfigjson`) exists in
  `loanengine`; Docker Hub username is `rahulnayak11631`.
- Memory: master ~79% used, worker-02 ~28% used → CI runner goes on worker-02.
- No `argocd`, `argo-rollouts`, `dev`, `test` namespaces existed yet.

## 1. GitHub repo bootstrap (done)

```bash
sudo dnf install -y 'dnf-command(config-manager)'
sudo dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
sudo dnf install -y gh
export GH_TOKEN="<repo-scoped PAT>"     # gh picks this up automatically
gh repo edit rahulnayak11631/argorollouts-bluegreen \
  --visibility private --accept-visibility-change-consequences
```

Docker Hub push credentials were read out of the existing `regcred` secret
(never printed to any log/terminal) and stored as GitHub Actions repo
secrets, so the pipeline can push images without new credentials:

```bash
DOCKER_AUTH=$(kubectl get secret regcred -n loanengine \
  -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | \
  python3 -c "import json,sys,base64; d=json.load(sys.stdin); \
  print(base64.b64decode(d['auths']['https://index.docker.io/v1/']['auth']).decode())")
echo -n "${DOCKER_AUTH%%:*}" | gh secret set DOCKERHUB_USERNAME --repo rahulnayak11631/argorollouts-bluegreen
echo -n "${DOCKER_AUTH#*:}"  | gh secret set DOCKERHUB_TOKEN    --repo rahulnayak11631/argorollouts-bluegreen
```

> Security note: the PAT used above was shared in plaintext chat to set this
> up - **rotate/revoke it** once everything is working (GitHub Settings →
> Developer settings → Personal access tokens).

## 2. Namespaces + shared secrets (done)

```bash
for ns in dev test argocd argo-rollouts; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done
# copy the existing wildcard-host TLS cert into every namespace that needs it
for ns in dev test argocd argo-rollouts; do
  kubectl get secret ingress-tls -n ai-copilot-demo -o yaml \
    | grep -v '^\s*\(resourceVersion\|uid\|creationTimestamp\|selfLink\):' \
    | sed "s/namespace: ai-copilot-demo/namespace: $ns/" | kubectl apply -f -
done
# copy the Docker Hub pull secret into dev/test
for ns in dev test; do
  kubectl get secret regcred -n loanengine -o yaml \
    | grep -v '^\s*\(resourceVersion\|uid\|creationTimestamp\|selfLink\):' \
    | sed "s/namespace: loanengine/namespace: $ns/" | kubectl apply -f -
done
```

## 3. Install ArgoCD via Helm (done)

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm install argocd argo/argo-cd -n argocd -f values-argocd.yaml
```

`values-argocd.yaml`:
```yaml
server:
  extraArgs:
    - --insecure
    - --rootpath=/argocd
  service:
    type: ClusterIP
configs:
  cm:
    url: "https://ai-poc-ingress:31083/argocd"
    accounts.ci: apiKey
  rbac:
    policy.csv: |
      p, role:ci, applications, sync, default/bluegreen-demo-*, allow
      p, role:ci, applications, get, default/bluegreen-demo-*, allow
      g, ci, role:ci
dex:
  enabled: false   # not using SSO for this POC; also its pods were churning
                    # (crash/evict loop) on the control-plane node for reasons
                    # unrelated to memory pressure - disabling it was simplest
```

**Gotcha found the hard way**: the `platform/argocd-ingress.yaml` must
**NOT** use `rewrite-target` like the other apps on this host do.
`argocd-server --rootpath=/argocd` expects the `/argocd` prefix to arrive
intact; rewriting it away to `/` made argocd-server itself 404 (confirmed
by comparing a direct `kubectl port-forward svc/argocd-server 18080:80` hit
at `/argocd/` [200] vs the same path through the rewriting ingress [404]).
Fix: plain `pathType: Prefix`, path `/argocd`, no rewrite annotation.

Also: the master node's own `/etc/hosts` had `ai-poc-ingress` pointed at the
public Elastic IP (34.204.251.107) - curling that *from a node inside the
same VPC* hung (no hairpin NAT back in from the IGW). Repointed it locally
to `127.0.0.1` on the master (the ingress-nginx NodePort listens on every
node, so localhost works fine) - this only affects the master node's own
outbound testing, not how other clients reach the cluster.

CLI login through the path-based ingress needs **both** `--grpc-web` and
`--grpc-web-root-path argocd` (not just one):
```bash
argocd login ai-poc-ingress:31083 --insecure --grpc-web --grpc-web-root-path argocd \
  --username admin --password "$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
argocd account generate-token --account ci --grpc-web --grpc-web-root-path argocd   # -> ARGOCD_AUTH_TOKEN secret
argocd account update-password --current-password ... --new-password ...            # rotated; new password saved only to
                                                                                       # ~/argorollouts-setup/argocd-admin-password.txt
                                                                                       # on the master (chmod 600) - retrieve via:
                                                                                       # ssh -i aiops-poc.pem ec2-user@34.238.167.145 cat ~/argorollouts-setup/argocd-admin-password.txt
kubectl -n argocd delete secret argocd-initial-admin-secret   # per ArgoCD's own guidance
```
GitHub Actions repo secrets set (values never printed to any terminal/log):
`DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN` (extracted from `regcred`),
`ARGOCD_SERVER` = `https://ai-poc-ingress:31083/argocd`, `ARGOCD_AUTH_TOKEN`
(the `ci` account's token, scoped to sync/get only `bluegreen-demo-*` apps).

## 4. Install Argo Rollouts via Helm (done)

```bash
helm install argo-rollouts argo/argo-rollouts -n argo-rollouts --set dashboard.enabled=true
curl -sSL -o /tmp/kubectl-argo-rollouts \
  https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
sudo install -m 555 /tmp/kubectl-argo-rollouts /usr/local/bin/kubectl-argo-rollouts
```

**Another subpath gotcha**, opposite flavor from ArgoCD's: the dashboard
binary has no `--rootpath` equivalent - it hardcodes its own base path to
`/rollouts/` internally (root `/` 302-redirects there, static assets are
referenced as absolute `/rollouts/...`). So its ingress path has to be
exactly `/rollouts` (no rewrite, no custom path like `/rollouts-dashboard`)
to match what the binary itself expects - confirmed the same way, via
`kubectl port-forward svc/argo-rollouts-dashboard 3100` first.

Both subpath issues followed the same debugging pattern, worth remembering
for any future in-cluster UI behind this shared ingress: **port-forward
straight to the Service first** and see what path/behavior it wants before
guessing at ingress annotations.

## 5. Push manifests, apply RBAC + ArgoCD Applications (done)

Repo pushed from the local machine (private repo, PAT used only for the
push, then scrubbed from `git remote -v`; added `.gitattributes` first so
the shell scripts survive as LF even though authored on Windows):
```bash
git init -b main
git add -A && git commit -m "..."
git remote add origin https://<PAT>@github.com/rahulnayak11631/argorollouts-bluegreen.git
git push -u origin main
git remote set-url origin https://github.com/rahulnayak11631/argorollouts-bluegreen.git
```

ArgoCD needs its own credential for the now-private repo (separate from the
GitHub Actions side):
```bash
argocd repo add https://github.com/rahulnayak11631/argorollouts-bluegreen.git \
  --username rahulnayak11631 --password "$(gh auth token)" \
  --grpc-web --grpc-web-root-path argocd
```

Then applied `ci/rbac.yaml` (creates the `ci-cd` namespace + `ci-deployer`
ServiceAccount + scoped Roles/RoleBindings in `dev`/`test` + its token
Secret) and both `argocd/application-*.yaml` directly with `kubectl apply`
(simplest for a POC - these two Application objects aren't themselves
GitOps-managed).

First sync (`argocd app sync bluegreen-demo-dev` / `-test`) created the
Rollouts/Services/Ingress correctly. Pods sit in `ErrImagePull` at this
point - expected, `rahulnayak11631/bluegreen-demo:v1` doesn't exist on
Docker Hub yet (that's the placeholder tag in the base kustomization; the
pipeline's first real run overwrites it with a real git-SHA tag it just
pushed).

## 6. Self-hosted GitHub Actions runner on worker-02 (done)

Built a scoped kubeconfig from the `ci-deployer` ServiceAccount (RBAC
verified: can list Rollouts in `dev`/`test`, forbidden everywhere else,
e.g. `loanengine`) and copied it to `~/.kube/ci-deployer.config` on
worker-02 - this is the `KUBECONFIG` the workflow's `deploy-dev`/`deploy-test`
jobs use:
```bash
SERVER=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')
CA_DATA=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
TOKEN=$(kubectl get secret ci-deployer-token -n ci-cd -o jsonpath='{.data.token}' | base64 -d)
# ... assembled into a kubeconfig, scp'd to worker-02:~/.kube/ci-deployer.config
```

Installed on worker-02: `gh`, `kustomize` (standalone binary - `kubectl
kustomize` alone doesn't have `edit`), `yq` (mikefarah/yq), `kubectl-argo-rollouts`,
`argocd` CLI. (`kubectl`, `git`, `python3`, `jq` were already present.)

Registered + installed the runner as a systemd service:
```bash
REG_TOKEN=$(gh api -X POST repos/rahulnayak11631/argorollouts-bluegreen/actions/runners/registration-token --jq .token)
./config.sh --url https://github.com/rahulnayak11631/argorollouts-bluegreen \
  --token "$REG_TOKEN" --name worker-02-poc --labels poc-cluster --work _work --unattended
sudo ./svc.sh install ec2-user && sudo ./svc.sh start
```
Matches the workflow's `runs-on: [self-hosted, poc-cluster]`.

**Note on `worker-02`'s Elastic IP doubling as SSH access**: the same
Elastic IP (`34.204.251.107`) that fronts the ingress NodePort also answers
SSH on port 22 straight to worker-02 - that's how tools got installed there
without needing a hop through master.

## 7. First run + verification

*(next: trigger the pipeline, watch it build/push/deploy/gate/promote for real)*
