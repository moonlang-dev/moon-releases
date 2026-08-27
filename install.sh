#!/usr/bin/env bash
set -euo pipefail

# Release archives contain one top-level `moon/` install tree with bin/, lib/,
# and include/. Every archive has a sibling `<archive>.sha256` release asset.

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

if (( $# > 1 )); then
    error "expected at most one version (for example: v1.0.0)"
fi

requested_version=${1:-${MOON_VERSION:-latest}}
case "$requested_version" in
    latest)
        release_path="latest/download"
        ;;
    v[0-9]*.[0-9]*.[0-9]* | [0-9]*.[0-9]*.[0-9]*)
        if [[ ! $requested_version =~ ^v?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
            error "invalid Moon version '$requested_version'"
        fi
        tag=${requested_version#v}
        release_path="download/v$tag"
        ;;
    *)
        error "invalid Moon version '$requested_version' (use latest or vX.Y.Z)"
        ;;
esac

os=$(uname -s)
arch=$(uname -m)
case "$os" in
    Linux) os=linux ;;
    Darwin) error "Moon tagged releases do not currently include macOS builds" ;;
    *) error "Moon tagged releases do not support $(uname -s) through this installer" ;;
esac
case "$arch" in
    x86_64 | amd64) arch=x86_64 ;;
    *) error "Moon tagged releases currently support only x86_64 (detected '$arch')" ;;
esac

for command in curl tar; do
    command -v "$command" >/dev/null 2>&1 || error "$command is required to install Moon"
done

github=${MOON_GITHUB:-$DEFAULT_GITHUB}
repository=${MOON_GITHUB_REPO:-$DEFAULT_REPOSITORY}
asset="moon-$os-$arch.tar.gz"
url="$github/$repository/releases/$release_path/$asset"

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

archive="$work_dir/$asset"
checksum_file="$archive.sha256"
info "Downloading $url"
curl --fail --location --retry 3 --progress-bar --output "$archive" "$url" ||
    error "failed to download '$url'"
curl --fail --location --retry 3 --silent --show-error \
    --output "$checksum_file" "$url.sha256" ||
    error "failed to download '$url.sha256'"

read -r expected_checksum _ <"$checksum_file" ||
    error "checksum asset is empty: '$url.sha256'"
expected_checksum=${expected_checksum//$'\r'/}
expected_checksum=$(printf '%s' "$expected_checksum" | tr '[:upper:]' '[:lower:]')
[[ $expected_checksum =~ ^[0-9a-f]{64}$ ]] ||
    error "checksum asset does not start with a SHA-256 digest"

if command -v sha256sum >/dev/null 2>&1; then
    actual_checksum=$(sha256sum "$archive" | awk '{print $1}')
elif command -v shasum >/dev/null 2>&1; then
    actual_checksum=$(shasum -a 256 "$archive" | awk '{print $1}')
elif command -v openssl >/dev/null 2>&1; then
    actual_checksum=$(openssl dgst -sha256 "$archive" | awk '{print $NF}')
else
    error "sha256sum, shasum, or openssl is required to verify Moon"
fi
actual_checksum=$(printf '%s' "$actual_checksum" | tr '[:upper:]' '[:lower:]')
[[ $actual_checksum == "$expected_checksum" ]] ||
    error "checksum verification failed for '$asset'"

# Reject absolute paths, parent traversal, links, and files outside the one
# documented top-level directory before asking tar to write anything.
while IFS= read -r entry; do
    entry=${entry#./}
    case "/$entry/" in
        */../*) error "release archive contains parent traversal: '$entry'" ;;
    esac
    case "$entry" in
        moon | moon/*) ;;
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
staged_dir="$extract_dir/moon"
[[ -f $staged_dir/bin/moon ]] || error "release archive does not contain moon/bin/moon"
[[ -d $staged_dir/lib ]] || error "release archive does not contain moon/lib"
[[ -d $staged_dir/include ]] || error "release archive does not contain moon/include"
chmod +x "$staged_dir/bin/moon"

if [[ -d $install_dir ]]; then
    mv -- "$install_dir" "$backup_dir" || error "failed to stage the existing Moon installation"
fi
replacement_started=true
if ! mv -- "$staged_dir" "$install_dir"; then
    error "failed to install Moon to '$install_dir'"
fi

exe="$install_dir/bin/moon"
if ! version_output=$("$exe" version 2>&1); then
    error "installed Moon could not start:\n$version_output"
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
            printf '\n# Moon\n%s\n' "$profile_line" >>"$profile"
            info "Added $bin_dir to PATH in $profile"
        fi
    fi
fi

success "Moon was installed successfully to $exe"
printf '%s\n' "$version_output" | sed -n '1p'
if [[ $path_ready == true ]]; then
    printf "Run '%smoon --help%s' to get started.\n" "$color_bold" "$color_reset"
elif [[ -n $profile ]]; then
    printf "Start a new shell, then run '%smoon --help%s'.\n" "$color_bold" "$color_reset"
else
    printf 'Add %s to PATH, then run '\''moon --help'\''.\n' "$bin_dir"
fi
