# Nigeria-DevOps — Repository Context

Index file. Deep details live in scoped CLAUDE.md files (listed at bottom) that load when working in those dirs. Keep this file an index; append new facts to the scoped files.

## Working Mode

- Act as a DevOps engineer fluent in: Go, Helm templating (`tpl`/`index`/deep-merge semantics), Kubernetes, ArgoCD (ApplicationSets, sync policies, ignoreDifferences), YAML overlays, Spring Boot property→env resolution, Node/TS `process.env.X`, git, git-sync, Jenkins shared libraries, SOPS (never decrypt)
- Discipline: plan before edit → identify blast radius (which of 18 env files, which tenants) → edit → verify by rendering with deployer `-p` and diffing before/after → report deltas as tables
- Env-var reading: Spring services — property `a.b-c.d` → env `A_B_C_D`; env vars override properties. Node/TS services — trust only `process.env.<NAME>` occurrences; surrounding JS object key names are irrelevant
- Delegation (benchmark-proven, see `benchmarks/claude-md-impact-report.md`): haiku-class agents for single-file/greppable lookups and mechanical work (multi-env key rollout, render+diff, grep sweeps, app-set entries) — doc context adds nothing there; strong model + these docs for cross-file/architecture reasoning (common-chart templates, central-instance/topic collisions, values precedence, cross-tenant impact) where docs gave +10% accuracy at −33% cost. Never judge a plan by spend — the cheapest answer was the wrongest; require render-verification before accepting any cross-file plan. Every agent prompt must restate the Constraints block verbatim; max 3 agents per task

## Repo Map

- `deploy-as-code/deployer` — Go render/deploy tool (see scoped CLAUDE.md)
- `deploy-as-code/helm/charts/{group}/` — helm charts; `common` = shared library chart; `argo-cd/<tenant>/` = ArgoCD AppProjects + ApplicationSets (see scoped CLAUDE.md)
- `deploy-as-code/helm/environments/` — 18 env value files + secrets (see scoped CLAUDE.md)
- `ci-as-code` — Jenkins shared library; ⚠ nested git repo, not a submodule (see scoped CLAUDE.md)
- `config-as-code` — raw k8s manifests: RBAC, matview-refresh cronjobs (chad), metrics access, `product-release-charts/.../dependancy_chart-*.yaml`
- `infra-as-code` — terraform (`ng-central-prd` live stack, af-south-1) + kubespray ansible
- `instructions.md` — a task brief (kafka audit), not repo documentation

## Tenants & Environments

- Env name = filename without `.yaml` in `helm/environments/`
- Central instance: one shared cluster/services (namespace `egov`, config `bauchi-central-prd.yaml`) serving many states; tenant-specific separations run in per-state namespaces
- Standalone (central instance disabled): `chad-prod`, `kebbi-azm` — own full health stacks, NOT ArgoCD-managed (deployer/Jenkins only)

| state | code | env file (`*-central-prd`) | namespace | argocd dir |
|---|---|---|---|---|
| bauchi (host) | ba | bauchi | egov (shared) | bauchi + egov |
| oyo | oy | oyo | oyo | oyo |
| kogi | ko | kogi | kogi | kogi |
| nasarawa | na | nasarawa | nasarawa | nasarawa |
| abuja | ab | abuja | abuja | abuja |
| plateau | pl | plateau | plateau | plateau |
| borno | bo | borno | borno | borno |
| kebbi | ke | kebbi | kebbi | kebbi |
| sokoto | so | sokoto | sokoto | sokoto |
| ondo | od | ondo | ondo | — |
| adamawa | ad | adamawa | adamawa | — |
| kaduna | kd | kaduna | kaduna | kaduna |
| jigawa | jg | jigawa | jigawa | jigawa |
| zamfara | zf | zamfara | zamfara | zamfara |
| gombe | go | gombe | gombe | — |
| chad (central) | ch | chad | chad | chad |
| chad standalone | chad | chad-prod | chad-prod | — |
| kebbi standalone | kb | kebbi-azm | kebbi-azm | — |

- `egov` argocd dir = shared central services, destination namespace `*`, valueFile `bauchi-central-prd.yaml`
- state-level tenant id for central = `ba`; `host-map` in egov-config maps code → public URL (`https://<state>-hcm.digit.org/`)

## Central-Instance Semantics

- Kafka topics of tenant-specific services under central instance get `<code>-` prefix (e.g. `bo-save-staff`); services strip it via `kafka-tenant-id-pattern: "(ba|oy|ko|...)-"` in egov-config
- Topics consumed/produced by shared (non-tenant-specific) services are NOT prefixed
- Two prefixing mechanisms: prefix-aware services (attendance, expense, project-factory — chart refs `kafka-tenant-id-pattern`) take UNPREFIXED env topic values and add/strip the prefix themselves; non-aware services (transformer, HCM registries) need explicit `<code>-`-prefixed values per env even under central instance; standalone envs always set names explicitly
- Central-instance disabled + tenant-specific service → tenant-specific db url; non-central builds also use flyway url as tenant db url
- Db-url keys per namespace: `ba-db-url`, `kd-db-url`, … selected by `eq .Values.namespace "<tenant>"` chains in `common/values.yaml`
- Indexer/persister sharded per state-group charts: `egov-indexer-ba-bo-ke`, `egov-persister-chad-kb-kd`, … under `indexer-tenant-charts/`/`persister-tenant-charts/`

## Topology & Routing

- Internal service hosts: `egov-service-host` ConfigMap (service name → URL); tenant-specific instances use suffixed keys, e.g. `egov-enc-service-kaduna`, `health-expense-borno` — override the host key in the consumer's env block to route to a tenant instance
- External: `global.hosts` list + per-state ingress hostnames; ingress via `common.ingress` template, cert/root ingress via `cluster-configs` chart
- `hostExclude` in a service block REMOVES those hostnames from that instance's ingress — a host in the list is NOT served by that instance (removing an entry EXPOSES it there)

## Verify Workflow (mandatory)

- Render: `cd deploy-as-code/deployer && go run main.go deploy -e <env> <svc>:<tag> -p`
- Compare: render each variant/env to scratchpad files, then `diff` — never eyeball raw env files to judge override correctness
- Multi-env change: render the same service for every touched env
- Topic parity: when wiring a consumer to tenant topics, diff its rendered topic envs against the producer's rendered output — names must match 1:1

## Assumptions Protocol

- State assumptions explicitly before editing
- Never assume — verify: key exists in target env file; which chart dir serves a service (index = dir name AND `<name>-values.yaml` files); whether consumer expects prefixed topic; vendored `common` tgz freshness
- Safe to assume: conventions documented in these CLAUDE.md files

## Self-Healing (symptom → cause → fix)

| symptom | cause | fix |
|---|---|---|
| render shows stale template | vendored `charts/common-0.0.5.tgz` outdated | `helm dep update` in chart dir (deployer does this automatically; bare `helm template` does not) |
| env override silently ignored | duplicate chart dir shadows real one (index overwrites, logs warning) | find both dirs, delete the stale chart |
| `nil pointer evaluating` in render | env file missing key referenced in `tpl` env block | add key to env file or guard template |
| ArgoCD reverts replica edits | HPA owns replicas; app-sets ignoreDifferences `/spec/replicas` + RespectIgnoreDifferences | never set replicas when `hpa.enabled`; tune `hpa.minReplicas/maxReplicas` |
| deployer aborts mid-run | any shelled command failure panics; args split on whitespace | fix underlying command; no spaces in paths |
| deployer CLI tag has no effect | env `<svc>:` block pins `image.tag`; merge wins over `--set` | bump the tag in the env file |

## Conventions

- Env var names in values: ALL_CAPS_WITH_UNDERSCORE; values keys kebab-case (access hyphenated keys via `index .Values "key-name"`)
- Per-service overrides: env-file top-level key = service name, deep-merged over `common` + chart values

## Constraints

- DO NOT DEPLOY, USE ONLY TO PRINT
- ALWAYS RUN GO COMMAND with `-p`
- DO NOT READ OR MODIFY SECRET FILES *-secrets.yaml or .sops.yaml AT ALL
- MUST NOT DO ANY WRITE OPERATIONS ON KUBERNETES
- DO NOT READ any db-url, aws config map values from env files egov-config

## Scoped CLAUDE.md Files

- `deploy-as-code/deployer/CLAUDE.md` — tool internals, flags, tag resolution, gotchas
- `deploy-as-code/helm/charts/CLAUDE.md` — chart groups, common-chart mechanics, values precedence, argo-cd app-sets
- `deploy-as-code/helm/environments/CLAUDE.md` — env file anatomy, editing/comparison recipes
- `ci-as-code/CLAUDE.md` — Jenkins pipelines, nested-repo caveat

## Maintenance (anti-bloat)

- Append only durable structural facts (mechanics, topology, gotchas) to the relevant scoped file — NEVER session summaries, task history, change logs, or current tags/values (they churn)
- One line per fact; dedupe against existing lines first; prefer correcting a wrong line over adding a new one
- Size caps: root ≤120 lines, scoped ≤80 — compress before appending if exceeded
