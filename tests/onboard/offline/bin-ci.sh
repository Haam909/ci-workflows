#!/usr/bin/env bash
# tests/onboard/offline/bin-ci.sh — what bin/ci --install installs for a python
# component, against a fake python: the lock file, else requirements.txt, else
# the package itself. A package with only a pyproject.toml once got
# `pip install -r requirements.txt` and failed every row seeded with py-pkg (#8).

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI="${HERE}/../../../local/bin/ci"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
export PATH="${HERE}/bin:${PATH}" FAKE_LOG="${TMP}/calls"

# A repo with one python component per way of declaring its dependencies.
R="${TMP}/repo"
mkdir -p "${R}/.github" "${R}/pkg" "${R}/req" "${R}/lock"
touch "${R}/pkg/pyproject.toml" "${R}/req/requirements.txt" "${R}/lock/requirements.txt" "${R}/lock/requirements.lock.txt"
cat > "${R}/.github/components.yml" <<'YML'
components:
  - { name: pkg,  runtime: python, target: package,   path: pkg }
  - { name: req,  runtime: python, target: function,  path: req }
  - { name: lock, runtime: python, target: container, path: lock }
YML

WRONG=0
t() {      # name component want-install-call
  local name="$1" only="$2" want="$3" out rc got ok=ok
  : > "${FAKE_LOG}"
  out="$(cd "${R}" && bash "${CI}" --install --quick --only "${only}" 2>&1)"; rc=$?
  got="$(grep -m1 ' -m pip install' "${FAKE_LOG}")"
  [[ "${rc}" == 0 && "${got}" == "${want}" ]] || { ok=WRONG; WRONG=$((WRONG + 1)); }
  printf '%-5s %-44s rc=%s  %s\n' "${ok}" "${name}" "${rc}" "${got:-$(sed 's/\x1b\[[0-9;]*m//g' <<< "${out}" | grep -m1 -iE 'error|✗')}"
}

t "pyproject only: installs itself"    pkg  "pkg: -m pip install -e .[dev]"
t "requirements.txt"                   req  "req: -m pip install -r requirements.txt"
t "lock file wins over requirements"   lock "lock: -m pip install --require-hashes -r requirements.lock.txt"

echo "bin-ci: ${WRONG} wrong"
[[ "${WRONG}" == 0 ]]
