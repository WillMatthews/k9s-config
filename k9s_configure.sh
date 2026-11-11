#!/usr/bin/env bash
#
# Give each Kubernetes context its own k9s skin colour, so prod never looks
# like dev.
#
# Usage: ./k9s_configure.sh [--refresh] [config.yaml]
#   The config defaults to k9s-skins.yaml next to this script.
#   --refresh downloads the base skin again even if it's already installed.
#
# Needs k9s >= 0.32.7, yq v4 (https://github.com/mikefarah/yq) and curl.
# Works with the bash 3.2 that macOS ships.

set -euo pipefail

readonly MIN_K9S_VERSION="0.32.7"
# Skins are fetched from <base>/<git ref>/skins/<name>.yaml.
readonly SKINS_BASE_URL="${K9S_SKINS_BASE_URL:-https://raw.githubusercontent.com/derailed/k9s}"

CONFIG=""
REFRESH=0
K9S_VERSION=""
MAIN_CONFIG_FILE=""
SKINS_PATH=""
CONTEXT_CONFIGS_PATH=""
THEME=""
DEFAULT_COLOUR=""

# Contexts from the kubeconfig, as parallel arrays.
KUBE_CONTEXTS=()
KUBE_CLUSTERS=()

# Rules from the config's `contexts:` list, as parallel arrays. Each rule has
# either a name (exact) or a match (glob pattern).
RULE_NAMES=()
RULE_MATCHES=()
RULE_CLUSTERS=()
RULE_COLOURS=()

die() {
    echo "🚨 $*" >&2
    exit 1
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [--refresh] [config.yaml]

Give each Kubernetes context its own k9s skin colour.

  config.yaml   defaults to k9s-skins.yaml next to this script
  --refresh     download the base skin again, even if it's already installed
  -h, --help    show this help
EOF
}

parse_args() {
    while (($#)); do
        case "$1" in
        --refresh) REFRESH=1 ;;
        -h | --help)
            usage
            exit 0
            ;;
        -*)
            usage >&2
            exit 2
            ;;
        *)
            [[ -z "$CONFIG" ]] || die "Only one config file can be given."
            CONFIG="$1"
            ;;
        esac
        shift
    done
    CONFIG="${CONFIG:-"$(dirname "${BASH_SOURCE[0]}")/k9s-skins.yaml"}"
}

require() {
    command -v "$1" &>/dev/null || die "$1 is not installed. $2"
}

check_dependencies() {
    echo "🔍 Checking dependencies..."
    require k9s "See https://k9scli.io/topics/install/"
    require yq "See https://github.com/mikefarah/yq#install"
    require curl "Install it with your package manager."
    yq --version 2>&1 | grep -q mikefarah ||
        die "yq must be mikefarah/yq v4 (https://github.com/mikefarah/yq), not the Python yq."
    [[ -f "$CONFIG" ]] || die "Config file not found: $CONFIG"
}

check_k9s_not_running() {
    # k9s writes its config back out when it exits, which would undo our changes.
    if pgrep -x k9s >/dev/null; then
        die "k9s is running. Please close it before running this script."
    fi
}

# k9s_info_field prints the value of one "Name: value" line from `k9s info`.
k9s_info_field() {
    local esc
    esc="$(printf '\033')"
    k9s info | sed "s/${esc}\[[0-9;]*m//g" | sed -n "s/^$1: *//p"
}

load_k9s_info() {
    K9S_VERSION="$(k9s_info_field Version)"
    K9S_VERSION="${K9S_VERSION#v}"
    if [[ "$(printf '%s\n' "$K9S_VERSION" "$MIN_K9S_VERSION" | sort -V | head -n1)" != "$MIN_K9S_VERSION" ]]; then
        die "This script needs k9s $MIN_K9S_VERSION or newer (found $K9S_VERSION). Please upgrade k9s."
    fi

    MAIN_CONFIG_FILE="$(k9s_info_field Config)"
    SKINS_PATH="$(k9s_info_field Skins)"
    CONTEXT_CONFIGS_PATH="$(k9s_info_field 'Context Configs')"
    [[ -n "$MAIN_CONFIG_FILE" && -n "$SKINS_PATH" && -n "$CONTEXT_CONFIGS_PATH" ]] ||
        die "Could not read k9s's config paths from 'k9s info'."
}

# colour_defined succeeds if colour $1 is listed under `colours:`.
colour_defined() {
    [[ "$(C="$1" yq '.colours | has(strenv(C))' "$CONFIG")" == "true" ]]
}

load_config() {
    THEME="$(yq '.theme // ""' "$CONFIG")"
    [[ -n "$THEME" ]] || die "Set a theme in $CONFIG."

    [[ "$(yq '.colours | length' "$CONFIG")" -gt 0 ]] || die "List at least one colour under colours in $CONFIG."

    DEFAULT_COLOUR="$(yq '.default // ""' "$CONFIG")"
    if [[ -n "$DEFAULT_COLOUR" ]] && ! colour_defined "$DEFAULT_COLOUR"; then
        die "The default colour '$DEFAULT_COLOUR' isn't listed under colours in $CONFIG."
    fi

    local count i name match cluster colour
    count="$(yq '.contexts // [] | length' "$CONFIG")"
    for ((i = 0; i < count; i++)); do
        name="$(yq ".contexts[$i].name // \"\"" "$CONFIG")"
        match="$(yq ".contexts[$i].match // \"\"" "$CONFIG")"
        cluster="$(yq ".contexts[$i].cluster // \"\"" "$CONFIG")"
        colour="$(yq ".contexts[$i].colour // \"\"" "$CONFIG")"

        if [[ -n "$name" && -n "$match" ]] || [[ -z "$name" && -z "$match" ]]; then
            die "contexts[$i] in $CONFIG needs either a name or a match, not both."
        fi
        if [[ -n "$match" && -n "$cluster" ]]; then
            die "contexts[$i] in $CONFIG: cluster can only be set with name, not match."
        fi
        [[ -n "$colour" ]] || die "contexts[$i] in $CONFIG needs a colour."
        colour_defined "$colour" ||
            die "contexts[$i] in $CONFIG uses colour '$colour', which isn't listed under colours."

        RULE_NAMES+=("$name")
        RULE_MATCHES+=("$match")
        RULE_CLUSTERS+=("$cluster")
        RULE_COLOURS+=("$colour")
    done
}

# kube_context_index prints the position of context $1 in KUBE_CONTEXTS, or
# fails if it isn't there.
kube_context_index() {
    local i
    for ((i = 0; i < ${#KUBE_CONTEXTS[@]}; i++)); do
        if [[ "${KUBE_CONTEXTS[i]}" == "$1" ]]; then
            echo "$i"
            return
        fi
    done
    return 1
}

# load_kube_contexts reads every context and its cluster from the kubeconfig
# files. As with kubectl, the first file to define a context wins.
load_kube_contexts() {
    local file name cluster
    local files=()
    IFS=: read -r -a files <<<"${KUBECONFIG:-"$HOME/.kube/config"}"

    for file in ${files[@]+"${files[@]}"}; do
        [[ -f "$file" ]] || continue
        while IFS=$'\t' read -r name cluster; do
            [[ -n "$name" ]] || continue
            kube_context_index "$name" >/dev/null && continue
            KUBE_CONTEXTS+=("$name")
            KUBE_CLUSTERS+=("$cluster")
        done < <(yq '(.contexts // [])[] | [.name // "", .context.cluster // ""] | @tsv' "$file")
    done
}

download_skin() {
    local file="$SKINS_PATH/$THEME.yaml"
    mkdir -p "$SKINS_PATH"
    if [[ -f "$file" && "$REFRESH" -eq 0 ]]; then
        echo "🌟 $THEME skin already exists. Skipping download (use --refresh to update it)."
        return
    fi

    # Prefer the skin as it was in the installed k9s release, so it only uses
    # keys that version understands. Newer skins only exist on master.
    local ref
    for ref in "v$K9S_VERSION" master; do
        if curl -fsL "$SKINS_BASE_URL/$ref/skins/$THEME.yaml" -o "$file.tmp"; then
            mv "$file.tmp" "$file"
            if [[ "$ref" == master ]]; then
                echo "📥 Downloaded $THEME skin from k9s master (it isn't in k9s v$K9S_VERSION)."
            else
                echo "📥 Downloaded $THEME skin from k9s $ref."
            fi
            return
        fi
    done
    rm -f "$file.tmp"
    die "Could not download skin '$THEME'. Is the name right?"
}

create_skin_variations() {
    echo "🎨 Creating skin variations..."
    local base="$SKINS_PATH/$THEME.yaml"

    # Every colour in the skin that refers to *background follows this one value.
    if [[ "$(yq '.background | anchor' "$base")" != "background" ]]; then
        die "Skin '$THEME' has no 'background: &background' value, so it can't be recoloured. Pick another theme."
    fi

    local colour
    while IFS= read -r colour; do
        BG="$(C="$colour" yq '.colours[strenv(C)]' "$CONFIG")" \
            yq '.background = strenv(BG)' "$base" >"$SKINS_PATH/$THEME-$colour.yaml"
    done < <(yq '.colours | keys | .[]' "$CONFIG")
}

update_main_config() {
    mkdir -p "$(dirname "$MAIN_CONFIG_FILE")"
    touch "$MAIN_CONFIG_FILE"
    SKIN="$THEME" yq -i '.k9s.ui.skin = strenv(SKIN)' "$MAIN_CONFIG_FILE"
}

# sanitise matches k9s's own folder naming: runs of ':' and '/' become '-'.
sanitise() {
    sed -E 's#[:/]+#-#g' <<<"$1"
}

configure_context() {
    local context="$1" cluster="$2" skin="$3"

    # k9s reads per-context config from <Context Configs>/<cluster>/<context>/config.yaml.
    local dir
    dir="$CONTEXT_CONFIGS_PATH/$(sanitise "$cluster")/$(sanitise "$context")"
    mkdir -p "$dir"
    touch "$dir/config.yaml"
    SKIN="$skin" yq -i '.k9s.skin = strenv(SKIN)' "$dir/config.yaml"

    echo "🔩 Configured $context (cluster $cluster) to use $skin."
}

# rule_for prints the index of the first rule that matches context $1, or
# fails if none do.
rule_for() {
    local i
    for ((i = 0; i < ${#RULE_COLOURS[@]}; i++)); do
        if [[ -n "${RULE_NAMES[i]}" ]]; then
            [[ "$1" == "${RULE_NAMES[i]}" ]] || continue
        else
            # shellcheck disable=SC2053 # the pattern is meant to glob
            [[ "$1" == ${RULE_MATCHES[i]} ]] || continue
        fi
        echo "$i"
        return
    done
    return 1
}

configure_contexts() {
    echo "🔧 Configuring context-specific skins..."
    local i r context cluster colour

    # Every context in the kubeconfig gets the colour of the first rule that
    # matches it, or the default colour.
    for ((i = 0; i < ${#KUBE_CONTEXTS[@]}; i++)); do
        context="${KUBE_CONTEXTS[i]}"
        cluster="${KUBE_CLUSTERS[i]}"
        if r="$(rule_for "$context")"; then
            colour="${RULE_COLOURS[r]}"
            cluster="${RULE_CLUSTERS[r]:-$cluster}"
        elif [[ -n "$DEFAULT_COLOUR" ]]; then
            colour="$DEFAULT_COLOUR"
        else
            echo "➖ $context matches no rule and there's no default colour, so it's left alone."
            continue
        fi
        configure_context "$context" "${cluster:-$context}" "$THEME-$colour"
    done

    # Contexts named in the config but not in the kubeconfig (yet) are
    # configured too, so their skin is ready when they're added.
    for ((r = 0; r < ${#RULE_COLOURS[@]}; r++)); do
        context="${RULE_NAMES[r]}"
        [[ -n "$context" ]] || continue
        kube_context_index "$context" >/dev/null && continue
        cluster="${RULE_CLUSTERS[r]}"
        if [[ -z "$cluster" ]]; then
            echo "⚠️  $context isn't in your kubeconfig, so assuming its cluster has the same name."
            cluster="$context"
        fi
        configure_context "$context" "$cluster" "$THEME-${RULE_COLOURS[r]}"
    done
}

main() {
    parse_args "$@"
    check_dependencies
    check_k9s_not_running
    load_k9s_info
    load_config
    load_kube_contexts

    download_skin
    create_skin_variations
    update_main_config
    configure_contexts

    echo "🎉 Configuration complete! Start k9s to see the changes."
    echo "💡 Note: You'll need to switch contexts to see different skins."
}

main "$@"
