#!/usr/bin/env bash
set -euo pipefail

# Each release holds `moon-<version>-<host>.tar.gz` per host, with one
# top-level `moon-<version>-<host>/` tree (bin/, lib/moon/targets/,
# include/moon/std/), and a `SHA256SUMS` asset listing every archive.

readonly DEFAULT_GITHUB="https://github.com"
readonly DEFAULT_REPOSITORY="moonlang-dev/moon-releases"

color_red=""
color_green=""
color_dim=""
color_bold=""
color_reset=""
if [[ -t 1 ]]; then
    color_red=$'\033[0;31m'
    color_green=$'\033[0;32m'
    color_dim=$'\033[0;2m'
    color_bold=$'\033[1m'
    color_reset=$'\033[0m'
fi

error() {
    printf '%serror%s: %s\n' "$color_red" "$color_reset" "$*" >&2
    exit 1
}

info() {
    printf '%s%s%s\n' "$color_dim" "$*" "$color_reset"
}

success() {
    printf '%s%s%s\n' "$color_green" "$*" "$color_reset"
}

usage() {
    cat <<'EOF'
Usage: install.sh [version] [editors] [options]

Installs the moon toolchain and, optionally, editor integrations.

Run from a terminal with no arguments, the installer asks where to install
moon, which editors to set up, and where each integration goes. Given any
argument, or without a terminal, it asks nothing and uses the defaults.

Arguments:
  version               latest (default) or vX.Y.Z; MOON_VERSION also sets this
  editors               same as --editor

Options:
  --editor NAMES        vscode, sublime, jetbrains, neovim, or zed (also
                        accepts code, subl, and nvim); separate several with
                        commas, or repeat the option
  --editor-path CMD     editor command to use (vscode, neovim)
  --editor-config DIR   where the integration is installed:
                          vscode     extensions directory
                          sublime    Packages directory
                          jetbrains  one IDE's plugins directory
                          neovim     config directory
                          zed        directory the extension is unpacked in
                        --editor-path and --editor-config need exactly one
                        editor
  --editor-only         keep the installed toolchain; install only the editors
  -i, --interactive     ask, with the other options as the suggested answers
  -y, --yes             ask nothing
  -h, --help            show this help

Environment:
  MOON_VERSION          same as the version argument
  MOON_INSTALL          install directory, ~/.moon by default
  MOON_INSTALL_ARGS     options as comma-separated pairs, for piping into bash;
                        an option passed explicitly wins:

    curl -fsSL <url> | MOON_INSTALL_ARGS=editor=nvim,editor-only bash

  Its keys are editor, editor-path, editor-config, editor-only, interactive,
  yes, and help. The last four take yes or no, and a bare key means yes.
  Repeat editor for several editors.
EOF
}

trim() {
    local value=$1
    value=${value#"${value%%[![:space:]]*}"}
    printf '%s' "${value%"${value##*[![:space:]]}"}"
}

lowercase() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

expand_tilde() {
    local rest
    case "$1" in
        '~') printf '%s' "$HOME" ;;
        '~/'*)
            rest=${1#\~/}
            printf '%s/%s' "$HOME" "$rest"
            ;;
        *) printf '%s' "$1" ;;
    esac
}

absolute_path() {
    local path
    path=$(expand_tilde "$1")
    case "$path" in
        /*) ;;
        *) path="$PWD/$path" ;;
    esac
    printf '%s' "$path"
}

sha256_of() {
    local digest
    if command -v sha256sum >/dev/null 2>&1; then
        digest=$(sha256sum "$1" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        digest=$(shasum -a 256 "$1" | awk '{print $1}')
    elif command -v openssl >/dev/null 2>&1; then
        digest=$(openssl dgst -sha256 "$1" | awk '{print $NF}')
    else
        error "sha256sum, shasum, or openssl is required to verify moon"
    fi
    lowercase "$digest"
}

all_editors=(vscode sublime jetbrains neovim zed)

canonical_editor() {
    case "$(lowercase "$1")" in
        vscode | code) printf vscode ;;
        sublime | subl) printf sublime ;;
        jetbrains) printf jetbrains ;;
        neovim | nvim) printf neovim ;;
        zed) printf zed ;;
        *) return 1 ;;
    esac
}

editor_label() {
    case "$1" in
        vscode) printf 'VS Code' ;;
        sublime) printf 'Sublime Text' ;;
        jetbrains) printf 'JetBrains' ;;
        neovim) printf 'Neovim' ;;
        zed) printf 'Zed' ;;
    esac
}

add_editor() {
    local name
    for name in ${editors[@]+"${editors[@]}"}; do
        [[ $name != "$1" ]] || return 0
    done
    editors+=("$1")
}

# Takes one name or a comma-separated list.
add_editors() {
    local names name canonical
    IFS=',' read -r -a names <<<"$1"
    for name in ${names[@]+"${names[@]}"}; do
        name=$(trim "$name")
        [[ -n $name ]] || continue
        canonical=$(canonical_editor "$name") ||
            error "unknown editor '$name' (use vscode, sublime, jetbrains, neovim, or zed)"
        add_editor "$canonical"
    done
}

# The detect_* functions fill in a location the options left unset, and fail
# quietly when there is nothing to find.
detect_vscode() {
    local macos_cli="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
    if command -v code >/dev/null 2>&1; then
        vscode_cli=$(command -v code)
    elif [[ -x $macos_cli ]]; then
        vscode_cli=$macos_cli
    else
        return 1
    fi
}

detect_sublime() {
    local candidate candidates
    if [[ $os == Darwin ]]; then
        candidates=(
            "$HOME/Library/Application Support/Sublime Text/Packages"
            "$HOME/Library/Application Support/Sublime Text 3/Packages"
        )
    else
        candidates=(
            "${XDG_CONFIG_HOME:-$HOME/.config}/sublime-text/Packages"
            "${XDG_CONFIG_HOME:-$HOME/.config}/sublime-text-3/Packages"
            "$HOME/.var/app/com.sublimetext.three/config/sublime-text/Packages"
        )
    fi
    for candidate in "${candidates[@]}"; do
        if [[ -d $candidate ]]; then
            sublime_dir=$candidate
            return 0
        fi
    done
    return 1
}

# Every IDE that can load the plugin gets it. Older IDEs reject it, because
# the plugin's since-build is 262 (2026.2).
detect_jetbrains() {
    local config_root plugin_root plugin_suffix="" product_dir product
    if [[ $os == Darwin ]]; then
        config_root="$HOME/Library/Application Support/JetBrains"
        plugin_root=$config_root
        plugin_suffix=/plugins
    else
        config_root="${XDG_CONFIG_HOME:-$HOME/.config}/JetBrains"
        plugin_root="${XDG_DATA_HOME:-$HOME/.local/share}/JetBrains"
    fi
    for product_dir in "$config_root"/*/; do
        product=$(basename -- "$product_dir")
        [[ $product =~ ^[A-Za-z]+([0-9]{4})\.([0-9]+)$ ]] || continue
        if (( BASH_REMATCH[1] > 2026 || (BASH_REMATCH[1] == 2026 && BASH_REMATCH[2] >= 2) )); then
            jetbrains_targets+=("$plugin_root/$product$plugin_suffix")
        fi
    done
    (( ${#jetbrains_targets[@]} > 0 ))
}

detect_zed() {
    command -v zed >/dev/null 2>&1 || command -v zeditor >/dev/null 2>&1 ||
        [[ -d ${XDG_CONFIG_HOME:-$HOME/.config}/zed || -d /Applications/Zed.app ]]
}

# Prints what stops the Neovim setup from running, and fails when nothing does.
neovim_problem() {
    local compiler
    if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
        printf 'Neovim setup requires bash 4.4 or newer (running %s)' "$BASH_VERSION"
        return 0
    fi
    for compiler in "${CC:-cc}" gcc clang; do
        ! command -v "$compiler" >/dev/null 2>&1 || return 1
    done
    printf 'a C compiler is required to build the Neovim parser (set CC, or install cc, gcc, or clang)'
}

# Reads one line from the terminal into `answer`; an empty line means the
# default. `shown` stands in for a default that has no value to print.
ask() {
    local prompt=$1 default=${2:-} shown=${3:-${2:-}} reply=""
    if [[ -n $shown ]]; then
        printf '%s %s[%s]%s: ' "$prompt" "$color_dim" "$shown" "$color_reset"
    else
        printf '%s: ' "$prompt"
    fi
    if ! IFS= read -r reply <&3; then
        printf '\n'
        error "the terminal closed before the installer got an answer"
    fi
    reply=$(trim "$reply")
    answer=${reply:-$default}
}

ask_required() {
    while true; do
        ask "$@"
        [[ -z $answer ]] || return 0
        printf 'A value is needed here.\n'
    done
}

# Sets `note` to what was found for an editor, and `detected` to whether its
# integration can be installed as things stand.
describe_editor() {
    local command_path problem count
    detected=false
    note="not found"
    case "$1" in
        vscode)
            [[ -z $vscode_cli ]] || { detected=true; note=$vscode_cli; }
            ;;
        sublime)
            [[ -z $sublime_dir ]] || { detected=true; note=$sublime_dir; }
            ;;
        jetbrains)
            count=${#jetbrains_targets[@]}
            note="no IDE at 2026.2 or newer found"
            if (( count == 1 )); then
                detected=true
                note=${jetbrains_targets[0]}
            elif (( count > 1 )); then
                detected=true
                note="$count IDEs at 2026.2 or newer"
            fi
            ;;
        neovim)
            command_path=${nvim_cli:-$(command -v nvim || true)}
            if [[ -n $command_path ]]; then
                if problem=$(neovim_problem); then
                    note="$command_path, but $problem"
                else
                    detected=true
                    note=$command_path
                fi
            fi
            ;;
        zed)
            ! detect_zed || { detected=true; note="found"; }
            ;;
    esac
}

choose_editors() {
    local index=0 name default="" words word chosen valid canonical
    printf '\n%sEditor integrations%s\n' "$color_bold" "$color_reset"
    for name in "${all_editors[@]}"; do
        index=$((index + 1))
        describe_editor "$name"
        printf '  %d) %-13s %s%s%s\n' "$index" "$(editor_label "$name")" \
            "$color_dim" "$note" "$color_reset"
        if [[ ${#editors[@]} -eq 0 && $detected == true ]]; then
            default="$default $name"
        fi
    done
    [[ ${#editors[@]} -eq 0 ]] || default=${editors[*]}
    default=$(trim "$default")

    while true; do
        ask "Editors to set up (numbers or names, 'all', or 'none')" "${default:-none}"
        read -r -a words <<<"${answer//,/ }"
        chosen=()
        valid=true
        for word in ${words[@]+"${words[@]}"}; do
            case "$(lowercase "$word")" in
                all) chosen=("${all_editors[@]}") ;;
                none) chosen=() ;;
                [1-5]) chosen+=("${all_editors[word - 1]}") ;;
                *)
                    if canonical=$(canonical_editor "$word"); then
                        chosen+=("$canonical")
                    else
                        printf "'%s' is not one of the editors above.\n" "$word"
                        valid=false
                    fi
                    ;;
            esac
        done
        [[ $valid == false ]] || break
    done
    editors=()
    for name in "${all_editors[@]}"; do
        for word in ${chosen[@]+"${chosen[@]}"}; do
            [[ $word != "$name" ]] || add_editor "$name"
        done
    done
}

configure_editor() {
    local count target
    case "$1" in
        vscode)
            ask "VS Code command" "${vscode_cli:-code}"
            vscode_cli=$answer
            ask "VS Code extensions directory" "$vscode_dir" "${vscode_dir:-the default}"
            vscode_dir=$answer
            ;;
        sublime)
            ask_required "Sublime Text Packages directory" "$sublime_dir"
            sublime_dir=$answer
            ;;
        jetbrains)
            count=${#jetbrains_targets[@]}
            if (( count > 1 )); then
                printf 'JetBrains plugins directories found:\n'
                for target in "${jetbrains_targets[@]}"; do
                    printf '  %s\n' "$target"
                done
                ask "JetBrains plugins directory" "" "all $count above"
                [[ -z $answer ]] || jetbrains_targets=("$answer")
            else
                ask_required "JetBrains plugins directory" "${jetbrains_targets[0]:-}"
                jetbrains_targets=("$answer")
            fi
            ;;
        neovim)
            ask "Neovim command" "${nvim_cli:-nvim}"
            nvim_cli=$answer
            ask "Neovim config directory" "$nvim_config" "${nvim_config:-the default}"
            nvim_config=$answer
            ;;
        zed)
            ask "Unpack the Zed extension in" "$zed_dir"
            zed_dir=$answer
            ;;
    esac
}

configure_interactively() {
    local name labels="" question
    printf '%smoon installer%s\n' "$color_bold" "$color_reset"
    info "Press Enter to accept the answer in brackets."
    printf '\n'
    if [[ $editor_only == false ]]; then
        ask "Install moon in" "$install_input"
        install_input=$answer
    fi

    [[ -n $vscode_cli ]] || detect_vscode || true
    [[ -n $sublime_dir ]] || detect_sublime || true
    [[ ${#jetbrains_targets[@]} -gt 0 ]] || detect_jetbrains || true
    choose_editors
    for name in ${editors[@]+"${editors[@]}"}; do
        configure_editor "$name"
        labels="$labels, $(editor_label "$name")"
    done
    labels=${labels#, }

    if [[ $editor_only == true ]]; then
        [[ -n $labels ]] || error "no editor was selected, and --editor-only installs nothing else"
        question="Set up $labels?"
    else
        question="Install moon ($requested_version) in $install_input"
        [[ -z $labels ]] || question="$question and set up $labels"
        question="$question?"
    fi
    printf '\n'
    ask "$question" y "Y/n"
    case "$(lowercase "$answer")" in
        y | yes) printf '\n' ;;
        *)
            info "Cancelled; nothing was installed."
            exit 1
            ;;
    esac
}

resolve_command() {
    local resolved
    resolved=$(command -v -- "$(expand_tilde "$1")") || error "editor command not found: '$1'"
    printf '%s' "$resolved"
}

# Runs before the toolchain is touched, so a bad editor request changes nothing.
prepare_editor() {
    local problem index
    case "$1" in
        vscode)
            if [[ -n $vscode_cli ]]; then
                vscode_cli=$(resolve_command "$vscode_cli")
            else
                detect_vscode || error "could not find the 'code' command; pass --editor-path"
            fi
            [[ -z $vscode_dir ]] || vscode_dir=$(absolute_path "$vscode_dir")
            ;;
        sublime)
            [[ -n $sublime_dir ]] || detect_sublime ||
                error "could not find Sublime Text's Packages directory; pass --editor-config"
            sublime_dir=$(absolute_path "$sublime_dir")
            ;;
        jetbrains)
            [[ ${#jetbrains_targets[@]} -gt 0 ]] || detect_jetbrains ||
                error "found no JetBrains IDE at version 2026.2 or newer; pass --editor-config"
            for index in "${!jetbrains_targets[@]}"; do
                jetbrains_targets[index]=$(absolute_path "${jetbrains_targets[index]}")
            done
            ;;
        neovim)
            [[ -z $nvim_cli ]] || nvim_cli=$(resolve_command "$nvim_cli")
            [[ -z $nvim_config ]] || nvim_config=$(absolute_path "$nvim_config")
            if problem=$(neovim_problem); then
                error "$problem"
            fi
            ;;
        zed)
            zed_dir=$(absolute_path "$zed_dir")
            ;;
    esac
    if [[ $1 != vscode ]] && ! command -v unzip >/dev/null 2>&1; then
        error "unzip is required to install the $1 integration"
    fi
}

find_moon() {
    local installed
    installed="$(absolute_path "$install_input")/bin/moon"
    if [[ -x $installed ]]; then
        exe=$installed
    elif command -v moon >/dev/null 2>&1; then
        exe=$(command -v moon)
    else
        error "moon is not installed; run this installer without --editor-only"
    fi
}

download_editor_asset() {
    local asset=$1 url="$editor_base_url/$1" path="$temp_dir/$1" expected=""
    info "Downloading $url"
    curl --fail --location --retry 3 --progress-bar --output "$path" "$url" ||
        error "failed to download '$url'"
    curl --fail --location --retry 3 --silent --show-error \
        --output "$path.sha256" "$url.sha256" ||
        error "failed to download '$url.sha256'"
    read -r expected _ <"$path.sha256" || true
    [[ $expected =~ ^[0-9a-fA-F]{64}$ ]] || error "invalid checksum file for '$asset'"
    expected=$(lowercase "$expected")
    [[ $(sha256_of "$path") == "$expected" ]] ||
        error "checksum verification failed for '$asset'"
}

# Applies the toolchain archive's rules: one top-level directory, no parent
# traversal, and no links.
fetch_editor_package() {
    local package=$1 archive="$temp_dir/$1.zip" entry listing
    download_editor_asset "$package.zip"
    while IFS= read -r entry; do
        case "/$entry/" in
            */../* | *\\*) error "editor package contains an unsafe path: '$entry'" ;;
        esac
        case "$entry" in
            "$package"/*) ;;
            *) error "editor package contains an unexpected path: '$entry'" ;;
        esac
    done < <(unzip -Z1 "$archive")
    listing=$(unzip -Z "$archive")
    if grep -q '^l' <<<"$listing"; then
        error "editor package contains a link"
    fi
    unzip -q "$archive" -d "$temp_dir" || error "failed to extract '$package.zip'"
}

replace_dir() {
    local source=$1 destination=$2 parent staged
    parent=$(dirname -- "$destination")
    staged="$parent/.$(basename -- "$destination").new.$$"
    mkdir -p -- "$parent" || error "failed to create '$parent'"
    if ! cp -R -- "$source" "$staged"; then
        rm -rf -- "$staged"
        error "failed to copy the integration into '$parent'"
    fi
    rm -rf -- "$destination"
    mv -- "$staged" "$destination" || error "failed to install '$destination'"
}

# A subshell, so the EXIT trap does not displace the toolchain's cleanup.
install_editor() (
    temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/moon-editor.XXXXXX") ||
        error "failed to create a temporary directory"
    trap 'rm -rf -- "$temp_dir"' EXIT

    printf '\n'
    case "$1" in
        vscode)
            download_editor_asset moon-vscode.vsix
            args=(--install-extension "$temp_dir/moon-vscode.vsix" --force)
            [[ -z $vscode_dir ]] || args+=(--extensions-dir "$vscode_dir")
            "$vscode_cli" "${args[@]}" || error "'$vscode_cli' could not install the extension"
            success "moon extension installed with $vscode_cli"
            ;;
        sublime)
            fetch_editor_package moon-sublime
            replace_dir "$temp_dir/moon-sublime" "$sublime_dir/moon-sublime"
            success "moon package installed to $sublime_dir/moon-sublime"
            printf 'For language server features, set up the LSP package as described in its README.md.\n'
            ;;
        jetbrains)
            fetch_editor_package moon-jetbrains
            for target in "${jetbrains_targets[@]}"; do
                replace_dir "$temp_dir/moon-jetbrains" "$target/moon-jetbrains"
                success "moon plugin installed to $target/moon-jetbrains"
            done
            printf 'Restart the IDE to load the plugin.\n'
            ;;
        neovim)
            fetch_editor_package moon-neovim
            bundle="$data_dir/moon-neovim"
            replace_dir "$temp_dir/moon-neovim" "$bundle"
            args=()
            [[ -z $nvim_config ]] || args=(--config-dir "$nvim_config")
            setup_path=$(dirname -- "$exe"):$PATH
            [[ -z $nvim_cli ]] || setup_path=$(dirname -- "$nvim_cli"):$setup_path
            MOON=$exe PATH=$setup_path "$BASH" "$bundle/editors/nvim/setup.sh" "${args[@]}" ||
                error "Neovim setup failed"
            ;;
        zed)
            fetch_editor_package moon-zed
            replace_dir "$temp_dir/moon-zed" "$zed_dir/moon-zed"
            success "moon extension unpacked to $zed_dir/moon-zed"
            printf "Finish in Zed: run '%szed: install dev extension%s' and select that directory.\n" \
                "$color_bold" "$color_reset"
            printf 'Zed builds it with Rust, which must be installed through rustup.\n'
            ;;
    esac
)

requested_version=""
editors=()
editor_path=""
editor_config=""
editor_only=false
mode=""
positional_count=0
# Any argument or MOON_INSTALL_ARGS marks a scripted run, which asks nothing
# unless told to.
configured=false
[[ $# -eq 0 && -z ${MOON_INSTALL_ARGS:-} ]] || configured=true
while (( $# > 0 )); do
    case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
        --editor | --editor-path | --editor-config)
            (( $# >= 2 )) || error "$1 requires a value"
            case "$1" in
                --editor) add_editors "$2" ;;
                --editor-path) editor_path=$2 ;;
                --editor-config) editor_config=$2 ;;
            esac
            shift 2
            ;;
        --editor-only)
            editor_only=true
            shift
            ;;
        -i | --interactive | -y | --yes)
            case "$1" in
                -i | --interactive) new_mode=interactive ;;
                *) new_mode=yes ;;
            esac
            [[ -z $mode || $mode == "$new_mode" ]] ||
                error "--interactive and --yes cannot be combined"
            mode=$new_mode
            shift
            ;;
        -*)
            error "unknown option '$1' (see --help)"
            ;;
        *)
            positional_count=$((positional_count + 1))
            case "$positional_count" in
                1) requested_version=$1 ;;
                2) add_editors "$1" ;;
                *) error "expected at most a version and editors (for example: v1.0.0 nvim,zed)" ;;
            esac
            shift
            ;;
    esac
done

# `curl <url> | bash` takes options only after `bash -s --`, so MOON_INSTALL_ARGS
# can carry them instead as comma-separated pairs, such as
# "editor=nvim,editor-path=nvim,editor-only". An option passed explicitly wins.
arg_flag() {
    case "$(lowercase "$2")" in
        '' | 1 | true | yes | on) return 0 ;;
        0 | false | no | off) return 1 ;;
        *) error "invalid value '$2' for $1 in MOON_INSTALL_ARGS (use yes or no)" ;;
    esac
}
if [[ -n ${MOON_INSTALL_ARGS:-} ]]; then
    explicit_editors=${#editors[@]}
    explicit_mode=$mode
    IFS=',' read -r -a install_args <<<"$MOON_INSTALL_ARGS"
    for pair in ${install_args[@]+"${install_args[@]}"}; do
        [[ -n $(trim "$pair") ]] || continue
        key=$(lowercase "$(trim "${pair%%=*}")")
        value=""
        [[ $pair != *=* ]] || value=$(trim "${pair#*=}")
        case "$key" in
            editor | editor-path | editor-config)
                [[ -n $value ]] || error "$key in MOON_INSTALL_ARGS needs a value, as in $key=<value>"
                case "$key" in
                    editor) (( explicit_editors > 0 )) || add_editors "$value" ;;
                    editor-path) editor_path=${editor_path:-$value} ;;
                    editor-config) editor_config=${editor_config:-$value} ;;
                esac
                ;;
            editor-only)
                if arg_flag "$key" "$value"; then
                    editor_only=true
                fi
                ;;
            interactive | yes)
                if arg_flag "$key" "$value" && [[ -z $explicit_mode ]]; then
                    [[ -z $mode || $mode == "$key" ]] ||
                        error "interactive and yes cannot be combined in MOON_INSTALL_ARGS"
                    mode=$key
                fi
                ;;
            help)
                if arg_flag "$key" "$value"; then
                    usage
                    exit 0
                fi
                ;;
            *)
                error "unknown key '$key' in MOON_INSTALL_ARGS (use editor, editor-path, editor-config, editor-only, interactive, yes, or help)"
                ;;
        esac
    done
fi

if [[ -n $editor_path || -n $editor_config ]]; then
    [[ ${#editors[@]} -eq 1 ]] ||
        error "--editor-path and --editor-config require exactly one editor"
fi
if [[ $editor_only == true && -n $requested_version && $requested_version != latest ]]; then
    error "--editor-only does not install a toolchain, so it cannot take a version"
fi

requested_version=${requested_version:-${MOON_VERSION:-latest}}
case "$requested_version" in
    latest)
        release_path="latest/download"
        ;;
    v[0-9]*.[0-9]*.[0-9]* | [0-9]*.[0-9]*.[0-9]*)
        if [[ ! $requested_version =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
            error "invalid moon version '$requested_version'"
        fi
        tag=${requested_version#v}
        release_path="download/v$tag"
        ;;
    *)
        error "invalid moon version '$requested_version' (use latest or vX.Y.Z)"
        ;;
esac

os=$(uname -s)
arch=$(uname -m)
case "$os/$arch" in
    Linux/x86_64 | Linux/amd64) host=x86_64-linux ;;
    Darwin/arm64 | Darwin/aarch64) host=aarch64-macos ;;
    Linux/* | Darwin/*)
        error "moon releases support x86-64 Linux and Apple silicon macOS (detected $os $arch)"
        ;;
    *) error "moon releases do not support $os through this installer; use install.ps1 on Windows" ;;
esac

for command in curl tar; do
    command -v "$command" >/dev/null 2>&1 || error "$command is required to install moon"
done

github=${MOON_GITHUB:-$DEFAULT_GITHUB}
repository=${MOON_GITHUB_REPO:-$DEFAULT_REPOSITORY}
base_url="$github/$repository/releases/$release_path"
editor_base_url="$github/$repository/releases/download/editors"

install_input=${MOON_INSTALL:-$HOME/.moon}
# Neovim's generated config and Zed's dev extension keep pointing at these
# files, so they live outside the toolchain directory that upgrades replace.
data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/moon/editors"
vscode_cli=""
vscode_dir=""
sublime_dir=""
jetbrains_targets=()
nvim_cli=""
nvim_config=""
zed_dir=$data_dir
if [[ -n $editor_path || -n $editor_config ]]; then
    case "${editors[0]}" in
        sublime | jetbrains | zed)
            [[ -z $editor_path ]] || error "--editor-path does not apply to ${editors[0]}"
            ;;
    esac
    case "${editors[0]}" in
        vscode)
            vscode_cli=$editor_path
            vscode_dir=$editor_config
            ;;
        sublime) sublime_dir=$editor_config ;;
        jetbrains) jetbrains_targets=("$editor_config") ;;
        neovim)
            nvim_cli=$editor_path
            nvim_config=$editor_config
            ;;
        zed) zed_dir=$editor_config ;;
    esac
fi

# Prompts are read from the terminal itself, because `curl <url> | bash` leaves
# the script on stdin.
can_prompt() {
    (: </dev/tty) 2>/dev/null
}
if [[ $mode == interactive ]]; then
    can_prompt || error "--interactive needs a terminal to ask on"
elif [[ -z $mode && $configured == false && -t 1 ]] && can_prompt; then
    mode=interactive
fi
if [[ $mode == interactive ]]; then
    exec 3</dev/tty
    configure_interactively
    exec 3<&-
fi

[[ $editor_only == false || ${#editors[@]} -gt 0 ]] || error "--editor-only requires an editor"
for editor in ${editors[@]+"${editors[@]}"}; do
    prepare_editor "$editor"
done
if [[ $editor_only == true ]]; then
    find_moon
    for editor in "${editors[@]}"; do
        install_editor "$editor"
    done
    exit 0
fi

[[ -n $install_input ]] || error "MOON_INSTALL must not be empty"
install_input=$(absolute_path "$install_input")
install_parent=$(dirname -- "$install_input")
install_name=$(basename -- "$install_input")
case "$install_name" in
    '' | . | ..) error "refusing unsafe install directory '$install_input'" ;;
esac
mkdir -p -- "$install_parent" || error "failed to create '$install_parent'"
install_parent=$(cd -- "$install_parent" && pwd -P)
install_dir="$install_parent/$install_name"
home_dir=$(cd -- "$HOME" && pwd -P)
[[ $install_dir != / && $install_dir != "$home_dir" ]] ||
    error "refusing unsafe install directory '$install_dir'"
[[ ! -e $install_dir || -d $install_dir ]] ||
    error "install path exists and is not a directory: '$install_dir'"

work_dir=$(mktemp -d "$install_parent/.moon-install.XXXXXX") ||
    error "failed to create a staging directory in '$install_parent'"
backup_dir="$work_dir/previous"
replacement_started=false
committed=false
cleanup() {
    if [[ $committed == false && -d $backup_dir ]]; then
        [[ ! -e $install_dir ]] || rm -rf -- "$install_dir"
        mv -- "$backup_dir" "$install_dir"
    elif [[ $replacement_started == true && $committed == false ]]; then
        [[ ! -e $install_dir ]] || rm -rf -- "$install_dir"
    fi
    rm -rf -- "$work_dir"
}
trap cleanup EXIT

# SHA256SUMS names each host's archive, so the latest release needs no
# separate version lookup.
sums_file="$work_dir/SHA256SUMS"
curl --fail --location --retry 3 --silent --show-error \
    --output "$sums_file" "$base_url/SHA256SUMS" ||
    error "failed to download '$base_url/SHA256SUMS'"
asset=""
expected_checksum=""
while read -r digest name _ || [[ -n ${digest:-} ]]; do
    name=${name//$'\r'/}
    name=${name#\*}
    if [[ $digest =~ ^[0-9a-fA-F]{64}$ && $name =~ ^moon-[0-9A-Za-z.+-]+-$host\.tar\.gz$ ]]; then
        expected_checksum=$(printf '%s' "$digest" | tr '[:upper:]' '[:lower:]')
        asset=$name
        break
    fi
done <"$sums_file"
[[ -n $asset ]] || error "the release at '$base_url' has no archive for $host"
root=${asset%.tar.gz}
url="$base_url/$asset"
archive="$work_dir/$asset"

info "Downloading $url"
curl --fail --location --retry 3 --progress-bar --output "$archive" "$url" ||
    error "failed to download '$url'"

[[ $(sha256_of "$archive") == "$expected_checksum" ]] ||
    error "checksum verification failed for '$asset'"

# Reject absolute paths, parent traversal, links, and files outside the one
# documented top-level directory before asking tar to write anything.
while IFS= read -r entry; do
    entry=${entry#./}
    case "/$entry/" in
        */../*) error "release archive contains parent traversal: '$entry'" ;;
    esac
    case "$entry" in
        "$root" | "$root"/*) ;;
        *) error "release archive contains an unexpected path: '$entry'" ;;
    esac
done < <(tar -tzf "$archive")
while IFS= read -r listing; do
    case "${listing:0:1}" in
        - | d) ;;
        *) error "release archive contains a link or special file" ;;
    esac
done < <(tar -tvzf "$archive")

extract_dir="$work_dir/extracted"
mkdir -p -- "$extract_dir"
tar -xzf "$archive" -C "$extract_dir" || error "failed to extract '$asset'"
staged_dir="$extract_dir/$root"
[[ -f $staged_dir/bin/moon ]] || error "release archive does not contain $root/bin/moon"
[[ -d $staged_dir/lib/moon/targets ]] || error "release archive does not contain $root/lib/moon/targets"
[[ -d $staged_dir/include/moon/std ]] || error "release archive does not contain $root/include/moon/std"
chmod +x "$staged_dir/bin/moon" "$staged_dir/bin/moon-c-import-worker"

if [[ -d $install_dir ]]; then
    mv -- "$install_dir" "$backup_dir" || error "failed to stage the existing moon installation"
fi
replacement_started=true
if ! mv -- "$staged_dir" "$install_dir"; then
    error "failed to install moon to '$install_dir'"
fi

exe="$install_dir/bin/moon"
if ! version_output=$("$exe" --version 2>&1); then
    error "installed moon could not start:\n$version_output"
fi
committed=true
rm -rf -- "$backup_dir"

bin_dir="$install_dir/bin"
export MOON_INSTALL="$install_dir"
case ":$PATH:" in
    *":$bin_dir:"*) path_ready=true ;;
    *) path_ready=false ;;
esac

profile=""
profile_line=""
if [[ $path_ready == false ]]; then
    printf -v quoted_install '%q' "$install_dir"
    case "$(basename -- "${SHELL:-}")" in
        bash)
            profile="$HOME/.bashrc"
            profile_line="export MOON_INSTALL=$quoted_install
export PATH=\"\$MOON_INSTALL/bin:\$PATH\""
            ;;
        zsh)
            profile="${ZDOTDIR:-$HOME}/.zshrc"
            profile_line="export MOON_INSTALL=$quoted_install
export PATH=\"\$MOON_INSTALL/bin:\$PATH\""
            ;;
        fish)
            profile="$HOME/.config/fish/config.fish"
            fish_install=${install_dir//\\/\\\\}
            fish_install=${fish_install//\'/\\\'}
            profile_line="set --global --export MOON_INSTALL '$fish_install'
fish_add_path --global --move \"\$MOON_INSTALL/bin\""
            ;;
    esac

    if [[ -n $profile ]]; then
        mkdir -p -- "$(dirname -- "$profile")"
        touch -- "$profile"
        if ! grep -Fq "$bin_dir" "$profile" && ! grep -Fq '"$MOON_INSTALL/bin' "$profile"; then
            printf '\n# moon\n%s\n' "$profile_line" >>"$profile"
            info "Added $bin_dir to PATH in $profile"
        fi
    fi
fi

success "moon was installed successfully to $exe"
printf '%s\n' "$version_output" | sed -n '1p'
if [[ $path_ready == true ]]; then
    printf "Run '%smoon --help%s' to get started.\n" "$color_bold" "$color_reset"
elif [[ -n $profile ]]; then
    printf "Start a new shell, then run '%smoon --help%s'.\n" "$color_bold" "$color_reset"
else
    printf 'Add %s to PATH, then run '\''moon --help'\''.\n' "$bin_dir"
fi

for editor in ${editors[@]+"${editors[@]}"}; do
    install_editor "$editor"
done
