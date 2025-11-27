#!/usr/bin/env bash

set -euo pipefail

RELEASE_TAG="latest"
CORE_TYPE=""
CORE_ARG_PROVIDED=false

STDIN_IS_TTY=false
if [ -t 0 ]; then
    STDIN_IS_TTY=true
fi

print_usage() {
    cat <<'EOF'
Usage: install_core.sh [--core xray|sing-box|both] [version]

When no version is provided the latest stable release will be installed.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
    --core)
        CORE_TYPE="${2:-xray}"
        CORE_ARG_PROVIDED=true
        shift 2
        ;;
    --core=*)
        CORE_TYPE="${1#*=}"
        CORE_ARG_PROVIDED=true
        shift
        ;;
    -h|--help)
        print_usage
        exit 0
        ;;
    *)
        RELEASE_TAG="$1"
        shift
        ;;
    esac
done

CORE_TYPE=$(echo "$CORE_TYPE" | tr '[:upper:]' '[:lower:]')

prompt_for_core_selection() {
    if [ "$CORE_ARG_PROVIDED" = true ]; then
        CORE_TYPE=${CORE_TYPE:-xray}
        return
    fi

    if [ "$STDIN_IS_TTY" = false ]; then
        CORE_TYPE="xray"
        return
    fi

    echo "Select which core to install:"
    echo "  1) Xray"
    echo "  2) Sing-Box"
    echo "  3) Both"
    read -rp "Choice [1]: " selection
    case "$selection" in
        2)
            CORE_TYPE="sing-box"
            ;;
        3)
            CORE_TYPE="both"
            ;;
        ""|1|*)
            CORE_TYPE="xray"
            ;;
    esac
}

install_xray_release() {
    local requested_tag="${1:-latest}"
    local previous_tag="$RELEASE_TAG"
    RELEASE_TAG="$requested_tag"
    TMP_DIRECTORY="$(mktemp -d)"
    ZIP_FILE="${TMP_DIRECTORY}/Xray-linux-$ARCH.zip"
    download_xray
    extract_xray
    place_xray
    rm -rf "$TMP_DIRECTORY"
    RELEASE_TAG="$previous_tag"
}

install_singbox_release() {
    local requested_tag="${1:-latest}"
    local previous_tag="$RELEASE_TAG"
    RELEASE_TAG="$requested_tag"
    TMP_DIRECTORY="$(mktemp -d)"
    local resolved_tag
    resolved_tag=$(resolve_singbox_tag)
    download_singbox "$resolved_tag"
    extract_singbox
    place_singbox
    rm -rf "$TMP_DIRECTORY"
    RELEASE_TAG="$previous_tag"
}

prompt_install_other_core() {
    local installed_core="$1"
    if [ "$STDIN_IS_TTY" = false ]; then
        return
    fi

    local other_core
    if [ "$installed_core" = "xray" ]; then
        other_core="sing-box"
    else
        other_core="xray"
    fi

    read -rp "Install ${other_core} as well? (y/N): " install_other
    if [[ ! "$install_other" =~ ^[Yy]$ ]]; then
        return
    fi

    if [ "$other_core" = "sing-box" ]; then
        read -rp "Enter Sing-Box version tag (default latest): " second_version
        install_singbox_release "${second_version:-latest}"
    else
        read -rp "Enter Xray version tag (default latest): " second_version
        install_xray_release "${second_version:-latest}"
    fi
}

prompt_for_core_selection

CORE_TYPE=${CORE_TYPE:-xray}

check_if_running_as_root() {
    # If you want to run as another user, please modify $EUID to be owned by this user
    if [[ "$EUID" -ne '0' ]]; then
        echo "error: You must run this script as root!"
        exit 1
    fi
}

identify_the_operating_system_and_architecture() {
    if [[ "$(uname)" == 'Linux' ]]; then
        case "$(uname -m)" in
            'i386' | 'i686')
                ARCH='32'
            ;;
            'amd64' | 'x86_64')
                ARCH='64'
            ;;
            'armv5tel')
                ARCH='arm32-v5'
            ;;
            'armv6l')
                ARCH='arm32-v6'
                grep Features /proc/cpuinfo | grep -qw 'vfp' || ARCH='arm32-v5'
            ;;
            'armv7' | 'armv7l')
                ARCH='arm32-v7a'
                grep Features /proc/cpuinfo | grep -qw 'vfp' || ARCH='arm32-v5'
            ;;
            'armv8' | 'aarch64')
                ARCH='arm64-v8a'
            ;;
            'mips')
                ARCH='mips32'
            ;;
            'mipsle')
                ARCH='mips32le'
            ;;
            'mips64')
                ARCH='mips64'
                lscpu | grep -q "Little Endian" && ARCH='mips64le'
            ;;
            'mips64le')
                ARCH='mips64le'
            ;;
            'ppc64')
                ARCH='ppc64'
            ;;
            'ppc64le')
                ARCH='ppc64le'
            ;;
            'riscv64')
                ARCH='riscv64'
            ;;
            's390x')
                ARCH='s390x'
            ;;
            *)
                echo "error: The architecture is not supported."
                exit 1
            ;;
        esac
    else
        echo "error: This operating system is not supported."
        exit 1
    fi
}

map_singbox_arch() {
    case "$ARCH" in
        '64' | 'x86_64') echo "amd64" ;;
        'arm64-v8a' | 'aarch64') echo "arm64" ;;
        'arm32-v7a') echo "armv7" ;;
        '32' | 'i386' | 'i686') echo "386" ;;
        *) echo "" ;;
    esac
}

resolve_singbox_tag() {
    if [[ "$RELEASE_TAG" != "latest" ]]; then
        echo "$RELEASE_TAG"
        return
    fi

    local latest_tag
    latest_tag=$(curl -fsSL "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep -Po '"tag_name"\s*:\s*"\K[^"]+') || true
    if [[ -z "$latest_tag" ]]; then
        echo "error: failed to resolve latest sing-box release" >&2
        exit 1
    fi
    echo "$latest_tag"
}

download_xray() {
    if [[ "$RELEASE_TAG" == "latest" ]]; then
        DOWNLOAD_LINK="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$ARCH.zip"
    else
        DOWNLOAD_LINK="https://github.com/XTLS/Xray-core/releases/download/$RELEASE_TAG/Xray-linux-$ARCH.zip"
    fi
    
    echo "Downloading Xray archive: $DOWNLOAD_LINK"
    if ! curl -RL -H 'Cache-Control: no-cache' -o "$ZIP_FILE" "$DOWNLOAD_LINK"; then
        echo 'error: Download failed! Please check your network or try again.'
        return 1
    fi
}

extract_xray() {
    if ! unzip -q "$ZIP_FILE" -d "$TMP_DIRECTORY"; then
        echo 'error: Xray decompression failed.'
        "rm" -rf "$TMP_DIRECTORY"
        echo "removed: $TMP_DIRECTORY"
        exit 1
    fi
    echo "Extracted Xray archive to $TMP_DIRECTORY"
}

place_xray() {
    install -m 755 "${TMP_DIRECTORY}/xray" "/usr/local/bin/xray"
    install -d "/usr/local/share/xray/"
    install -m 644 "${TMP_DIRECTORY}/geoip.dat" "/usr/local/share/xray/geoip.dat"
    install -m 644 "${TMP_DIRECTORY}/geosite.dat" "/usr/local/share/xray/geosite.dat"
    echo "Xray files installed"
}

download_singbox() {
    local tag="$1"
    local version_no_v="${tag#v}"
    local sing_arch
    sing_arch=$(map_singbox_arch)

    if [[ -z "$sing_arch" ]]; then
        echo "error: unsupported architecture $ARCH for sing-box" >&2
        exit 1
    fi

    local file_name="sing-box-${version_no_v}-linux-${sing_arch}.tar.gz"
    DOWNLOAD_LINK="https://github.com/SagerNet/sing-box/releases/download/${tag}/${file_name}"
    TAR_FILE="${TMP_DIRECTORY}/${file_name}"

    echo "Downloading Sing-Box archive: $DOWNLOAD_LINK"
    if ! curl -RL -H 'Cache-Control: no-cache' -o "$TAR_FILE" "$DOWNLOAD_LINK"; then
        echo 'error: Download failed! Please check your network or try again.'
        return 1
    fi
    SINGBOX_EXTRACT_DIR="$TMP_DIRECTORY/sing-box-${version_no_v}-linux-${sing_arch}"
}

extract_singbox() {
    if ! tar -xzf "$TAR_FILE" -C "$TMP_DIRECTORY"; then
        echo 'error: Sing-Box decompression failed.'
        "rm" -rf "$TMP_DIRECTORY"
        echo "removed: $TMP_DIRECTORY"
        exit 1
    fi
    echo "Extracted Sing-Box archive to $TMP_DIRECTORY"
}

place_singbox() {
    install -m 755 "${SINGBOX_EXTRACT_DIR}/sing-box" "/usr/local/bin/sing-box"
    install -d "/usr/local/share/sing-box/"
    for data_file in geoip.db geosite.db geoip.mmdb geosite.mmdb; do
        if [[ -f "${SINGBOX_EXTRACT_DIR}/${data_file}" ]]; then
            install -m 644 "${SINGBOX_EXTRACT_DIR}/${data_file}" "/usr/local/share/sing-box/${data_file}"
        fi
    done
    echo "Sing-Box files installed"
}

check_if_running_as_root
identify_the_operating_system_and_architecture

case "$CORE_TYPE" in
    xray)
        install_xray_release "$RELEASE_TAG"
        prompt_install_other_core "xray"
        ;;
    sing-box|singbox|sing)
        install_singbox_release "$RELEASE_TAG"
        prompt_install_other_core "sing-box"
        ;;
    both|all)
        install_xray_release "$RELEASE_TAG"
        sing_prompt_version="latest"
        if [ "$STDIN_IS_TTY" = true ]; then
            read -rp "Enter Sing-Box version tag (default latest): " sing_prompt_version
        fi
        install_singbox_release "${sing_prompt_version:-latest}"
        ;;
    *)
        echo "error: unsupported core type '$CORE_TYPE'"
        exit 1
        ;;
esac