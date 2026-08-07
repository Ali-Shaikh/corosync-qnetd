# corosync-qnetd, the server half of a Corosync QDevice.
#
# Debian 13 "trixie" is the base because Proxmox VE 9 is itself built on trixie.
# Keeping the base aligned keeps this image on the same corosync 3.0.x branch as
# the cluster nodes, so the qnetd server here and the corosync-qdevice clients
# there speak the same protocol.
FROM debian:trixie-slim

# corosync-qnetd is the server half of the QDevice pair. The client half is
# corosync-qdevice, which belongs on the Proxmox nodes, so it is deliberately
# not installed here.
#
# openssh-server is required rather than optional: "pvecm qdevice setup" drives
# the entire certificate exchange over SSH as root, and reaches the host with
# ssh-copy-id on first contact.
#
# The Debian postinst for corosync-qnetd runs "corosync-qnetd-certutil -i -G",
# which creates a CA and its private key under the nssdb directory at build
# time. Publishing that would hand every pull of this image the same CA private
# key, so the directory is recreated empty in the same layer. The entrypoint
# generates a fresh CA on first start instead.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        corosync-qnetd \
        openssh-server \
    && rm -rf /etc/corosync/qnetd/nssdb \
    && mkdir -p /etc/corosync/qnetd/nssdb \
    && chown root:coroqnetd /etc/corosync/qnetd/nssdb \
    && chmod 0750 /etc/corosync/qnetd/nssdb \
    && mkdir -p /root/.ssh \
    && chmod 0700 /root/.ssh \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

# The CA and every signed node certificate live here. Losing this directory does
# not raise an error anywhere, it just silently stops the QDevice voting, and the
# cluster carries on until the next time it actually needs the extra vote. It has
# to outlive the container.
VOLUME ["/etc/corosync/qnetd/nssdb"]

# 5403 is TCP, not UDP. corosync-qnetd listens on a TCP socket, which "ss -lntp"
# inside this image confirms. Several published images and setup guides map it as
# UDP, which yields a QDevice that never connects and no obvious error to explain
# why. 22 is for the SSH access that "pvecm qdevice setup" needs.
EXPOSE 22/tcp 5403/tcp

# corosync-qnetd-tool exits non-zero when it cannot reach the daemon socket
# (verified: exit code 3 with the daemon stopped), so this genuinely fails rather
# than reporting healthy against a dead daemon.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD corosync-qnetd-tool -s >/dev/null 2>&1 || exit 1

# No root password is baked in. The entrypoint requires either a mounted
# authorized_keys file or a ROOT_PASSWORD supplied at run time.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
