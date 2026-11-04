# OpenCost

Kubernetes cost monitoring for the `ng-central-prd` cluster. Runs in the
`monitoring` namespace alongside kube-prometheus-stack, Grafana and GoAlert, and
is served on its own hostname: **https://opencost-global.digit.org**

One Deployment, two containers:

| container | image | port | role |
|---|---|---|---|
| `opencost` | `ghcr.io/opencost/opencost:1.121.3` | 9003 | exporter: cost model API + `/metrics` |
| `opencost-ui` | `ghcr.io/opencost/opencost-ui:1.121.3` | 9090 | nginx serving the SPA, proxies `/model/` to the exporter over localhost |

The ingress targets port 9090; the ServiceMonitor scrapes port 9003.

## Why this chart does not use `common.ingress` or `common.service`

Both were written for the shared-domain DIGIT services and cannot express what
OpenCost needs:

- `common.ingress` can only emit `.Values.global.domain` as its host, and always
  mounts at `/{{ ingress.context }}`. OpenCost gets its own subdomain at `/`.
- `common.service` emits exactly one port. This pod serves two.

`common.deployment` *is* used — the UI rides along in `extraContainers`.

## Why a subdomain and not `bauchi-hcm.digit.org/opencost`

The OpenCost UI cannot be served from a sub-path using the published image.
`ui/vite.config.ts` sets Vite's `base` from the `VITE_BASENAME` build argument,
so the asset prefix is compiled in, not configurable at runtime. The published
image is built with the default (`/`), which you can confirm from the image
itself:

```sh
# ENV UI_PATH=/
crane config ghcr.io/opencost/opencost-ui:1.121.3

# every asset is absolute: href="/assets/root-*.css", and the bundle carries
# window.__reactRouterContext = {"basename":"/"}
crane export ghcr.io/opencost/opencost-ui:1.121.3 - | tar -xO var/www/index.html
```

Behind an ingress at `/opencost`, the browser would therefore request
`/assets/*` at the domain root and get the DIGIT frontend instead. The runtime
`BASE_URL` env var does **not** fix this — it only moves the *API* prefix, which
is why the subpath looks supported but isn't. Upstream says the same thing in
its chart values: `uiPath: /  # Requires building a custom image using the build
argument "ui_path"`.

Serving at the root of a dedicated hostname sidesteps all of it and keeps the
image stock, so version bumps are a tag change rather than a rebuild.

## DNS and TLS

`digit.org` is **not** in this AWS account's Route 53 (only `okd-digit.com` is) —
it runs on GoDaddy nameservers, and there is no wildcard record. Before this app
can serve traffic, someone with DNS access must add:

```
opencost-global.digit.org.  CNAME  a3286d4063f16429c981706f79486b47-750184101.af-south-1.elb.amazonaws.com.
```

TLS is then automatic. Unlike the GoAlert ingress — which references
`bauchi-hcm.digit.org-tls-certs` and quietly relies on `root-ingress` in the
`egov` namespace already holding that certificate — nothing else serves this
hostname, so this ingress owns its own cert. The
`cert-manager.io/cluster-issuer: letsencrypt-prod` annotation makes
cert-manager's ingress-shim create the Certificate and write
`opencost-global.digit.org-tls-certs` into the `monitoring` namespace.

The solver is HTTP-01, so **the DNS record must resolve before the cert can
issue**. Order of operations: DNS → sync → cert.

Watch it with:

```sh
kubectl -n monitoring get certificate opencost-global.digit.org-tls-certs -w
kubectl -n monitoring describe certificaterequest   # if it stays False
```

## Putting authentication in front of it

**`ingress.auth.enabled` ships as `false`, which means the UI is reachable by
anyone who can resolve the name.** OpenCost exposes a full inventory of every
workload, namespace and node in the cluster along with its cost. Close this
before sharing the link.

It is off by default because it cannot be switched on from this chart alone.
The cluster's oauth2-proxy (`egov` namespace) is a **GitHub** OAuth App gated on
org `HCM-BAUCHI` / team `central-oauth-access`, and its ingress answers for
exactly one host, `bauchi-hcm.digit.org`. Two things are therefore missing for a
second hostname:

1. oauth2-proxy has no ingress rule for `opencost-global.digit.org/oauth2`, so
   the `auth-url` subrequest has nowhere to land.
2. A GitHub OAuth App accepts a single authorization callback URL. The existing
   app points at `https://bauchi-hcm.digit.org/oauth2/callback`, so the login
   round-trip for a new host is rejected by GitHub.

To enable it properly:

1. Register a second GitHub OAuth App in the `HCM-BAUCHI` org with callback
   `https://opencost-global.digit.org/oauth2/callback`.
2. Add its client id/secret to the oauth2-proxy secret in
   `environments/bauchi-central-prd-secrets.yaml` (SOPS), as a second
   oauth2-proxy instance or via a separate release.
3. Give that instance an ingress for `opencost-global.digit.org` at `/oauth2`.
4. Set `ingress.auth.enabled: true` here and re-sync.

Do **not** reach for `--cookie-domain=.digit.org` on the existing proxy as a
shortcut: it would share the session cookie with every other tenant's HCM site.

Until that is in place, the zero-dependency guard is a source-IP allowlist:

```yaml
ingress:
  sourceRange: "196.x.x.0/24,41.x.x.0/24"   # office / VPN egress
```

which renders `nginx.ingress.kubernetes.io/whitelist-source-range`.

## Cost data

The exporter reads cluster inventory through its own read-only ClusterRole and
joins it against Prometheus at
`kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090`.

No cloud credentials are configured. On AWS, OpenCost falls back to the public
AWS pricing API for on-demand node list prices, which is enough for relative
allocation (which namespace/workload costs what) but is **not** your actual
bill — it ignores savings plans, reserved instances, spot discounts and EDP
terms. Wire up a cloud-integration secret (Cost and Usage Report) if you need
real billing figures.

`EMIT_KSM_V1_METRICS=false` + `EMIT_KSM_V1_METRICS_ONLY=true` is deliberate:
kube-prometheus-stack already ships kube-state-metrics v2, so OpenCost takes the
`else if` branch in `pkg/metrics/kubemetrics.go` and emits only the handful of
v1 metrics KSM v2 dropped, instead of duplicating the full set.

The ServiceMonitor carries `release: kube-prometheus-stack` because that is what
this cluster's Prometheus CR selects on. Without it OpenCost still works, but
the UI can only show the present moment — it reads its own history back out of
Prometheus.

## RBAC and the ArgoCD project

`templates/rbac.yaml` creates a ServiceAccount plus a cluster-scoped ClusterRole
and ClusterRoleBinding (read-only: get/list/watch on nodes, pods, PVs, etc. —
OpenCost never writes).

`egov-project` had no `clusterResourceWhitelist`, which in ArgoCD means **every**
cluster-scoped resource is denied. `argo-cd/egov/egov-app-project.yaml` now
whitelists `ClusterRole` and `ClusterRoleBinding`; without that change the app
fails to sync with "resource ClusterRole is not permitted in project".

## Deploying

```sh
kubectl apply -f ../../argo-cd/egov/egov-app-project.yaml
kubectl apply -f ../../argo-cd/egov/egov-app-set-opencost.yaml
```

The ApplicationSet has no `automated:` block on purpose — review the diff in the
UI and sync `egov-opencost` manually the first time, because this app creates
cluster-scoped RBAC. Add `automated: {prune: false, selfHeal: true}` once it is
running clean.

### Rendering locally

```sh
helm template opencost . \
  -f values.yaml \
  -f ../../../environments/bauchi-central-prd.yaml \
  -n monitoring
```

Note that editing the nginx ConfigMap does not restart the UI container by
itself — `kubectl -n monitoring rollout restart deploy/opencost` after a config
change.

## Gotchas

- **The nginx config is mounted, not generated.** `docker-entrypoint.sh` runs
  `envsubst` over `default.nginx.conf.template` only
  `if [ ! -e /etc/nginx/conf.d/default.nginx.conf ]`. Mounting a finished file
  there skips substitution entirely, so `templates/configmap-ui-nginx.yaml` must
  contain **no** `${...}` placeholders. We mount our own for two reasons: the
  shipped template hardcodes `listen [::]:9090` and this is an IPv4-only EKS
  cluster, and its `${API_SERVER}` defaults to `0.0.0.0` where `127.0.0.1` is
  correct for a sidecar.
- **`BASE_URL` still matters even though envsubst is skipped.** The entrypoint
  separately rewrites a `{PLACEHOLDER_BASE_URL}` token inside the compiled JS
  bundles with it. It must match the `location /model/` block in the ConfigMap.
- **Keep `replicas: 1`.** Two exporters emit duplicate cost metrics for the same
  cluster and double-count in Prometheus.
- The Jaeger env vars on the exporter come from the common chart
  (`global.tracing-enabled: true` in the env file) and are inert here — they use
  a `fieldRef`, not a ConfigMap, so they cost nothing.
