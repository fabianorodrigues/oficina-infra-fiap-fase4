#!/bin/sh
# Testa a classificacao shell com um helm fake. Nao acessa cluster nem rede.
set -eu

script_dir="$(cd "$(dirname "$0")" && pwd)"
classifier="$script_dir/classify-helm-release.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
pass() { echo "  ok   $1"; }
fail() { echo "  FALHA $1" >&2; failures=$((failures + 1)); }

mkdir -p "$work/bin"
cat > "$work/bin/helm" <<'EOF'
#!/bin/sh
mode="${HELM_FAKE_MODE:-exists}"
cmd="$1"
shift

case "$cmd:$mode" in
  status:absent)
    echo 'Error: release: not found' >&2
    exit 1
    ;;
  status:exists)
    printf 'NAME: nr-otel\nREVISION: 3\nSTATUS: deployed\n'
    ;;
  status:exists_history_fails)
    printf 'NAME: nr-otel\nREVISION: 7\nSTATUS: deployed\n'
    ;;
  status:list_fallback)
    echo 'context deadline exceeded' >&2
    exit 1
    ;;
  status:unknown)
    echo 'context deadline exceeded' >&2
    exit 1
    ;;
  history:exists)
    printf '[{"revision":1},{"revision":3}]\n'
    ;;
  history:exists_history_fails)
    echo 'history unavailable' >&2
    exit 1
    ;;
  history:list_fallback)
    printf '[{"revision":8}]\n'
    ;;
  list:list_fallback)
    printf '[{"name":"nr-otel","revision":"8","status":"deployed"}]\n'
    ;;
  list:unknown)
    echo 'cluster unavailable' >&2
    exit 1
    ;;
  *)
    echo "helm fake nao cobre: $cmd em $mode" >&2
    exit 1
    ;;
esac
EOF
chmod 0755 "$work/bin/helm"

run_case() {
    mode="$1"
    HELM_FAKE_MODE="$mode" PATH="$work/bin:$PATH" sh "$classifier" nr-otel newrelic 2 2>&1
}

output="$(run_case absent)"
if printf '%s\n' "$output" | grep -q 'OFICINA_RELEASE_STATE=absent'; then
    pass 'release ausente classificado'
else
    fail "release ausente nao classificado: $output"
fi

output="$(run_case exists)"
if printf '%s\n' "$output" | grep -q 'OFICINA_RELEASE_STATE=exists' &&
    printf '%s\n' "$output" | grep -q 'OFICINA_CURRENT_REVISION=3' &&
    printf '%s\n' "$output" | grep -q '"revision":3'; then
    pass 'release existente com history classificado'
else
    fail "release existente nao classificado: $output"
fi

output="$(run_case exists_history_fails)"
if printf '%s\n' "$output" | grep -q 'OFICINA_RELEASE_STATE=exists' &&
    printf '%s\n' "$output" | grep -q 'OFICINA_CURRENT_REVISION=7' &&
    printf '%s\n' "$output" | grep -q 'helm history indisponivel'; then
    pass 'history indisponivel usa revision do status'
else
    fail "fallback de history falhou: $output"
fi

output="$(run_case list_fallback)"
if printf '%s\n' "$output" | grep -q 'OFICINA_RELEASE_STATE=exists' &&
    printf '%s\n' "$output" | grep -q '"revision":"8"'; then
    pass 'helm list classifica release quando status falha'
else
    fail "fallback de helm list falhou: $output"
fi

output="$(run_case unknown)"
if printf '%s\n' "$output" | grep -q 'OFICINA_RELEASE_STATE=unknown' &&
    printf '%s\n' "$output" | grep -q 'context deadline exceeded'; then
    pass 'erro real permanece unknown com diagnostico'
else
    fail "unknown sem diagnostico correto: $output"
fi

if [ "$failures" -gt 0 ]; then
    echo "classificacao Helm shell reprovada em $failures verificacao(oes)." >&2
    exit 1
fi

echo 'classificacao Helm shell aprovada.'
