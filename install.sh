#!/usr/bin/env bash
# Install a GitHub-backed static Nginx site on Ubuntu/Debian.
set -Eeuo pipefail

readonly SITE_NAME="${SITE_NAME:-github-nginx-site}"
readonly SITE_DOMAIN="${SITE_DOMAIN:-_}"
readonly SITE_REPOSITORY_URL="${SITE_REPOSITORY_URL:-https://github.com/xik54/nginx-site-content.git}"
readonly INSTALLER_REPOSITORY_URL="${INSTALLER_REPOSITORY_URL:-https://github.com/xik54/nginx-vps-installer.git}"
readonly BRANCH="${BRANCH:-main}"
readonly SITE_REPO_DIR="${SITE_REPO_DIR:-/opt/nginx-site-content}"
readonly INSTALLER_REPO_DIR="${INSTALLER_REPO_DIR:-/opt/nginx-vps-installer}"
readonly WEB_ROOT="${WEB_ROOT:-/var/www/${SITE_NAME}}"
readonly NGINX_AVAILABLE_DIR="${NGINX_AVAILABLE_DIR:-/etc/nginx/sites-available}"
readonly NGINX_ENABLED_DIR="${NGINX_ENABLED_DIR:-/etc/nginx/sites-enabled}"
readonly NGINX_MAIN_CONFIG="${NGINX_MAIN_CONFIG:-}"
readonly NGINX_BIN="${NGINX_BIN:-nginx}"
readonly CONFIG_DIR="${CONFIG_DIR:-/etc/${SITE_NAME}}"
readonly SYNC_SCRIPT_PATH="${SYNC_SCRIPT_PATH:-/usr/local/sbin/${SITE_NAME}-sync}"
readonly SYSTEMD_UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
readonly SYNC_INTERVAL="${SYNC_INTERVAL:-5min}"
readonly LETSENCRYPT_LIVE_DIR="${LETSENCRYPT_LIVE_DIR:-/etc/letsencrypt/live}"
readonly SKIP_APT="${SKIP_APT:-0}"
readonly SKIP_SYSTEMCTL="${SKIP_SYSTEMCTL:-0}"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die 'Run with sudo: curl ... | sudo env SITE_DOMAIN=your.domain bash'
}

validate_settings() {
  [[ "${SITE_NAME}" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || die 'SITE_NAME must contain lowercase letters, digits, or hyphens.'
  [[ "${SITE_DOMAIN}" == '_' || "${SITE_DOMAIN}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die 'SITE_DOMAIN must be one hostname (or _ during local testing).'
  [[ "${BRANCH}" =~ ^[A-Za-z0-9._/-]+$ ]] || die 'BRANCH contains unsupported characters.'
}

install_packages() {
  if [[ "${SKIP_APT}" == '1' ]]; then
    command -v git >/dev/null || die 'git is required when SKIP_APT=1.'
    command -v rsync >/dev/null || die 'rsync is required when SKIP_APT=1.'
    command -v "${NGINX_BIN}" >/dev/null || die "${NGINX_BIN} is required when SKIP_APT=1."
    return
  fi

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates git nginx rsync
}

checkout_repository() {
  local repository_url="$1"
  local repository_dir="$2"

  if [[ -d "${repository_dir}/.git" ]]; then
    git -C "${repository_dir}" fetch --quiet origin "${BRANCH}"
    git -C "${repository_dir}" checkout --quiet --detach "origin/${BRANCH}"
  else
    install -d -m 0755 "$(dirname "${repository_dir}")"
    git clone --branch "${BRANCH}" --single-branch "${repository_url}" "${repository_dir}"
    git -C "${repository_dir}" checkout --quiet --detach "origin/${BRANCH}"
  fi
}

write_settings() {
  install -d -m 0755 "${CONFIG_DIR}"
  cat > "${CONFIG_DIR}/settings" <<SETTINGS
SITE_NAME=$(printf '%q' "${SITE_NAME}")
SITE_DOMAIN=$(printf '%q' "${SITE_DOMAIN}")
SITE_REPOSITORY_URL=$(printf '%q' "${SITE_REPOSITORY_URL}")
INSTALLER_REPOSITORY_URL=$(printf '%q' "${INSTALLER_REPOSITORY_URL}")
BRANCH=$(printf '%q' "${BRANCH}")
SITE_REPO_DIR=$(printf '%q' "${SITE_REPO_DIR}")
WEB_ROOT=$(printf '%q' "${WEB_ROOT}")
NGINX_AVAILABLE_DIR=$(printf '%q' "${NGINX_AVAILABLE_DIR}")
NGINX_ENABLED_DIR=$(printf '%q' "${NGINX_ENABLED_DIR}")
NGINX_MAIN_CONFIG=$(printf '%q' "${NGINX_MAIN_CONFIG}")
NGINX_BIN=$(printf '%q' "${NGINX_BIN}")
LETSENCRYPT_LIVE_DIR=$(printf '%q' "${LETSENCRYPT_LIVE_DIR}")
SKIP_SYSTEMCTL=$(printf '%q' "${SKIP_SYSTEMCTL}")
SETTINGS
  chmod 0600 "${CONFIG_DIR}/settings"
}

write_systemd_units() {
  cat > "${SYSTEMD_UNIT_DIR}/${SITE_NAME}-sync.service" <<SERVICE
[Unit]
Description=Safely sync ${SITE_NAME} from GitHub and reload Nginx
Wants=network-online.target
After=network-online.target nginx.service

[Service]
Type=oneshot
Environment=SETTINGS_FILE=${CONFIG_DIR}/settings
ExecStart=${SYNC_SCRIPT_PATH}
SERVICE

  cat > "${SYSTEMD_UNIT_DIR}/${SITE_NAME}-sync.timer" <<TIMER
[Unit]
Description=Periodically sync ${SITE_NAME} from GitHub

[Timer]
OnBootSec=2min
OnUnitActiveSec=${SYNC_INTERVAL}
Persistent=true

[Install]
WantedBy=timers.target
TIMER
}

systemctl_safe() {
  if [[ "${SKIP_SYSTEMCTL}" == '1' ]]; then
    printf '%s\n' "Skipping systemctl $* (SKIP_SYSTEMCTL=1)."
    return
  fi
  systemctl "$@"
}

main() {
  require_root
  validate_settings
  install_packages
  checkout_repository "${INSTALLER_REPOSITORY_URL}" "${INSTALLER_REPO_DIR}"
  checkout_repository "${SITE_REPOSITORY_URL}" "${SITE_REPO_DIR}"

  # Files created through GitHub's web API may not retain an executable mode.
  # `install -m 0755` below establishes the required mode on the VPS.
  [[ -f "${INSTALLER_REPO_DIR}/scripts/sync-nginx-site" ]] || die 'Installer repository is missing scripts/sync-nginx-site.'
  [[ -d "${SITE_REPO_DIR}/site" || -d "${SITE_REPO_DIR}/dist" ]] \
    || die 'Site repository must contain site/ or dist/.'

  install -d -m 0755 \
    "${WEB_ROOT}" \
    "${NGINX_AVAILABLE_DIR}" \
    "${NGINX_ENABLED_DIR}" \
    "${SYSTEMD_UNIT_DIR}" \
    "$(dirname "${SYNC_SCRIPT_PATH}")"
  install -m 0755 "${INSTALLER_REPO_DIR}/scripts/sync-nginx-site" "${SYNC_SCRIPT_PATH}"
  write_settings
  write_systemd_units
  systemctl_safe daemon-reload
  SETTINGS_FILE="${CONFIG_DIR}/settings" "${SYNC_SCRIPT_PATH}"
  systemctl_safe enable --now "${SITE_NAME}-sync.timer"

  printf '\nInstalled %s for %s.\n' "${SITE_NAME}" "${SITE_DOMAIN}"
  printf 'Manual sync: sudo systemctl start %s-sync.service\n' "${SITE_NAME}"
}

main "$@"
