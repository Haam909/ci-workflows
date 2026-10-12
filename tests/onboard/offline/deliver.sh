#!/usr/bin/env bash
# tests/onboard/offline/deliver.sh — which Feed the deliver step publishes a
# package to, against fake dotnet, npm and az: GitHub Packages is the repo's
# own Host's, on github.com and on a GHE.com tenant alike (#12).

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${HERE}/../../../actions/deliver-artifact/action.yml"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

# The step's script, and fakes that log "<tool> <arguments>" to ${FAKE_LOG}.
yq '.runs.steps[] | select(.name == "Publish package") | .run' "${ACTION}" > "${TMP}/publish.sh"
mkdir -p "${TMP}/bin"
for tool in dotnet npm az; do
  printf '#!/usr/bin/env bash\necho "%s $*" >> "${FAKE_LOG}"\n' "${tool}" > "${TMP}/bin/${tool}"
  chmod +x "${TMP}/bin/${tool}"
done
touch "${TMP}/pkg.nupkg" "${TMP}/pkg.tgz"
export PATH="${TMP}/bin:${PATH}" FAKE_LOG="${TMP}/calls"

WRONG=0
t() {      # name host runtime feed want-rc want-output want-call
  local name="$1" host="$2" rt="$3" feed="$4" want_rc="$5" want_out="$6" want_call="$7" out rc got ok=ok api c
  : > "${FAKE_LOG}"
  if [[ "${host}" == github.com ]]; then api="https://api.github.com"; else api="https://api.${host}"; fi
  c="$(jq -nc --arg rt "${rt}" --arg feed "${feed}" '{runtime: $rt, target: "package"} + (if $feed == "" then {} else {feed: $feed} end)')"
  out="$(C="${c}" ARTIFACT="${TMP}/pkg.$([[ "${rt}" == node ]] && echo tgz || echo nupkg)" STAGE=test \
         GH_TOKEN_IN=ghtok FEED_TOKEN_IN="" RUNNER_TEMP="${TMP}" \
         GITHUB_SERVER_URL="https://${host}" GITHUB_API_URL="${api}" GITHUB_REPOSITORY_OWNER=o \
         bash "${TMP}/publish.sh" 2>&1)"; rc=$?
  got="$(grep -m1 -E '^(dotnet nuget add|npm publish)' "${FAKE_LOG}")"
  [[ "${rc}" == "${want_rc}" && "${out}" == *"${want_out}"* && "${got}" == *"${want_call}"* ]] || { ok=WRONG; WRONG=$((WRONG + 1)); }
  printf '%-5s %-52s rc=%s  %s  %s\n' "${ok}" "${name}" "${rc}" "$(grep -m1 -E '^(Feed:|::error::)' <<< "${out}" | cut -c1-80)" "${got:0:90}"
}
GPR="Feed: GitHub Packages"
REFUSED="set 'feed-token-secret'"
AZ_FEED="https://pkgs.dev.azure.com/x/_packaging/f/nuget/v3/index.json"

t "github.com dotnet, no feed"                   github.com   dotnet ""                                         0 "${GPR}" "add source https://nuget.pkg.github.com/o/index.json "
t "github.com node, no feed"                     github.com   node   ""                                         0 "${GPR}" "--registry https://npm.pkg.github.com/"
t "github.com dotnet, feed its own GPR"          github.com   dotnet "https://nuget.pkg.github.com/o/index.json" 0 "${GPR}" "add source https://nuget.pkg.github.com/o/index.json "
t "tenant dotnet, no feed"                       octo.ghe.com dotnet ""                                         0 "${GPR}" "add source https://nuget.octo.ghe.com/o/index.json "
t "tenant node, no feed"                         octo.ghe.com node   ""                                         0 "${GPR}" "--registry https://npm.octo.ghe.com/"
t "tenant dotnet, feed its own GPR"              octo.ghe.com dotnet "https://nuget.octo.ghe.com/o/index.json"  0 "${GPR}" "add source https://nuget.octo.ghe.com/o/index.json "
t "tenant node, feed its own GPR"                octo.ghe.com node   "https://npm.octo.ghe.com/"                0 "${GPR}" "--registry https://npm.octo.ghe.com/"
t "tenant, github.com GPR is foreign"            octo.ghe.com dotnet "https://nuget.pkg.github.com/o/index.json" 1 "${REFUSED}" ""
t "github.com, a tenant's GPR is foreign"        github.com   node   "https://npm.octo.ghe.com"                 1 "${REFUSED}" ""
t "Azure Artifacts still by its hostnames"       octo.ghe.com dotnet "${AZ_FEED}"                               0 "Feed: Azure Artifacts" "add source ${AZ_FEED} "
t "Azure Artifacts node, its npm registry"     github.com   node   "https://pkgs.dev.azure.com/x/_packaging/f/npm/registry/" 0 "Feed: Azure Artifacts" "--registry https://pkgs.dev.azure.com/x/_packaging/f/npm/registry/"
t "python, no feed: refused"                     github.com   python ""                                         1 "Python packages need a 'feed'" ""

echo "deliver: ${WRONG} wrong"
[[ "${WRONG}" == 0 ]]
