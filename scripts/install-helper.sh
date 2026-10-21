#!/bin/bash
# One-time installer for the NTFS Mount privileged helper.
# Usage: sudo bash install-helper.sh /path/to/NTFSMount.app/Contents/Resources
set -euo pipefail

RESOURCES="${1:-}"
HELPER_DIR="/usr/local/libexec/ntfsmount"
HELPER="$HELPER_DIR/ntfsmount-helper"
NTFS3G="$HELPER_DIR/ntfs-3g"
SUDOERS="/etc/sudoers.d/ntfsmount"

fail() { echo "install: $*" >&2; exit 1; }

if [[ -z "$RESOURCES" ]]; then
    fail "missing resources directory argument"
fi
if [[ "$(id -u)" -ne 0 ]]; then
    fail "must run as root"
fi

for f in ntfsmount-helper ntfs-3g install-helper.sh; do
    [[ -f "$RESOURCES/$f" ]] || fail "missing $RESOURCES/$f"
done
[[ -e /usr/local/lib/libfuse-t.dylib ]] || fail "FUSE-T is not installed (expected /usr/local/lib/libfuse-t.dylib)"

CONSOLE_USER="$(stat -f '%Su' /dev/console)"
CONSOLE_UID="$(stat -f '%u' /dev/console)"
if [[ -z "$CONSOLE_USER" || "$CONSOLE_USER" == "root" ]]; then
    CONSOLE_USER="${SUDO_USER:-}"
    CONSOLE_UID="$(id -u "$CONSOLE_USER" 2>/dev/null || echo 0)"
fi
[[ "$CONSOLE_UID" -ge 500 ]] || fail "cannot determine the logged-in desktop user"

install -d -o root -g wheel -m 0755 "$HELPER_DIR"
install -o root -g wheel -m 0755 "$RESOURCES/ntfsmount-helper" "$HELPER"
install -o root -g wheel -m 0755 "$RESOURCES/ntfs-3g" "$NTFS3G"

# Ad-hoc signatures keep arm64 code pages valid after copying.
/usr/bin/codesign --force --sign - "$HELPER" >/dev/null 2>&1 || true
/usr/bin/codesign --force --sign - "$NTFS3G" >/dev/null 2>&1 || true

umask 022
printf '%s ALL=(root) NOPASSWD: %s\n' "$CONSOLE_USER" "$HELPER" > "$SUDOERS"
chown root:wheel "$SUDOERS"
chmod 0440 "$SUDOERS"
/usr/sbin/visudo -c >/dev/null || { rm -f "$SUDOERS"; fail "sudoers validation failed"; }

# Drop the development-only test entry if present.
rm -f /etc/sudoers.d/ntfsmount-test

if ! /usr/bin/sudo -u "$CONSOLE_USER" /usr/bin/sudo -n "$HELPER" ping | grep -q '"ok":true'; then
    fail "helper failed its self-test"
fi

echo "Installed NTFS Mount helper for $CONSOLE_USER."
echo "Helper: $HELPER"
echo "Driver:  $NTFS3G"
