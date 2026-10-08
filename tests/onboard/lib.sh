# tests/onboard/lib.sh — sandbox handling and assertions. Sourced by run.

GITHUB_ACTIONS_APP=15368

# ------------------------------------------------------------ logging ----

# Harness lines start with ▶ or »; everything else in the log is the output
# of the commands run.
log()  { printf '%s\n' "▶ $*" | tee -a "${LOG}"; }
note() { printf '%s\n' "» · $*" | tee -a "${LOG}"; }
pass() { printf '%s\n' "» ✓ $*" | tee -a "${LOG}"; }
fail() { printf '%s\n' "» ✗ $*" | tee -a "${LOG}"; ROW_OK=false; }
# Run a command, keep its output in the log, return its status.
logged() { local rc; { "$@"; } > "${WORK_ROW}/last.out" 2>&1; rc=$?; sed 's/\x1b\[[0-9;]*m//g' "${WORK_ROW}/last.out" >> "${LOG}"; return ${rc}; }
last_out() { sed 's/\x1b\[[0-9;]*m//g' "${WORK_ROW}/last.out"; }

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
  gh repo create "${REPO}" --public --description "ci-workflows onboarding sandbox (tests/onboard); reset on every run" > /dev/null
}

# Back to nothing: no protection, environments, releases, tags, PRs or extra
# branches. The seed is force-pushed afterwards.
reset_repo() {
  local id b
  for id in $(gh api "repos/${REPO}/rulesets" --jq '.[].id'); do gh api -X DELETE "repos/${REPO}/rulesets/${id}" > /dev/null; done
  for b in $(gh api "repos/${REPO}/branches?per_page=100" --jq '.[] | select(.protected) | .name' 2> /dev/null); do
    gh api -X DELETE "repos/${REPO}/branches/${b}/protection" > /dev/null 2>&1
  done
  for id in $(gh api "repos/${REPO}/environments" --jq '.environments[].name' 2> /dev/null); do gh api -X DELETE "repos/${REPO}/environments/${id}" > /dev/null; done
  for id in $(gh api "repos/${REPO}/releases?per_page=100" --jq '.[].id'); do gh api -X DELETE "repos/${REPO}/releases/${id}" > /dev/null; done
  for id in $(gh api "repos/${REPO}/git/matching-refs/tags" --jq '.[].ref' 2> /dev/null); do gh api -X DELETE "repos/${REPO}/git/${id}" > /dev/null; done
  for id in $(gh pr list -R "${REPO}" --state open --json number --jq '.[].number'); do gh pr close -R "${REPO}" "${id}" > /dev/null; done
  gh api -X PATCH "repos/${REPO}" -F allow_squash_merge=true -F allow_rebase_merge=true -F allow_merge_commit=true \
    -F delete_branch_on_merge=false > /dev/null
  if [[ "$(gh api "repos/${REPO}" --jq .visibility)" != public ]]; then
    gh repo edit "${REPO}" --visibility public --accept-visibility-change-consequences > /dev/null
  fi
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
    git push -q --force origin "${BRANCH}" && { [[ -z "${TAGS}" ]] || git push -q --force origin --tags; }
  ) >> "${LOG}" 2>&1 || { fail "pushing the seed failed"; return 1; }
  gh api -X PATCH "repos/${REPO}" -f default_branch="${BRANCH}" > /dev/null
  for b in $(gh api "repos/${REPO}/branches?per_page=100" --jq '.[].name'); do
    [[ "$b" == "${BRANCH}" ]] || gh api -X DELETE "repos/${REPO}/git/refs/heads/${b}" > /dev/null
  done
  if [[ "${VIS}" == private ]]; then
    gh repo edit "${REPO}" --visibility private --accept-visibility-change-consequences > /dev/null
  fi
  local m args=(-F allow_squash_merge=false -F allow_rebase_merge=false -F allow_merge_commit=false)
  for m in ${MERGES}; do
    case "$m" in squash) args[1]=allow_squash_merge=true ;; rebase) args[3]=allow_rebase_merge=true ;; merge) args[5]=allow_merge_commit=true ;; esac
  done
  gh api -X PATCH "repos/${REPO}" "${args[@]}" > /dev/null
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
  gh api -X POST "repos/${REPO}/rulesets" --input - > /dev/null <<EOF
{"name":"${name}","target":"branch","enforcement":"active",
 "conditions":{"ref_name":{"include":["~DEFAULT_BRANCH"],"exclude":[]}},"rules":[${rules}]}
EOF
}

apply_protection() {
  case "${PROTECT}" in
    none) ;;
    ours)
      # What onboard itself creates, created beforehand.
      local p excl="\"refs/heads/main\""
      for p in feature feat fix hotfix bugfix breaking chore docs refactor test ci build perf deps dependabot; do excl+=",\"refs/heads/${p}/**\""; done
      gh api -X POST "repos/${REPO}/rulesets" --input - > /dev/null <<EOF
{"name":"branch naming","target":"branch","enforcement":"active","conditions":{"ref_name":{"include":["~ALL"],"exclude":[${excl}]}},"rules":[{"type":"creation"}]}
EOF
      ruleset main 0 true '{"type":"non_fast_forward"},{"type":"required_linear_history"}' "ci / gate" "ci / branch-name" "local/ci" ;;
    pr-only) ruleset "org standard" 0 none "" ;;
    strict)  ruleset "org standard" 0 true "" "ci / gate" ;;
    foreign) ruleset "org standard" 1 true "" "ci / gate" "external/lint" ;;
    classic)
      gh api -X PUT "repos/${REPO}/branches/${BRANCH}/protection" --input - > /dev/null <<EOF
{"required_status_checks":{"strict":true,"checks":[{"context":"ci / gate","app_id":${GITHUB_ACTIONS_APP}}]},
 "enforce_admins":true,"required_pull_request_reviews":{"required_approving_review_count":1},"restrictions":null}
EOF
      ;;
  esac
}

# The approval and the foreign check can't be satisfied by one account, so a
# row that tests getting past them lowers them, as an admin would.
relax_protection() {
  local id
  id="$(gh api "repos/${REPO}/rulesets" --jq '.[] | select(.name=="org standard") | .id')"
  if [[ -n "${id}" ]]; then
    gh api "repos/${REPO}/rulesets/${id}" --jq '{name,target,enforcement,conditions,rules}' \
      | jq '(.rules[] | select(.type=="pull_request") | .parameters.required_approving_review_count) = 0
            | (.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks) |= map(select(.context != "external/lint"))' \
      | gh api -X PUT "repos/${REPO}/rulesets/${id}" --input - > /dev/null
  fi
  if gh api "repos/${REPO}/branches/${BRANCH}/protection" > /dev/null 2>&1; then
    gh api -X PATCH "repos/${REPO}/branches/${BRANCH}/protection/required_pull_request_reviews" -F required_approving_review_count=0 > /dev/null
  fi
  note "harness: lowered required approvals to 0 and dropped external/lint"
  sleep 20      # GitHub recomputes the PR's merge state in the background
}

# Someone else merges while the onboarding PR waits.
move_default_branch() {
  local id
  id="$(gh api "repos/${REPO}/rulesets" --jq '.[] | select(.name=="org standard") | .id')"
  gh api -X PUT "repos/${REPO}/rulesets/${id}" -f enforcement=disabled > /dev/null
  (
    cd "${WORK_ROW}/other" 2> /dev/null || { git clone -q "https://github.com/${REPO}.git" "${WORK_ROW}/other" && cd "${WORK_ROW}/other"; } || exit 1
    git pull -q && echo "moved on" >> README.md && git commit -qam "docs: someone else's change" && git push -q --no-verify origin "${BRANCH}"
  ) >> "${LOG}" 2>&1
  gh api -X PUT "repos/${REPO}/rulesets/${id}" -f enforcement=active > /dev/null
  note "harness: pushed a commit to ${BRANCH} while the onboarding PR waited"
}

# The onboarding PR was closed and the local branch removed; apply runs again.
abandon_onboarding_pr() {
  local pr; pr="$(gh pr list -R "${REPO}" --head chore/onboard-ci --json number --jq '.[0].number')"
  gh pr close -R "${REPO}" "${pr}" > /dev/null
  git branch -D chore/onboard-ci > /dev/null 2>&1
  note "harness: closed PR #${pr} and deleted the local branch; re-running apply from scratch"
  RERUN_FROM_SCRATCH=true
}

push_stray_onboard_branch() {
  (
    git switch -q -c chore/onboard-ci && echo "unrelated" > STRAY.md && git add STRAY.md && git commit -qm "unrelated work" \
      && git push -q --no-verify origin chore/onboard-ci && git switch -q "${BRANCH}" && git branch -q -D chore/onboard-ci
  ) >> "${LOG}" 2>&1
  note "harness: pushed an unrelated chore/onboard-ci branch"
}

seed_conflicting_files() {
  mkdir -p .github/workflows
  printf 'name: Pull request\non:\n  pull_request:\njobs:\n  ci:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo existing\n' > .github/workflows/trigger-pull-request.yml
  printf '<Project>\n  <PropertyGroup>\n    <LangVersion>latest</LangVersion>\n  </PropertyGroup>\n</Project>\n' > Directory.Build.props
}

crlf_clone_runs_gate() {
  local d="${WORK_ROW}/crlf"
  rm -rf "$d"; git -c core.autocrlf=true clone -q "https://github.com/${REPO}.git" "$d" >> "${LOG}" 2>&1
  local f bad=0
  for f in bin/ci bin/signoff .githooks/pre-push; do grep -q $'\r' "$d/$f" && { fail "$f has CRLF in an autocrlf clone"; bad=1; }; done
  [[ "${bad}" == 0 ]] && pass "gate files are LF in an autocrlf=true clone"
  # A fresh clone has no node_modules: install first, as a developer would.
  (cd "$d" && logged bash bin/ci --install --quick) && pass "bin/ci --install --quick runs in the autocrlf clone" || fail "bin/ci --install --quick failed in the autocrlf clone"
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
  python -m pip install --quiet ruff pytest >> "${LOG}" 2>&1
  while IFS=' ' read -r rt d; do
    case "${rt}" in
      python)
        if [[ -f "$d/requirements.txt" ]]; then python -m pip install --quiet -r "$d/requirements.txt"
        else python -m pip install --quiet -e "$d[dev]"; fi ;;
      node) (cd "$d" && npm ci --silent --no-audit --no-fund) ;;
    esac >> "${LOG}" 2>&1 || fail "developer setup: installing ${d} (${rt}) failed"
  done < <(yq '.components[] | .runtime + " " + (.path // ".")' .github/components.yml)
  pass "developer setup (venv with ruff and pytest; each component's dependencies)"
  logged bash bin/ci --install && pass "bin/ci --install" || fail "bin/ci --install: $(last_out | grep -iE 'error|✗' | head -2 | tr '\n' ' ')"
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

onboard_pr() { gh pr list -R "${REPO}" --head chore/onboard-ci --state open --json number --jq '.[0].number // empty'; }

checks_settled() {       # pr — the gate's three checks have all reported, none pending
  local s
  s="$(gh pr checks "$1" -R "${REPO}" --json name,state 2> /dev/null)" || [[ -n "$s" ]] || return 1
  jq -e '(["ci / gate", "ci / branch-name", "local/ci"] - [.[].name] | length == 0)
         and all(.[]; .state != "PENDING" and .state != "QUEUED" and .state != "IN_PROGRESS")' <<< "$s" > /dev/null
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
      fail "onboard apply failed: $(last_out | tail -3 | tr '\n' ' ')"; return 1
    fi
    local pr; pr="$(onboard_pr)"
    [[ -z "${pr}" ]] && break                 # direct push, or merged: done
    note "onboarding PR #${pr} open"
    wait_for 900 "checks on PR #${pr}" checks_settled "${pr}" || return 1
    note "checks: $(gh pr checks "${pr}" -R "${REPO}" --json name,state --jq 'map(.name + "=" + .state) | join(", ")')"
    if [[ "${pass_no}" == 1 ]] && declare -F between > /dev/null; then
      RERUN_FROM_SCRATCH=false; between
      if [[ "${RERUN_FROM_SCRATCH}" == true ]]; then continue; fi
      [[ "${PROTECT}" == strict ]] && { sleep 15; wait_for 900 "checks on PR #${pr}" checks_settled "${pr}" || return 1; }
    fi
  done
  [[ -z "$(onboard_pr)" ]] || { fail "onboarding PR still open after 3 passes"; return 1; }
  if [[ -n "${stop_at:-}" ]]; then fail "onboard was expected to stop with /${stop_at}/ but completed"; return 1; fi

  log "onboard check"
  if run_onboard check; then pass "onboard check: $(last_out | tail -1)"; else fail "onboard check: $(last_out | grep '✗' | tr '\n' ' ')"; return 1; fi
  git switch -q "${BRANCH}" && git pull -q --ff-only

  # What onboarding put on the default branch.
  local skipped; skipped="$(git log -1 --format=%s)"
  note "onboarding commit: $(git log --oneline -1)"
  if [[ -n "${TAGS}" ]]; then
    git ls-remote --tags origin | grep -q 'refs/tags/v0.1.0' && fail "v0.1.0 created although ${TAGS} existed" || pass "no v0.1.0: existing tags kept"
  fi
  if [[ "${DEPLOY}" == true ]]; then
    # A run may exist for the onboarding commit; its deploy job must not have run.
    sleep 20
    local sha runs ran; sha="$(git rev-parse HEAD)"
    runs="$(gh run list -R "${REPO}" --workflow trigger-merge-to-main.yml --json databaseId,headSha --jq "[.[] | select(.headSha==\"${sha}\") | .databaseId] | .[]" 2> /dev/null)"
    ran=0
    for r in ${runs}; do
      wait_for 300 "deploy run ${r} to finish" run_done "${r}"
      ran=$(( ran + $(gh run view "${r}" -R "${REPO}" --json jobs --jq '[.jobs[] | select(.conclusion != "skipped")] | length') ))
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
  logged git push -q -u origin feature/sandbox-change || { fail "push of feature branch refused: $(last_out | tail -2 | tr '\n' ' ')"; return 1; }
  local pr; pr="$(gh pr create -R "${REPO}" --base "${BRANCH}" --head feature/sandbox-change --title "feature: sandbox change" --body "tests/onboard" | grep -o '[0-9]*$')"
  wait_for 900 "checks on PR #${pr}" checks_settled "${pr}" || return 1
  local states; states="$(gh pr checks "${pr}" -R "${REPO}" --json name,state --jq 'map(.name + "=" + .state) | join(", ")')"
  if gh pr checks "${pr}" -R "${REPO}" --json state --jq 'all(.[]; .state=="SUCCESS" or .state=="SKIPPED")' | grep -q true \
     && grep -q 'local/ci=SUCCESS' <<< "${states}" && grep -q 'gate=SUCCESS' <<< "${states}"; then
    pass "feature PR #${pr} checks: ${states}"
  else
    fail "feature PR #${pr} checks: ${states}"; return 1
  fi
  local method
  for method in squash rebase merge; do [[ " ${MERGES} " == *" ${method} "* ]] && break; done
  logged gh pr merge "${pr}" -R "${REPO}" "--${method}" --delete-branch || { fail "merging feature PR failed: $(last_out | tail -1)"; return 1; }
  git switch -q "${BRANCH}" && git pull -q --ff-only
  RELEASE_SHA="$(git rev-parse HEAD)"
  pass "feature PR merged by ${method}: $(git log --oneline -1)"
}

# ------------------------------------------------------------ release ----

run_status() { gh run view "$1" -R "${REPO}" --json status --jq .status; }
run_done()   { [[ "$(run_status "$1")" == completed ]]; }
run_waiting_on() {       # run env — true once a deployment to env waits on review
  gh api "repos/${REPO}/actions/runs/$1/pending_deployments" --jq ".[].environment.name" 2> /dev/null | grep -qx "$2"
}
# Jobs of a called workflow are named "<caller job> / <job>"; match on <job>.
job_conclusion() { gh run view "$1" -R "${REPO}" --json jobs --jq ".jobs[] | select(.name | sub(\"^ci / \"; \"\") | test(\"$2\")) | .conclusion" | sort -u | paste -sd, -; }

release() {
  log "release"
  # Hold production so promote never delivers anything from a sandbox.
  local me; me="$(gh api user --jq .id)"
  printf '{"reviewers":[{"type":"User","id":%s}]}' "${me}" | gh api -X PUT "repos/${REPO}/environments/production" --input - > /dev/null 2>&1 \
    || note "production can't hold for review here (plan or visibility); promote will run and fail at azure/login"
  local before; before="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  logged gh workflow run trigger-release.yml -R "${REPO}" --ref "${BRANCH}" -f sha="${RELEASE_SHA}" || { fail "dispatching the release failed: $(last_out | tail -1)"; return 1; }
  local run=""
  wait_for 120 "the release run to appear" bash -c "[[ -n \"\$(gh run list -R '${REPO}' --workflow trigger-release.yml --created '>=${before}' --json databaseId --jq '.[0].databaseId')\" ]]" || return 1
  run="$(gh run list -R "${REPO}" --workflow trigger-release.yml --created ">=${before}" --json databaseId --jq '.[0].databaseId')"
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
  run_done "${run}" || { fail "release run didn't finish"; return 1; }
  note "jobs: $(gh run view "${run}" -R "${REPO}" --json jobs --jq '.jobs | map(.name + "=" + .conclusion) | join(", ")')"

  if [[ "${RELEASE}" == build-fails:* ]]; then
    local c="${RELEASE#build-fails:}" step
    step="$(gh run view "${run}" -R "${REPO}" --json jobs --jq ".jobs[] | select(.name==\"ci / build ${c}\") | .steps[] | select(.conclusion==\"failure\") | .name")"
    [[ "${step}" == *azure/login* ]] && pass "build ${c} stopped at azure/login (no Azure in a sandbox), as expected" \
      || fail "build ${c}: expected failure at azure/login, got '${step:-no failure}'"
    return 0
  fi

  [[ "$(job_conclusion "${run}" '^build')" == success ]] && pass "build jobs succeeded" || { fail "build jobs: $(job_conclusion "${run}" '^build')"; return 1; }
  [[ "$(job_conclusion "${run}" '^tag and draft')" == success ]] && pass "draft release published" || { fail "publish: $(job_conclusion "${run}" '^tag and draft')"; return 1; }
  check_assets
}

check_assets() {
  local v="${VERSION}" d="${WORK_ROW}/assets" n rt tg pid art
  rm -rf "$d"; mkdir -p "$d"
  logged gh release download "v${v}" -R "${REPO}" -D "$d" || { fail "no release v${v}: $(last_out | tail -1)"; return 1; }
  note "assets: $(ls "$d" | tr '\n' ' ')"
  (cd "$d" && sha256sum -c SHA256SUMS > /dev/null 2>&1) && pass "SHA256SUMS matches every asset" || fail "SHA256SUMS mismatch"
  while IFS=' ' read -r n rt tg; do
    case "${tg}" in
      package)
        case "${rt}" in
          dotnet) pid="$(grep -o '<PackageId>[^<]*' "$(yq ".components[] | select(.name==\"${n}\") | .project" .github/components.yml)" | sed 's/.*>//')"; art="${pid}.${v}.nupkg" ;;
          node)   art="$(jq -r '.name' "$(yq ".components[] | select(.name==\"${n}\") | (.path // \".\")" .github/components.yml)/package.json" | sed 's/^@//; s#/#-#')-${v}.tgz" ;;
          python) art="$(ls "$d" | grep -E '\.whl$' | grep -iE "^$(grep -o '^name = "[^"]*' "$(yq ".components[] | select(.name==\"${n}\") | (.path // \".\")" .github/components.yml)/pyproject.toml" | sed 's/.*"//; s/-/_/g')-${v}-")" ;;
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
    if logged gh attestation verify "$d/${art}" -R "${REPO}" --signer-repo "${CIW_REPO}"; then pass "${n}: attestation verifies"
    elif [[ "${VIS}" == private ]]; then note "${n}: no attestation (private repo; GitHub offers them there only with Enterprise Cloud)"
    else fail "${n}: attestation: $(last_out | grep -iE 'error|fail' | head -1)"; fi
  done < <(yq '.components[] | .name + " " + .runtime + " " + .target' .github/components.yml)
}

# ------------------------------------------------------------ one row ----

# A pool of POOL sandboxes, ${OWNER}/ciw-sbx-01.., shared by every row (GitHub
# limits how fast an account may create repos). A row takes the first free
# one; mkdir is the lock, so several `run`s can go at once.
claim_sandbox() {
  local i slot end=$(( $(date +%s) + 7200 ))
  while (( $(date +%s) < end )); do
    for (( i = 1; i <= ${POOL:-10}; i++ )); do
      slot="$(printf '%02d' "$i")"
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
  LOG="${WORK_ROW}/log.txt"; : > "${LOG}"; ROW_OK=true
  local started; started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  log "row ${ROW}: seed [${SEED}] branch=${BRANCH} vis=${VIS} merges=[${MERGES}] protect=${PROTECT} tags=[${TAGS}] deploy=${DEPLOY}"
  note "repo https://github.com/${REPO}, onboard from ${ONBOARD} ($(git -C "${CIW_UNDER_TEST}" rev-parse --short HEAD)), triggers @${CIW_REF}"

  local rc=0
  (
    ensure_repo && reset_repo || { fail "sandbox setup failed"; exit 1; }
    push_seed || exit 1
    apply_protection
    git clone -q "https://github.com/${REPO}.git" "${WORK_ROW}/repo" >> "${LOG}" 2>&1 || { fail "clone failed"; exit 1; }
    cd "${WORK_ROW}/repo" || exit 1
    if declare -F pre_clone > /dev/null; then pre_clone; fi
    onboard_repo; rc=$?
    [[ "${rc}" == 2 ]] && { [[ "${ROW_OK}" == true ]] && exit 0 || exit 1; }   # stopped where the row expects
    # Carry on after a ✗ so one row reports everything it hits; the row fails at the end.
    [[ "${rc}" == 0 ]] || exit 1
    feature_pr || exit 1
    release || exit 1
    [[ "${ROW_OK}" == true ]]
  ); rc=$?

  {
    echo "## ${ROW} — $([[ ${rc} == 0 ]] && echo PASS || echo FAIL)"
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
