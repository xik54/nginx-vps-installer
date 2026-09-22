#!/usr/bin/env bash
# Integration verification for Ubuntu. Run as root in a disposable test environment.
set -Eeuo pipefail

readonly PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly TEST_ROOT="${TEST_ROOT:-$(mktemp -d /tmp/github-nginx-site-test.XXXXXX)}"
readonly TEST_INSTALLER_REPO="${TEST_ROOT}/installer.git"
readonly TEST_SITE_REPO="${TEST_ROOT}/site.git"
readonly TEST_INSTALLER_CHECKOUT="${TEST_ROOT}/installer-seed"
readonly TEST_SITE_CHECKOUT="${TEST_ROOT}/site-seed"
readonly INSTALL_ROOT="${TEST_ROOT}/installed"
readonly TEST_SITE_NAME='github-nginx-site'

cleanup() {
  rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

[[ "${EUID}" -eq 0 ]] || { printf 'Run this verification as root.\n' >&2; exit 1; }
command -v git >/dev/null || { printf 'git must be installed before running verification.\n' >&2; exit 1; }
command -v openssl >/dev/null || { printf 'openssl must be installed before running verification.\n' >&2; exit 1; }

mkdir -p "${TEST_ROOT}/etc/nginx/sites-available" "${TEST_ROOT}/etc/nginx/sites-enabled" "${TEST_ROOT}/etc/nginx/conf.d"
cat > "${TEST_ROOT}/etc/nginx/nginx.conf" <<EOF
pid ${TEST_ROOT}/nginx.pid;
error_log stderr notice;
events { worker_connections 64; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    include ${TEST_ROOT}/etc/nginx/sites-enabled/*;
}
EOF

git init --bare "${TEST_INSTALLER_REPO}" >/dev/null
git clone "${TEST_INSTALLER_REPO}" "${TEST_INSTALLER_CHECKOUT}" >/dev/null
shopt -s dotglob nullglob
for source_item in "${PROJECT_ROOT}"/*; do
  source_name="$(basename "${source_item}")"
  [[ "${source_name}" == '.git' || "${source_name}" == 'site-repository' ]] && continue
  cp -a "${source_item}" "${TEST_INSTALLER_CHECKOUT}/"
done
shopt -u dotglob nullglob
git -C "${TEST_INSTALLER_CHECKOUT}" checkout -b main >/dev/null
git -C "${TEST_INSTALLER_CHECKOUT}" config user.name 'Ubuntu verification'
git -C "${TEST_INSTALLER_CHECKOUT}" config user.email 'verification@example.invalid'
git -C "${TEST_INSTALLER_CHECKOUT}" add .
git -C "${TEST_INSTALLER_CHECKOUT}" commit -m 'Initial installer' >/dev/null
git -C "${TEST_INSTALLER_CHECKOUT}" push -u origin main >/dev/null

git init --bare "${TEST_SITE_REPO}" >/dev/null
git clone "${TEST_SITE_REPO}" "${TEST_SITE_CHECKOUT}" >/dev/null
shopt -s dotglob nullglob
for source_item in "${PROJECT_ROOT}/site-repository"/*; do
  cp -a "${source_item}" "${TEST_SITE_CHECKOUT}/"
done
shopt -u dotglob nullglob
git -C "${TEST_SITE_CHECKOUT}" checkout -b main >/dev/null
git -C "${TEST_SITE_CHECKOUT}" config user.name 'Ubuntu verification'
git -C "${TEST_SITE_CHECKOUT}" config user.email 'verification@example.invalid'
git -C "${TEST_SITE_CHECKOUT}" add .
git -C "${TEST_SITE_CHECKOUT}" commit -m 'Initial site' >/dev/null
git -C "${TEST_SITE_CHECKOUT}" push -u origin main >/dev/null

SITE_REPOSITORY_URL="${TEST_SITE_REPO}" \
INSTALLER_REPOSITORY_URL="${TEST_INSTALLER_REPO}" \
SITE_DOMAIN='sync-test.invalid' \
SITE_REPO_DIR="${INSTALL_ROOT}/opt/nginx-site-content" \
INSTALLER_REPO_DIR="${INSTALL_ROOT}/opt/nginx-vps-installer" \
WEB_ROOT="${INSTALL_ROOT}/var/www/${TEST_SITE_NAME}" \
NGINX_AVAILABLE_DIR="${TEST_ROOT}/etc/nginx/sites-available" \
NGINX_ENABLED_DIR="${TEST_ROOT}/etc/nginx/sites-enabled" \
NGINX_MAIN_CONFIG="${TEST_ROOT}/etc/nginx/nginx.conf" \
CONFIG_DIR="${INSTALL_ROOT}/etc/${TEST_SITE_NAME}" \
SYNC_SCRIPT_PATH="${INSTALL_ROOT}/usr/local/sbin/${TEST_SITE_NAME}-sync" \
SYSTEMD_UNIT_DIR="${INSTALL_ROOT}/etc/systemd/system" \
LETSENCRYPT_LIVE_DIR="${TEST_ROOT}/etc/letsencrypt/live" \
SKIP_SYSTEMCTL=1 \
bash "${PROJECT_ROOT}/install.sh"

test -L "${INSTALL_ROOT}/var/www/${TEST_SITE_NAME}/current"
grep -Fq 'GitHub → Nginx 同步已启用' "${INSTALL_ROOT}/var/www/${TEST_SITE_NAME}/current/index.html"
nginx -t -c "${TEST_ROOT}/etc/nginx/nginx.conf" >/dev/null

printf '%s\n' '<!-- verified update -->' >> "${TEST_SITE_CHECKOUT}/site/index.html"
git -C "${TEST_SITE_CHECKOUT}" add site/index.html
git -C "${TEST_SITE_CHECKOUT}" commit -m 'Verify a content update' >/dev/null
git -C "${TEST_SITE_CHECKOUT}" push >/dev/null
SETTINGS_FILE="${INSTALL_ROOT}/etc/${TEST_SITE_NAME}/settings" "${INSTALL_ROOT}/usr/local/sbin/${TEST_SITE_NAME}-sync"
grep -Fq 'verified update' "${INSTALL_ROOT}/var/www/${TEST_SITE_NAME}/current/index.html"

cp "${TEST_SITE_CHECKOUT}/nginx/site.conf.template" "${TEST_SITE_CHECKOUT}/nginx/site.conf.template.good"
printf '%s\n' 'this is invalid nginx syntax;' > "${TEST_SITE_CHECKOUT}/nginx/site.conf.template"
git -C "${TEST_SITE_CHECKOUT}" add nginx/site.conf.template
git -C "${TEST_SITE_CHECKOUT}" commit -m 'Verify invalid Nginx config is rejected' >/dev/null
git -C "${TEST_SITE_CHECKOUT}" push >/dev/null
if SETTINGS_FILE="${INSTALL_ROOT}/etc/${TEST_SITE_NAME}/settings" "${INSTALL_ROOT}/usr/local/sbin/${TEST_SITE_NAME}-sync"; then
  printf 'Expected invalid Nginx configuration to fail.\n' >&2
  exit 1
fi
grep -Fq 'server_name sync-test.invalid;' "${TEST_ROOT}/etc/nginx/sites-available/${TEST_SITE_NAME}.conf"
nginx -t -c "${TEST_ROOT}/etc/nginx/nginx.conf" >/dev/null

rm -rf "${TEST_SITE_CHECKOUT}/site" "${TEST_SITE_CHECKOUT}/nginx"
mkdir -p "${TEST_SITE_CHECKOUT}/dist"
printf '%s\n' '<h1>dist fallback verified</h1>' > "${TEST_SITE_CHECKOUT}/dist/index.html"
git -C "${TEST_SITE_CHECKOUT}" add -A
git -C "${TEST_SITE_CHECKOUT}" commit -m 'Verify dist fallback without Nginx template' >/dev/null
git -C "${TEST_SITE_CHECKOUT}" push >/dev/null
SETTINGS_FILE="${INSTALL_ROOT}/etc/${TEST_SITE_NAME}/settings" "${INSTALL_ROOT}/usr/local/sbin/${TEST_SITE_NAME}-sync"
grep -Fq 'dist fallback verified' "${INSTALL_ROOT}/var/www/${TEST_SITE_NAME}/current/index.html"
grep -Fq 'try_files $uri $uri/ /index.html;' "${TEST_ROOT}/etc/nginx/sites-available/${TEST_SITE_NAME}.conf"

test_certificate_dir="${TEST_ROOT}/etc/letsencrypt/live/sync-test.invalid"
mkdir -p "${test_certificate_dir}"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -subj '/CN=sync-test.invalid' \
  -keyout "${test_certificate_dir}/privkey.pem" \
  -out "${test_certificate_dir}/fullchain.pem" >/dev/null 2>&1
SETTINGS_FILE="${INSTALL_ROOT}/etc/${TEST_SITE_NAME}/settings" "${INSTALL_ROOT}/usr/local/sbin/${TEST_SITE_NAME}-sync"
grep -Fq 'listen 443 ssl;' "${TEST_ROOT}/etc/nginx/sites-available/${TEST_SITE_NAME}.conf"
grep -Fq "ssl_certificate ${test_certificate_dir}/fullchain.pem;" "${TEST_ROOT}/etc/nginx/sites-available/${TEST_SITE_NAME}.conf"
nginx -t -c "${TEST_ROOT}/etc/nginx/nginx.conf" >/dev/null

printf 'Ubuntu integration verification passed.\n'
