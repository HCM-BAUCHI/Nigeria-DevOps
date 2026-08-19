# Environments

18 env value files, one per state/cluster. Env name = filename without `.yaml`. Secrets: only `bauchi-central-prd`, `chad-prod-central-prd`, `kebbi-azm-central-prd` have `-secrets.yaml` — NEVER open secrets or `.sops.yaml`.

## File Anatomy (e.g. `bauchi-central-prd.yaml`)

- `global:` — `domain`, `setup`, `hosts:` (all public hostnames served), `schema:` (state codes hosted: ba oy ko na ab pl bo ke so od ad kd jg kb ch go chad zf)
- `cluster-configs:` — mirrors cluster-configs chart values:
  - `namespaces.values`: infra ns (backbone, es-cluster, kafka-cluster, …) + one ns per state
  - `configmaps.egov-config.data`: shared config (⚠ db-url/aws values forbidden to read), incl. `kafka-tenant-id-pattern`, `egov-state-level-tenant-id: ba`, `host-map` (code → `https://<state>-hcm.digit.org/`), `db-schema-names`, `is-environment-central-instance`
  - `configmaps.egov-service-host.data`: internal service URLs; tenant-specific instances = suffixed keys (`egov-enc-service-kaduna`, `health-expense-borno`)
- `disableAnnotationTimestamp: true` — suppresses redeploy-timestamp annotation diffs
- Remaining top-level keys = per-service override blocks (matched via deployer `--set name=<svc>`): `image.tag`, `hpa.*`, resources, `central-instance-build/enabled`, kafka topic envs, service-specific config

## ArgoCD Wiring

- Only central envs are ArgoCD-managed (valueFile refs in `charts/argo-cd/<tenant>/`); `bauchi-central-prd.yaml` is used by both `bauchi` and shared `egov` app-sets
- `chad-prod` and `kebbi-azm` (standalone, central-instance disabled) have no argocd refs — deployer/Jenkins only
- No argocd dirs yet: ondo, adamawa, gombe

## Editing Recipes

- Tenant-specific service separation (Chad-prod / Borno-expense model):
  0. first check whether the service is already per-tenant (`grep -l "^<svc>:" environments/*.yaml` + suffixed `egov-service-host` keys) — "separation" may mean standing up a missing dedicated instance (e.g. health-expense-calculator runs per-tenant in ba/bo/oy), not peeling off a shared one
  1. per-service block in tenant env file (image, db, topics)
  2. suffixed key in `egov-service-host` for routing consumers to the tenant instance
  3. list entry in the tenant's app-set (if ArgoCD-managed)
  4. prefixed kafka topics (`<code>-<topic>`) where tenant-specific + central instance
- Kafka topic naming: prefix `<code>-` only for tenant-specific flows under central instance; topics to shared services stay unprefixed; validate codes against `kafka-tenant-id-pattern`
- Comparison: render each env with deployer `-p` to scratchpad files, `diff` the renders — raw env-file eyeballing misses merge/default effects
- Additive-only proof: render every touched service before/after in the target env AND at least one untouched env — untouched-env diffs must be empty
- Multi-env key rollout: decide per-tenant value vs shared default; tenant-level override only when values can legitimately differ (e.g. `STATE_LEVEL_TENANTID`); list which of the 18 files were touched
