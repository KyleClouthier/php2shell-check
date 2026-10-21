#!/usr/bin/env bash
# check-all-php.sh  -  find every PHP install on this server and say which ones still need the PHP2Shell fix.
#
# Servers with cPanel, Plesk, DirectAdmin, CloudLinux, LiteSpeed or several PHP versions often have many PHP
# builds side by side. Each one needs the fix. This lists them all, plus PHP-FPM pools still running old code
# after an update (installed but not restarted).
#
# Usage:   bash check-all-php.sh                     (run as root to also check running PHP-FPM workers)
#          bash check-all-php.sh /path/to/php ...    (also check PHP builds in other places)
# Exit:    0 = everything found is fixed, 1 = something needs action, 2 = no PHP found
# Source:  https://github.com/KyleClouthier/php2shell-check   Browser check: https://simgen.dev/php-patch-check
# Reads only. Changes nothing.

set -u
LC_ALL=C

# Fixed releases per branch (21 October 2026).
fixed_for() {
  case "$1" in
    8.5) echo 8.5.12 ;; 8.4) echo 8.4.27 ;; 8.3) echo 8.3.36 ;; 8.2) echo 8.2.35 ;; *) echo "" ;;
  esac
}

# 0 if $1 >= $2 (dotted versions).
ver_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -n1)" = "$2" ]
}

if [ -t 1 ]; then RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; DIM=$'\033[2m'; OFF=$'\033[0m'; else RED=; YEL=; GRN=; DIM=; OFF=; fi

# Every place control panels and package managers put PHP binaries.
EXTRA=("$@")
candidates() {
  for p in "${EXTRA[@]+"${EXTRA[@]}"}"; do [ -x "$p" ] && echo "$p"; done
  command -v php 2>/dev/null
  for p in \
    /usr/bin/php /usr/bin/php[0-9]* /usr/local/bin/php /usr/local/bin/php[0-9]* \
    /usr/sbin/php-fpm* /usr/local/sbin/php-fpm* \
    /opt/cpanel/ea-php*/root/usr/bin/php /opt/cpanel/ea-php*/root/usr/sbin/php-fpm \
    /opt/alt/php*/usr/bin/php /opt/alt/php*/usr/sbin/php-fpm \
    /opt/plesk/php/*/bin/php /opt/plesk/php/*/sbin/php-fpm \
    /opt/remi/php*/root/usr/bin/php /opt/remi/php*/root/usr/sbin/php-fpm \
    /usr/local/php*/bin/php /usr/local/php*/sbin/php-fpm \
    /usr/local/lsws/lsphp*/bin/php /usr/local/lsws/lsphp*/bin/lsphp \
    /opt/php*/bin/php /opt/homebrew/opt/php*/bin/php /usr/local/opt/php*/bin/php; do
    [ -x "$p" ] && [ ! -d "$p" ] && echo "$p"
  done
}

# Version string from a PHP binary. php-fpm and lsphp do not take -r, so read -v for those.
php_version() {
  local bin="$1" out
  out=$("$bin" -n -v 2>/dev/null | head -n1)
  [ -z "$out" ] && out=$("$bin" -v 2>/dev/null | head -n1)
  printf '%s' "$out"
}

need_action=0
found=0
declare -A seen=()

printf '\n%sPHP2Shell check: every PHP install on %s%s\n\n' "" "$(hostname 2>/dev/null || echo this server)" ""
printf '%-10s %-28s %s\n' "VERSION" "STATUS" "PATH"
printf '%-10s %-28s %s\n' "-------" "------" "----"

while IFS= read -r bin; do
  [ -z "$bin" ] && continue
  real=$(readlink -f "$bin" 2>/dev/null || echo "$bin")
  [ -n "${seen[$real]+x}" ] && continue
  seen[$real]=1

  line=$(php_version "$real")
  ver=$(printf '%s' "$line" | grep -oE 'PHP [0-9]+\.[0-9]+\.[0-9]+' | head -n1 | cut -d' ' -f2)
  [ -z "$ver" ] && continue
  found=$((found + 1))
  branch=$(printf '%s' "$ver" | cut -d. -f1,2)
  fix=$(fixed_for "$branch")
  distro=""
  printf '%s' "$line" | grep -qiE 'ubuntu|debian|deb[0-9]|\.el[0-9]|fedora|suse' && distro=1

  if [ -n "$fix" ]; then
    if ver_ge "$ver" "$fix"; then
      status="${GRN}FIXED${OFF}"
    elif [ -n "$distro" ]; then
      status="${YEL}CHECK DISTRO NOTICE${OFF}"; need_action=1
    else
      status="${RED}UPDATE to $fix${OFF}"; need_action=1
    fi
  else
    major=$(printf '%s' "$ver" | cut -d. -f1); minor=$(printf '%s' "$ver" | cut -d. -f2)
    if [ "$major" -eq 8 ] || { [ "$major" -eq 7 ] && [ "$minor" -eq 4 ]; }; then
      status="${RED}NO RELEASE, needs backport${OFF}"
    else
      status="${RED}END OF LIFE, NO FIX${OFF}"
    fi
    need_action=1
  fi
  # Pad on the plain text so colour codes do not break the columns.
  plain=$(printf '%s' "$status" | sed 's/\x1b\[[0-9;]*m//g')
  printf '%-10s %s%*s %s\n' "$ver" "$status" $((28 - ${#plain})) "" "$real"
done < <(candidates | sort -u)

# Apache mod_php modules: these run inside Apache, so Apache itself must be restarted after an update.
mods=$(ls /usr/lib/apache2/modules/libphp*.so /etc/httpd/modules/libphp*.so /usr/lib64/httpd/modules/libphp*.so /usr/local/apache/modules/libphp*.so 2>/dev/null)
if [ -n "$mods" ]; then
  printf '\n%sApache mod_php found (highest risk per PHP; restart Apache after updating):%s\n' "$YEL" "$OFF"
  printf '  %s\n' $mods
fi

# PHP-FPM masters started before their binary was replaced are still running the old, vulnerable code.
if [ -d /proc ] && command -v pgrep >/dev/null 2>&1; then
  stale=""
  for pid in $(pgrep -f 'php-fpm: master' 2>/dev/null; pgrep -f 'lsphp' 2>/dev/null); do
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || continue
    case "$exe" in *"(deleted)"*) stale="$stale\n  pid $pid  ${exe}  (binary replaced since start)"; continue ;; esac
    started=$(stat -c %Y "/proc/$pid" 2>/dev/null) || continue
    built=$(stat -c %Y "$exe" 2>/dev/null) || continue
    [ "$built" -gt "$started" ] && stale="$stale\n  pid $pid  $exe  (updated after this process started)"
  done
  if [ -n "$stale" ]; then
    need_action=1
    printf '\n%sRESTART NEEDED: these PHP processes are still running the old code:%s' "$RED" "$OFF"
    printf '%b\n' "$stale"
    printf '  Restart PHP-FPM (for example: systemctl restart php8.3-fpm) or the web server.\n'
  elif [ "$(id -u)" != "0" ]; then
    printf '\n%sRun as root to also check that running PHP-FPM workers were restarted.%s\n' "$DIM" "$OFF"
  fi
fi

printf '\n'
if [ "$found" -eq 0 ]; then
  printf 'No PHP binaries found in the usual places. If a site runs PHP, use check-php.php from the web root instead.\n'
  exit 2
fi
if [ "$need_action" -eq 1 ]; then
  printf '%sAction needed.%s Fixed releases: 8.5.12, 8.4.27, 8.3.36, 8.2.35. For 8.1 and older there is no PHP\n' "$RED" "$OFF"
  printf 'release: use your distribution, panel or hosting vendor backport, or move the sites to 8.2 or newer.\n'
  printf 'Distribution builds can carry fixes without a version change: check their security notice.\n'
  printf 'Want a hand? https://simgen.dev/php-patch-check#fix\n\n'
  exit 1
fi
if [ "$found" -eq 1 ]; then what="The PHP install found is"; else what="All $found PHP installs found are"; fi
printf '%s%s on a fixed release.%s Check that nothing was planted before the update.\n\n' "$GRN" "$what" "$OFF"
exit 0
