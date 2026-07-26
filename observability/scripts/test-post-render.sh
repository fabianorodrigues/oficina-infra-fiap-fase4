#!/bin/sh
# Prova o contrato do post-renderer sem depender de cluster nem de rede.
#
# O que precisa ser provado, porque um post-renderer descuidado corrompe o
# release inteiro em silencio:
#   - exatamente UM Deployment alterado, e ele e o nr-otel-gateway;
#   - somente spec.strategy muda;
#   - kube-state-metrics permanece intocado (vem do values.yaml);
#   - ausencia do gateway reprova, em vez de aplicar manifesto incompleto.
set -eu

script_dir="$(cd "$(dirname "$0")" && pwd)"
renderer="$script_dir/post-render-newrelic.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
pass() { echo "  ok   $1"; }
fail() { echo "  FALHA $1" >&2; failures=$((failures + 1)); }

cat > "$work/base.yaml" <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nr-otel
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nr-otel-gateway
  labels:
    app.kubernetes.io/name: nr-otel
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: nr-otel
  template:
    spec:
      containers:
        - name: collector
          image: newrelic/nrdot-collector-k8s:1.19.0
          resources:
            requests:
              memory: 256Mi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nr-otel-kube-state-metrics
spec:
  strategy:
    type: Recreate
  replicas: 1
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: nr-otel-daemonset
spec:
  template:
    spec:
      containers:
        - name: collector
EOF

echo 'Caso 1: chart sem strategy no gateway.'
"$renderer" < "$work/base.yaml" > "$work/base.out"

added="$(diff "$work/base.yaml" "$work/base.out" | grep -c '^> ' || true)"
removed="$(diff "$work/base.yaml" "$work/base.out" | grep -c '^< ' || true)"
if [ "$added" = "2" ] && [ "$removed" = "0" ]; then
    pass "diff acrescenta 2 linhas e remove 0"
else
    fail "diff inesperado: +$added -$removed"
fi

if diff "$work/base.yaml" "$work/base.out" | grep -q 'type: Recreate'; then
    pass 'a linha acrescentada e type: Recreate'
else
    fail 'Recreate nao encontrado no diff'
fi

# O KSM tem de sair igual nas duas renderizacoes: ele vem do values.yaml.
if [ "$(grep -c 'kube-state-metrics' "$work/base.out")" = "$(grep -c 'kube-state-metrics' "$work/base.yaml")" ]; then
    pass 'kube-state-metrics intocado'
else
    fail 'kube-state-metrics foi alterado pelo post-renderer'
fi

if [ "$(grep -c 'strategy:' "$work/base.out")" = "2" ]; then
    pass 'exatamente dois blocos strategy: gateway e KSM'
else
    fail "quantidade de blocos strategy inesperada: $(grep -c 'strategy:' "$work/base.out")"
fi

# Imagens, resources e selectors nao podem mudar.
for token in 'image: newrelic/nrdot-collector-k8s:1.19.0' 'memory: 256Mi' 'app.kubernetes.io/name: nr-otel'; do
    if grep -q "$token" "$work/base.out"; then
        pass "preservado: $token"
    else
        fail "campo alterado indevidamente: $token"
    fi
done

echo 'Caso 2: chart com RollingUpdate no gateway.'
cat > "$work/rolling.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nr-otel-gateway
spec:
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  replicas: 1
EOF
"$renderer" < "$work/rolling.yaml" > "$work/rolling.out"

if [ "$(grep -c 'strategy:' "$work/rolling.out")" = "1" ]; then
    pass 'strategy nao foi duplicada'
else
    fail "strategy duplicada: $(grep -c 'strategy:' "$work/rolling.out") ocorrencias"
fi

if grep -q 'type: Recreate' "$work/rolling.out" && ! grep -q 'RollingUpdate' "$work/rolling.out"; then
    pass 'RollingUpdate substituido por Recreate'
else
    fail 'RollingUpdate nao foi substituido'
fi

if ! grep -q 'maxSurge' "$work/rolling.out"; then
    pass 'corpo antigo de rollingUpdate removido'
else
    fail 'maxSurge sobrou apos a substituicao'
fi

echo 'Caso 3: gateway ausente reprova.'
if printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: outro\nspec:\n  replicas: 1\n' \
    | "$renderer" > /dev/null 2>&1; then
    fail 'gateway ausente deveria reprovar'
else
    pass 'gateway ausente reprovou'
fi

echo 'Caso 4: manifesto de documento unico sem separador inicial.'
printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: nr-otel-gateway\nspec:\n  replicas: 1\n' \
    | "$renderer" > "$work/single.out"
if grep -q 'type: Recreate' "$work/single.out"; then
    pass 'documento unico transformado'
else
    fail 'documento unico nao transformado'
fi

if [ "$failures" -gt 0 ]; then
    echo "post-renderer reprovado em $failures verificacao(oes)." >&2
    exit 1
fi

echo 'post-renderer aprovado.'
