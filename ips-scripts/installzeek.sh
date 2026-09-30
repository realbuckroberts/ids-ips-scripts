#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# Zeek installer for Ubuntu
# ------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "Please run this script with sudo:"
    echo "  sudo $0"
    exit 1
fi

echo "[+] Detecting Ubuntu version..."

source /etc/os-release

if [[ "${ID}" != "ubuntu" ]]; then
    echo "ERROR: This script is intended for Ubuntu."
    echo "Detected: ${PRETTY_NAME:-unknown}"
    exit 1
fi

UBUNTU_VERSION="${VERSION_ID}"

case "$UBUNTU_VERSION" in
    22.04)
        ZEEK_REPO="xUbuntu_22.04"
        ;;
    24.04)
        ZEEK_REPO="xUbuntu_24.04"
        ;;
    *)
        echo "ERROR: Unsupported Ubuntu version: $UBUNTU_VERSION"
        echo
        echo "Supported versions:"
        echo "  Ubuntu 22.04"
        echo "  Ubuntu 24.04"
        exit 1
        ;;
esac

echo "[+] Detected: ${PRETTY_NAME}"
echo "[+] Using Zeek repository: ${ZEEK_REPO}"

# ------------------------------------------------------------
# Dependencies
# ------------------------------------------------------------

echo "[+] Installing prerequisites..."

apt-get update
apt-get install -y \
    ca-certificates \
    curl \
    gnupg

# ------------------------------------------------------------
# Zeek repository
# ------------------------------------------------------------

REPO_FILE="/etc/apt/sources.list.d/security:zeek.list"
KEY_FILE="/etc/apt/trusted.gpg.d/security_zeek.gpg"

echo "[+] Adding Zeek repository..."

cat > "$REPO_FILE" <<EOF
deb https://download.opensuse.org/repositories/security:/zeek/${ZEEK_REPO}/ /
EOF

curl -fsSL \
    "https://download.opensuse.org/repositories/security:/zeek/${ZEEK_REPO}/Release.key" \
    | gpg --dearmor --yes -o "$KEY_FILE"

# ------------------------------------------------------------
# Install Zeek
# ------------------------------------------------------------

echo "[+] Updating package lists..."

apt-get update

echo "[+] Installing Zeek..."

apt-get install -y zeek-8.0

# ------------------------------------------------------------
# PATH configuration
# ------------------------------------------------------------

ZEEK_BIN="/opt/zeek/bin"

echo "[+] Configuring PATH..."

cat > /etc/profile.d/zeek.sh <<EOF
export PATH="${ZEEK_BIN}:\$PATH"
EOF

export PATH="${ZEEK_BIN}:$PATH"

# ------------------------------------------------------------
# Verification
# ------------------------------------------------------------

echo
echo "[+] Verifying installation..."

if ! command -v zeek >/dev/null 2>&1; then
    echo "ERROR: Zeek was installed but could not be found in PATH."
    echo
    echo "Try:"
    echo "  source /etc/profile.d/zeek.sh"
    echo "  zeek --version"
    exit 1
fi

echo
echo "============================================"
echo " Zeek installation successful"
echo "============================================"
echo
echo "Version:"
zeek --version

echo
echo "Binary:"
command -v zeek

echo
echo "Zeek installation directory:"
echo "/opt/zeek"

echo
echo "Next steps:"
echo
echo "  source /etc/profile.d/zeek.sh"
echo "  zeek --version"
echo
echo "For live traffic monitoring, configure:"
echo "  /opt/zeek/etc/node.cfg"
echo

