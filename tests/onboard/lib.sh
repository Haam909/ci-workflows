# tests/onboard/lib.sh — sandbox handling and assertions. Sourced by run.

GITHUB_ACTIONS_APP=15368

# ------------------------------------------------------------ logging ----

# Harness lines start with ▶ or »; everything else in the log is the output
# of the commands run.
log()  { printf '%s\n' "▶ $*" | tee -a "${LOG}"; }
note() { printf '%s\n' "» · $*" | tee -a "${LOG}"; }
pass() { printf '%s\n' "» ✓ $*" | tee -a "${LOG}"; }
fail() { printf '%s\n' "» ✗ $*" | tee -a "${LOG}"; ROW_OK=false; ROW_FAILED=true; }
# GitHub or the network, not the code under test: the row ends INFRA, not FAIL.
infra() { printf '%s\n' "» ⚠ INFRA: $*" | tee -a "${LOG}"; ROW_OK=false; }
# Run a command, keep its output in the log, return its status.
logged() { local rc; { "$@"; } > "${WORK_ROW}/last.out" 2>&1; rc=$?; sed 's/\x1b\[[0-9;]*m//g' "${WORK_ROW}/last.out" >> "${LOG}"; return ${rc}; }
last_out() { sed 's/\x1b\[[0-9;]*m//g' "${WORK_ROW}/last.out"; }
# A step that talks to GitHub: logged, and tried again after a bad moment.
retried() { local try; for try in 1 2 3; do logged "$@" && return 0; transient_out || return 1; (( try < 3 )) && sleep 20; done; return 1; }
# Did the last step fail on GitHub or the network rather than on what it tested?
is_transient() {
  grep -qiE 'HTTP 5[0-9]{2}|5[0-9]{2} (Bad Gateway|Service Unavailable|Gateway Time)|timed out|timeout|Could not resolve|Connection (reset|refused)|unable to access|repository is disabled|RPC failed|rate limit|TLS handshake|Sigstore verifier|ECONNRESET|ETIMEDOUT|couldn.t read .* from GitHub|can.t read .* from GitHub|can.t fetch'
}
transient_out() { last_out | is_transient; }
# A GitHub call whose output is wanted: tried again after a bad moment. A
# failure leaves its error in last.out and the log, for fail_step.
gh_out() {
  local try out
  for try in 1 2 3; do
    if out="$("$@" 2> "${WORK_ROW}/last.out")"; then printf '%s\n' "${out}"; return 0; fi
    printf '%s\n' "${out}" >> "${WORK_ROW}/last.out"      # gh api prints an error's body on stdout
    transient_out || break
    (( try < 3 )) && sleep 20
  done
  sed 's/\x1b\[[0-9;]*m//g' "${WORK_ROW}/last.out" >> "${LOG}"
  return 1
}
# The last gh_out failed with "not found".
not_found() { last_out | grep -q 'HTTP 404'; }
# fail, or infra when the last step failed on GitHub or the network.
fail_step() { if transient_out; then infra "$*"; else fail "$*"; fi; }
# The row's outcome as its subshell's exit status: 0 PASS, 1 FAIL, 3 INFRA.
exit_row() { [[ "${ROW_FAILED}" == true ]] && exit 1; [[ "${ROW_OK}" == true ]] && exit 0; exit 3; }

# Poll until a command succeeds. wait_for <seconds> <description> <command...>
wait_for() {
  local limit="$1" what="$2"; shift 2
  local end=$(( $(date +%s) + limit ))
  until "$@" > /dev/null 2>&1; do
    (( $(date +%s) < end )) || { fail "timed out after ${limit}s waiting for ${what}"; return 1; }
    sleep 10
  done
}

# ------------------------------------------------------------ sandbox ----

ensure_repo() {
  gh api "repos/${REPO}" > /dev/null 2>&1 && return 0
  gh repo create "${REPO}" "--${VIS}" --description "ci-workflows onboarding sandbox (tests/onboard); reset on every run" > /dev/null
}

# Back to nothing: no protection, environments, releases, tags, PRs or extra
# branches. The seed is force-pushed afterwards.
reset_repo() {
  local id b try left=""
  # A call GitHub fails in a bad moment deletes nothing and says nothing, and
  # what's left leaks into the next row (an earlier row's v0.1.0 made L1
  # release 0.1.0 again). Delete, then check nothing is left; repeat.
  for try in 1 2 3; do
    for id in $(gh api "repos/${REPO}/rulesets" --jq '.[].id' 2> /dev/null); do gh api -X DELETE "repos/${REPO}/rulesets/${id}" > /dev/null 2>&1; done
    for b in $(gh api "repos/${REPO}/branches?per_page=100" --jq '.[] | select(.protected) | .name' 2> /dev/null); do
      gh api -X DELETE "repos/${REPO}/branches/${b}/protection" > /dev/null 2>&1
    done
    for id in $(gh api "repos/${REPO}/environments" --jq '.environments[].name' 2> /dev/null); do gh api -X DELETE "repos/${REPO}/environments/${id}" > /dev/null 2>&1; done
    for id in $(gh api "repos/${REPO}/releases?per_page=100" --jq '.[].id' 2> /dev/null); do gh api -X DELETE "repos/${REPO}/releases/${id}" > /dev/null 2>&1; done
    for id in $(gh api "repos/${REPO}/git/matching-refs/tags" --jq '.[].ref' 2> /dev/null); do gh api -X DELETE "repos/${REPO}/git/${id}" > /dev/null 2>&1; done
    for id in $(gh pr list -R "${REPO}" --state open --json number --jq '.[].number' 2> /dev/null); do gh pr close -R "${REPO}" "${id}" > /dev/null 2>&1; done
    if left="$(sandbox_leftovers)"; then [[ -z "${left}" ]] && break; else left="GitHub didn't say what's left"; fi
    sleep 10
  done
  [[ -z "${left}" ]] || { infra "sandbox reset incomplete: ${left}"; return 1; }
  gh_out gh api -X PATCH "repos/${REPO}" -F allow_squash_merge=true -F allow_rebase_merge=true -F allow_merge_commit=true \
    -F delete_branch_on_merge=false > /dev/null || { fail_step "resetting the merge settings failed"; return 1; }
  # Sandboxes never change visibility: GitHub refuses git access ("Your
  # repository is disabled") for a while after a change.
  local vis; vis="$(gh_out gh api "repos/${REPO}" --jq .visibility)" || { fail_step "can't read ${REPO}'s visibility"; return 1; }
  [[ "${vis}" == "${VIS}" ]] || { fail "${REPO} is ${vis}, the row needs ${VIS}; sandboxes keep the visibility they were created with"; return 1; }
}

# What a reset should have removed, or a failure if GitHub can't say.
sandbox_leftovers() {
  local n out=""
  if ! n="$(gh api "repos/${REPO}/rulesets" --jq length 2> /dev/null)"; then
    [[ "${VIS}" == private ]] || return 1; n=0      # a personal plan has no rulesets on private repos
  fi
  [[ "${n}" == 0 ]] || out+="${n} ruleset(s) "
  n="$(gh api "repos/${REPO}/environments" --jq .total_count 2> /dev/null)" || return 1; [[ "${n}" == 0 ]] || out+="${n} environment(s) "
  n="$(gh api "repos/${REPO}/releases?per_page=100" --jq length 2> /dev/null)" || return 1; [[ "${n}" == 0 ]] || out+="${n} release(s) "
  n="$(gh api "repos/${REPO}/git/matching-refs/tags" --jq length 2> /dev/null)" || return 1; [[ "${n}" == 0 ]] || out+="${n} tag(s) "
  n="$(gh pr list -R "${REPO}" --state open --json number --jq length 2> /dev/null)" || return 1; [[ "${n}" == 0 ]] || out+="${n} open PR(s) "
  printf '%s' "${out}"
}

assemble_seed() {        # dir
  local dir="$1" part
  rm -rf "${dir}"; mkdir -p "${dir}"
  for part in ${SEED}; do
    [[ -d "${HERE}/parts/${part}" ]] || { fail "no part ${part}"; return 1; }
    (cd "${HERE}/parts/${part}" && find . -type f -not -path '*/node_modules/*' -not -path '*/bin/*' -not -path '*/obj/*' \
       -not -name .gitignore -print0 | while IFS= read -r -d '' f; do mkdir -p "${dir}/$(dirname "$f")"; cp "$f" "${dir}/$f"; done)
    [[ -f "${HERE}/parts/${part}/.gitignore" ]] && cat "${HERE}/parts/${part}/.gitignore" >> "${dir}/.gitignore"
  done
  printf '# %s\n\nSandbox for ci-workflows tests/onboard row %s.\n' "${REPO#*/}" "${ROW}" > "${dir}/README.md"
}

push_seed() {
  local dir="${WORK_ROW}/seed" b t
  assemble_seed "${dir}" || return 1
  (
    cd "${dir}" || exit 1
    git init -q -b "${BRANCH}"
    if declare -F pre_seed > /dev/null; then pre_seed; fi
    git add -A && git commit -qm "seed" && git remote add origin "https://github.com/${REPO}.git"
    for t in ${TAGS}; do git tag -a "$t" -m "$t"; done
  ) >> "${LOG}" 2>&1 || { fail "preparing the seed failed"; return 1; }
  retried git -C "${dir}" push -q --force origin "${BRANCH}" \
    && { [[ -z "${TAGS}" ]] || retried git -C "${dir}" push -q --force origin --tags; } \
    || { fail_step "pushing the seed failed: $(last_out | tail -1)"; return 1; }
  gh_out gh api -X PATCH "repos/${REPO}" -f default_branch="${BRANCH}" > /dev/null || { fail_step "setting the default branch failed"; return 1; }
  # A leftover branch (an earlier row's chore/onboard-ci) changes what onboard
  # does: delete, then check only ${BRANCH} is left.
  local branches
  branches="$(gh_out gh api "repos/${REPO}/branches?per_page=100" --jq '.[].name')" || { fail_step "listing the branches failed"; return 1; }
  for b in ${branches}; do
    [[ "$b" == "${BRANCH}" ]] || gh api -X DELETE "repos/${REPO}/git/refs/heads/${b}" > /dev/null 2>&1
  done
  branches="$(gh_out gh api "repos/${REPO}/branches?per_page=100" --jq '.[].name')" || { fail_step "listing the branches failed"; return 1; }
  [[ "${branches}" == "${BRANCH}" ]] || { infra "branches left after the reset: $(tr '\n' ' ' <<< "${branches}")"; return 1; }
  local m args=(-F allow_squash_merge=false -F allow_rebase_merge=false -F allow_merge_commit=false)
  for m in ${MERGES}; do
    case "$m" in squash) args[1]=allow_squash_merge=true ;; rebase) args[3]=allow_rebase_merge=true ;; merge) args[5]=allow_merge_commit=true ;; esac
  done
  gh_out gh api -X PATCH "repos/${REPO}" "${args[@]}" > /dev/null || { fail_step "setting the merge methods failed"; return 1; }
}

# ------------------------------------------------------------ protection ----

checks_json() {          # contexts...
  local c out=""
  for c in "$@"; do
    [[ "$c" == local/* ]] && out+="{\"context\":\"$c\"}," || out+="{\"context\":\"$c\",\"integration_id\":${GITHUB_ACTIONS_APP}},"
  done
  echo "[${out%,}]"
}

ruleset() {              # name approvals strict(true|false|none) extra-rules-json checks...
  local name="$1" approvals="$2" strict="$3" extra="$4"; shift 4
  local rules="{\"type\":\"pull_request\",\"parameters\":{\"required_approving_review_count\":${approvals},\"dismiss_stale_reviews_on_push\":false,\"require_code_owner_review\":false,\"require_last_push_approval\":false,\"required_review_thread_resolution\":false}}"
  [[ "${strict}" != none ]] && rules+=",{\"type\":\"required_status_checks\",\"parameters\":{\"strict_required_status_checks_policy\":${strict},\"required_status_checks\":$(checks_json "$@")}}"
  [[ -n "${extra}" ]] && rules+=",${extra}"
  post_ruleset "${name}" <<EOF
{"name":"${name}","target":"branch","enforcement":"active",
 "conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[${rules}]}
EOF
}

# A POST that failed in a bad moment may have landed: check before trying again.
post_ruleset() {         # name; json on stdin
  local f="${WORK_ROW}/ruleset.json" try have
  cat > "$f"
  for try in 1 2 3; do
    logged gh api -X POST "repos/${REPO}/rulesets" --input "$f" && return 0
    transient_out || break
    sleep 20
    have="$(gh_out gh api "repos/${REPO}/rulesets" --jq ".[] | select(.name==\"$1\") | .id")" || break
    [[ -n "${have}" ]] && return 0
  done
  fail_step "creating ruleset '$1' failed: $(last_out | tail -1)"; return 1
}

apply_protection() {
  case "${PROTECT}" in
    none) ;;
    ours)
      # What onboard itself creates, created beforehand.
      local p excl="\"refs/heads/main\""
      for p in feature feat fix hotfix bugfix breaking chore docs refactor test ci build perf deps dependabot; do excl+=",\"refs/heads/${p}/**\""; done
      post_ruleset "branch naming" <<EOF || return 1
{"name":"branch naming","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~ALL"],"exclude":[${excl}]}},"rules":[{"type":"creation"}]}
EOF
      ruleset main 0 true '{"type":"non_fast_forward"},{"type":"required_linear_history"}' "ci / gate" "ci / branch-name" "local/ci" ;;
    pr-only) ruleset "org standard" 0 none "" ;;
    strict)  ruleset "org standard" 0 true "" "ci / gate" ;;
    foreign) ruleset "org standard" 1 true "" "ci / gate" "external/lint" ;;
    classic)
      cat > "${WORK_ROW}/classic.json" <<EOF
{"required_status_checks":{"strict":true,"checks":[{"context":"ci / gate","app_id":${GITHUB_ACTIONS_APP}}]},
 "enforce_admins":true,"required_pull_request_reviews":{"required_approving_review_count":1},"restrictions":null}
EOF
      gh_out gh api -X PUT "repos/${REPO}/branches/${BRANCH}/protection" --input "${WORK_ROW}/classic.json" > /dev/null \
        || { fail_step "setting classic protection failed"; return 1; } ;;
  esac
}

# The approval and the foreign check can't be satisfied by one account, so a
# row that tests getting past them lowers them, as an admin would.
relax_protection() {
  local id cur
  id="$(gh_out gh api "repos/${REPO}/rulesets" --jq '.[] | select(.name=="org standard") | .id')" || { fail_step "harness: can't read the rulesets"; return 1; }
  if [[ -n "${id}" ]]; then
    cur="$(gh_out gh api "repos/${REPO}/rulesets/${id}" --jq '{name,target,enforcement,conditions,rules}')" || { fail_step "harness: can't read ruleset ${id}"; return 1; }
    jq '(.rules[] | select(.type=="pull_request") | .parameters.required_approving_review_count) = 0
        | (.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks) |= map(select(.context != "external/lint"))' \
      <<< "${cur}" > "${WORK_ROW}/relaxed.json"
    gh_out gh api -X PUT "repos/${REPO}/rulesets/${id}" --input "${WORK_ROW}/relaxed.json" > /dev/null || { fail_step "harness: lowering ruleset ${id} failed"; return 1; }
  fi
  if gh_out gh api "repos/${REPO}/branches/${BRANCH}/protection" > /dev/null; then
    gh_out gh api -X PATCH "repos/${REPO}/branches/${BRANCH}/protection/required_pull_request_reviews" -F required_approving_review_count=0 > /dev/null \
      || { fail_step "harness: lowering classic protection failed"; return 1; }
  elif ! not_found; then
    fail_step "harness: can't read the classic protection"; return 1
  fi
  note "harness: lowered required approvals to 0 and dropped external/lint"
  sleep 20      # GitHub recomputes the PR's merge state in the background
}

# Someone else merges while the onboarding PR waits.
move_default_branch() {
  local id d="${WORK_ROW}/other"
  id="$(gh_out gh api "repos/${REPO}/rulesets" --jq '.[] | select(.name=="org standard") | .id')" && [[ -n "${id}" ]] \
    || { fail_step "harness: can't find the 'org standard' ruleset"; return 1; }
  gh_out gh api -X PUT "repos/${REPO}/rulesets/${id}" -f enforcement=disabled > /dev/null || { fail_step "harness: disabling the ruleset failed"; return 1; }
  [[ -d "$d" ]] || retried git clone -q "https://github.com/${REPO}.git" "$d" || { fail_step "harness: clone failed"; return 1; }
  retried git -C "$d" pull -q && echo "moved on" >> "$d/README.md" && git -C "$d" commit -qam "docs: someone else's change" >> "${LOG}" 2>&1 \
    && retried git -C "$d" push -q --no-verify origin "${BRANCH}" || { fail_step "harness: pushing someone else's change failed"; return 1; }
  gh_out gh api -X PUT "repos/${REPO}/rulesets/${id}" -f enforcement=active > /dev/null || { fail_step "harness: re-enabling the ruleset failed"; return 1; }
  note "harness: pushed a commit to ${BRANCH} while the onboarding PR waited"
}

# The onboarding PR was closed and the local branch removed; apply runs again.
abandon_onboarding_pr() {
  local pr; pr="$(onboard_pr)" && [[ -n "${pr}" ]] || { fail_step "harness: can't find the onboarding PR"; return 1; }
  gh_out gh pr close -R "${REPO}" "${pr}" > /dev/null || { fail_step "harness: closing PR #${pr} failed"; return 1; }
  git branch -D chore/onboard-ci > /dev/null 2>&1
  note "harness: closed PR #${pr} and deleted the local branch; re-running apply from scratch"
  RERUN_FROM_SCRATCH=true
}

push_stray_onboard_branch() {
  {
    git switch -q -c chore/onboard-ci && echo "unrelated" > STRAY.md && git add STRAY.md && git commit -qm "unrelated work"
  } >> "${LOG}" 2>&1 || { fail "harness: committing the stray branch failed"; return 1; }
  retried git push -q --no-verify origin chore/onboard-ci || { fail_step "harness: pushing the stray branch failed"; return 1; }
  { git switch -q "${BRANCH}" && git branch -q -D chore/onboard-ci; } >> "${LOG}" 2>&1
  note "harness: pushed an unrelated chore/onboard-ci branch"
}

seed_conflicting_files() {
  mkdir -p .github/workflows
  printf 'name: Pull request\non:\n  pull_request:\njobs:\n  ci:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo existing\n' > .github/workflows/trigger-pull-request.yml
  printf '<Project>\n  <PropertyGroup>\n    <LangVersion>latest</LangVersion>\n  </PropertyGroup>\n</Project>\n' > Directory.Build.props
}

crlf_clone_runs_gate() {
  local d="${WORK_ROW}/crlf"
  rm -rf "$d"
  retried git -c core.autocrlf=true clone -q "https://github.com/${REPO}.git" "$d" || { fail_step "autocrlf clone failed"; return 1; }
  local f bad=0
  for f in bin/ci bin/signoff .githooks/pre-push; do grep -q $'\r' "$d/$f" && { fail "$f has CRLF in an autocrlf clone"; bad=1; }; done
  [[ "${bad}" == 0 ]] && pass "gate files are LF in an autocrlf=true clone"
  # A fresh clone has no node_modules: install first, as a developer would.
  (cd "$d" && retried bash bin/ci --install --quick) && pass "bin/ci --install --quick runs in the autocrlf clone" || fail_step "bin/ci --install --quick failed in the autocrlf clone"
}

# ------------------------------------------------------------ developer ----

# What a developer has: a venv with the python tools and each component's
# dependencies, node_modules. Set up by hand, the way a developer would, so a
# bin/ci --install bug is reported (next) without hiding everything after it.
dev_setup() {
  local venv="${WORK_ROW}/venv" d rt
  [[ -d "${venv}" ]] || python -m venv "${venv}" >> "${LOG}" 2>&1
  if [[ -d "${venv}/Scripts" ]]; then PATH="${venv}/Scripts:${PATH}"; else PATH="${venv}/bin:${PATH}"; fi
  export PATH VIRTUAL_ENV="${venv}"
  retried python -m pip install --quiet ruff pytest || fail_step "developer setup: installing ruff and pytest failed"
  while IFS=' ' read -r rt d; do
    case "${rt}" in
      python)
        if [[ -f "$d/requirements.txt" ]]; then retried python -m pip install --quiet -r "$d/requirements.txt"
        else retried python -m pip install --quiet -e "${d}[dev]"; fi ;;
      node) retried npm ci --prefix "$d" --silent --no-audit --no-fund ;;
    esac || fail_step "developer setup: installing ${d} (${rt}) failed"
  done < <(yq '.components[] | .runtime + " " + (.path // ".")' .github/components.yml)
  pass "developer setup (venv with ruff and pytest; each component's dependencies)"
  retried bash bin/ci --install && pass "bin/ci --install" || fail_step "bin/ci --install: $(last_out | grep -iE 'error|✗' | head -2 | tr '\n' ' ')"
}

# ------------------------------------------------------------ expectations ----

expected_manifest() {    # prints "name runtime target path" per part
  local part name="${REPO#*/}"
  for part in ${SEED}; do
    case "${part}" in
      dotnet-api)   echo "api dotnet app-service ." ;;
      dotnet-func)  echo "func dotnet function ." ;;
      dotnet-lib)   echo "contracts dotnet package ." ;;
      node-web)     echo "web node app-service src/web" ;;
      node-pkg)     echo "ciw-sbx-pkg node package ." ;;     # from package.json
      py-func)      echo "${name} python function ." ;;
      py-pkg)       echo "sdk python package src/sdk" ;;
      py-container) echo "worker python container src/worker" ;;
    esac
  done | sort
}

check_manifest() {
  local got want
  want="$(expected_manifest)"
  got="$(yq '.components[] | .name + " " + .runtime + " " + .target + " " + (.path // ".")' .github/components.yml | sort)"
  if [[ "${got}" == "${want}" ]]; then pass "manifest scaffolded as expected: $(tr '\n' ';' <<< "${got}")"
  else fail "manifest: got [$(tr '\n' ';' <<< "${got}")] want [$(tr '\n' ';' <<< "${want}")]"; fi
}

# ------------------------------------------------------------ onboarding ----

run_onboard() {          # args...
  local flags=()
  [[ "${DEPLOY}" == true ]] || flags+=(--no-deploy-to-test)
  # v1's onboard has no --ref; it always writes @v1.
  [[ "${CIW_REF}" == v1 ]] || flags+=(--ref "${CIW_REF}")
  logged bash "${ONBOARD}" "$@" "${flags[@]}"
}

# stop_at: the row passes only if onboard stopped, and said this.
stopped_as_expected() {
  if [[ -n "${stop_at:-}" ]]; then
    if last_out | grep -qiE "${stop_at}"; then pass "onboard stopped, saying: $(last_out | grep -iE "${stop_at}" | head -1)"
    else fail "onboard stopped, but not with /${stop_at}/: $(last_out | tail -1)"; fi
    return 0
  fi
  return 1
}

# Why onboard stopped, on one line: its ✗ lines, else its last words. Its
# last lines are a summary ("1 problem(s).") under the ✓ lines.
stop_reason() {
  local why; why="$(last_out | grep '✗')"
  [[ -n "${why}" ]] || why="$(last_out | tail -3)"
  tr '\n' ' ' <<< "${why}"
}

# onboard's own failure is a FAIL, unless all it reports is GitHub reads it
# couldn't make after retrying.
onboard_failed() {
  local problems; problems="$(last_out | grep -E '✗|^can.t ')"
  if [[ -n "${problems}" ]]; then
    if grep -qvE "couldn.t (read|list)|can.t (read|fetch)" <<< "${problems}"; then fail "$*"; else infra "$*"; fi
  # It stopped without a list of problems: on GitHub if that's what its last words say.
  elif last_out | tail -5 | is_transient; then infra "$*"
  else fail "$*"; fi
}

# The open onboarding PR's number, or nothing; fails if GitHub can't say.
onboard_pr() { gh_out gh pr list -R "${REPO}" --head chore/onboard-ci --state open --json number --jq '.[0].number // empty'; }

checks_settled() {       # pr — the gate's three checks have all reported, none pending
  local s head name
  # Right after a push the PR can still point at the commit before it, whose
  # checks are done: wait until it points at what origin has.
  read -r head name <<< "$(gh pr view "$1" -R "${REPO}" --json headRefOid,headRefName --jq '"\(.headRefOid) \(.headRefName)"' 2> /dev/null)"
  [[ -n "${head}" && "${head}" == "$(git ls-remote origin "refs/heads/${name}" 2> /dev/null | cut -f1)" ]] || return 1
  # bucket sorts every state, queued and waiting ones included, into pending
  # or a result; state alone let a gate that hadn't started count as done.
  s="$(gh pr checks "$1" -R "${REPO}" --json name,bucket 2> /dev/null)" || [[ -n "$s" ]] || return 1
  jq -e '(["ci / gate", "ci / branch-name", "local/ci"] - [.[].name] | length == 0)
         and all(.[]; .bucket != "pending")' <<< "$s" > /dev/null
}

onboard_repo() {
  log "onboard init"
  if ! run_onboard init; then
    stopped_as_expected && return 2
    fail "onboard init failed: $(last_out | tail -1)"; return 1
  fi
  check_manifest
  sed -i 's/   # onboard: check this//' .github/components.yml
  dev_setup

  local pass_no
  for pass_no in 1 2 3; do
    log "onboard apply (pass ${pass_no})"
    if ! run_onboard apply; then
      stopped_as_expected && return 2
      onboard_failed "onboard apply failed: $(stop_reason)"; return 1
    fi
    local pr; pr="$(onboard_pr)" || { fail_step "can't list the open PRs"; return 1; }
    [[ -z "${pr}" ]] && break                 # direct push, or merged: done
    note "onboarding PR #${pr} open"
    wait_for 900 "checks on PR #${pr}" checks_settled "${pr}" || return 1
    note "checks: $(gh pr checks "${pr}" -R "${REPO}" --json name,state --jq 'map(.name + "=" + .state) | join(", ")')"
    if [[ "${pass_no}" == 1 ]] && declare -F between > /dev/null; then
      RERUN_FROM_SCRATCH=false; between || return 1
      if [[ "${RERUN_FROM_SCRATCH}" == true ]]; then continue; fi
      [[ "${PROTECT}" == strict ]] && { sleep 15; wait_for 900 "checks on PR #${pr}" checks_settled "${pr}" || return 1; }
    fi
  done
  pr="$(onboard_pr)" || { fail_step "can't list the open PRs"; return 1; }
  [[ -z "${pr}" ]] || { fail "onboarding PR still open after 3 passes"; return 1; }
  if [[ -n "${stop_at:-}" ]]; then fail "onboard was expected to stop with /${stop_at}/ but completed"; return 1; fi

  log "onboard check"
  if run_onboard check; then pass "onboard check: $(last_out | tail -1)"; else onboard_failed "onboard check: $(last_out | grep '✗' | tr '\n' ' ')"; return 1; fi
  git switch -q "${BRANCH}" && retried git pull -q --ff-only || { fail_step "pulling ${BRANCH} failed"; return 1; }

  # What onboarding put on the default branch.
  note "onboarding commit: $(git log --oneline -1)"
  if [[ -n "${TAGS}" ]]; then
    local tags; tags="$(gh_out git ls-remote --tags origin)" || { fail_step "can't list origin's tags"; return 1; }
    grep -q 'refs/tags/v0.1.0' <<< "${tags}" && fail "v0.1.0 created although ${TAGS} existed" || pass "no v0.1.0: existing tags kept"
  fi
  if [[ "${DEPLOY}" == true ]]; then
    # A run may exist for the onboarding commit; its deploy job must not have run.
    sleep 20
    local sha runs ran n; sha="$(git rev-parse HEAD)"
    runs="$(gh_out gh run list -R "${REPO}" --workflow trigger-merge-to-main.yml --json databaseId,headSha --jq "[.[] | select(.headSha==\"${sha}\") | .databaseId] | .[]")" \
      || { fail_step "can't list the merge-trigger runs"; return 1; }
    ran=0
    for r in ${runs}; do
      wait_for 300 "deploy run ${r} to finish" run_done "${r}"
      n="$(gh_out gh run view "${r}" -R "${REPO}" --json jobs --jq '[.jobs[] | select(.conclusion != "skipped")] | length')" \
        || { fail_step "can't read run ${r}'s jobs"; return 1; }
      ran=$(( ran + n ))
    done
    [[ "${ran}" == 0 ]] && pass "onboarding commit deployed nothing ($(wc -w <<< "${runs}" | tr -d ' ') merge-trigger run(s), every job skipped)"       || fail "onboarding commit ran ${ran} deploy job(s): $(for r in ${runs}; do echo "https://github.com/${REPO}/actions/runs/${r}"; done)"
  fi
  if declare -F after_onboard > /dev/null; then after_onboard; fi
  return 0
}

# ------------------------------------------------------------ feature PR ----

feature_pr() {
  log "feature PR through the gate"
  git switch -q -c feature/sandbox-change
  echo "change $(date +%s)" >> README.md
  git commit -qam "feature: sandbox change"
  retried git push -q -u origin feature/sandbox-change || { fail_step "push of feature branch refused: $(last_out | tail -2 | tr '\n' ' ')"; return 1; }
  logged gh pr create -R "${REPO}" --base "${BRANCH}" --head feature/sandbox-change --title "feature: sandbox change" --body "tests/onboard" \
    || { fail_step "opening the feature PR failed: $(last_out | tail -1)"; return 1; }
  local pr; pr="$(last_out | grep -o '/pull/[0-9]*$' | grep -o '[0-9]*')"
  wait_for 900 "checks on PR #${pr}" checks_settled "${pr}" || return 1
  local checks states
  checks="$(gh_out gh pr checks "${pr}" -R "${REPO}" --json name,state)" || { fail_step "can't read PR #${pr}'s checks"; return 1; }
  states="$(jq -r 'map(.name + "=" + .state) | join(", ")' <<< "${checks}")"
  if jq -e 'all(.[]; .state=="SUCCESS" or .state=="SKIPPED")' <<< "${checks}" > /dev/null \
     && grep -q 'local/ci=SUCCESS' <<< "${states}" && grep -q 'gate=SUCCESS' <<< "${states}"; then
    pass "feature PR #${pr} checks: ${states}"
  else
    fail "feature PR #${pr} checks: ${states}"; return 1
  fi
  local method
  for method in squash rebase merge; do [[ " ${MERGES} " == *" ${method} "* ]] && break; done
  logged gh pr merge "${pr}" -R "${REPO}" "--${method}" --delete-branch || { fail_step "merging feature PR failed: $(last_out | tail -1)"; return 1; }
  # Release the merge itself: right after merging, origin can still show the
  # branch without it.
  wait_for 120 "PR #${pr}'s merge commit" bash -c "[[ -n \"\$(gh pr view ${pr} -R '${REPO}' --json mergeCommit --jq '.mergeCommit.oid // empty')\" ]]" || return 1
  RELEASE_SHA="$(gh_out gh pr view "${pr}" -R "${REPO}" --json mergeCommit --jq .mergeCommit.oid)" || { fail_step "can't read PR #${pr}'s merge commit"; return 1; }
  # Logged, so a timeout says whether the fetch failed or origin lacked the merge.
  local end=$(( $(date +%s) + 300 ))
  until logged git fetch -q origin "${BRANCH}" && git merge-base --is-ancestor "${RELEASE_SHA}" "origin/${BRANCH}"; do
    if (( $(date +%s) >= end )); then
      fail_step "merge ${RELEASE_SHA:0:7} not on origin/${BRANCH} after 300s (origin/${BRANCH} is at $(git rev-parse --short "origin/${BRANCH}"))"; return 1
    fi
    sleep 10
  done
  git switch -q "${BRANCH}" && git merge -q --ff-only "origin/${BRANCH}"
  pass "feature PR merged by ${method}: $(git log --oneline -1 "${RELEASE_SHA}")"
}

# ------------------------------------------------------------ release ----

run_status() { gh_out gh run view "$1" -R "${REPO}" --json status --jq .status; }
run_done()   { [[ "$(run_status "$1")" == completed ]]; }
run_waiting_on() {       # run env — true once a deployment to env waits on review
  gh api "repos/${REPO}/actions/runs/$1/pending_deployments" --jq ".[].environment.name" 2> /dev/null | grep -qx "$2"
}
# Jobs of a called workflow are named "<caller job> / <job>"; match on <job>.
# Fails if GitHub can't say.
job_conclusion() {
  local c; c="$(gh_out gh run view "$1" -R "${REPO}" --json jobs --jq ".jobs[] | select(.name | sub(\"^ci / \"; \"\") | test(\"$2\")) | .conclusion")" || return 1
  sort -u <<< "${c}" | grep -v '^$' | paste -sd, -
}

release() {
  log "release"
  # Hold production so promote never delivers anything from a sandbox.
  local me; me="$(gh_out gh api user --jq .id)" || { fail_step "can't read the gh user"; return 1; }
  printf '{"reviewers":[{"type":"User","id":%s}]}' "${me}" > "${WORK_ROW}/production.json"
  gh_out gh api -X PUT "repos/${REPO}/environments/production" --input "${WORK_ROW}/production.json" > /dev/null \
    || note "production can't hold for review here (plan or visibility); promote will run and fail at azure/login"
  local before; before="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  logged gh workflow run trigger-release.yml -R "${REPO}" --ref "${BRANCH}" -f sha="${RELEASE_SHA}" || { fail_step "dispatching the release failed: $(last_out | tail -1)"; return 1; }
  local run=""
  wait_for 120 "the release run to appear" bash -c "[[ -n \"\$(gh run list -R '${REPO}' --workflow trigger-release.yml --created '>=${before}' --json databaseId --jq '.[0].databaseId')\" ]]" || return 1
  run="$(gh_out gh run list -R "${REPO}" --workflow trigger-release.yml --created ">=${before}" --json databaseId --jq '.[0].databaseId')" \
    || { fail_step "can't list the release runs"; return 1; }
  RELEASE_RUN="https://github.com/${REPO}/actions/runs/${run}"
  note "release run ${RELEASE_RUN}"

  # Approve the release gate (where the plan offers one).
  local end=$(( $(date +%s) + 600 )) approved=false
  while (( $(date +%s) < end )) && ! run_done "${run}"; do
    if run_waiting_on "${run}" release; then
      local ids; ids="$(gh api "repos/${REPO}/actions/runs/${run}/pending_deployments" --jq '[.[] | select(.environment.name=="release") | .environment.id]')"
      jq -n --argjson ids "${ids}" '{environment_ids: $ids, state: "approved", comment: "tests/onboard"}' \
        | gh api -X POST "repos/${REPO}/actions/runs/${run}/pending_deployments" --input - > /dev/null && approved=true && break
    fi
    [[ "$(job_conclusion "${run}" '^build')" =~ success|failure ]] && break   # no gate on this plan
    sleep 10
  done
  [[ "${approved}" == true ]] && pass "release gate approved" || note "release gate never waited for approval"

  # Wait for publish (or the build failure), then turn production away.
  end=$(( $(date +%s) + 1500 ))
  while (( $(date +%s) < end )) && ! run_done "${run}"; do
    if run_waiting_on "${run}" production; then
      local ids; ids="$(gh api "repos/${REPO}/actions/runs/${run}/pending_deployments" --jq '[.[] | .environment.id]')"
      jq -n --argjson ids "${ids}" '{environment_ids: $ids, state: "rejected", comment: "tests/onboard: sandbox, not delivered"}' \
        | gh api -X POST "repos/${REPO}/actions/runs/${run}/pending_deployments" --input - > /dev/null
    fi
    sleep 15
  done
  local st; st="$(run_status "${run}")" || { fail_step "can't read the release run's status"; return 1; }
  [[ "${st}" == completed ]] || { fail "release run didn't finish"; return 1; }
  note "jobs: $(gh run view "${run}" -R "${REPO}" --json jobs --jq '.jobs | map(.name + "=" + .conclusion) | join(", ")')"

  if [[ "${RELEASE}" == build-fails:* ]]; then
    local c="${RELEASE#build-fails:}" step
    step="$(gh_out gh run view "${run}" -R "${REPO}" --json jobs --jq ".jobs[] | select(.name==\"ci / build ${c}\") | .steps[] | select(.conclusion==\"failure\") | .name")" \
      || { fail_step "can't read the release run's steps"; return 1; }
    [[ "${step}" == *azure/login* ]] && pass "build ${c} stopped at azure/login (no Azure in a sandbox), as expected" \
      || fail "build ${c}: expected failure at azure/login, got '${step:-no failure}'"
    return 0
  fi

  local c
  c="$(job_conclusion "${run}" '^build')" || { fail_step "can't read the release run's jobs"; return 1; }
  [[ "${c}" == success ]] && pass "build jobs succeeded" || { fail "build jobs: ${c:-no conclusion}"; return 1; }
  c="$(job_conclusion "${run}" '^tag and draft')" || { fail_step "can't read the release run's jobs"; return 1; }
  [[ "${c}" == success ]] && pass "draft release published" || { fail "publish: ${c:-no conclusion}"; return 1; }
  check_assets
}

check_assets() {
  local v="${VERSION}" d="${WORK_ROW}/assets" n rt tg pid art
  rm -rf "$d"; mkdir -p "$d"
  retried gh release download "v${v}" -R "${REPO}" -D "$d" --clobber || { fail_step "no release v${v}: $(last_out | tail -1)"; return 1; }
  note "assets: $(ls "$d" | tr '\n' ' ')"
  (cd "$d" && sha256sum -c SHA256SUMS > /dev/null 2>&1) && pass "SHA256SUMS matches every asset" || fail "SHA256SUMS mismatch"
  while IFS=' ' read -r n rt tg; do
    case "${tg}" in
      package)
        case "${rt}" in
          dotnet) pid="$(grep -o '<PackageId>[^<]*' "$(yq ".components[] | select(.name==\"${n}\") | .project" .github/components.yml)" | sed 's/.*>//')"; art="${pid}.${v}.nupkg" ;;
          node)   art="$(jq -r '.name' "$(yq ".components[] | select(.name==\"${n}\") | (.path // \".\")" .github/components.yml)/package.json" | sed 's/^@//; s#/#-#')-${v}.tgz" ;;
          # The wheel's name comes from pyproject.toml, read here in the clone before looking in $d.
          python) pid="$(grep -o '^name = "[^"]*' "$(yq ".components[] | select(.name==\"${n}\") | (.path // \".\")" .github/components.yml)/pyproject.toml" | sed 's/.*"//; s/-/_/g')"
                  art="$(cd "$d" && printf '%s\n' *.whl | grep -iE "^${pid}-${v}-")" ;;
        esac ;;
      *) art="${n}-${v}.zip" ;;
    esac
    if [[ -n "${art}" && -f "$d/${art}" ]]; then pass "${n}: ${art}"; else fail "${n}: expected artifact ${art:-?} not in the release"; continue; fi
    if [[ "${VIS}" == private ]]; then
      # Keyless cosign would publish a private repo's name to Sigstore's log.
      [[ -f "$d/${art}.cosign.bundle" ]] && fail "${n}: a private repo's asset was signed to the public log" || pass "${n}: no cosign bundle (private repo)"
    else
      [[ -f "$d/${art}.cosign.bundle" ]] && pass "${n}: cosign bundle" || fail "${n}: no ${art}.cosign.bundle"
    fi
    local root; root="$(jq -r '.metadata.component | "\(.name)@\(.version)"' "$d/${n}-${v}.cdx.json" 2> /dev/null)"
    [[ "${root}" == *"@${v}" ]] && pass "${n}: SBOM root ${root}" || fail "${n}: SBOM root '${root:-missing}'"
    if retried gh attestation verify "$d/${art}" -R "${REPO}" --signer-repo "${CIW_REPO}"; then pass "${n}: attestation verifies"
    elif [[ "${VIS}" == private ]]; then note "${n}: no attestation (private repo; GitHub offers them there only with Enterprise Cloud)"
    else fail_step "${n}: attestation: $(last_out | grep -iE 'error|fail' | head -1)"; fi
  done < <(yq '.components[] | .name + " " + .runtime + " " + .target' .github/components.yml)
}

# ------------------------------------------------------------ one row ----

# Two pools shared by every row (GitHub limits how fast an account may create
# repos): POOL public sandboxes, ${OWNER}/ciw-sbx-01.., and PRIVATE_POOL
# private ones, ${OWNER}/ciw-sbx-p01... A row takes the first free one of its
# visibility; mkdir is the lock, so several `run`s can go at once.
claim_sandbox() {
  local i slot n=${POOL:-10} prefix="" end=$(( $(date +%s) + 7200 ))
  [[ "${VIS}" == private ]] && { n=${PRIVATE_POOL:-2}; prefix=p; }
  while (( $(date +%s) < end )); do
    for (( i = 1; i <= n; i++ )); do
      slot="${prefix}$(printf '%02d' "$i")"
      if mkdir "${LOCKS}/slot-${slot}.lock" 2> /dev/null; then
        SLOT_LOCK="${LOCKS}/slot-${slot}.lock"; REPO="${OWNER}/ciw-sbx-${slot}"
        echo "${ROW} $$" > "${SLOT_LOCK}/owner"
        trap 'rm -rf "${SLOT_LOCK}"' EXIT
        return 0
      fi
    done
    sleep 20
  done
  echo "no free sandbox after 2h" >&2; return 1
}

run_row() {
  local ROW="$1"
  # Defaults, then the row.
  SEED=""; BRANCH=main; VIS=public; MERGES="squash rebase merge"; PROTECT=none; TAGS=""; DEPLOY=false
  VERSION=0.2.0; RELEASE=full; stop_at=""; RELEASE_RUN=""; RELEASE_SHA=""
  unset -f pre_seed pre_clone between after_onboard
  "row_${ROW}"
  local slug; slug="$(tr 'A-Z' 'a-z' <<< "${ROW}")"
  claim_sandbox || return 1
  CIW_REPO="Haam909/ci-workflows"
  WORK_ROW="${WORK}/${slug}"; rm -rf "${WORK_ROW}"; mkdir -p "${WORK_ROW}"
  LOG="${WORK_ROW}/log.txt"; : > "${LOG}"; ROW_OK=true; ROW_FAILED=false
  local started; started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log "row ${ROW}: seed [${SEED}] branch=${BRANCH} vis=${VIS} merges=[${MERGES}] protect=${PROTECT} tags=[${TAGS}] deploy=${DEPLOY}"
  note "repo https://github.com/${REPO}, onboard from ${ONBOARD} ($(git -C "${CIW_UNDER_TEST}" rev-parse --short HEAD)), triggers @${CIW_REF}"

  local rc=0
  (
    # Setup is all GitHub calls; a row-specific refusal (visibility) is a fail of its own.
    ensure_repo && reset_repo || { [[ "${ROW_FAILED}" == true ]] || infra "sandbox setup failed"; exit_row; }
    push_seed || exit_row
    apply_protection || exit_row
    retried git clone -q "https://github.com/${REPO}.git" "${WORK_ROW}/repo" || { fail_step "clone failed: $(last_out | tail -1)"; exit_row; }
    cd "${WORK_ROW}/repo" || exit 1
    if declare -F pre_clone > /dev/null; then pre_clone || exit_row; fi
    onboard_repo; rc=$?
    [[ "${rc}" == 2 ]] && exit_row   # stopped where the row expects
    # Carry on after a ✗ so one row reports everything it hits; the row fails at the end.
    [[ "${rc}" == 0 ]] || exit_row
    feature_pr || exit_row
    release || exit_row
    exit_row
  ); rc=$?

  {
    echo "## ${ROW} — $(case ${rc} in 0) echo PASS ;; 3) echo INFRA ;; *) echo FAIL ;; esac)"
    echo
    echo "Started ${started}. Sandbox https://github.com/${REPO}. ci-workflows under test: $(git -C "${CIW_UNDER_TEST}" rev-parse --short HEAD), triggers @${CIW_REF}."
    echo
    echo '```'
    grep -E '^(▶|» )' "${LOG}"
    echo '```'
  } > "${RESULTS}/${ROW}.md"
  rm -rf "${SLOT_LOCK}"
  return ${rc}
}
