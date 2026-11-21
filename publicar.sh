#!/bin/bash
# Envia os arquivos do app de viagens Partiu para o GitHub num único commit, sem precisar do Git instalado.
# Uso: ./publicar.sh "mensagem do commit"
# app/data só vai junto com INCLUIR_DADOS=1 (primeiro envio): depois disso quem cuida dos preços é o robô na nuvem.
set -euo pipefail
cd "$(dirname "$0")"
GH=../.ferramentas/gh
REPO=${REPO:-burneikoantonio/partiu}
MSG=${1:-"Atualiza o app"}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# o celular sempre baixa a versão nova do Juntos (evita cópia antiga em cache)
sed -i "" -E "s/(juntos)\.js\?v=[0-9]+/\1.js?v=$(date +%s)/g" app/index.html

excluir_dados=(-not -path './app/data/*')
[ "${INCLUIR_DADOS:-0}" = 1 ] && excluir_dados=()
find . -type f -not -path './.prefs/*' -not -name '.DS_Store' -not -name logo-original.png ${excluir_dados[@]+"${excluir_dados[@]}"} | sed 's|^\./||' | sort > "$TMP/arquivos.txt"

base=$($GH api "repos/$REPO/git/ref/heads/main" --jq .object.sha 2>/dev/null || true)
echo '[]' > "$TMP/tree.json"
while IFS= read -r f; do
  jq -n --rawfile c <(base64 -i "$f") '{content: $c, encoding: "base64"}' > "$TMP/blob.json"
  sha=$($GH api "repos/$REPO/git/blobs" --input "$TMP/blob.json" --jq .sha)
  modo=100644; [ -x "$f" ] && modo=100755
  jq --arg p "$f" --arg s "$sha" --arg m "$modo" '. + [{path: $p, mode: $m, type: "blob", sha: $s}]' "$TMP/tree.json" > "$TMP/t2.json" && mv "$TMP/t2.json" "$TMP/tree.json"
done < "$TMP/arquivos.txt"

if [ -n "$base" ]; then
  base_tree=$($GH api "repos/$REPO/git/commits/$base" --jq .tree.sha)
  jq -n --arg b "$base_tree" --slurpfile t "$TMP/tree.json" '{base_tree: $b, tree: $t[0]}' > "$TMP/tree-body.json"
  pais='["'$base'"]'
else
  jq -n --slurpfile t "$TMP/tree.json" '{tree: $t[0]}' > "$TMP/tree-body.json"
  pais='[]'
fi
tree=$($GH api "repos/$REPO/git/trees" --input "$TMP/tree-body.json" --jq .sha)
jq -n --arg m "$MSG" --arg t "$tree" --argjson p "$pais" '{message: $m, tree: $t, parents: $p}' > "$TMP/commit.json"
commit=$($GH api "repos/$REPO/git/commits" --input "$TMP/commit.json" --jq .sha)
if [ -n "$base" ]; then
  $GH api -X PATCH "repos/$REPO/git/refs/heads/main" -f sha="$commit" --silent
else
  $GH api "repos/$REPO/git/refs" -f ref=refs/heads/main -f sha="$commit" --silent
fi
echo "Enviado: $(wc -l < "$TMP/arquivos.txt" | tr -d ' ') arquivos, commit ${commit:0:7}"
