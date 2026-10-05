# goalert

[GoAlert](https://github.com/target/goalert) — on-call scheduling, escalation policies and
alert notification. Deployed to the shared `monitoring` namespace on `ng-central-prd` and
served at `https://bauchi-hcm.digit.org/goalert`.

| | |
|---|---|
| namespace | `monitoring` (alongside kube-prometheus-stack / Alertmanager) |
| ArgoCD app | `egov-goalert` (project `egov-project`) |
| ApplicationSet | `argo-cd/egov/egov-app-set-goalert.yaml` — **manual sync**, no `automated` block |
| image | `goalert/goalert:v0.35.0` (docker.io, repo contains `/` so `global.containerRegistry` is not prefixed) |
| port | `8081` |
| ingress | `/goalert` on `global.domain`, behind oauth2-proxy |
| database | dedicated `goalert` DB on the existing RDS instance |

## Sub-path hosting (do not add a rewrite)

GoAlert handles its own path prefix: `app/inithttp.go` wraps the whole mux in
`http.StripPrefix(cfg.HTTPPrefix, ...)`. Consequences:

- nginx must forward the **full** path — there is deliberately **no**
  `nginx.ingress.kubernetes.io/rewrite-target` annotation on this ingress.
- the pod itself answers on `/goalert/health`, which is why the probe paths include
  the prefix.
- the prefix is **derived from the path of `GOALERT_PUBLIC_URL`** —
  `app/cmd.go` does `cfg.HTTPPrefix = u.Path`.

> **Do not set `GOALERT_HTTP_PREFIX`.** As of v0.35.0 `--http-prefix` is deprecated
> (`MarkDeprecated("http-prefix", "use --public-url instead")`, which is why it no
> longer appears in `goalert --help`), and supplying it alongside `--public-url` is a
> hard startup failure: `public-url and http-prefix cannot be used together`.
> Setting the prefix in the public URL is the only supported way.

`ingress.waf.enabled` is set to `false` for this chart (the `common` default turns on the
lua-resty-waf annotations) so the GraphQL API is not score-filtered.

## Prerequisites — do these before the first ArgoCD sync

### 1. Database

GoAlert needs its own database and the `pgcrypto` extension. It will try to create the
extension itself on first boot, which needs elevated privileges — easiest to do it up front
as the RDS master user:

```sql
CREATE DATABASE goalert;
CREATE USER goalert WITH PASSWORD '<generated>';
GRANT ALL PRIVILEGES ON DATABASE goalert TO goalert;
\c goalert
CREATE EXTENSION IF NOT EXISTS pgcrypto;
GRANT ALL ON SCHEMA public TO goalert;
```

Schema migrations run automatically on container start.

### 2. Secret

The deployment reads both sensitive values from a Secret named `goalert` in the
`monitoring` namespace. It is intentionally **not** templated by this chart so credentials
stay out of git:

```bash
kubectl create secret generic goalert -n monitoring \
  --from-literal=db-url='postgres://goalert:<password>@<rds-host>:5432/goalert?sslmode=require' \
  --from-literal=data-encryption-key="$(openssl rand -base64 32)"
```

> Keep `data-encryption-key` safe. Rotating it requires passing the previous value as
> `GOALERT_DATA_ENCRYPTION_KEY_OLD` until re-encryption completes.

To manage it via GitOps instead, add a `goalert` block under
`cluster-configs.secrets` in `environments/bauchi-central-prd-secrets.yaml` (SOPS) and add a
matching template under `cluster-configs/templates/secrets/`, following
`pgadmin-secret.yaml`.

### 3. First admin user

After the pod is `Running`:

```bash
kubectl exec -n monitoring deploy/goalert -- \
  goalert add-user --admin --user admin --email <you>@egovernments.org
```

## Wiring Alertmanager → GoAlert

Use the **native** Alertmanager endpoint (not the generic one):
`POST /api/v2/prometheusalertmanager/incoming`, integration key type
`prometheusAlertmanager`.

Alertmanager runs in this same namespace, so route to the ClusterIP service and bypass the
ingress and oauth2-proxy entirely. The `/goalert` prefix is still required in-cluster —
GoAlert strips it internally, so omitting it returns 404.

Existing objects in GoAlert (created at rollout):

| | |
|---|---|
| escalation policy | `ng-central-prd Cluster Alerts` (repeat 0) |
| service | `ng-central-prd Alertmanager` |
| integration key | `kube-prometheus-stack`, type `prometheusAlertmanager` |

Config, in the SOPS secrets file under `cluster-configs.secrets.alertmanager.config`
(re-apply the `kube-prometheus-stack` release from `helm/charts/monitoring` afterwards):

```yaml
receivers:
  - name: goalert
    webhook_configs:
      - url: http://goalert.monitoring:8081/goalert/api/v2/prometheusalertmanager/incoming
        send_resolved: true    # firing -> triggered, resolved -> auto-close
        max_alerts: 0
        http_config:
          authorization:
            type: Bearer       # keeps the key out of URLs and access logs
            credentials: <integration-key>

route:
  routes:
    - receiver: goalert
      continue: true           # see caveat below
      group_by: ['alertname', 'namespace']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h
      matchers:
        - severity =~ "critical|warning"
```

Bearer auth needs Alertmanager >= 0.22 (cluster runs 0.26.0). `?token=` also works —
`auth.GetToken` prefers the `token` field/query, then the legacy `integrationKey`,
`integration_key`, `key` aliases, then `Authorization: Bearer`.

### Wiring caveats (both will bite silently)

- **`continue: true` is mandatory.** Without it this route consumes matching alerts and the
  pre-existing Slack/email receivers go quiet. Order matters too — place it before any
  broader route that would match the same alerts.
- **Dedup is keyed off the summary string.** The handler sets
  `Dedup: alert.NewUserDedup(summary)`, and one webhook POST becomes **one** GoAlert alert
  per Alertmanager *group*, not per individual alert. Summary comes from
  `commonAnnotations.summary`; when that is absent it falls back to
  `"<first alert summary> and N others"`, which changes as the group grows — producing
  duplicate alerts that never auto-close. Make sure rules set `annotations.summary` and
  group by `alertname` so the common annotation stays stable.

### Automating against the GoAlert API

`POST /api/v2/identity/providers/basic?noRedirect=1` (form `username`/`password`) returns a
session token for use as `Authorization: Bearer` against `/api/graphql`. It **requires a
`Referer` header matching the public URL** — without one GoAlert replies
`307 -> /?login_error=invalid+referer`. `createService` can create the escalation policy and
integration keys in a single mutation via `newEscalationPolicy` / `newIntegrationKeys`.

## Known caveats

- **Double login.** oauth2-proxy guards the perimeter (GitHub org `HCM-BAUCHI`, team
  `central-oauth-access`), then GoAlert asks for its own credentials. GoAlert cannot consume
  oauth2-proxy's trusted headers. To collapse this to one login, configure GoAlert's own
  GitHub/OIDC provider in its admin config and drop the two `auth-*` annotations.
- **Inbound webhooks from the internet** (Twilio status callbacks, Mailgun) will be
  intercepted by oauth2-proxy. In-cluster callers are unaffected. If external webhooks are
  needed, add a second ingress for the specific `/goalert/api/v2/...` paths without the
  `auth-*` annotations.
- **JAEGER_\* env vars** are injected by the `common` chart because
  `global.tracing-enabled: true` in the env file. GoAlert only reads `GOALERT_*` variables,
  so these are inert.
- **`replicas` is pinned to 1.** The GoAlert engine should run as a single instance per
  region (`GOALERT_REGION_NAME: ng-central-prd`). Scale out by adding replicas with
  `GOALERT_API_ONLY=true`, not by raising this value.
- **Metrics are not scraped yet.** GoAlert can expose Prometheus metrics via
  `GOALERT_LISTEN_PROMETHEUS`, but that needs a second Service port plus a ServiceMonitor,
  which `common.service` does not emit. Left off deliberately.
