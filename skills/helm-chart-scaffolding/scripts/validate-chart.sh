#!/bin/bash
# Valida um chart Helm para além do `helm lint` (que só verifica sintaxe de template).
#
# Uso:
#   ./validate-chart.sh [CHART_DIR] [VALUES_FILE]
#   STRICT=1 ./validate-chart.sh ./minha-chart values-prod.yaml   # falha também no Production Gate
#   SKIP_CLUSTER=1 ./validate-chart.sh                            # sem cluster acessível
#
# Checks de cluster (12+, Production Gate) exigem `kubectl` apontando para o alvo.
set -e

CHART_DIR="${1:-.}"
VALUES_FILE="${2:-}"
RELEASE_NAME="${RELEASE_NAME:-test-release}"
NAMESPACE="${NAMESPACE:-default}"
STRICT="${STRICT:-0}"
SKIP_CLUSTER="${SKIP_CLUSTER:-0}"

TEMPLATE_ARGS=()
if [ -n "$VALUES_FILE" ] && [ -f "$VALUES_FILE" ]; then
    TEMPLATE_ARGS+=("-f" "$VALUES_FILE")
fi

echo "═══════════════════════════════════════════════════════"
echo "  Helm Chart Validation"
echo "═══════════════════════════════════════════════════════"
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

success() {
    echo -e "${GREEN}✓${NC} $1"
}

warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

error() {
    echo -e "${RED}✗${NC} $1"
}

# Check if Helm is installed
if ! command -v helm &> /dev/null; then
    error "Helm is not installed"
    exit 1
fi

echo "📦 Chart directory: $CHART_DIR"
echo ""

# 1. Check chart structure
echo "1️⃣  Checking chart structure..."
if [ ! -f "$CHART_DIR/Chart.yaml" ]; then
    error "Chart.yaml not found"
    exit 1
fi
success "Chart.yaml exists"

if [ ! -f "$CHART_DIR/values.yaml" ]; then
    error "values.yaml not found"
    exit 1
fi
success "values.yaml exists"

if [ ! -d "$CHART_DIR/templates" ]; then
    error "templates/ directory not found"
    exit 1
fi
success "templates/ directory exists"
echo ""

# 2. Lint the chart
echo "2️⃣  Linting chart..."
if helm lint "$CHART_DIR"; then
    success "Chart passed lint"
else
    error "Chart failed lint"
    exit 1
fi
echo ""

# 3. Check Chart.yaml
echo "3️⃣  Validating Chart.yaml..."
CHART_NAME=$(grep "^name:" "$CHART_DIR/Chart.yaml" | awk '{print $2}')
CHART_VERSION=$(grep "^version:" "$CHART_DIR/Chart.yaml" | awk '{print $2}')
APP_VERSION=$(grep "^appVersion:" "$CHART_DIR/Chart.yaml" | awk '{print $2}' | tr -d '"')

if [ -z "$CHART_NAME" ]; then
    error "Chart name not found"
    exit 1
fi
success "Chart name: $CHART_NAME"

if [ -z "$CHART_VERSION" ]; then
    error "Chart version not found"
    exit 1
fi
success "Chart version: $CHART_VERSION"

if [ -z "$APP_VERSION" ]; then
    warning "App version not specified"
else
    success "App version: $APP_VERSION"
fi
echo ""

# 4. Test template rendering
echo "4️⃣  Testing template rendering..."
if helm template "$RELEASE_NAME" "$CHART_DIR" "${TEMPLATE_ARGS[@]}" > /tmp/helm-rendered.yaml 2>/dev/null; then
    success "Templates rendered successfully"
else
    error "Template rendering failed"
    helm template "$RELEASE_NAME" "$CHART_DIR" "${TEMPLATE_ARGS[@]}"
    exit 1
fi
echo ""

# 4b. values.schema.json (typo em values passa silencioso sem schema)
echo "4️⃣b Validating values schema..."
if [ -f "$CHART_DIR/values.schema.json" ]; then
    if command -v jq &> /dev/null && jq empty "$CHART_DIR/values.schema.json" 2>/dev/null; then
        success "values.schema.json valid JSON"
    else
        error "values.schema.json is not valid JSON"; exit 1
    fi
    if helm lint --strict "$CHART_DIR" "${TEMPLATE_ARGS[@]}" > /dev/null 2>&1; then
        success "values conform to schema (helm lint --strict)"
    else
        warning "helm lint --strict reported schema issues"; printf '%s\n' "$(helm lint --strict "$CHART_DIR" ${VALUES_FILE:+-f "$VALUES_FILE"} 2>&1 | tail -5)"
    fi
else
    warning "values.schema.json missing — typos in values will be silently ignored"
fi
echo ""

# 4c. Imagens: existem? cobrem a arquitetura do nó?
echo "4️⃣c Checking referenced images and platforms..."
IMAGES=$(grep -oE '^[[:space:]]*image: [^ ]+' /tmp/helm-rendered.yaml | awk '{print $2}' | sort -u)
NODE_ARCH=""
if [ "$SKIP_CLUSTER" != "1" ] && command -v kubectl &> /dev/null; then
    NODE_ARCH=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null || true)
fi
for img in $IMAGES; do
    if ! command -v docker &> /dev/null; then
        warning "docker ausente; não foi possível verificar $img"; continue
    fi
    if ! MANIFEST=$(docker manifest inspect "$img" 2>/dev/null); then
        error "image not found in registry: $img"; MISSING_IMAGE=1; continue
    fi
    if [ -n "$NODE_ARCH" ] && [ "$NODE_ARCH" != "amd64" ]; then
        # manifest list -> plataformas; imagem simples -> architecture
        if echo "$MANIFEST" | grep -q "\"architecture\""; then
            if echo "$MANIFEST" | grep -q "\"$NODE_ARCH\""; then
                success "$img has $NODE_ARCH"
            else
                error "$img has NO $NODE_ARCH (node is $NODE_ARCH) — exec format error at runtime"
                MISSING_ARCH=1
            fi
        fi
    else
        success "image exists: $img"
    fi
done
if [ "${MISSING_IMAGE:-0}" = "1" ] || [ "${MISSING_ARCH:-0}" = "1" ]; then
    error "image gate failed"; [ "$STRICT" = "1" ] && exit 1
fi
echo ""

# 4d. secretKeyRef: todas as chaves existem no Secret? (CreateContainerConfigError)
echo "4️⃣d Checking secret references..."
REQUIRED_KEYS=$(grep -B3 'key: ' /tmp/helm-rendered.yaml | grep -A3 'secretKeyRef' >/dev/null 2>&1; true)
REQUIRED_KEYS=$(awk '/secretKeyRef:/{found=1;next} found&&/key:/{print $2;found=0}' /tmp/helm-rendered.yaml | sort -u)
SECRET_NAMES=$(awk '/secretKeyRef:/{f=1;next} f&&/name:/{print $2;f=0}' /tmp/helm-rendered.yaml | sort -u)
if [ -z "$REQUIRED_KEYS" ]; then
    success "no secretKeyRef in the chart"
else
    echo "   chaves exigidas: $(echo $REQUIRED_KEYS | tr '\n' ' ')"
    for secret in $SECRET_NAMES; do
        if [ "$SKIP_CLUSTER" = "1" ] || ! command -v kubectl &> /dev/null; then
            warning "skip cluster check for Secret '$secret'"
            continue
        fi
        if ! kubectl -n "$NAMESPACE" get secret "$secret" >/dev/null 2>&1; then
            error "Secret '$secret' does not exist in ns '$NAMESPACE'"
            MISSING_SECRET=1; continue
        fi
        for key in $REQUIRED_KEYS; do
            if kubectl -n "$NAMESPACE" get secret "$secret" -o jsonpath="{.data.$key}" 2>/dev/null | grep -q .; then
                success "key $key present"
            else
                # pode ser opcional:true — avisa, não falha
                warning "key $key missing in '$secret' (ok only if secretKeyRef.optional: true)"
                MISSING_KEY=1
            fi
        done
    done
fi
if [ "${MISSING_SECRET:-0}" = "1" ]; then error "required Secret missing"; [ "$STRICT" = "1" ] && exit 1; fi
echo ""

# 4e. Perfil do cluster: o controller de Ingress do chart existe?
echo "4️⃣e Checking cluster profile (ingress controller / arch / storage)..."
if [ "$SKIP_CLUSTER" != "1" ] && command -v kubectl &> /dev/null; then
    CLASSES=$(kubectl get ingressclass -o jsonpath='{range .items[*]}{.metadata.name} {end}' 2>/dev/null || true)
    echo "   ingressclasses: ${CLASSES:-(none)}"
    CHART_CLASS=$(grep -oE '^[[:space:]]*ingressClassName: .*' /tmp/helm-rendered.yaml | awk '{print $2}' | tr -d '"' | sort -u)
    for c in $CHART_CLASS; do
        if [ -n "$CLASSES" ] && echo " $CLASSES " | grep -q " $c "; then
            success "ingressClass '$c' exists"
        else
            error "chart uses ingressClass '$c' which does NOT exist — 404 on every path"
            CLASS_MISMATCH=1
        fi
    done
    # nginx annotations + traefik-only cluster is the classic silent failure
    if grep -q 'nginx.ingress.kubernetes.io' /tmp/helm-rendered.yaml && \
       [ -n "$CLASSES" ] && ! echo " $CLASSES " | grep -q ' nginx '; then
        error "chart uses nginx annotations but no nginx IngressClass exists — they are silently ignored"
        CLASS_MISMATCH=1
    fi
    [ -n "$NODE_ARCH" ] && echo "   node architecture: $NODE_ARCH"
    # TLS: quem termina? O chart estar HTTP-only é correto quando há proxy no edge;
    # errado quando o cluster é o edge e não há cert-manager.
    CERT_MGR=$(kubectl get pods -A 2>/dev/null | grep -c 'cert-manager' || true)
    if grep -qE '^\s+tls:' /tmp/helm-rendered.yaml; then
        if [ "${CERT_MGR:-0}" -gt 0 ]; then
            success "chart enables TLS and cert-manager is installed"
        else
            warning "chart enables TLS but no cert-manager found — needs a pre-existing TLS Secret"
            echo "   (if an external proxy terminates TLS, the chart must NOT enable tls:)"
        fi
    else
        if [ "${CERT_MGR:-0}" -gt 0 ]; then
            warning "no tls: in the chart although cert-manager exists — confirm the edge topology"
        else
            success "chart is HTTP-only (correct when an external proxy terminates TLS)"
            echo "   → the proxy must send Host, X-Forwarded-Proto/Host/For, and the app needs trustProxy"
        fi
    fi

    SC=$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}' 2>/dev/null || true)
    echo "   default storageClass: ${SC:-(none)}"
    if [ "${SC:-}" = "local-path" ]; then
        warning "local-path does NOT enforce PVC size limits — sum PVCs against real free disk"
        NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        AVAIL=$(kubectl get --raw "/api/v1/nodes/$NODE/proxy/stats/summary" 2>/dev/null \
          | jq -r '.node.fs.availableBytes' 2>/dev/null || echo 0)
        REQ=$(grep -oE 'storage: "[0-9]+(Gi|Mi)"' /tmp/helm-rendered.yaml | sed -E 's/.*"([0-9]+)(Gi|Mi)"/\1 \2/' \
          | awk '{ if ($2=="Gi") g+=$1; else g+=$1/1024 } END { printf "%d", g }')
        if [ "${AVAIL:-0}" -gt 0 ] 2>/dev/null; then
            AVAIL_GI=$((AVAIL / 1024 / 1024 / 1024))
            echo "   PVCs requested: ~${REQ}Gi | node free: ${AVAIL_GI}Gi"
            if [ "$REQ" -ge "$AVAIL_GI" ] 2>/dev/null; then
                error "sum of PVC sizes (${REQ}Gi) >= free disk (${AVAIL_GI}Gi) — will fill the node"
                DISK_RISK=1
            fi
        fi
    fi
    if [ "${CLASS_MISMATCH:-0}" = "1" ] || [ "${DISK_RISK:-0}" = "1" ]; then
        [ "$STRICT" = "1" ] && exit 1
    fi
else
    warning "cluster checks skipped (SKIP_CLUSTER=1 or kubectl unavailable)"
fi
echo ""

# 5. Dry-run installation
echo "5️⃣  Testing dry-run installation..."
if helm install "$RELEASE_NAME" "$CHART_DIR" --dry-run --debug "${TEMPLATE_ARGS[@]}" > /dev/null 2>&1; then
    success "Dry-run installation successful"
else
    error "Dry-run installation failed"
    exit 1
fi
echo ""

# 5b. Server-side dry-run, quando o cluster está acessível (pega RBAC/CRD/admission)
if [ "$SKIP_CLUSTER" != "1" ] && command -v kubectl &> /dev/null; then
    echo "5️⃣b Server-side dry-run..."
    if kubectl apply --dry-run=server -f /tmp/helm-rendered.yaml > /dev/null 2>&1; then
        success "manifests accepted by the API server"
    else
        warning "server-side dry-run reported problems:"
        kubectl apply --dry-run=server -f /tmp/helm-rendered.yaml 2>&1 | tail -10
        [ "$STRICT" = "1" ] && exit 1
    fi
    echo ""
fi

# 6. Check for required Kubernetes resources
echo "6️⃣  Checking generated resources..."
MANIFESTS=$(helm template "$RELEASE_NAME" "$CHART_DIR")

if echo "$MANIFESTS" | grep -q "kind: Deployment"; then
    success "Deployment found"
else
    warning "No Deployment found"
fi

if echo "$MANIFESTS" | grep -q "kind: Service"; then
    success "Service found"
else
    warning "No Service found"
fi

if echo "$MANIFESTS" | grep -q "kind: ServiceAccount"; then
    success "ServiceAccount found"
else
    warning "No ServiceAccount found"
fi
echo ""

# 7. Check for security best practices
echo "7️⃣  Checking security best practices..."
if echo "$MANIFESTS" | grep -q "runAsNonRoot: true"; then
    success "Running as non-root user"
else
    warning "Not explicitly running as non-root"
fi

if echo "$MANIFESTS" | grep -q "readOnlyRootFilesystem: true"; then
    success "Using read-only root filesystem"
else
    warning "Not using read-only root filesystem"
fi

if echo "$MANIFESTS" | grep -q "allowPrivilegeEscalation: false"; then
    success "Privilege escalation disabled"
else
    warning "Privilege escalation not explicitly disabled"
fi
echo ""

# 8. Check for resource limits
echo "8️⃣  Checking resource configuration..."
if echo "$MANIFESTS" | grep -q "resources:"; then
    if echo "$MANIFESTS" | grep -q "limits:"; then
        success "Resource limits defined"
    else
        warning "No resource limits defined"
    fi
    if echo "$MANIFESTS" | grep -q "requests:"; then
        success "Resource requests defined"
    else
        warning "No resource requests defined"
    fi
else
    warning "No resources defined"
fi
echo ""

# 9. Check for health probes
echo "9️⃣  Checking health probes..."
if echo "$MANIFESTS" | grep -q "livenessProbe:"; then
    success "Liveness probe configured"
else
    warning "No liveness probe found"
fi

if echo "$MANIFESTS" | grep -q "readinessProbe:"; then
    success "Readiness probe configured"
else
    warning "No readiness probe found"
fi
echo ""

# 10. Check dependencies
if [ -f "$CHART_DIR/Chart.yaml" ] && grep -q "^dependencies:" "$CHART_DIR/Chart.yaml"; then
    echo "🔟 Checking dependencies..."
    if helm dependency list "$CHART_DIR" > /dev/null 2>&1; then
        success "Dependencies valid"

        if [ -f "$CHART_DIR/Chart.lock" ]; then
            success "Chart.lock file present"
        else
            warning "Chart.lock file missing (run 'helm dependency update')"
        fi
    else
        error "Dependencies check failed"
    fi
    echo ""
fi

# 11. Check for values schema
if [ -f "$CHART_DIR/values.schema.json" ]; then
    echo "1️⃣1️⃣ Validating values schema..."
    success "values.schema.json present"

    # Validate schema if jq is available
    if command -v jq &> /dev/null; then
        if jq empty "$CHART_DIR/values.schema.json" 2>/dev/null; then
            success "values.schema.json is valid JSON"
        else
            error "values.schema.json contains invalid JSON"
            exit 1
        fi
    fi
    echo ""
fi

# Summary
echo "═══════════════════════════════════════════════════════"
echo "  Validation Complete!"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "Chart: $CHART_NAME"
echo "Version: $CHART_VERSION"
if [ -n "$APP_VERSION" ]; then
    echo "App Version: $APP_VERSION"
fi
echo ""
if [ "$STRICT" = "1" ]; then
    success "All validations passed (STRICT)"
else
    success "Structural validations passed"
    echo ""
    warning "Run with STRICT=1 for the Production Gate (images, arch, secrets, cluster profile)."
fi
echo ""
echo "Next steps:"
echo "  • helm package $CHART_DIR"
echo "  • helm template $RELEASE_NAME $CHART_DIR -f values-prod.yaml | kubectl apply --dry-run=server -f -"
echo "  • helm upgrade --install $RELEASE_NAME $CHART_DIR -n <ns> --atomic --timeout 15m"
echo "  • helm test $RELEASE_NAME"
echo ""
