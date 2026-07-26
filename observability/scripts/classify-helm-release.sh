#!/bin/sh
# Classifica o release Helm do Collector sem tratar erro real como instalacao
# inicial. Saida consumida por Resolve-HelmOperation.
set -u

release="$1"
namespace="$2"
history_max="$3"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

status_out="$work/helm-status.out"
status_err="$work/helm-status.err"
history_out="$work/helm-history.json"
history_err="$work/helm-history.err"
list_out="$work/helm-list.json"
list_err="$work/helm-list.err"

emit_existing_release() {
    echo 'OFICINA_RELEASE_STATE=exists'
    if [ -s "$status_out" ]; then
        revision="$(awk -F: 'toupper($1) == "REVISION" { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit }' "$status_out")"
        if printf '%s\n' "$revision" | grep -Eq '^[0-9]+$'; then
            echo "OFICINA_CURRENT_REVISION=$revision"
        fi
    fi
    if helm history "$release" --namespace "$namespace" --max "$history_max" --output json > "$history_out" 2>"$history_err"; then
        cat "$history_out"
    else
        echo 'AVISO: helm history indisponivel; usando revision do helm status/list quando disponivel.' >&2
        cat "$history_err" >&2
    fi
}

if helm status "$release" --namespace "$namespace" > "$status_out" 2>"$status_err"; then
    emit_existing_release
else
    if grep -qiE 'release: not found|not found' "$status_err"; then
        echo 'OFICINA_RELEASE_STATE=absent'
    elif helm list --namespace "$namespace" --all --filter "^${release}$" --output json > "$list_out" 2>"$list_err" &&
        grep -q "\"name\"[[:space:]]*:[[:space:]]*\"$release\"" "$list_out"; then
        cat "$list_out"
        emit_existing_release
    else
        echo 'OFICINA_RELEASE_STATE=unknown'
        echo '--- helm status stderr'
        cat "$status_err"
        echo '--- helm list stderr'
        cat "$list_err" 2>/dev/null || true
    fi
fi
