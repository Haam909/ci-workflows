#!/usr/bin/env bash
# tests/onboard/offline/harness.sh — the harness's GitHub helpers against a
# fake gh, and how a row's outcome is told: a bad moment on GitHub is INFRA,
# anything else FAIL, and a failed read is never taken for an answer.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${HERE}/../lib.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
export PATH="${HERE}/bin:${PATH}" FAKE_LOG="${TMP}/calls" FAKE_Q="${TMP}/q"

WRONG=0
# Runs code as a row step would; the outcome is the row's: PASS, INFRA or FAIL.
t() {      # name want-outcome want-text code answers...
  local name="$1" want="$2" text="$3" code="$4" out got ok=ok; shift 4
  printf '%s\n' "$@" > "${FAKE_Q}"; : > "${FAKE_LOG}"
  out="$(bash -c 'sleep() { :; }; source "$1"; WORK_ROW="$2"; LOG="$2/log"; : > "${LOG}"; : > "$2/last.out"
                  REPO=x/y; BRANCH=main; ROW_OK=true; ROW_FAILED=false; '"${code}"'; exit_row' _ "${LIB}" "${TMP}" 2>&1)"
  case $? in 0) got=PASS ;; 3) got=INFRA ;; *) got=FAIL ;; esac
  out="$(tr '\n' ' ' <<< "${out}")"
  [[ "${got}" == "${want}" && "${out}" == *"${text}"* ]] || { ok=WRONG; WRONG=$((WRONG + 1)); }
  printf '%-5s %-44s %-5s calls=%s  %s\n' "${ok}" "${name}" "${got}" "$(wc -l < "${FAKE_LOG}")" "${out:0:120}"
}
E404='1|{"message":"Not Found"}|gh: Not Found (HTTP 404)'
E502='1||gh: Bad Gateway (HTTP 502)'
E422='1|{"message":"Validation Failed"}|gh: Validation Failed (HTTP 422)'

t "gh_out: 502, then ok"                  PASS  "out=[42]"            'x="$(gh_out gh api a)"; echo "out=[$x]"' "${E502}" '0|42|'
t "gh_out: 502 x3: INFRA"                 INFRA "INFRA: read"         'x="$(gh_out gh api a)" || fail_step read' "${E502}" "${E502}" "${E502}"
t "gh_out: 422: not retried, FAIL"        FAIL  "✗ read"              'x="$(gh_out gh api a)" || fail_step read' "${E422}" "${E502}"
t "onboard_pr: none"                      PASS  "pr=[]"               'x="$(onboard_pr)" || fail_step list; echo "pr=[$x]"' '0||'
t "onboard_pr: 502 x3: not 'no PR'"       INFRA "INFRA: list"         'x="$(onboard_pr)" || fail_step list' "${E502}" "${E502}" "${E502}"
t "post_ruleset: ok"                      PASS  ""                    'post_ruleset main <<< "{}"' '0|{}|'
t "post_ruleset: 502 but landed: 1 POST"  PASS  ""                    'post_ruleset main <<< "{}"' "${E502}" '0|7|'
t "post_ruleset: 502, absent: POST again" PASS  ""                    'post_ruleset main <<< "{}"' "${E502}" '0||' '0|{}|'
t "post_ruleset: 422: FAIL"               FAIL  "creating ruleset"    'post_ruleset main <<< "{}"' "${E422}"
t "job_conclusion: success"               PASS  "c=[success]"         'c="$(job_conclusion 1 ^build)" || fail_step jobs; echo "c=[$c]"' '0|success|'
t "job_conclusion: 502 x3: INFRA"         INFRA "INFRA: jobs"         'c="$(job_conclusion 1 ^build)" || fail_step jobs' "${E502}" "${E502}" "${E502}"
t "relax: no classic protection (404)"    PASS  "lowered"             'relax_protection' '0||' "${E404}"
t "relax: classic 502 x3: INFRA"          INFRA "classic protection"  'relax_protection' '0||' "${E502}" "${E502}" "${E502}"

# onboard_failed: what onboard printed before it stopped decides the outcome.
c() {      # name want-outcome onboard-output
  printf '%s\n' "$3" > "${TMP}/onboard.out"
  t "$1" "$2" "" 'cp "${WORK_ROW}/onboard.out" "${WORK_ROW}/last.out"; onboard_failed x > /dev/null'
}
c "onboard: TLS timeout, can't see repo"  INFRA $'── commit\nPost "https://api.github.com/graphql": net/http: TLS handshake timeout\ngh can\'t see this repo (or can\'t reach GitHub; the error is above)'
c "check: couldn't read protection"       INFRA $'  ✗ couldn\'t read the branch protection on main from GitHub (x: TLS handshake timeout); nothing about it is checked. Re-run onboard check\n1 problem(s).'
c "apply: waiting on a required check"    FAIL  $'PR #13 can\'t be merged yet. It is waiting on:\n  - required check \'ci / gate\': \nWhen that\'s done, run onboard apply again.'
c "'timeout' early, real stop at the end" FAIL  $'restore: timeout 30s\n...\n...\n...\n...\n...\nthe repo allows only merge commits'

# The reason a row gives quotes onboard's ✗ line, which comes before more ✓
# lines and the summary, not its last lines.
printf '%s\n' $'  ✗ couldn\'t read the branch protection on main from GitHub (x: TLS handshake timeout)\n── repo settings\n  ✓ auto-merge\n  ✓ merge methods: squash rebase merge\n1 problem(s).' > "${TMP}/onboard.out"
t "apply: the reason is the ✗ line"       INFRA "apply:   ✗ couldn't read the branch protection" \
  'cp "${WORK_ROW}/onboard.out" "${WORK_ROW}/last.out"; onboard_failed "apply: $(stop_reason)"'

echo "harness: ${WRONG} wrong"
[[ "${WRONG}" == 0 ]]
