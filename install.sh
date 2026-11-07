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
Usage: install.sh [version] [editor] [options]

Installs the moon toolchain and, optionally, one editor integration.

Arguments:
  version               latest (default) or vX.Y.Z; MOON_VERSION also sets this
  editor                same as --editor

Options:
  --editor NAME         vscode, sublime, jetbrains, neovim, or zed
                        (also accepts code, subl, and nvim)
  --editor-path CMD     editor command to use (vscode, neovim)
  --editor-config DIR   where the integration is installed:
                          vscode     extensions directory
                          sublime    Packages directory
                          jetbrains  one IDE's plugins directory
                          neovim     config directory
  --editor-only         keep the installed toolchain; install only the editor
  -h, --help            show this help
EOF
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
    printf '%s' "$digest" | tr '[:upper:]' '[:lower:]'
}

find_vscode() {
    local macos_cli="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
    [[ -z $editor_cli ]] || return 0
    if command -v code >/dev/null 2>&1; then
        editor_cli=$(command -v code)
    elif [[ -x $macos_cli ]]; then
        editor_cli=$macos_cli
    else
        error "could not find the 'code' command; pass --editor-path"
    fi
}

find_sublime_packages() {
    local candidate candidates
    [[ ${#editor_targets[@]} -eq 0 ]] || return 0
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
            editor_targets=("$candidate")
            return 0
        fi
    done
    error "could not find Sublime Text's Packages directory; pass --editor-config"
}

# Every IDE that can load the plugin gets it. Older IDEs reject it, because
# the plugin's since-build is 262 (2026.2).
find_jetbrains_plugins() {
    local config_root plugin_root plugin_suffix="" product_dir product
    [[ ${#editor_targets[@]} -eq 0 ]] || return 0
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
            editor_targets+=("$plugin_root/$product$plugin_suffix")
        fi
    done
    [[ ${#editor_targets[@]} -gt 0 ]] ||
        error "found no JetBrains IDE at version 2026.2 or newer; pass --editor-config"
}

check_neovim_requirements() {
    local compiler
    if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
        error "Neovim setup requires bash 4.4 or newer (running $BASH_VERSION)"
    fi
    for compiler in "${CC:-cc}" gcc clang; do
        command -v "$compiler" >/dev/null 2>&1 && return 0
    done
    error "a C compiler is required to build the Neovim parser (set CC, or install cc, gcc, or clang)"
}

# Runs before the toolchain is touched, so a bad editor request changes nothing.
prepare_editor() {
    case "$(printf '%s' "$editor" | tr '[:upper:]' '[:lower:]')" in
        vscode | code) editor=vscode ;;
        sublime | subl) editor=sublime ;;
        jetbrains) editor=jetbrains ;;
        neovim | nvim) editor=neovim ;;
        zed) editor=zed ;;
        *) error "unknown editor '$editor' (use vscode, sublime, jetbrains, neovim, or zed)" ;;
    esac
    case "$editor" in
        sublime | jetbrains | zed)
            [[ -z $editor_path ]] || error "--editor-path does not apply to $editor"
            ;;
    esac
    [[ $editor != zed || -z $editor_config ]] || error "--editor-config does not apply to zed"

    if [[ -n $editor_path ]]; then
        editor_cli=$(command -v -- "$editor_path") ||
            error "editor command not found: '$editor_path'"
    fi
    if [[ -n $editor_config ]]; then
        case "$editor_config" in
            /*) ;;
            *) editor_config="$PWD/$editor_config" ;;
        esac
        editor_targets=("$editor_config")
    fi
    if [[ $editor != vscode ]] && ! command -v unzip >/dev/null 2>&1; then
        error "unzip is required to install the $editor integration"
    fi
    case "$editor" in
        vscode) find_vscode ;;
        sublime) find_sublime_packages ;;
        jetbrains) find_jetbrains_plugins ;;
        neovim) check_neovim_requirements ;;
    esac
}

find_moon() {
    local installed="${MOON_INSTALL:-$HOME/.moon}/bin/moon"
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
    expected=$(printf '%s' "$expected" | tr '[:upper:]' '[:lower:]')
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

    # Neovim's generated config and Zed's dev extension keep pointing at these
    # files, so they live outside the toolchain directory that upgrades replace.
    data_dir="${XDG_DATA_HOME:-$HOME/.local/share}/moon/editors"

    case "$editor" in
        vscode)
            download_editor_asset moon-vscode.vsix
            args=(--install-extension "$temp_dir/moon-vscode.vsix" --force)
            [[ -z $editor_config ]] || args+=(--extensions-dir "$editor_config")
            "$editor_cli" "${args[@]}" || error "'$editor_cli' could not install the extension"
            success "moon extension installed with $editor_cli"
            ;;
        sublime)
            fetch_editor_package moon-sublime
            replace_dir "$temp_dir/moon-sublime" "${editor_targets[0]}/moon-sublime"
            success "moon package installed to ${editor_targets[0]}/moon-sublime"
            printf 'For language server features, set up the LSP package as described in its README.md.\n'
            ;;
        jetbrains)
            fetch_editor_package moon-jetbrains
            for target in "${editor_targets[@]}"; do
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
            [[ -z $editor_config ]] || args=(--config-dir "$editor_config")
            setup_path=$(dirname -- "$exe"):$PATH
            [[ -z $editor_cli ]] || setup_path=$(dirname -- "$editor_cli"):$setup_path
            MOON=$exe PATH=$setup_path "$BASH" "$bundle/editors/nvim/setup.sh" "${args[@]}" ||
                error "Neovim setup failed"
            ;;
        zed)
            fetch_editor_package moon-zed
            replace_dir "$temp_dir/moon-zed" "$data_dir/moon-zed"
            success "moon extension unpacked to $data_dir/moon-zed"
            printf "Finish in Zed: run '%szed: install dev extension%s' and select that directory.\n" \
                "$color_bold" "$color_reset"
            printf 'Zed builds it with Rust, which must be installed through rustup.\n'
            ;;
    esac
)

requested_version=""
editor=""
editor_path=""
editor_config=""
editor_only=false
editor_cli=""
editor_targets=()
positional_count=0
while (( $# > 0 )); do
    case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
        --editor | --editor-path | --editor-config)
            (( $# >= 2 )) || error "$1 requires a value"
            case "$1" in
                --editor) editor=$2 ;;
                --editor-path) editor_path=$2 ;;
                --editor-config) editor_config=$2 ;;
            esac
            shift 2
            ;;
        --editor-only)
            editor_only=true
            shift
            ;;
        -*)
            error "unknown option '$1' (see --help)"
            ;;
        *)
            positional_count=$((positional_count + 1))
            case "$positional_count" in
                1) requested_version=$1 ;;
                2) editor=$1 ;;
                *) error "expected at most a version and an editor (for example: v1.0.0 nvim)" ;;
            esac
            shift
            ;;
    esac
done

if [[ -z $editor ]]; then
    [[ -z $editor_path && -z $editor_config ]] ||
        error "--editor-path and --editor-config require an editor"
    [[ $editor_only == false ]] || error "--editor-only requires an editor"
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

[[ -z $editor ]] || prepare_editor
if [[ $editor_only == true ]]; then
    find_moon
    install_editor
    exit 0
fi

install_input=${MOON_INSTALL:-$HOME/.moon}
[[ -n $install_input ]] || error "MOON_INSTALL must not be empty"
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

[[ -z $editor ]] || install_editor
