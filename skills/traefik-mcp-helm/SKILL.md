---
name: traefik-mcp-helm
description: Configure Helm charts for Go MCP services behind Traefik. Prefer Traefik IngressRoute + Middleware for /mcp/<sub-path> routing, and fall back to Ingress annotations only when the repo or cluster already standardizes on them.
---

# Traefik MCP Helm

Use this skill first when a repo exposes MCP HTTP services through Helm and Traefik, especially when the public URL must look like `/mcp/<sub-pasta>` or when an ingress/middleware error appears after deployment.

## Workflow

1. Prefer Traefik `IngressRoute` + `Middleware` first.
2. Fall back to plain `Ingress` only if the repo already standardizes on it or the cluster cannot use Traefik CRDs.
3. Keep the app HTTP handler stable when possible; prefer proxy rewrite over changing the Go server path contract.
4. Expose the public route as `http[s]://<host>/mcp/<sub-pasta>` and rewrite it internally to `/mcp` unless the user explicitly wants the app changed.
5. Model routing values explicitly in `values.yaml`:
   - `ingress.enabled`
   - `ingress.className`
   - `ingress.entrypoints`
   - `ingress.host`
   - `ingress.path`
   - `ingress.rewriteTarget`
6. For Traefik annotations or CRDs, reference middleware using the namespace-qualified name pattern required by the cluster.
7. Use `traefik.io/v1alpha1` when the cluster exposes the newer CRDs; switch only if the cluster's installed CRDs prove otherwise.
8. Validate the chart with `helm template` and `helm lint` before returning changes.

## Implementation notes

- Prefer `PathPrefix` for subpath routing unless the user needs exact matching.
- For IngressRoute, keep `entryPoints`, `Host(...)`, and `PathPrefix(...)` together in the route.
- Keep the backend service port and readiness/liveness probes unchanged unless the app contract also changes.
- If a repo has duplicate charts for deploy vs. local templates, keep them in sync.

## Failure modes to check

- IngressRoute references a middleware that Traefik cannot resolve.
- Middleware CRD apiVersion does not match the installed Traefik CRDs.
- Public path matches the route but the backend still expects the internal `/mcp` path.
- `NOTES.txt` or prod values still point to the old URL.
