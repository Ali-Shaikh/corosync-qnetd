#!/bin/sh
#
# Entrypoint for the corosync-qnetd QDevice container.
#
# Two jobs, in order: make sure the container is reachable over SSH so that
# "pvecm qdevice setup" can complete, then hand PID 1 to the qnetd daemon.

set -eu

NSSDB_DIR=/etc/corosync/qnetd/nssdb
AUTHORIZED_KEYS=/root/.ssh/authorized_keys
SSHD_DROPIN=/etc/ssh/sshd_config.d/10-qnetd.conf

log() {
    echo "[qnetd-entrypoint] $*"
}

fatal() {
    echo "[qnetd-entrypoint] ERROR: $*" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Check the SSH configuration before anything else
# ---------------------------------------------------------------------------
# The Proxmox documentation is explicit that the external QDevice host needs
# key-based root access, or root password login allowed for the duration of the
# setup. Without one of the two, "pvecm qdevice setup" cannot exchange
# certificates and the QDevice will never come up, so refuse to start rather
# than run a daemon nobody can finish configuring.
#
# This check runs before the certificate database is touched, so that a
# misconfigured container fails without having written anything to the volume.
keys_present=false
if [ -s "${AUTHORIZED_KEYS}" ]; then
    keys_present=true
fi

if [ "${keys_present}" = false ] && [ -z "${ROOT_PASSWORD:-}" ]; then
    fatal "No SSH access is configured, so pvecm qdevice setup would not be able to log in.

Choose one of the following and start the container again:

  * Mount a public key at ${AUTHORIZED_KEYS}. This is the preferred option:
      -v /mnt/user/appdata/qnetd/authorized_keys:/root/.ssh/authorized_keys:ro

  * Set the ROOT_PASSWORD environment variable, which allows root password
    login so that ssh-copy-id can deliver its key on first contact:
      -e ROOT_PASSWORD=<a password you choose>
    Clear it again once pvecm qdevice setup has finished."
fi

# ---------------------------------------------------------------------------
# Certificate database
# ---------------------------------------------------------------------------
# The CA is created on first start rather than at build time, so that every
# deployment gets its own key rather than one shared by everybody who pulls the
# published image. When the nssdb volume is already populated this is a no-op,
# which is what preserves the signed node certificates across a recreate.
if [ ! -f "${NSSDB_DIR}/cert9.db" ]; then
    log "No certificate database in ${NSSDB_DIR}, initialising a new QNetd CA"
    corosync-qnetd-certutil -i >/dev/null
else
    log "Existing certificate database found in ${NSSDB_DIR}, leaving it untouched"
fi

# ---------------------------------------------------------------------------
# Apply the SSH configuration
# ---------------------------------------------------------------------------
mkdir -p /etc/ssh/sshd_config.d /run/sshd

if [ "${keys_present}" = true ]; then
    log "Found ${AUTHORIZED_KEYS}, using key-based root login with passwords disabled"

    # sshd refuses key authentication when the ownership or mode of these paths
    # is too permissive. A read-only bind mount cannot be chmodded, which is
    # fine and expected, so neither failure is fatal.
    chmod 0700 /root/.ssh 2>/dev/null \
        || log "Could not chmod /root/.ssh, continuing (read-only mount?)"
    chmod 0600 "${AUTHORIZED_KEYS}" 2>/dev/null \
        || log "Could not chmod ${AUTHORIZED_KEYS}, continuing (read-only mount?)"

    cat > "${SSHD_DROPIN}" <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
EOF

    if [ -n "${ROOT_PASSWORD:-}" ]; then
        log "ROOT_PASSWORD is set as well, but mounted keys take precedence, so password authentication stays off"
    fi

else
    log "No keys mounted, enabling root password login so that ssh-copy-id can reach this container"
    echo "root:${ROOT_PASSWORD}" | chpasswd

    cat > "${SSHD_DROPIN}" <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
EOF
fi

chmod 0600 "${SSHD_DROPIN}"

# Host keys are generated per deployment rather than baked into the image, so
# that two containers from the same image do not share an identity.
ssh-keygen -A >/dev/null

log "Starting sshd"
/usr/sbin/sshd

# ---------------------------------------------------------------------------
# Hand over to the daemon
# ---------------------------------------------------------------------------
# -f is the foreground flag. This is not an assumption: the Debian trixie unit
# at /usr/lib/systemd/system/corosync-qnetd.service runs
# "ExecStart=/usr/bin/corosync-qnetd -f", and running the binary with -f blocks
# while running it without -f returns immediately and daemonises.
#
# exec matters. It replaces this shell so that corosync-qnetd becomes PID 1 and
# receives SIGTERM directly from "docker stop", which lets it shut down at once
# instead of being killed after the ten second grace period.
log "Starting corosync-qnetd in the foreground as PID 1"
exec /usr/bin/corosync-qnetd -f "$@"
