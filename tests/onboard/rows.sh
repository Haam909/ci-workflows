# tests/onboard/rows.sh — one function per configuration. Sourced by run.
# shellcheck disable=SC2034  # each variable a row sets is read by lib.sh
#
# A row sets:
#   SEED        parts to assemble (see parts/), space-separated
#   BRANCH      default branch name                         (main)
#   VIS         public | private                            (public)
#   MERGES      merge methods the repo allows               (squash rebase merge)
#   PROTECT     protection on the default branch before onboarding:
#                 none | ours | pr-only | strict | foreign | classic   (none)
#   TAGS        tags placed on the seed commit
#   DEPLOY      true adds the merge trigger                 (false)
#   VERSION     release version expected                    (0.2.0)
#   RELEASE     full | build-fails:<component>              (full)
#   FEED        "" | github: the Feed its packages publish to; set, it's a
#               Publish row, named per run, released on to production  ("")
#                 github  GitHub Packages on the repo's Host, the default a
#                         component with no `feed` gets
# and may define hooks, each run in the sandbox clone:
#   pre_seed      edit the seed tree before it's pushed
#   pre_clone     configure the repo before onboarding
#   between       after `apply` opened the onboarding PR, before re-running it
#   after_onboard extra checks once `check` passes
#   stop_at       the row ends once onboard stops with this output (regex);
#                 the row passes only if it does stop with it

APP_SEED="dotnet-api node-web py-pkg dotnet-lib"

# ---- layouts, each on the baseline: public, main, unprotected -------------
row_L1()  { SEED="dotnet-api"; }
row_L2()  { SEED="dotnet-func"; }
row_L3()  { SEED="dotnet-lib"; }
row_L4()  { SEED="node-web"; }
row_L5()  { SEED="node-pkg"; }
row_L6()  { SEED="py-func"; }
row_L7()  { SEED="py-pkg"; }
row_L8()  { SEED="py-container"; RELEASE="build-fails:worker"; }
row_L9()  { SEED="${APP_SEED}"; }
row_L10() { SEED="${APP_SEED} py-container"; RELEASE="build-fails:worker"; }

# ---- configurations, on the multi-component layout ------------------------
row_C1()  { SEED="${APP_SEED}"; BRANCH=master; }
row_C2()  { SEED="${APP_SEED}"; BRANCH=master; VIS=private; }
row_C3()  { SEED="${APP_SEED}"; PROTECT=ours; }
row_C4()  { SEED="${APP_SEED}"; PROTECT=foreign; stop_at='approval|review'; }
row_C4b() { SEED="${APP_SEED}"; PROTECT=foreign; between() { relax_protection; }; }
row_C5()  { SEED="${APP_SEED}"; PROTECT=classic; stop_at='approval|review'; }
row_C5b() { SEED="${APP_SEED}"; PROTECT=classic; between() { relax_protection; }; }
row_C6()  { SEED="${APP_SEED}"; PROTECT=pr-only; MERGES="rebase"; }
row_C7()  { SEED="${APP_SEED}"; PROTECT=pr-only; MERGES="merge"; stop_at='linear history'; }
row_C8()  { SEED="${APP_SEED}"; PROTECT=strict; between() { move_default_branch; }; }
row_C9()  { SEED="${APP_SEED}"; PROTECT=pr-only; between() { abandon_onboarding_pr; }; }
row_C9b() { SEED="${APP_SEED}"; PROTECT=pr-only; pre_clone() { push_stray_onboard_branch; }; stop_at='chore/onboard-ci'; }
row_C10() { SEED="${APP_SEED}"; TAGS="v1.4.0 release-2024"; VERSION=1.5.0; }
row_C11() { SEED="${APP_SEED}"; pre_seed() { seed_conflicting_files; }; stop_at='RestorePackagesWithLockFile'; }
row_C12() { SEED="${APP_SEED}"; after_onboard() { crlf_clone_runs_gate; }; }
row_C13() { SEED="${APP_SEED}"; PROTECT=pr-only; DEPLOY=true; }

# ---- publish rows: the release goes on to production and publishes ------
row_P1()  { SEED="dotnet-lib"; FEED=github; DEPLOY=true; }
