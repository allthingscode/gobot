#!/usr/bin/env bash
# Provision a fresh WSL2 Ubuntu (or any Debian-family) distro to run Crucible's
# PowerShell test suite under pwsh 7 - a local mirror of the CI ubuntu-latest leg
# (.github/workflows/ci.yml). Idempotent: re-running skips already-installed tools.
#
# This installs TOOLS only. It does not clone the repo or run tests; see the
# "Local Linux testing with WSL" section of CONTRIBUTING.md for those steps.
#
# Usage (inside the distro):
#   bash scripts/wsl-bootstrap.sh
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
export DEBIAN_FRONTEND=noninteractive

have() { command -v "$1" >/dev/null 2>&1; }

echo "==> apt update + base packages"
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq wget curl ca-certificates apt-transport-https gnupg jq git rsync

# --- Go (factory_lint) -------------------------------------------------------
if have go; then
  echo "==> Go present: $(go version)"
else
  echo "==> Installing Go (golang-go)"
  $SUDO apt-get install -y -qq golang-go
fi

# --- gh (GitHub CLI) ---------------------------------------------------------
# GitHub's hosted ubuntu-latest ships gh preinstalled; the factory-doctor test
# asserts on gh auth state, so without gh that one test fails locally even though
# nothing is wrong with the framework. Install gh to match CI.
if have gh; then
  echo "==> gh present: $(gh --version | head -n1)"
else
  echo "==> Installing gh (GitHub CLI) from cli.github.com"
  $SUDO mkdir -p -m 755 /etc/apt/keyrings
  wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    | $SUDO tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  $SUDO chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    | $SUDO tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq gh
fi

# --- PowerShell 7 ------------------------------------------------------------
# Prefer Microsoft's apt repo; fall back to the GitHub release tarball. As of
# Ubuntu 26.04 the MS repo has no powershell package, so the tarball path is the
# one that actually runs there - do not remove it.
if have pwsh; then
  echo "==> pwsh present: $(pwsh --version)"
else
  echo "==> Installing PowerShell 7"
  installed_via=""
  . /etc/os-release
  ms_deb_url="https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb"
  if wget -q -O /tmp/ms-prod.deb "$ms_deb_url"; then
    $SUDO dpkg -i /tmp/ms-prod.deb && rm -f /tmp/ms-prod.deb
    $SUDO apt-get update -qq
    if $SUDO apt-get install -y -qq powershell; then installed_via="apt"; fi
  fi
  if [ -z "$installed_via" ]; then
    echo "    MS apt repo has no powershell for ${VERSION_ID}; using GitHub tarball"
    case "$(dpkg --print-architecture)" in
      amd64) pwsh_arch="linux-x64" ;;
      arm64) pwsh_arch="linux-arm64" ;;
      *) echo "unsupported arch $(dpkg --print-architecture)"; exit 2 ;;
    esac
    $SUDO apt-get install -y -qq libicu-dev
    tag="$(curl -fsSL https://api.github.com/repos/PowerShell/PowerShell/releases/latest | jq -r .tag_name)"
    ver="${tag#v}"
    tar_url="https://github.com/PowerShell/PowerShell/releases/download/${tag}/powershell-${ver}-${pwsh_arch}.tar.gz"
    echo "    downloading $tar_url"
    curl -fsSL -o /tmp/pwsh.tar.gz "$tar_url"
    $SUDO mkdir -p /opt/microsoft/powershell/7
    $SUDO tar zxf /tmp/pwsh.tar.gz -C /opt/microsoft/powershell/7
    $SUDO chmod +x /opt/microsoft/powershell/7/pwsh
    $SUDO ln -sf /opt/microsoft/powershell/7/pwsh /usr/bin/pwsh
    rm -f /tmp/pwsh.tar.gz
    installed_via="tarball"
  fi
  echo "    pwsh installed via $installed_via"
fi

# --- Git identity ------------------------------------------------------------
# Several tests create temp repos and commit; a missing global identity makes
# those commits fail. CI sets one explicitly - match that here if unset.
if ! git config --global user.email >/dev/null 2>&1; then
  echo "==> Setting placeholder global git identity (override if you like)"
  git config --global user.email "dev@localhost"
  git config --global user.name "Crucible Dev"
fi

echo ""
echo "==> Done. Versions:"
printf '    git  : %s\n' "$(git --version)"
printf '    pwsh : %s\n' "$(pwsh --version)"
printf '    go   : %s\n' "$(go version)"
printf '    gh   : %s\n' "$(gh --version | head -n1)"
echo ""
echo "Next: clone into the LINUX filesystem (not /mnt/c) and run the suite -"
echo "see CONTRIBUTING.md -> 'Local Linux testing with WSL'."
