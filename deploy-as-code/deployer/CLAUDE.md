# Deployer (Go tool)

Renders/deploys helm charts for an environment. In this repo: PRINT ONLY (`-p`), never apply.

## Code Path

- `main.go` → `cmd/root.go` (cobra) → `cmd/deploy.go` → `pkg/cmd/deployer/deployer.go` (`DeployCharts`) + `options.go`
- Dead/legacy, ignore: `internal/`, `configs/deployment_configurator.go`, `full_installer.go`, `standalone_installer.go`

## Command

```
go run main.go deploy -e <env> [-p] [-c] [--helm-dir <path>] <svc>[:<tag>][,<svc2>:<tag2>...]
```

- `--helm-dir` default `../../deploy-as-code/helm` (works when run from `deployer/`)
- `-e` env = filename without `.yaml` under `helm/environments/`
- `-p` print manifests to stdout, no cluster mutation
- `-c` also renders+applies `cluster-configs` chart and decrypts `<env>-secrets.yaml` via sops — never use for inspection tasks

## Chart Index

- Walks helm dir: each `values.yaml` → key = parent dir name; each `<name>-values.yaml` → extra key `<name>` mapped to same dir (one chart can serve many services, e.g. elasticsearch master/data)
- Duplicate key = warning + overwrite; walk is lexical (`filepath.Walk`), so the LATER path wins (`charts/common` beats vendored `backbone-services/.../common`) — shadowing bug source; unknown service = panic

## Tag Resolution

1. CLI `svc:tag` → adds `--set image.tag=<tag> --set initContainers.dbMigration.image.tag=<tag>`
2. No tag → live cluster lookup `kubectl get deployments -l app=<svc> --all-namespaces` (fails silently offline)
3. Else env-file/chart `image.tag`
- ⚠ if the env file's `<svc>:` block pins `image.tag`, it WINS over the CLI `--set` (common.name merge order, render-verified) — real tag change = edit the env file (also what ArgoCD deploys); CLI tag is effective only when the env block has no `image.tag`
- `svc-db:tag` → `-db` stripped, resolves to `svc` chart

## Render Steps Executed

1. `helm dep update` in chart dir (re-vendors `common` tgz)
2. `kubectl apply -f crds/` if chart has one (errors suppressed)
3. `helm template -f <env-file> --set name=<svc> [-f <chart>/<svc>-values.yaml] .`
4. `-p` → stdout; else `--output-dir` tmp + `kubectl apply`

## Gotchas

- Any shelled command failure → `log.Panicln`, whole run aborts
- Commands split via `strings.Fields` — no shell quoting, paths with spaces break
- Runtime deps: helm3, kubectl, sops (bundled in Dockerfile image)
