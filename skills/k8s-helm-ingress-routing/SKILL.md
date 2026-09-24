---
name: k8s-helm-ingress-routing
description: Configure Helm charts for Kubernetes services exposed through Ingress controllers. For Traefik, prefer IngressRoute + Middleware first; cover host/path routing, TLS, rewrites, and keeping duplicated charts in sync.
---

# K8s Helm Ingress Routing

Use this skill when a repo needs Kubernetes exposure through Helm and an Ingress controller, especially for host/path routing, HTTPS, rewrites, and chart synchronization across environments.

## Workflow

1. Identify the controller and exposure model.
2. For Traefik, prefer `IngressRoute` + `Middleware` first.
3. Use plain `Ingress` annotations only when the repo already follows that pattern or the controller lacks the needed CRDs.
4. Keep app handlers stable when possible; prefer proxy rewrite/strip-prefix over changing backend paths.
5. Model ingress behavior explicitly in `values.yaml` and `values-prod.yaml`:
   - `ingress.enabled`
   - `ingress.className`
   - `ingress.entrypoints` or controller equivalent
   - `ingress.host`
   - `ingress.path`
   - `ingress.pathType`
   - `ingress.tls`
   - rewrite/middleware settings when needed
6. Keep local and deploy charts synchronized when both exist.
7. Keep `NOTES.txt` and docs aligned with the real public URL.
8. Validate with `helm template` and `helm lint` before returning changes.

## Controller rules

### Traefik

- Prefer `IngressRoute` + `Middleware` before annotation-based `Ingress`.
- Use `router.entrypoints`, `router.tls`, and `router.middlewares` only when the chart already relies on Traefik Ingress annotations.
- For `router.middlewares`, use the reference format required by the active Traefik provider and cluster CRDs.
- Add a `Middleware` resource when a public prefix must be rewritten before reaching the app.
- Prefer `websecure` for HTTPS-facing routes when Traefik is terminating TLS.

### NGINX

- Use ingress annotations only when the chart already follows the NGINX pattern.
- If path rewriting is required, prefer the controller-supported rewrite annotation pattern already used in the repo.
- Keep the path matcher and rewrite behavior consistent with the backend expectation.

### Gateway API

- Use `HTTPRoute`, `ReferenceGrant`, and `filters` only when the repo already uses Gateway API.
- Keep routing objects and backend service ports aligned with the existing service contract.

## Failure modes to check

- Ingress path matches the URL but the backend still expects a different internal path.
- TLS is enabled in values but the controller is still bound to a non-TLS entrypoint.
- Middleware/rewrite resource exists in Kubernetes but the controller cannot resolve it.
- Local chart and deploy chart diverge.
- Prod values still point to an old host or path.

## Defaults

- Prefer host-based routing plus `PathPrefix` for mounted subpaths.
- Prefer proxy rewrite over changing backend code.
- Prefer chart-level configuration over hardcoded hosts and paths.
