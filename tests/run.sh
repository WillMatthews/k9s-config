#!/usr/bin/env bash
#
# Tests for k9s_configure.sh. Needs only bash, yq and curl: k9s and pgrep are
# replaced by stubs in tests/bin, and skins come from tests/fixtures/skins.
#
# Usage: tests/run.sh [name-filter]
# Set TEST_BASH to run the script under another bash, e.g. TEST_BASH=/bin/bash
# on macOS to check it works with bash 3.2.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/tests/fixtures"
TEST_BASH="${TEST_BASH:-bash}"

# Each test gets a fresh home whose paths contain spaces, like macOS's
# "Application Support".
setup() {
    T="$(mktemp -d)"
    export XDG_CONFIG_HOME="$T/Application Support/config"
    export XDG_DATA_HOME="$T/Application Support/data"
    export XDG_STATE_HOME="$T/Application Support/state"
    export HOME="$T"
    export KUBECONFIG="$FIXTURES/kubeconfig"
    export K9S_SKINS_BASE_URL="file://$FIXTURES/skins"
    export PATH="$ROOT/tests/bin:$PATH"
    unset FAKE_K9S_VERSION FAKE_K9S_RUNNING
    SKINS="$XDG_CONFIG_HOME/k9s/skins"
    CLUSTERS="$XDG_DATA_HOME/k9s/clusters"
    CONFIG="$T/config.yaml"
    cp "$FIXTURES/config.yaml" "$CONFIG"
}

run_script() {
    output="$(cd "$T" && "$TEST_BASH" "$ROOT/k9s_configure.sh" "$@" 2>&1)"
    status=$?
}

fail() {
    echo "    $*"
    echo "    --- script output ---"
    local line
    while IFS= read -r line; do echo "    | $line"; done <<<"${output:-}"
    exit 1
}

assert_success() { [[ "$status" -eq 0 ]] || fail "expected success, got exit status $status"; }

assert_failure() {
    [[ "$status" -ne 0 ]] || fail "expected failure, got success"
    [[ -z "${1:-}" || "$output" == *"$1"* ]] || fail "expected the error to mention: $1"
}

assert_output_has() { [[ "$output" == *"$1"* ]] || fail "expected the output to mention: $1"; }

assert_equal() { [[ "$1" == "$2" ]] || fail "expected '$2', got '$1'"; }

# assert_skin checks the skin configured for cluster $1, context $2.
assert_skin() {
    local file="$CLUSTERS/$1/$2/config.yaml"
    [[ -f "$file" ]] || fail "expected $1/$2/config.yaml to exist"
    assert_equal "$(yq '.k9s.skin' "$file")" "$3"
}

# --- contexts -----------------------------------------------------------------

test_name_rule_uses_cluster_from_kubeconfig() {
    run_script "$CONFIG"
    assert_success
    assert_skin aks-dev aks-dev test-dark-blue
}

test_match_rule_globs_and_cluster_comes_first_in_path() {
    run_script "$CONFIG"
    assert_success
    assert_skin aks-prod-uk-cluster aks-prod-uk test-dark-red
    [[ ! -e "$CLUSTERS/aks-prod-uk" ]] || fail "wrote the context/cluster path the wrong way round"
}

test_first_matching_rule_wins() {
    yq -i '.contexts = [{"match": "aks-*", "colour": "blue"}] + .contexts' "$CONFIG"
    run_script "$CONFIG"
    assert_success
    assert_skin aks-prod-uk-cluster aks-prod-uk test-dark-blue
}

test_names_are_sanitised_like_k9s() {
    run_script "$CONFIG"
    assert_success
    local dir="arn-aws-eks-eu-west-2-123456789012-cluster-prod-eks"
    assert_skin "$dir" "$dir" test-dark-red
}

test_unmatched_context_left_alone_without_default() {
    run_script "$CONFIG"
    assert_success
    [[ ! -e "$CLUSTERS/legacy" ]] || fail "configured a context that no rule matches"
    assert_output_has "legacy matches no rule"
}

test_default_colour_for_unmatched_contexts() {
    yq -i '.default = "grey"' "$CONFIG"
    run_script "$CONFIG"
    assert_success
    assert_skin legacy legacy test-dark-grey
    assert_skin aks-dev aks-dev test-dark-blue
}

test_named_contexts_missing_from_kubeconfig() {
    run_script "$CONFIG"
    assert_success
    assert_skin future-cluster not-in-kubeconfig test-dark-red
    assert_skin no-cluster-given no-cluster-given test-dark-blue
    assert_output_has "no-cluster-given isn't in your kubeconfig"
}

test_first_kubeconfig_file_wins() {
    export KUBECONFIG="$FIXTURES/kubeconfig:$FIXTURES/kubeconfig-extra"
    yq -i '.default = "grey"' "$CONFIG"
    run_script "$CONFIG"
    assert_success
    assert_skin aks-dev aks-dev test-dark-blue
    [[ ! -e "$CLUSTERS/shadowed-cluster" ]] || fail "used aks-dev's cluster from the second kubeconfig"
    assert_skin kind-local kind-local test-dark-grey
}

test_works_without_a_kubeconfig() {
    export KUBECONFIG="$T/does-not-exist"
    run_script "$CONFIG"
    assert_success
    assert_skin aks-dev aks-dev test-dark-blue
    assert_skin future-cluster not-in-kubeconfig test-dark-red
}

test_keeps_other_settings_and_can_run_again() {
    mkdir -p "$XDG_CONFIG_HOME/k9s" "$CLUSTERS/aks-dev/aks-dev"
    printf 'k9s:\n  refreshRate: 5\n  ui:\n    headless: true\n' >"$XDG_CONFIG_HOME/k9s/config.yaml"
    printf 'k9s:\n  namespace:\n    active: kube-system\n  skin: old\n' >"$CLUSTERS/aks-dev/aks-dev/config.yaml"
    run_script "$CONFIG"
    assert_success
    run_script "$CONFIG"
    assert_success
    local main="$XDG_CONFIG_HOME/k9s/config.yaml"
    assert_equal "$(yq '.k9s.refreshRate' "$main")" 5
    assert_equal "$(yq '.k9s.ui.headless' "$main")" true
    assert_equal "$(yq '.k9s.ui.skin' "$main")" test-dark
    assert_equal "$(yq '.k9s.namespace.active' "$CLUSTERS/aks-dev/aks-dev/config.yaml")" kube-system
    assert_skin aks-dev aks-dev test-dark-blue
}

# --- skins --------------------------------------------------------------------

test_variations_change_only_the_background() {
    run_script "$CONFIG"
    assert_success
    local red="$SKINS/test-dark-red.yaml"
    assert_equal "$(yq '.background' "$red")" "#3f1f28"
    assert_equal "$(yq '.background | anchor' "$red")" background
    assert_equal "$(yq 'explode(.) | .k9s.frame.title.bgColor' "$red")" "#3f1f28"
    assert_equal "$(yq 'del(.background)' "$red")" "$(yq 'del(.background)' "$SKINS/test-dark.yaml")"
    [[ -f "$SKINS/test-dark-grey.yaml" ]] || fail "expected a variation for every colour"
}

test_downloads_skin_for_installed_version() {
    run_script "$CONFIG"
    assert_success
    assert_equal "$(yq '.background' "$SKINS/test-dark.yaml")" "#282c34"
    assert_output_has "from k9s v0.32.7"
}

test_falls_back_to_master_for_newer_skins() {
    yq -i '.theme = "only-on-master"' "$CONFIG"
    run_script "$CONFIG"
    assert_success
    assert_equal "$(yq '.background' "$SKINS/only-on-master.yaml")" "#222222"
    assert_output_has "from k9s master"
}

test_falls_back_to_master_for_untagged_versions() {
    export FAKE_K9S_VERSION=0.99.0
    run_script "$CONFIG"
    assert_success
    assert_equal "$(yq '.background' "$SKINS/test-dark.yaml")" "#111111"
}

test_keeps_installed_skin_unless_refresh() {
    mkdir -p "$SKINS"
    printf 'background: &background "#abcdef"\n' >"$SKINS/test-dark.yaml"
    run_script "$CONFIG"
    assert_success
    assert_equal "$(yq '.background' "$SKINS/test-dark.yaml")" "#abcdef"
    run_script --refresh "$CONFIG"
    assert_success
    assert_equal "$(yq '.background' "$SKINS/test-dark.yaml")" "#282c34"
}

# --- errors -------------------------------------------------------------------

test_refuses_while_k9s_is_running() {
    export FAKE_K9S_RUNNING=1
    run_script "$CONFIG"
    assert_failure "k9s is running"
}

test_refuses_old_k9s() {
    export FAKE_K9S_VERSION=0.31.9
    run_script "$CONFIG"
    assert_failure "needs k9s 0.32.7 or newer"
}

test_unknown_skin() {
    yq -i '.theme = "no-such-skin"' "$CONFIG"
    run_script "$CONFIG"
    assert_failure "Could not download skin 'no-such-skin'"
    [[ ! -e "$SKINS/no-such-skin.yaml" && ! -e "$SKINS/no-such-skin.yaml.tmp" ]] || fail "left a broken skin file behind"
}

test_skin_without_background_anchor() {
    yq -i '.theme = "no-anchor"' "$CONFIG"
    run_script "$CONFIG"
    assert_failure "has no 'background: &background' value"
}

test_undefined_colour() {
    yq -i '.contexts[0].colour = "pink"' "$CONFIG"
    run_script "$CONFIG"
    assert_failure "uses colour 'pink'"
}

test_undefined_default_colour() {
    yq -i '.default = "pink"' "$CONFIG"
    run_script "$CONFIG"
    assert_failure "default colour 'pink'"
}

test_rule_with_name_and_match() {
    yq -i '.contexts[0].match = "*"' "$CONFIG"
    run_script "$CONFIG"
    assert_failure "either a name or a match"
}

test_match_rule_with_cluster() {
    yq -i '.contexts[1].cluster = "x"' "$CONFIG"
    run_script "$CONFIG"
    assert_failure "cluster can only be set with name"
}

test_missing_config() {
    run_script "$T/nope.yaml"
    assert_failure "Config file not found"
}

test_unknown_option() {
    run_script --nope
    assert_equal "$status" 2
    assert_output_has "Usage:"
}

test_help() {
    run_script --help
    assert_success
    assert_output_has "--refresh"
}

# --- runner -------------------------------------------------------------------

passed=0
failed=0
for test in $(declare -F | awk '{print $3}' | grep '^test_' | grep -- "${1:-}"); do
    if (setup && trap 'rm -rf "$T"' EXIT && "$test"); then
        echo "✅ $test"
        passed=$((passed + 1))
    else
        echo "❌ $test"
        failed=$((failed + 1))
    fi
done

echo
echo "$passed passed, $failed failed"
[[ "$failed" -eq 0 && "$passed" -gt 0 ]]
