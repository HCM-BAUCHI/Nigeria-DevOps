# Helm Charts

## Groups

| dir | content |
|---|---|
| `common/` | library chart (v0.0.5): `_helpers.tpl`, `_deployment.yaml`, `_service.yaml`, `_ingress.yaml`, `_hpa.yaml`, `_cronjob.yaml` + platform default values |
| `cluster-configs/` | bootstrap chart: namespaces, `egov-config`/`egov-service-host` configmaps, root ingress, RBAC, secrets |
| `core-services/`, `business-services/`, `health-services/`, `frontend/`, `backbone-services/`, `utilities/` | service charts per category |
| `indexer-tenant-charts/`, `persister-tenant-charts/` | state-group sharded indexer/persister charts (`egov-indexer-ba-bo-ke`, `egov-persister-chad-kb-kd`, …) |
| `argo-cd/<tenant>/` | AppProject + ApplicationSets per tenant (see below) |
| `backbone-services/argo-cd/` | vendored ArgoCD install chart itself |
| `monitoring/` | helmfile-based, not driven by deployer |

## Common Chart Mechanics (correctness-critical)

- Service chart `templates/*.yaml` are one-liners: `{{- template "common.deployment" . -}}`
- `common.name` resolution: `--set name=<svc>` → looks up env-file top-level key `<svc>` → `mustMergeOverwrite` deep-merge over `.Values.common` then `.Values` — this is how one env file overrides every service
- Hyphenated keys must be read via `index .Values "key-name"` (e.g. `central-instance-build`, `db-read-url-enabled`, `rollout-max-surge`)
- `appType: "java-spring"` triggers Spring env bundle (`extraEnv.java`: tomcat threads, hikari pool, flyway, kafka bootstrap) + default resources
- Env blocks are raw YAML strings piped through `tpl` + `nindent`; they reference ConfigMaps `egov-config` (db hosts, kafka brokers, flags, `kafka-tenant-id-pattern`, `host-map`, `db-schema-names`) and `egov-service-host` (service → internal URL) and Secret `db`
- Db-url key per namespace via `{{- if eq .Values.namespace "kaduna" }} kd-db-url {{- else if ... }}` chains in `common/values.yaml`
- HPA: `replicas:` emitted only when `hpa.enabled` is false; `_hpa.yaml` = autoscaling/v2, CPU+memory 80%, `hpa.minReplicas`/`hpa.maxReplicas`; rollout keys `rollout-max-surge`/`rollout-max-unavailable`
- initContainers: `dbMigration` (flyway, own `image.tag`), `gitSync` (SSH secret `git-creds`, clones into shared emptyDir); extra via `initContainers.extraInitContainers`
- `common.image`: prefixes `global.containerRegistry` (default `egovio`) unless repository contains `/`; tag is `required`

## Values Precedence (lowest → highest, render-verified)

1. common chart defaults (`common/values.yaml` via vendored tgz → `.Values.common`)
2. service chart `values.yaml`
3. env file top-level + `common:` keys (`-f <env>.yaml`)
4. `<svc>-values.yaml` alt file
5. `--set` flags (incl. deployer `--set image.tag`)
6. env file `<service-name>:` block — merged LAST inside `common.name`, wins over everything incl. `--set`

- The merge is a side effect: `common.name` (`_helpers.tpl:5`) runs `mustMergeOverwrite . $values`, mutating the root context on its first invocation (`metadata.name`); anything templated before that call sees unmerged values

## Vendoring

- Every service chart: `Chart.yaml` dependency `common` v0.0.5 `repository: file://../../common`, committed `charts/common-0.0.5.tgz` + `Chart.lock`
- After editing `common/templates/*`: re-vendor consumers (`helm dep update` per chart) or renders use the stale tgz; deployer runs dep update automatically, bare `helm template` does not
- `*.tgz` may be gitignored in places — do not assume re-vendoring produces a commit diff

## argo-cd/<tenant>

- `<tenant>-project.yaml` AppProject: sourceRepo `git@github.com:HCM-BAUCHI/Nigeria-Devops.git`, destination namespaces, resource whitelists
- `<tenant>-app-set-<category>.yaml` ApplicationSets (categories: health, ui, core, business, utilities, indexer, persister, airflow), list generator of service names
  - path `deploy-as-code/helm/charts/<category>-services/{{name}}`, targetRevision `ng-central-prd`
  - `helm.valueFiles`: `values.yaml` + `../../../environments/<env>.yaml`
  - syncPolicy: automated `{prune: false, selfHeal: true}`, `ApplyOutOfSyncOnly`, `ServerSideApply`, `RespectIgnoreDifferences`; retry limit 10
  - `ignoreDifferences` on Deployment `/spec/replicas` (HPA ownership)
- `egov/` dir = shared central services, destination namespace `*`, valueFile `bauchi-central-prd.yaml`
- Add a service to a tenant = list-generator entry in the matching app-set; standalone envs `chad-prod`/`kebbi-azm` have NO argocd wiring (deployer/Jenkins only)
