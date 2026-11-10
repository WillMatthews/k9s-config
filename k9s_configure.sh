#!/usr/bin/env bash
#
# Give each Kubernetes context its own k9s skin colour, so prod never looks
# like dev.
#
# Usage: ./k9s_configure.sh [config.yaml]
#   The config defaults to k9s-skins.yaml next to this script.
#
# Needs k9s >= 0.32.7, yq v4 (https://github.com/mikefarah/yq) and curl.

set -euo pipefail

readonly MIN_K9S_VERSION="0.32.7"
readonly SKINS_URL="https://raw.githubusercontent.com/derailed/k9s/master/skins"

CONFIG="${1:-"$(dirname "${BASH_SOURCE[0]}")/k9s-skins.yaml"}"
MAIN_CONFIG_FILE=""
SKINS_PATH=""
CONTEXT_CONFIGS_PATH=""
THEME=""

die() {
    echo "🚨 $*" >&2
    exit 1
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
    local version
    version="$(k9s_info_field Version)"
    version="${version#v}"
    if [[ "$(printf '%s\n' "$version" "$MIN_K9S_VERSION" | sort -V | head -n1)" != "$MIN_K9S_VERSION" ]]; then
        die "This script needs k9s $MIN_K9S_VERSION or newer (found $version). Please upgrade k9s."
    fi

    MAIN_CONFIG_FILE="$(k9s_info_field Config)"
    SKINS_PATH="$(k9s_info_field Skins)"
    CONTEXT_CONFIGS_PATH="$(k9s_info_field 'Context Configs')"
    [[ -n "$MAIN_CONFIG_FILE" && -n "$SKINS_PATH" && -n "$CONTEXT_CONFIGS_PATH" ]] ||
        die "Could not read k9s's config paths from 'k9s info'."
}

download_skin() {
    local file="$SKINS_PATH/$THEME.yaml"
    mkdir -p "$SKINS_PATH"
    if [[ -f "$file" ]]; then
        echo "🌟 $THEME skin already exists. Skipping download."
        return
    fi

    echo "📥 Downloading $THEME skin..."
    curl -fsSL "$SKINS_URL/$THEME.yaml" -o "$file.tmp" ||
        { rm -f "$file.tmp"; die "Could not download skin '$THEME'. Is the name right?"; }
    mv "$file.tmp" "$file"
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
        BG="$(CONFIG_COLOUR="$colour" yq '.colours[strenv(CONFIG_COLOUR)]' "$CONFIG")" \
            yq '.background = strenv(BG)' "$base" >"$SKINS_PATH/$THEME-$colour.yaml"
    done < <(yq '.colours | keys | .[]' "$CONFIG")
}

update_main_config() {
    mkdir -p "$(dirname "$MAIN_CONFIG_FILE")"
    touch "$MAIN_CONFIG_FILE"
    SKIN="$THEME" yq -i '.k9s.ui.skin = strenv(SKIN)' "$MAIN_CONFIG_FILE"
}

# lookup_cluster prints the cluster that context $1 uses in the kubeconfig.
lookup_cluster() {
    local file cluster
    local IFS=:
    for file in ${KUBECONFIG:-"$HOME/.kube/config"}; do
        [[ -f "$file" ]] || continue
        cluster="$(CTX="$1" yq '.contexts[] | select(.name == strenv(CTX)) | .context.cluster' "$file")"
        if [[ -n "$cluster" ]]; then
            echo "$cluster"
            return
        fi
    done
}

# sanitise matches k9s's own folder naming: runs of ':' and '/' become '-'.
sanitise() {
    sed -E 's#[:/]+#-#g' <<<"$1"
}

configure_context() {
    local context="$1" cluster="$2" skin="$3"

    if [[ -z "$cluster" ]]; then
        cluster="$(lookup_cluster "$context")"
    fi
    if [[ -z "$cluster" ]]; then
        echo "⚠️  $context isn't in your kubeconfig, so assuming its cluster has the same name."
        cluster="$context"
    fi

    # k9s reads per-context config from <Context Configs>/<cluster>/<context>/config.yaml.
    local dir
    dir="$CONTEXT_CONFIGS_PATH/$(sanitise "$cluster")/$(sanitise "$context")"
    mkdir -p "$dir"
    touch "$dir/config.yaml"
    SKIN="$skin" yq -i '.k9s.skin = strenv(SKIN)' "$dir/config.yaml"

    echo "🔩 Configured $context (cluster $cluster) to use $skin."
}

configure_contexts() {
    echo "🔧 Configuring context-specific skins..."
    local count i context cluster colour
    count="$(yq '.contexts | length' "$CONFIG")"
    for ((i = 0; i < count; i++)); do
        context="$(yq ".contexts[$i].name // \"\"" "$CONFIG")"
        cluster="$(yq ".contexts[$i].cluster // \"\"" "$CONFIG")"
        colour="$(yq ".contexts[$i].colour // \"\"" "$CONFIG")"
        [[ -n "$context" && -n "$colour" ]] || die "contexts[$i] in $CONFIG needs a name and a colour."
        [[ -f "$SKINS_PATH/$THEME-$colour.yaml" ]] ||
            die "Context '$context' uses colour '$colour', which isn't listed under colours in $CONFIG."
        configure_context "$context" "$cluster" "$THEME-$colour"
    done
}

main() {
    check_dependencies
    check_k9s_not_running
    load_k9s_info

    THEME="$(yq '.theme // ""' "$CONFIG")"
    [[ -n "$THEME" ]] || die "Set a theme in $CONFIG."

    download_skin
    create_skin_variations
    update_main_config
    configure_contexts

    echo "🎉 Configuration complete! Start k9s to see the changes."
    echo "💡 Note: You'll need to switch contexts to see different skins."
}

main
