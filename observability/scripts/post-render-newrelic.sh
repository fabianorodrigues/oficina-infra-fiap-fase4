#!/bin/sh
# Post-renderer do Helm com responsabilidade unica:
#
#   Deployment nr-otel-gateway -> spec.strategy.type=Recreate
#
# Por que post-renderer e nao patch depois do install: se o chart renderizar
# RollingUpdate, o Helm sobe um segundo gateway antes do patch chegar. Num
# t3.medium com orcamento de 512Mi isso e exatamente o que se quer evitar, e o
# upgrade seguinte restauraria o manifesto original do chart.
#
# O kube-state-metrics NAO passa por aqui: o subchart expoe updateStrategy e e
# configurado pelo values.yaml. Casar o nome do KSM num script de texto seria
# fragil sem necessidade.
#
# Nao suportado em `helm rollback`. Ali a garantia vem de a revisao anterior ter
# sido gravada com Recreate, conferida por `helm get manifest --revision` antes do
# upgrade e revalidada depois do rollback.
set -eu

TARGET_KIND='Deployment'
TARGET_NAME='nr-otel-gateway'

input="$(mktemp)"
output="$(mktemp)"
trap 'rm -f "$input" "$output"' EXIT

cat > "$input"

# Transformacao feita por documento YAML, alterando somente spec.strategy do
# Deployment alvo. Qualquer outro documento e copiado byte a byte.
awk -v kind="$TARGET_KIND" -v name="$TARGET_NAME" '
function flush_doc() {
    if (doc_kind == kind && doc_name == name) {
        matched = 1

        # Pre-varredura: saber de antemao se o chart ja declara strategy decide
        # entre substituir o bloco existente e inserir um novo. Sem isso, um
        # documento que ja tem strategy receberia a chave duas vezes.
        has_strategy = 0
        for (i = 1; i <= n; i++) {
            if (buffer[i] ~ /^  strategy:[[:space:]]*$/) { has_strategy = 1; break }
        }

        in_strategy = 0
        inserted = 0
        for (i = 1; i <= n; i++) {
            line = buffer[i]

            if (has_strategy) {
                if (line ~ /^  strategy:[[:space:]]*$/) {
                    print "  strategy:"
                    print "    type: Recreate"
                    in_strategy = 1
                    continue
                }
                if (in_strategy) {
                    # Descarta o corpo antigo enquanto a indentacao for maior.
                    if (line ~ /^    /) { continue }
                    in_strategy = 0
                }
            }
            else if (!inserted && line ~ /^spec:[[:space:]]*$/) {
                print line
                print "  strategy:"
                print "    type: Recreate"
                inserted = 1
                continue
            }

            print line
        }
    } else {
        for (i = 1; i <= n; i++) { print buffer[i] }
    }
    n = 0; doc_kind = ""; doc_name = ""; in_metadata = 0; in_strategy = 0
}

BEGIN { n = 0; matched = 0 }

/^---[[:space:]]*$/ {
    flush_doc()
    print
    next
}

{
    buffer[++n] = $0
    if ($0 ~ /^kind:[[:space:]]/) {
        doc_kind = $2
    }
    if ($0 ~ /^metadata:[[:space:]]*$/) { in_metadata = 1; next }
    if (in_metadata) {
        if ($0 ~ /^[^[:space:]]/) { in_metadata = 0 }
        else if ($0 ~ /^  name:[[:space:]]/) { doc_name = $2 }
    }
}

END {
    flush_doc()
    if (!matched) {
        print "post-render: Deployment " name " nao encontrado no manifesto renderizado." > "/dev/stderr"
        exit 1
    }
}
' "$input" > "$output"

cat "$output"
