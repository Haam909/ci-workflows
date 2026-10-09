#!/usr/bin/env bash
# tests/onboard/offline/onboard.sh — onboard's GitHub reads against a fake gh:
# a bad moment is retried, a failed read stops apply instead of being taken
# for an answer, and a plan refusal is still an answer.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CIW="$(cd "${HERE}/../../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
export PATH="${HERE}/bin:${PATH}" FAKE_LOG="${TMP}/calls" FAKE_Q="${TMP}/q"

# onboard's functions without its main section, where its CIW resolves to a
# copy holding the prefixes file it reads.
LIB="${TMP}/ciw/local/bin/onboard-lib.sh"
mkdir -p "${TMP}/ciw/local/bin" "${TMP}/ciw/actions/derive-version"
cp "${CIW}/actions/derive-version/prefixes" "${TMP}/ciw/actions/derive-version/"
sed '/^# -* main -*$/,$d' "${CIW}/local/bin/onboard" > "${LIB}"

# A clone of x/y whose origin/HEAD says main.
R="${TMP}/repo"
git init -q -b main "${R}"
git -C "${R}" -c user.name=t -c user.email=t@t commit -q --allow-empty -m x
git -C "${R}" remote add origin https://github.com/x/y.git
git -C "${R}" update-ref refs/remotes/origin/main HEAD
git -C "${R}" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

WRONG=0
t() {      # name cmd want-rc want-text code answers...
  local name="$1" cmd="$2" want="$3" text="$4" code="$5" out rc ok=ok; shift 5
  printf '%s\n' "$@" > "${FAKE_Q}"; : > "${FAKE_LOG}"
  out="$(cd "${R}" && bash -c 'f="$1"; c="$2"; set -- "${c}"; sleep() { :; }; source "$f"; REPO=x/y; '"${code}" _ "${LIB}" "${cmd}" 2>&1)"; rc=$?
  out="$(sed 's/\x1b\[[0-9;]*m//g' <<< "${out}" | tr '\n' ' ')"
  [[ "${rc}" == "${want}" && "${out}" == *"${text}"* ]] || { ok=WRONG; WRONG=$((WRONG + 1)); }
  printf '%-5s %-44s rc=%s calls=%s  %s\n' "${ok}" "${name}" "${rc}" "$(wc -l < "${FAKE_LOG}")" "${out:0:140}"
}
E404='1|{"message":"Not Found"}|gh: Not Found (HTTP 404)'
E502='1||gh: Bad Gateway (HTTP 502)'
ETLS='1||net/http: TLS handshake timeout'
EPLAN='1|{"message":"Upgrade to GitHub Pro or make this repository public to enable this feature."}|gh: Upgrade to GitHub Pro (HTTP 403)'
OK='0|{}|'

t "environment exists"                apply 0 "environment test exists"      'ensure_environment test' "${OK}"
t "environment 404: created"          apply 0 "✓ environment test"           'ensure_environment test' "${E404}" "${OK}"
t "environment 502 x4: stop, no PUT"  apply 1 "can't read environment test"  'ensure_environment test' "${E502}" "${E502}" "${E502}" "${E502}"
t "environment 502, then exists"      apply 0 "exists; left alone"           'ensure_environment test' "${E502}" "${OK}"
t "ruleset exists"                    apply 0 "exists; left alone"           'ensure_ruleset main "{}"' '0|7|'
t "ruleset absent: POST"              apply 0 "✓ ruleset 'main'"             'ensure_ruleset main "{}"' '0||' "${OK}"
t "ruleset list 502 x4: stop"         apply 1 "can't read the rulesets"      'ensure_ruleset main "{}"' "${E502}" "${E502}" "${E502}" "${E502}"
t "ruleset plan refusal: said"        apply 1 "GitHub refused it"            'ensure_ruleset main "{}"' "${EPLAN}" "${EPLAN}"
t "push_blocked: pull_request rule"   apply 0 ""                             'push_blocked' '0|pull_request|' "${E404}"
t "push_blocked: nothing"             apply 1 ""                             'push_blocked' '0||' "${E404}"
t "push_blocked: TLS x4: stop"        apply 1 "can't read the branch protection" 'push_blocked' "${ETLS}" "${ETLS}" "${ETLS}" "${ETLS}" "${E404}"
t "push_blocked: private plan"        apply 1 ""                             'push_blocked' "${EPLAN}" "${E404}"
t "pr_blockers: view fails x3: stop"  apply 1 "can't read PR #5"             'x="$(pr_blockers 5)" || exit 1; echo "[$x]"' "${E502}" "${E502}" "${E502}"

# No origin/HEAD: apply asks GitHub and stops if it can't say; init, which
# changes nothing on GitHub, takes the current branch.
git -C "${R}" symbolic-ref --delete refs/remotes/origin/HEAD
t "default branch unreadable: apply"  apply 1 "can't read the default branch" 'true' "${E502}" "${E502}" "${E502}"
t "default branch unreadable: init"   init  0 "DEFAULT=main"                 'echo "DEFAULT=${DEFAULT}"' "${E502}" "${E502}" "${E502}"

echo "onboard: ${WRONG} wrong"
[[ "${WRONG}" == 0 ]]
