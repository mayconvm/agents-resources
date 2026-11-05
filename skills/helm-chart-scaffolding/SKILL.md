---
name: helm-chart-scaffolding
description: Design, organize, and manage Helm charts for templating and packaging Kubernetes applications with reusable configurations. Use when creating Helm charts, packaging Kubernetes applications, implementing templated deployments, adapting a chart to a real cluster (Traefik-only Ingress — never ingress-nginx, ARM64 images, edge TLS), or auditing a chart for production readiness before go-live.
---

# Helm Chart Scaffolding

Comprehensive guidance for creating, organizing, and managing Helm charts for packaging and deploying Kubernetes applications.

## Purpose

This skill provides step-by-step instructions for building production-ready Helm charts, including chart structure, templating patterns, values management, and validation strategies.

## When to Use This Skill

Use this skill when you need to:

- Create new Helm charts from scratch
- Package Kubernetes applications for distribution
- Manage multi-environment deployments with Helm
- Implement templating for reusable Kubernetes manifests
- Set up Helm chart repositories
- Follow Helm best practices and conventions
- **Adapt an existing chart to a real cluster** (see Cluster Profile below)
- **Audit a chart for production readiness** before go-live (see Production Gate)

## Cluster Profile — read this BEFORE writing templates

A chart that lints is not a chart that deploys. **`helm lint` only parses templates; it
never validates against the cluster.** Always inspect the target cluster first, then write
templates that match it.

### Reference cluster (crm-whats production target)

Verified on 02/11/2026 with read-only commands. Re-verify on a different target.

| Item | Value | Consequence for the chart |
|---|---|---|
| Distribution | k3s **v1.35.5** | CRDs and RBAC are plain upstream Kubernetes |
| Nodes | **1 node**, 4 vCPU, 23 Gi RAM | No HA; no `PodAntiAffinity` that needs 2 nodes; **1 replica is the only safe default** |
| **Architecture** | **aarch64 / linux-arm64** (Oracle Linux 9.8, kernel `el9uek.aarch64`) | Every app image **must** publish `linux/arm64`. An amd64-only image = `exec format error` |
| IngressClass | **`traefik`** only (Traefik v3.6.12) | **No ingress-nginx.** `nginx.ingress.kubernetes.io/*` annotations are silently ignored |
| Traefik entrypoints | `web` 80, `websecure` 443 | Route on **`web`**: TLS terminates at the edge proxy (see TLS topology below) |
| **TLS** | **Terminated by an external reverse proxy**, not the cluster | The chart must stay **HTTP-only**: no `tls:`, no cert-manager, no ACME, no `websecure` |
| Network path | Edge proxy → **VPN** `100.101.79.205` → Traefik `10.0.0.217` | The proxy must forward `Host` and `X-Forwarded-Proto/Host/For`; the app needs `trustProxy` |
| storageClass | `local-path` (rancher.io/local-path), **default** | **No quota enforcement.** `spec.resources.requests.storage` is decorative |
| Disk | 29.4 Gi total, **15.5 Gi available** | PVC sizes in `values.yaml` are a promise you cannot keep — size against real free space |
| Registry access | GHCR private, credentials in `imagePullSecrets` | No local `docker build` reaches the cluster — **everything flows through the registry** |
| Secrets | `sealed-secrets` controller installed | Preferred over raw `kubectl create secret` |
| Add-ons absent | cert-manager, metrics-server HPA targets, external-dns | Do not assume they exist |

### Mandatory pre-flight inspection

Run these before writing or changing templates. Everything is read-only.

```bash
# What controller actually exists?
kubectl get ingressclass
kubectl get pods -A | grep -iE 'traefik|nginx|cert-manager|external-dns'

# Which CRDs can I rely on?
kubectl get crd | grep -E 'traefik\.io|cert-manager\.io'

# Storage reality (local-path does NOT enforce the PVC size)
kubectl get storageclass
kubectl get pvc -A
kubectl top nodes 2>/dev/null || true
kubectl get node -o jsonpath='{.items[0].status.allocatable}{"\n"}'

# Real free disk on the node (no pod required)
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl get --raw "/api/v1/nodes/$NODE/proxy/stats/summary" \
  | jq '{capacity: .node.fs.capacityBytes, used: .node.fs.usedBytes, avail: .node.fs.availableBytes}'

# Architecture of the target (decides image platforms)
kubectl get nodes -o wide   # check OS-IMAGE / kernel for aarch64

# Is the Traefik websecure entrypoint actually serving TLS?
kubectl get deploy -n kube-system traefik \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep -iE 'acme|tls|cert'
```

### Sizing against a single node

```bash
# Sum of requests the chart will ask for, vs. what is free
kubectl describe node | grep -A8 'Allocated resources'
```

Rules:

1. **Requests must fit in `allocatable - already requested`.** Do not size for "a real
   cluster"; size for this one. Overcommitted requests = pods stuck `Pending`, and with a
   single node there is nowhere to schedule them.
2. **`local-path` ignores the PVC size.** If the sum of PVCs exceeds free disk, the chart
   will fill the node and take down Postgres with it. Prefer externalizing object storage.
3. **Single node means `replicaCount: 1`** for stateful components, and a `RollingUpdate`
   with `maxUnavailable: 0` will deadlock on a `ReadWriteOnce` volume: the new pod cannot
   mount the PVC until the old one releases it.

## Production Gate — the checks that `helm lint` cannot do

`helm lint` passing means "the templates parse". It says nothing about whether the release
will run. Before declaring a chart production-ready, every item below must be answered.

| # | Gate | How to check | Why it bites |
|---|---|---|---|
| 1 | **Image tags exist** in the registry | `docker manifest inspect <repo>:<tag>` for every referenced image | `ImagePullBackOff` with a chart that lints perfectly |
| 2 | **Image platforms cover the node arch** | `docker manifest inspect <repo>:<tag>` → look for `arm64` | `exec format error` on an aarch64 node |
| 3 | **Ingress controller matches annotations** | `kubectl get ingressclass` | nginx `rewrite-target` on Traefik → 404 on every path |
| 4 | **TLS terminates somewhere real, and only once** | Edge proxy owns the cert (chart HTTP-only), **or** cert-manager/Secret in-cluster | Enabling `tls:` when the edge already terminates TLS serves a self-signed cert on an entrypoint the proxy cannot reach; enabling nothing when the cluster is the edge breaks `Secure` cookies |
| 5 | **Every `secretKeyRef` is satisfiable** | `existingSecret` has **all** keys, or `optional: true` | One missing key = `CreateContainerConfigError`, pod never starts |
| 6 | **Public endpoints are browser-reachable** | presign/CDN host is a public DNS name, not a Service DNS name | Signed URLs point at `http://svc:9000`, unreachable from a browser |
| 7 | **Wildcard DNS exists when tenancy uses subdomains** | `dig +short A '<slug>.<base>'` | No wildcard = no tenant can log in |
| 8 | **Requests and PVCs fit the node** | `kubectl describe node` + `stats/summary` | `Pending` pods, or a full disk |
| 9 | **Build-time config is baked correctly** | env vars consumed by `vite`/`next` at build are set **before** the image is built | Wrong domain baked in; **only fixable by rebuilding** |
| 10 | **Credentials/digests are reproducible** | registry tag from a release pipeline, not `latest` | Rollback is impossible and `helm rollback` restores nothing |
| 11 | **StatefulSets are not fighting a RWO volume** | `strategy`/`updateStrategy` vs `ReadWriteOnce` | Rollout deadlock on a single node |
| 12 | **Migrations run once, not per replica** | initContainer on a multi-replica Deployment without a lock | Concurrent schema changes corrupt the migration journal |
| 13 | **Operational jobs exist** | admin bootstrap, bucket init, DB backup | Chart installs but the product is unusable/unrecoverable |

Prefer a **chart-owned `values.schema.json`** plus a CI job running `helm lint`,
`helm template` and `kubectl apply --dry-run=server` so these regressions are caught
before the cluster.

### `values.schema.json` — fail fast on typos

A misspelled key in `values.yaml` is silently ignored by Helm. A schema turns it into a
hard error:

```json
{
  "$schema": "https://json-schema.org/draft-07/schema#",
  "type": "object",
  "required": ["image", "ingress"],
  "properties": {
    "image": {
      "type": "object",
      "required": ["tag"],
      "properties": { "tag": { "type": "string", "minLength": 1 } }
    },
    "ingress": {
      "type": "object",
      "properties": {
        "entryPoint": { "type": "string", "enum": ["web"] },
        "hosts": { "type": "array", "minItems": 1, "items": { "type": "string" } }
      }
    }
  }
}
```

Validate with `helm lint --strict` and `helm template ... > /dev/null` in CI.

## Helm Overview

**Helm** is the package manager for Kubernetes that:

- Templates Kubernetes manifests for reusability
- Manages application releases and rollbacks
- Handles dependencies between charts
- Provides version control for deployments
- Simplifies configuration management across environments

## Step-by-Step Workflow

### 1. Initialize Chart Structure

**Create new chart:**

```bash
helm create my-app
```

**Standard chart structure:**

```
my-app/
├── Chart.yaml           # Chart metadata
├── values.yaml          # Default configuration values
├── charts/              # Chart dependencies
├── templates/           # Kubernetes manifest templates
│   ├── NOTES.txt       # Post-install notes
│   ├── _helpers.tpl    # Template helpers
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   ├── serviceaccount.yaml
│   ├── hpa.yaml
│   └── tests/
│       └── test-connection.yaml
└── .helmignore         # Files to ignore
```

### 2. Configure Chart.yaml

**Chart metadata defines the package:**

```yaml
apiVersion: v2
name: my-app
description: A Helm chart for My Application
type: application
version: 1.0.0 # Chart version
appVersion: "2.1.0" # Application version

# Keywords for chart discovery
keywords:
  - web
  - api
  - backend

# Maintainer information
maintainers:
  - name: DevOps Team
    email: devops@example.com
    url: https://github.com/example/my-app

# Source code repository
sources:
  - https://github.com/example/my-app

# Homepage
home: https://example.com

# Chart icon
icon: https://example.com/icon.png

# Dependencies
dependencies:
  - name: postgresql
    version: "12.0.0"
    repository: "https://charts.bitnami.com/bitnami"
    condition: postgresql.enabled
  - name: redis
    version: "17.0.0"
    repository: "https://charts.bitnami.com/bitnami"
    condition: redis.enabled
```

**Reference:** See `assets/Chart.yaml.template` for complete example

### 3. Design values.yaml Structure

**Organize values hierarchically:**

```yaml
# Image configuration
image:
  repository: myapp
  tag: "1.0.0"
  pullPolicy: IfNotPresent

# Number of replicas
replicaCount: 3

# Service configuration
service:
  type: ClusterIP
  port: 80
  targetPort: 8080

# Ingress configuration — Traefik only (never ingress-nginx)
ingress:
  enabled: false
  entryPoint: web          # HTTP; the edge proxy terminates TLS
  hosts:
    - app.example.com
    - "*.app.example.com"  # wildcard when tenancy is per-subdomain
  tls: null                # never enable TLS in the cluster with an edge proxy

# Resources
resources:
  requests:
    memory: "256Mi"
    cpu: "250m"
  limits:
    memory: "512Mi"
    cpu: "500m"

# Autoscaling
autoscaling:
  enabled: false
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 80

# Environment variables
env:
  - name: LOG_LEVEL
    value: "info"

# ConfigMap data
configMap:
  data:
    APP_MODE: production

# Dependencies
postgresql:
  enabled: true
  auth:
    database: myapp
    username: myapp

redis:
  enabled: false
```

**Reference:** See `assets/values.yaml.template` for complete structure

### 4. Create Template Files

**Use Go templating with Helm functions:**

**templates/deployment.yaml:**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "my-app.fullname" . }}
  labels:
    {{- include "my-app.labels" . | nindent 4 }}
spec:
  {{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicaCount }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "my-app.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "my-app.selectorLabels" . | nindent 8 }}
    spec:
      containers:
      - name: {{ .Chart.Name }}
        image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        ports:
        - name: http
          containerPort: {{ .Values.service.targetPort }}
        resources:
          {{- toYaml .Values.resources | nindent 12 }}
        env:
          {{- toYaml .Values.env | nindent 12 }}
```

### 5. Create Template Helpers

**templates/\_helpers.tpl:**

```yaml
{{/*
Expand the name of the chart.
*/}}
{{- define "my-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "my-app.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "my-app.labels" -}}
helm.sh/chart: {{ include "my-app.chart" . }}
{{ include "my-app.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "my-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "my-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
```

### 6. Manage Dependencies

**Add dependencies in Chart.yaml:**

```yaml
dependencies:
  - name: postgresql
    version: "12.0.0"
    repository: "https://charts.bitnami.com/bitnami"
    condition: postgresql.enabled
```

**Update dependencies:**

```bash
helm dependency update
helm dependency build
```

**Override dependency values:**

```yaml
# values.yaml
postgresql:
  enabled: true
  auth:
    database: myapp
    username: myapp
    password: changeme
  primary:
    persistence:
      enabled: true
      size: 10Gi
```

### 7. Test and Validate

**Validation commands:**

```bash
# Lint the chart
helm lint my-app/

# Dry-run installation
helm install my-app ./my-app --dry-run --debug

# Template rendering
helm template my-app ./my-app

# Template with values
helm template my-app ./my-app -f values-prod.yaml

# Show computed values
helm show values ./my-app
```

**Validation script:**

```bash
#!/bin/bash
set -e

echo "Linting chart..."
helm lint .

echo "Testing template rendering..."
helm template test-release . --dry-run

echo "Checking for required values..."
helm template test-release . --validate

echo "All validations passed!"
```

**Reference:** See `scripts/validate-chart.sh`

### 8. Package and Distribute

**Package the chart:**

```bash
helm package my-app/
# Creates: my-app-1.0.0.tgz
```

**Create chart repository:**

```bash
# Create index
helm repo index .

# Upload to repository
# AWS S3 example
aws s3 sync . s3://my-helm-charts/ --exclude "*" --include "*.tgz" --include "index.yaml"
```

**Use the chart:**

```bash
helm repo add my-repo https://charts.example.com
helm repo update
helm install my-app my-repo/my-app
```

### 9. Multi-Environment Configuration

**Environment-specific values files:**

```
my-app/
├── values.yaml          # Defaults
├── values-dev.yaml      # Development
├── values-staging.yaml  # Staging
└── values-prod.yaml     # Production
```

**values-prod.yaml:**

```yaml
replicaCount: 5

image:
  tag: "2.1.0"

resources:
  requests:
    memory: "512Mi"
    cpu: "500m"
  limits:
    memory: "1Gi"
    cpu: "1000m"

autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 20

ingress:
  enabled: true
  hosts:
    - host: app.example.com
      paths:
        - path: /
          pathType: Prefix

postgresql:
  enabled: true
  primary:
    persistence:
      size: 100Gi
```

**Install with environment:**

```bash
helm install my-app ./my-app -f values-prod.yaml --namespace production
```

### 10. Implement Hooks and Tests — and know when NOT to use a hook

> **`pre-install` runs BEFORE the release resources exist.** A `pre-install` Job that
> connects to a database shipped by the same chart **can never work on the first install**:
> the Postgres StatefulSet, its Service and its PVC do not exist yet. This is exactly the
> bug that had to be fixed in `crm-whats`: the migrations Job was moved from a
> `pre-install` hook to a **plain (non-hook) `Job`** / **initContainer**, which Helm only
> creates as part of the release and which can retry until the dependency is up.

**Use a hook only when ordering relative to the release lifecycle genuinely matters:**

| Goal | Correct primitive |
|---|---|
| Run schema migrations before the app starts | **initContainer** on the app, or a plain `Job` with a retry loop |
| Create a bucket/admin/tenant once the DB is up | **plain `Job`**, or `post-install` hook **with** a wait loop |
| Prune something before deleting the release | `pre-delete` hook |
| Smoke-test the installed release | `test` hook |

**Never** put a "wait for dependency" step in a `pre-install` hook for a dependency the
chart itself creates.

**Plain Job that waits for its dependency (correct pattern):**

```yaml
# templates/migrate-job.yaml — NO hook: created with the release, retries until DB is up
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ include "my-app.fullname" . }}-migrate
  annotations:
    "helm.sh/hook-delete-policy": before-hook-creation
spec:
  backoffLimit: 6
  template:
    spec:
      restartPolicy: Never
      initContainers:
        - name: wait-for-db
          image: postgres:16
          command: ['/bin/sh', '-c']
          args:
            - |
              set -eu
              until pg_isready -h {{ include "my-app.fullname" . }}-postgres -p 5432; do
                echo "aguardando postgres..."; sleep 5
              done
      containers:
        - name: migrate
          image: "{{ .Values.image.migrations.repository }}:{{ .Values.image.tag }}"
          envFrom:
            - secretRef:
                name: {{ .Values.secrets.existingSecret }}
```

Caveats that follow from this pattern:

- A plain `Job` is **not** re-run by `helm upgrade`. Give the name a checksum annotation
  (`checksum/config: {{ include ... | sha256sum }}`) or bump a `migrations.revision` value,
  otherwise later schema changes never apply.
- A Job in an initContainer-style role on a **multi-replica Deployment** runs once per
  replica. Use a single-replica Deployment, a Job, or make the migration idempotent **and**
  serialized (advisory lock). Drizzle 0.45's migrator uses a transaction but **no advisory
  lock**.
- `helm.sh/hook-delete-policy: before-hook-creation` avoids `Job already exists` on retries.

**Test connection:**

```yaml
# templates/tests/test-connection.yaml
apiVersion: v1
kind: Pod
metadata:
  name: "{{ include "my-app.fullname" . }}-test-connection"
  annotations:
    "helm.sh/hook": test
spec:
  containers:
  - name: wget
    image: busybox
    command: ['wget']
    args: ['{{ include "my-app.fullname" . }}:{{ .Values.service.port }}']
  restartPolicy: Never
```

**Run tests:**

```bash
helm test my-app
```

## Ingress: **always Traefik** — never ingress-nginx

**Hard rule for this environment: charts are Traefik-only.** The clusters run Traefik
(k3s ships it by default), there is no ingress-nginx and adding one is out of scope.
Do not scaffold `ingressClassName: nginx`, do not emit `nginx.ingress.kubernetes.io/*`
annotations, and do not make the controller a `traefik | nginx` switch — a chart with an
nginx path invites someone to use it and then silently 404s everything.

If you find an nginx-based chart, migrating it to Traefik is the default action. Keep the
nginx comparison table below only as a **migration reference** (what each old annotation
used to mean), never as an option to implement.

### TLS topology: edge vs in-cluster

Decide **where TLS terminates** before writing the Ingress. Getting this backwards is a
common and confusing failure.

| Topology | Who owns the cert | Chart must | Chart must NOT |
|---|---|---|---|
| **Edge proxy / LB / CDN** (external, reaches the cluster over HTTP) | The proxy — Let's Encrypt, ACME, corporate CA | Route on the **HTTP** entrypoint; trust `X-Forwarded-*` | Configure `tls:`, cert-manager, ACME, or `websecure` |
| **In-cluster** (cert-manager, or a manually managed Secret) | The cluster | `tls.secretName` on the `IngressRoute` + `websecure` | Assume a cert exists without a `Certificate`/Secret |
| **Both (edge terminates, cluster re-encrypts)** | Two certs | `websecure` + an internal cert; the backend speaks HTTPS | Leave the hop plaintext if the network is untrusted |

**Rule:** if a proxy outside the cluster terminates TLS, the chart is HTTP-only. Adding
`tls:` there makes Traefik serve its self-signed default cert on `websecure`, which the
proxy cannot even reach — the symptom is a certificate error at the edge or a dead route,
not an obvious "TLS misconfigured".

When TLS is external, the app behind it still needs:

- `trustProxy` enabled, so `request.ip` and rate limiting see the real client instead of all
  traffic collapsing into the proxy's IP.
- `X-Forwarded-Proto`, `X-Forwarded-Host`, `X-Forwarded-For` forwarded by the proxy.
  Without `X-Forwarded-Proto: https`, `Secure` cookies are dropped and absolute URLs come out
  as `http://`.
- The original `Host` header preserved — mandatory when tenants are resolved by subdomain or
  the app validates the host.
- HSTS emitted by the app (it is correct even when TLS is at the edge: the browser sees
  HTTPS).

```yaml
# values.yaml — Traefik + edge TLS
ingress:
  enabled: true
  entryPoint: web            # HTTP only; the edge proxy terminates TLS
  hosts: ["app.example.com", "*.app.example.com"]
  tls: null                  # never enable TLS in the cluster in this topology
```

Add a guard in the template so the decision cannot be reversed by accident:

```yaml
{{- if or .Values.ingress.tls .Values.ingress.className }}
{{- fail "ingress não suporta className/tls: o chart é Traefik-only e o TLS termina no proxy externo." }}
{{- end }}
{{- if ne (default "web" .Values.ingress.entryPoint) "web" }}
{{- fail "entrypoint deve ser `web`: o proxy externo fala HTTP com o cluster." }}
{{- end }}
```

### Traefik: the routing primitives

| Need | Traefik answer |
|---|---|
| Strip a path prefix (`/api/*` → `/v1/*`) | `Middleware` `stripPrefix` |
| Prefix match | `PathPrefix('/api')` (note: also matches `/apifoo`; use `PathRegexp('^/api(/|$)')` if the app has a root route) |
| Host match | `Host(\`app.example.com\`)` — **exact string compare, no wildcard**. For subdomains use `HostRegexp(\`^[^.]+\\.example\\.com$\`)`, which is a real regex (`regexp.Compile`): escape dots and anchor the pattern |
| WebSocket | Native on HTTP routers — nothing to configure |
| Body size / timeouts | `Middleware`/`serversTransport`, not annotations |

### Three traps that no gate catches

1. **`Host()` is NOT a wildcard matcher.** `Host(\`*.example.com\`)` matches only a host
   *literally* named `*.example.com` — Traefik compares strings (`matcher.go: host()`,
   `reqHost == host`). For subdomain tenancy use `HostRegexp` and translate the wildcard:
   `*.example.com` → `^[^.]+\.example\.com$`. Idiom:
   ```
   {{- if contains "*" $host }}
   {{- $pattern := $host | replace "." "\\." | replace "*" "[^.]+" }}
   HostRegexp(`^%s$`)
   {{- else }}
   Host(`$host`)
   {{- end }}
   ```
   `HostRegexp` compiles the argument with `regexp.Compile`, so dots MUST be escaped and
   the pattern anchored (`^...$`), otherwise `example.com` also matches
   `example.com.evil.test`. The apex is not covered by the wildcard — list both hosts.
2. **`&&` binds tighter than `||`.** `Host(a) || Host(b) && PathPrefix(/x)` matches
   `Host(a)` on **every** path — the apex swallows the whole app and the API is never
   reached. **Always parenthesize the host group:**
   `(Host(a) || Host(b)) && PathPrefix(...)`.
   `helm lint`, `helm template` and `kubectl apply --dry-run=server` all pass with the
   semantically wrong rule: they validate syntax, not meaning.
3. **Route priority is not declaration order.** Each `route` becomes its own router; the
   winner is the highest `priority`, whose default is the **length of the rule text**
   (`GetRulePriority` in `pkg/muxer/http/mux.go`, sorted descending with a **non-stable**
   sort, so ties are undefined). Put the catch-all and the specific routes in **separate
   `IngressRoute` resources**; when a specific host must beat a broader catch-all (e.g. a
   storage host that a tenant wildcard also matches), set an **explicit `priority`** and
   document that it only has to exceed the catch-all's rule length.

### Reference templates

```yaml
# templates/traefik-middleware.yaml
{{- if .Values.ingress.enabled }}
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: {{ include "my-app.fullname" . }}-strip-api
spec:
  stripPrefix:
    prefixes: ["/api"]
{{- end }}
```

```yaml
# templates/ingress.yaml — IngressRoutes (Traefik only)
{{- if .Values.ingress.enabled }}
{{- $hosts := list }}
{{- range .Values.ingress.hosts }}
{{- $hosts = append $hosts (printf "Host(`%s`)" .) }}
{{- end }}
{{- /* Parentheses are mandatory: `&&` binds tighter than `||`. */ -}}
{{- $hostGroup := printf "(%s)" (join " || " $hosts) }}
{{- $ep := default "web" .Values.ingress.entryPoint }}
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: {{ include "my-app.fullname" . }}-api
spec:
  entryPoints: [{{ $ep | quote }}]
  routes:
    - kind: Rule
      match: {{ printf "%s && PathPrefix(`/api`)" $hostGroup | quote }}
      middlewares:
        - name: {{ include "my-app.fullname" . }}-strip-api
      services:
        - name: {{ include "my-app.fullname" . }}-api
          port: {{ .Values.service.api.port }}
    - kind: Rule
      match: {{ printf "%s && (PathPrefix(`/ws`) || PathPrefix(`/webhooks`))" $hostGroup | quote }}
      services:
        - name: {{ include "my-app.fullname" . }}-api
          port: {{ .Values.service.api.port }}
---
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: {{ include "my-app.fullname" . }}-web
spec:
  entryPoints: [{{ $ep | quote }}]
  routes:
    - kind: Rule
      match: {{ $hostGroup | quote }}
      services:
        - name: {{ include "my-app.fullname" . }}-web
          port: {{ .Values.service.web.port }}
{{- end }}
```

Keep health/metrics endpoints (`/healthz`, `/readyz`, `/metrics`) **out** of the public
routes. With a catch-all they fall through to the frontend and return its responses —
noisy and confusing, though not a leak to the API. Add an explicit route/Middleware if you
need a real 404.

### Migration reference: what the nginx annotations meant

| nginx | Traefik equivalent |
|---|---|
| `ingressClassName: nginx` | `traefik`, plus `entryPoints` on the `IngressRoute` |
| `rewrite-target: /$2` + regex path | `Middleware` `stripPrefix` |
| `proxy-body-size` | `Middleware` `buffering` / `serversTransport` |
| `proxy-read-timeout` / `proxy-send-timeout` | `serversTransport` or entrypoint config |
| Any `nginx.*` annotation | **Silently ignored by Traefik** — no warning, no error |


## Secrets: every `secretKeyRef` is a startup dependency

A `secretKeyRef` without `optional: true` makes the **pod unschedulable-adjacent**:
`CreateContainerConfigError` until the key exists. A single missing optional key (an AI API
key for a deployment that has AI disabled, an SMTP password) takes the whole app down.

```yaml
# Required: fail loudly, this is genuinely mandatory
- name: DATABASE_URL
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.existingSecret }}
      key: DATABASE_URL

# Optional feature: must not block startup
- name: AI_API_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.secrets.existingSecret }}
      key: AI_API_KEY
      optional: true
```

Additional rules:

- **Generate the Secret out-of-band** (Sealed Secrets, External Secrets, SOPS) and point
  `secrets.existingSecret` at it. Loading real values through `values.yaml` puts secrets in
  git and in `helm get values`.
- **Secret key names must match the `<secretKeyRef>`s exactly.** Document the required key
  list in `README.md`; drift here is the most common first-install failure.
- **Service DNS names depend on the release name.** `include "chart.fullname"` changes with
  `--generate-name` / a different release name, so DSNs hardcoded in a Secret silently point
  at a non-existent host. Either document "the Secret must be built for release X" or
  resolve hosts from the ConfigMap and keep only credentials in the Secret.
- **Never put credentials in ConfigMap.** ConfigMap is for non-secret env only.

## Stateful workloads on a single node

- `ReadWriteOnce` + `maxUnavailable: 0` (or a `RollingUpdate` StatefulSet) **deadlocks** on
  a single node: the replacement pod cannot attach the volume while the old pod holds it.
  For StatefulSets use the default `OnDelete`/`RollingUpdate` ordering and accept a brief
  outage, or use `Recreate` on Deployments with PVCs.
- **`local-path` does not enforce `requests.storage`.** Treat the PVC size as documentation.
  Sum all PVCs against real free disk before installing; prefer managed object storage for
  anything unbounded.
- **Postgres/Redis init SQL runs once, on an empty volume only.** Changing `initSql` later
  has no effect. Roles created there with hardcoded passwords must stay in sync with the
  Secret, or the app cannot log in.


## Common Patterns

### Pattern 1: Conditional Resources

```yaml
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: {{ include "my-app.fullname" . }}
spec:
  # ...
{{- end }}
```

### Pattern 2: Iterating Over Lists

```yaml
env:
{{- range .Values.env }}
- name: {{ .name }}
  value: {{ .value | quote }}
{{- end }}
```

### Pattern 3: Including Files

```yaml
data:
  config.yaml: |
    {{- .Files.Get "config/application.yaml" | nindent 4 }}
```

### Pattern 4: Global Values

```yaml
global:
  imageRegistry: docker.io
  imagePullSecrets:
    - name: regcred

# Use in templates:
image: {{ .Values.global.imageRegistry }}/{{ .Values.image.repository }}
```

## Images: architecture, tags and build-time config

### Match the node architecture

The reference cluster is **aarch64**. A multi-arch build is not a nice-to-have:

```bash
# Confirm what your build produced
docker manifest inspect ghcr.io/org/app:1.2.3 \
  | jq -r '.manifests[].platform | "\(.os)/\(.architecture)"'
# must include linux/arm64
```

```yaml
# CI build (GitHub Actions / buildx)
- uses: docker/build-push-action@v6
  with:
    platforms: linux/amd64,linux/arm64
```

A single-arch amd64 image on an arm64 node fails at container start with
`exec format error` — **not** at pull time, so it looks like a crash-loop.

### Verify that every referenced tag exists

```bash
# One check per image referenced by values.yaml — do this before helm install
for img in $(helm template r . -f values-prod.yaml \
  | grep -oE 'image: [^ ]+' | awk '{print $2}' | sort -u); do
  docker manifest inspect "$img" >/dev/null 2>&1 \
    && echo "OK       $img" || echo "MISSING  $img"
done
```

### Build-time (baked) configuration

If the frontend reads a variable at **build** time (`VITE_*`, `NEXT_PUBLIC_*`,
`REACT_APP_*`), it lives **inside the image layer**. Setting it in the ConfigMap at runtime
changes nothing.

Consequences:

1. The CI variable/env must be set **before** the release is tagged.
2. Changing the domain later requires **rebuilding and republishing the image**, not just
   `helm upgrade`.
3. Verify by rendering the image's built output, not by reading `values.yaml`.

```yaml
# Build args must be wired in the workflow, with a real default that is not "localhost"
build-args: |
  VITE_APP_BASE_DOMAIN=${{ vars.APP_BASE_DOMAIN }}
```

A `|| 'localhost'` fallback in CI is a silent trap: the pipeline stays green and the
production bundle is unusable.

## Best Practices

1. **Use semantic versioning** for chart and app versions
2. **Document all values** in values.yaml with comments
3. **Use template helpers** for repeated logic
4. **Validate charts** before packaging
5. **Pin dependency versions** explicitly
6. **Use conditions** for optional resources
7. **Follow naming conventions** (lowercase, hyphens)
8. **Include NOTES.txt** with usage instructions
9. **Add labels** consistently using helpers
10. **Test installations** in all environments
11. **Inspect the target cluster before writing templates** — controller, arch, storage class, free resources
12. **Treat `helm lint` as a syntax check only**; run the Production Gate before go-live
13. **Never use a `pre-install` hook for something the chart itself creates**
14. **Make the Ingress controller an explicit value** and support the one that actually exists
15. **Mark optional secret keys `optional: true`**
16. **Size requests and PVCs against `kubectl describe node`, not against a hypothetical cluster**

## Anti-patterns seen in production charts

Real defects found while auditing `crm-whats`; each one lints clean.

| Anti-pattern | Symptom | Fix |
|---|---|---|
| `pre-install` Job that needs the chart's own Postgres | First install hangs forever | Plain `Job` / initContainer with wait-and-retry |
| nginx annotations on a Traefik cluster | Every `/api` path 404s | `Middleware stripPrefix` + `IngressRoute`, or `ingress.controller` value |
| `Host(\`*.example.com\`)` for subdomain tenancy | `Host` compares strings; the wildcard never matches a real tenant, so **no tenant can open** | `HostRegexp` with the wildcard translated to `^[^.]+\.example\.com$` |
| Presigned S3 URL behind a path prefix (`/storage` + `stripPrefix`) | `403 SignatureDoesNotMatch` — SigV4 signs the full path, so stripping it invalidates the signature | Dedicated host (no prefix), or rename the bucket to match the prefix and skip stripping |
| `tls:` enabled when an external proxy already terminates TLS | Traefik serves its self-signed cert on `websecure`; the edge cannot reach it | Chart is HTTP-only; route on the `web` entrypoint |
| Proxy not sending `X-Forwarded-Proto` | `Secure` cookies dropped, absolute URLs in `http://`, rate limit sees one IP | Forward `X-Forwarded-Proto/Host/For`; enable `trustProxy` |
| Proxy rewriting `Host` | Subdomain tenancy fails, host guards reject | Preserve the original `Host` header |
| `S3_PUBLIC_ENDPOINT: ""` with presigned URLs | Signed URL points at `http://svc:9000`; browser upload fails | Set a public host and sign with it (a second S3 client — SigV4 signs the `Host`) |
| Helper computed but never used | Dead code; the value silently stays empty | Wire the helper into the template or delete it |
| `secretKeyRef` without `optional: true` | `CreateContainerConfigError` when one optional key is absent | `optional: true` for feature flags |
| Requests summing above node allocatable | Pods stuck `Pending`, nowhere to schedule on 1 node | Re-measure and shrink |
| PVCs summing above free disk on `local-path` | Node disk fills, Postgres crashes | Size to reality or externalize storage |
| `maxUnavailable: 0` + RWO PVC on 1 node | Rollout deadlock | `Recreate` or accept downtime |
| Migrations as initContainer with >1 api replica | Concurrent migrations, no advisory lock | Single replica, or a Job with a lock |
| `/metrics`, `/healthz` published on the public Ingress | Internal metrics/logs exposed | Keep them cluster-internal |
| `VITE_*` set only in ConfigMap | Production bundle still points at `localhost` | Set at build time, rebuild to change |
| No `values.schema.json` and no CI lint | Typos in values ship silently | Schema + `helm lint`/`template`/`dry-run` job |

## Troubleshooting

**Template rendering errors:**

```bash
helm template my-app ./my-app --debug
```

**Dependency issues:**

```bash
helm dependency update
helm dependency list
```

**Installation failures:**

```bash
helm install my-app ./my-app --dry-run --debug
kubectl get events --sort-by='.lastTimestamp'
```

**Release passes `helm lint` but pods do not start — diagnose in this order:**

```bash
kubectl -n <ns> get pods                                  # status tells you the layer
kubectl -n <ns> describe pod <pod> | sed -n '/Events/,$p' # scheduling / image / config
kubectl -n <ns> logs <pod> --previous                     # app-level crash
kubectl -n <ns> get events --sort-by='.lastTimestamp'     # what changed
```

| Pod status | Likely cause |
|---|---|
| `Pending` | Requests above allocatable, or PVC unbound (`local-path` waits for a consumer, then fails on disk) |
| `ImagePullBackOff` / `ErrImagePull` | Tag does not exist, or missing `imagePullSecrets` |
| `exec format error` (CrashLoopBackOff) | Image has no `linux/arm64` |
| `CreateContainerConfigError` | Missing Secret/ConfigMap key → `optional: true` or create the key |
| `CrashLoopBackOff` | App-side config validation (`NODE_ENV=production` without a required secret), not the chart |
| Ready but 404 on every path | Ingress controller/annotation mismatch |
| Ready but login fails | TLS missing (`secure` cookie), or build-time domain wrong in the image |



## Related Skills

- `k8s-manifest-generator` - For creating base Kubernetes manifests
- `gitops-workflow` - For automated Helm chart deployments
