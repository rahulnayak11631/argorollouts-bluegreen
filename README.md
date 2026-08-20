# Argo Rollouts Blue-Green learning pipeline

A minimal Spring Boot app deployed with **Argo Rollouts (Blue-Green strategy)**
into two namespaces, `dev` and `test`, on a kubeadm cluster - GitOps'd by
**ArgoCD**, gated by a **GitHub Actions** pipeline that only promotes `dev`
to active (and rolls the same image into `test`) if a smoke test against the
**preview** pod passes.

See [`docs/IMPLEMENTATION-STEPS.md`](docs/IMPLEMENTATION-STEPS.md) for the
full step-by-step runbook of everything that was actually done on the
cluster to stand this up - use it as your reference/take-home notes.

## Layout

- `app/` - the Spring Boot sample (`/version` reports which release is
  answering; `/actuator/health` can be toggled via `APP_HEALTHY=false` to
  simulate a broken release for the negative-path demo).
- `k8s/base` + `k8s/overlays/{dev,test}` - kustomize: one `Rollout` (Blue-Green)
  + active/preview `Service`s + `Ingress` per namespace, same app.
- `argocd/` - the two ArgoCD `Application` objects (one per namespace).
- `platform/` - cluster infra ingresses for ArgoCD's own UI and the Argo
  Rollouts dashboard, applied once manually (not part of the app's GitOps).
- `ci/` - RBAC for the CI runner's scoped kubeconfig, and the shell scripts
  the pipeline uses to wait for rollout phases and smoke-test an endpoint.
- `.github/workflows/ci-cd.yml` - build image → deploy to `dev` → smoke test
  the preview → promote (or abort) → repeat for `test`.

## How the Blue-Green + gate mechanics work

1. Pushing an `app/**` change builds+pushes a new image tagged with the git
   short SHA.
2. The `dev` overlay's image tag is bumped and pushed to `main`; ArgoCD syncs
   it. Because `autoPromotionEnabled: false` in `dev`, Argo Rollouts spins up
   a new "preview" ReplicaSet and points `bluegreen-demo-preview` at it, while
   `bluegreen-demo-active` (and the live traffic on `/dev-bluegreen`) stays on
   the old version. The Rollout's `.status.phase` becomes `Paused`.
3. CI curls `/dev-bluegreen-preview` (the preview Service, not the active
   one) and checks both `/actuator/health` and that `/version` reports the
   SHA it just built.
4. **Pass** → `kubectl argo rollouts promote` flips `active` to the new
   ReplicaSet; the pipeline then repeats the bump+sync+smoke-test for `test`
   (which has `autoPromotionEnabled: true`, since `dev` already proved the
   image works - `test` still gets its own independent Blue-Green cycle).
5. **Fail** → `kubectl argo rollouts abort` leaves `active` untouched and
   scales down the bad preview; the `test` job never runs.

## Access

- App: `https://ai-poc-ingress:31083/dev-bluegreen/version`,
  `/dev-bluegreen-preview/version`, `/test-bluegreen/version` (needs
  `ai-poc-ingress` in your hosts file, already used by other apps on this
  cluster).
- ArgoCD UI: `https://ai-poc-ingress:31083/argocd`
- Argo Rollouts dashboard: `https://ai-poc-ingress:31083/rollouts/` (the
  dashboard hardcodes this base path internally, see `platform/rollouts-dashboard-ingress.yaml`)
