#!/usr/bin/with-contenv bash
# Web login is set exactly once. On first start it is derived from
# PASSWORD/CUSTOM_USER and written to /config (persistent volume) together
# with a marker file. On every later start this script is a no-op, so
# changing PASSWORD/CUSTOM_USER in the compose file has no effect anymore -
# by design, so the login can't be reset just by editing the environment.
#
# nginx is pointed at /config/.htpasswd via root/defaults/default.conf,
# which always has auth_basic enabled - independent of whatever the base
# image's own init-nginx step does with PASSWORD/ /etc/nginx/.htpasswd.

set -e

MARKER="/config/.aegisub_auth_initialized"
HTPASSWD="/config/.htpasswd"
CUSER="${CUSTOM_USER:-admin}"

mkdir -p /config
# Bind-mounted host folders can arrive with restrictive permissions; nginx's
# www-data worker needs the 'x' (traverse) bit on /config to reach
# .htpasswd at all, regardless of the file's own mode. Safe to force open
# here since /config only holds this app's own settings.
chmod 755 /config

if [ -f "$MARKER" ]; then
  echo "[aegisub-auth] Login already locked (set on $(cat "$MARKER")). Ignoring PASSWORD/CUSTOM_USER."
  exit 0
fi

# Refuse to lock in the placeholder shipped in docker-compose.yml - if it
# were used as-is, the real login would be a value published in this repo.
if [ -z "${PASSWORD}" ] || [ "${PASSWORD}" = "changeme_on_first_run" ]; then
  PASSWORD="$(openssl rand -base64 12)"
  echo "############################################################"
  echo "# [aegisub-auth] PASSWORD was unset or left as the shipped   #"
  echo "# placeholder - refusing to lock that in. Generated instead: #"
  echo "#   user:     ${CUSER}"
  echo "#   password: ${PASSWORD}"
  echo "# Shown only this once - save it now.                        #"
  echo "############################################################"
fi

printf '%s:%s\n' "${CUSER}" "$(openssl passwd -apr1 "${PASSWORD}")" > "$HTPASSWD"
chown abc:abc "$HTPASSWD"
# 644, not 600: nginx worker processes run as www-data (stock Debian nginx
# package default) and read this file per-request via auth_basic_module -
# a mode that only 'abc' can read would make every login fail with a 500.
chmod 644 "$HTPASSWD"
date > "$MARKER"
chown abc:abc "$MARKER"

echo "[aegisub-auth] Login locked for user '${CUSER}'."
echo "[aegisub-auth] To change it later: stop the container, delete ${HTPASSWD} and ${MARKER} from the appdata volume, then start again with a new PASSWORD."
