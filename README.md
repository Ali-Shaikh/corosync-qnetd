# corosync-qnetd

A Debian 13 "trixie" container image of `corosync-qnetd`, the server side of a
Corosync QDevice, intended as an external quorum arbitrator for a Proxmox VE 9
cluster.

```
cloudsprocket/corosync-qnetd
```

Built on trixie deliberately. Proxmox VE 9 is itself a trixie derivative, so this
keeps the qnetd server on the same corosync 3.0.x branch as the
`corosync-qdevice` clients running on the nodes.

Available for `linux/amd64` and `linux/arm64`, so it runs equally well on an
Unraid box or a Raspberry Pi.

## Contents

- [What a QDevice is, and when you need one](#what-a-qdevice-is-and-when-you-need-one)
- [The quorum arithmetic](#the-quorum-arithmetic)
- [Running the container](#running-the-container)
- [Configuration reference](#configuration-reference)
- [Unraid specifics](#unraid-specifics)
- [Setting up the Proxmox side](#setting-up-the-proxmox-side)
- [Verifying it works](#verifying-it-works)
- [Troubleshooting](#troubleshooting)
- [Building locally](#building-locally)

## What a QDevice is, and when you need one

Corosync keeps a cluster consistent by requiring a majority of votes before a
partition is allowed to run resources. Each node normally holds one vote, and a
partition is quorate when it holds more than half of the total. That rule is what
stops two halves of a split cluster from both deciding they are in charge and
corrupting shared storage.

The rule works badly when the cluster has an even number of votes, and it works
badly when most of the cluster is switched off. A four node cluster has four
votes and needs three of them. Two nodes on their own hold two votes, so they are
inquorate and will not start a VM, even though nothing is broken and both nodes
can see each other perfectly well.

A QDevice fixes this by adding a vote that does not live on any node. It is made
of two halves:

- `corosync-qnetd`, the arbitrator daemon. It runs somewhere outside the cluster,
  which is what this image provides.
- `corosync-qdevice`, the client. It runs on every Proxmox node and asks the
  arbitrator whether its partition should be allowed to hold the extra vote.

The arbitrator grants its vote to one partition only, so the extra vote breaks
ties rather than creating new ones.

Reach for a QDevice when either of these is true:

- The cluster has an even number of nodes, most commonly two, and you want it to
  survive losing one of them.
- You deliberately run a subset of the cluster, for example because you power
  nodes down to save electricity, and the subset does not hold a majority on its
  own.

This repository exists for the second case: a four node cluster with two nodes
shut down most of the time.

## The quorum arithmetic

Quorum is `floor(expected_votes / 2) + 1`.

Without a QDevice a four node cluster has four expected votes, so it needs three.
Adding a QDevice to an even numbered cluster adds exactly one vote, using the
`ffsplit` algorithm, giving five expected votes. Five still needs three, and that
is the whole trick: the total went up by one but the threshold did not.

**Four nodes, no QDevice. Expected votes 4, quorum 3.**

| Nodes running | Node votes | QDevice | Total | Needed | Quorate? |
| --- | --- | --- | --- | --- | --- |
| 4 | 4 | not present | 4 | 3 | Yes |
| 3 | 3 | not present | 3 | 3 | Yes, and exactly at the line |
| 2 | 2 | not present | 2 | 3 | **No** |
| 1 | 1 | not present | 1 | 3 | No |

**Four nodes plus a QDevice. Expected votes 5, quorum 3.**

| Nodes running | Node votes | QDevice | Total | Needed | Quorate? |
| --- | --- | --- | --- | --- | --- |
| 4 | 4 | 1 | 5 | 3 | Yes |
| 3 | 3 | 1 | 4 | 3 | Yes |
| 2 | 2 | 1 | 3 | 3 | **Yes, and exactly at the line** |
| 2 | 2 | unreachable | 2 | 3 | No |
| 1 | 1 | 1 | 2 | 3 | No |

The row that matters for the power saving setup is two nodes plus the QDevice.
That configuration is quorate at exactly three votes out of three, with **zero
headroom**. Every one of the following drops the cluster below quorum on its own:

- Either running node goes down or reboots, including for updates.
- The QDevice container stops, or the Unraid host it runs on reboots.
- The network path between the nodes and the QDevice breaks.

So the QDevice buys the ability to run with two nodes at all. It does not buy any
tolerance on top of that. If you want the two node configuration to survive a
further failure, the answer is to power on a third node, not to add a second
QDevice, since a cluster may only have one.

A related consequence worth knowing before you build a habit around it: while two
nodes are running with the QDevice, the arbitrator is genuinely load bearing. It
is worth putting it on hardware that stays up, which is the reason for hosting it
on an always on Unraid box rather than on one of the cluster nodes. Running it on
a cluster node would defeat the point entirely, because the vote would disappear
at exactly the moment the cluster needed it.

## Running the container

Two things need to persist or be provided:

- The certificate database at `/etc/corosync/qnetd/nssdb`. It holds the CA and
  every signed node certificate.
- A way for `pvecm qdevice setup` to log in over SSH as root.

### Preferred: mount an SSH public key

```bash
docker run -d \
  --name qnetd \
  --restart unless-stopped \
  --network br0 \
  --ip 192.168.1.50 \
  -v /mnt/user/appdata/qnetd/nssdb:/etc/corosync/qnetd/nssdb \
  -v /mnt/user/appdata/qnetd/authorized_keys:/root/.ssh/authorized_keys:ro \
  cloudsprocket/corosync-qnetd:trixie
```

Populate `authorized_keys` with the root public key of each Proxmox node, one per
line. Nodes use `/root/.ssh/id_rsa.pub` by default:

```bash
cat /root/.ssh/id_rsa.pub
```

With keys mounted, password authentication stays switched off.

### Alternative: a temporary root password

If you would rather let `pvecm qdevice setup` deliver its own key with
`ssh-copy-id`, set a password instead:

```bash
docker run -d \
  --name qnetd \
  --restart unless-stopped \
  --network br0 \
  --ip 192.168.1.50 \
  -v /mnt/user/appdata/qnetd/nssdb:/etc/corosync/qnetd/nssdb \
  -e ROOT_PASSWORD='choose-something-sensible' \
  cloudsprocket/corosync-qnetd:trixie
```

`PermitRootLogin yes` and `PasswordAuthentication yes` are applied only when
`ROOT_PASSWORD` is set. Once setup has finished, recreate the container without
the variable and with the key mounted instead.

The container refuses to start if neither is configured, rather than running a
daemon that nothing can finish configuring.

Note that if you rely on `ssh-copy-id` writing to `/root/.ssh/authorized_keys`
inside the container, that file lives on the container filesystem and is lost on
recreate. It keeps working because `ROOT_PASSWORD` is still set, but mounting the
key from the host is the durable arrangement.

## Configuration reference

| Setting | Value |
| --- | --- |
| Image | `cloudsprocket/corosync-qnetd` |
| Tags | `latest`, `trixie`, and `vX.Y.Z` on tagged releases |
| Platforms | `linux/amd64`, `linux/arm64` |
| Port | `5403/tcp` for the QDevice protocol |
| Port | `22/tcp` for the setup SSH session |
| Volume | `/etc/corosync/qnetd/nssdb` for the certificate database |
| Mount | `/root/.ssh/authorized_keys` for key based access, optional |
| Variable | `ROOT_PASSWORD` enables root password login, optional |

**Port 5403 is TCP, not UDP.** A number of published images and setup guides map
it as UDP. The result is a QDevice that never connects, with nothing in the logs
that points at the mapping as the cause. You can confirm the protocol yourself:

```bash
docker exec qnetd corosync-qnetd-tool -s
```

No root password is baked into the image, and no CA is baked in either. The
Debian package initialises a certificate database during installation, which
would mean every pull of this image shared one CA private key, so the image
deliberately ships that directory empty and the entrypoint generates a fresh CA
on first start.

## Unraid specifics

Three things catch people out on Unraid.

### The container needs its own IP address

Unraid's own management SSH daemon already owns port 22 on the host IP, so
publishing the container's port 22 with `-p 22:22` will either fail or collide.
Give the container its own address on the LAN instead, using `--network br0` and
an explicit `--ip`, as in the examples above. Port 5403 then sits on that address
too, which keeps the Proxmox configuration straightforward.

Pick an address outside your DHCP pool, and treat it as fixed. Changing it later
means redoing the QDevice setup, because the nodes have the old address written
into `/etc/pve/corosync.conf`.

### Leave custom networks on ipvlan

Unraid defaults custom Docker networks to **ipvlan**, and that default is the one
you want. Switching to **macvlan** while the parent interface is a bridge such as
`br0` produces kernel call traces and hard lockups on Unraid. The symptom is a
server that freezes after hours or days, with traces mentioning `macvlan` in the
syslog, which is a miserable thing to debug from a stopped cluster.

Check under **Settings, Docker** that the custom network type is `ipvlan` before
creating the container. If you have previously switched to macvlan for another
container, switch back.

### Keep appdata on the cache pool

Docker on Unraid depends on the array being started. If the array stops, Docker
stops with it, and the QDevice vote disappears at that moment. That is
uncomfortable in the two node configuration described above, where the vote is
the difference between quorate and not.

Keep the `appdata` share on the cache pool, set to stay there rather than being
moved to the array. It keeps the certificate database on fast storage, stops the
mover from relocating live files, and avoids the container waiting on spinning
disks. It does not make Docker independent of the array, so plan Unraid
maintenance for a time when at least three Proxmox nodes are powered on.

### Example Unraid template

Save as `/boot/config/plugins/dockerMan/templates-user/my-corosync-qnetd.xml`.

```xml
<?xml version="1.0"?>
<Container version="2">
  <Name>qnetd</Name>
  <Repository>cloudsprocket/corosync-qnetd:trixie</Repository>
  <Registry>https://hub.docker.com/r/cloudsprocket/corosync-qnetd</Registry>
  <Network>br0</Network>
  <MyIP>192.168.1.50</MyIP>
  <Privileged>false</Privileged>
  <Support>https://github.com/Ali-Shaikh/corosync-qnetd/issues</Support>
  <Project>https://github.com/Ali-Shaikh/corosync-qnetd</Project>
  <Overview>
    External Corosync QDevice arbitrator for a Proxmox VE cluster. Provides the
    extra quorum vote that lets an even numbered cluster, or a cluster running
    with some nodes powered down, stay quorate. Needs its own IP because port 22
    is used for the initial certificate exchange.
  </Overview>
  <Category>Network:Management</Category>
  <WebUI/>
  <Icon>https://raw.githubusercontent.com/Ali-Shaikh/corosync-qnetd/main/icon.png</Icon>
  <ExtraParams>--restart unless-stopped</ExtraParams>
  <Config
    Name="Certificate database"
    Target="/etc/corosync/qnetd/nssdb"
    Default="/mnt/user/appdata/qnetd/nssdb"
    Mode="rw"
    Description="CA and signed node certificates. Must persist, or the QDevice silently stops voting."
    Type="Path"
    Display="always"
    Required="true"
    Mask="false">/mnt/user/appdata/qnetd/nssdb</Config>
  <Config
    Name="authorized_keys"
    Target="/root/.ssh/authorized_keys"
    Default="/mnt/user/appdata/qnetd/authorized_keys"
    Mode="ro"
    Description="Preferred access method. Root public keys of the Proxmox nodes, one per line."
    Type="Path"
    Display="always"
    Required="false"
    Mask="false">/mnt/user/appdata/qnetd/authorized_keys</Config>
  <Config
    Name="ROOT_PASSWORD"
    Target="ROOT_PASSWORD"
    Default=""
    Mode=""
    Description="Only needed if you are not mounting authorized_keys. Allows root password login so that pvecm can copy its key across. Clear it afterwards."
    Type="Variable"
    Display="always"
    Required="false"
    Mask="true"/>
  <Config
    Name="QDevice port"
    Target="5403"
    Default="5403"
    Mode="tcp"
    Description="QDevice protocol. TCP, not UDP."
    Type="Port"
    Display="always"
    Required="true"
    Mask="false">5403</Config>
  <Config
    Name="SSH port"
    Target="22"
    Default="22"
    Mode="tcp"
    Description="Used by pvecm qdevice setup for the certificate exchange."
    Type="Port"
    Display="always"
    Required="true"
    Mask="false">22</Config>
</Container>
```

The template references an `icon.png` that this repository does not ship. Either
add one or drop the `<Icon>` line.

## Setting up the Proxmox side

Install the client half on **every node** in the cluster:

```bash
apt update && apt install corosync-qdevice
```

Then, from **one node only**, point the cluster at the container:

```bash
pvecm qdevice setup 192.168.1.50
```

That single command does the whole certificate exchange. It reaches the container
over SSH as root, collects the CA certificate, generates a certificate request
for the cluster, has the container sign it, and distributes the result to every
node. This is why the container needs SSH access on port 22 and why the
`nssdb` directory has to persist afterwards.

If your cluster has an odd number of nodes, `pvecm` will refuse and ask for
`--force`. Read the caveat in the Proxmox documentation before using it: on an
odd numbered cluster the QDevice is given `N - 1` votes rather than one, which
changes the failure behaviour considerably. The four node case in this README
does not need `--force`.

## Verifying it works

On any Proxmox node:

```bash
pvecm status
```

You are looking for a `Qdevice` line in the membership information and, in the
votequorum section, `Expected votes: 5` with `Quorate: Yes` for the four node
cluster described here. The QDevice should be listed with `A,V,NMW`, meaning
alive, voting, and not the master wins mode.

On the Unraid host:

```bash
docker exec qnetd corosync-qnetd-tool -s
```

Which reports the listener and the clients attached to it:

```
QNetd address:                  *:5403
TLS:                            Supported (client certificate required)
Connected clients:              2
Connected clusters:             1
```

`Connected clients` counts nodes currently talking to the arbitrator, so it
should match the number of nodes powered on, not the size of the cluster. The
same command is what the container's `HEALTHCHECK` runs, so:

```bash
docker inspect --format '{{.State.Health.Status}}' qnetd
```

should report `healthy`.

## Troubleshooting

### The QDevice shows as not registered, or the votes never appear

Check the three things that usually cause it, in order:

1. Port 5403 mapped or firewalled as UDP rather than TCP.
2. The container not reachable at the address written into `corosync.conf`. Check
   with `grep -A5 quorum /etc/pve/corosync.conf` on a node.
3. `corosync-qdevice` not installed on one of the nodes. It is needed on all of
   them, not just the node you ran setup from.

### Starting again from scratch

The certificate exchange is not idempotent. If the databases on the two sides
disagree, for example because the container was recreated without its volume,
resetting both ends is the reliable fix rather than rerunning setup.

On one Proxmox node:

```bash
pvecm qdevice remove
```

Then on the Unraid host, clear the arbitrator's database and let it rebuild:

```bash
docker exec qnetd sh -c 'rm -rf /etc/corosync/qnetd/nssdb/*'
docker restart qnetd
```

The entrypoint notices the empty directory on start and generates a new CA. Then
run the setup again from one node:

```bash
pvecm qdevice setup 192.168.1.50
```

### The container will not start

If the log shows the "No SSH access is configured" error, neither
`/root/.ssh/authorized_keys` nor `ROOT_PASSWORD` was provided. This is deliberate:
without one of them `pvecm qdevice setup` cannot log in, so the container stops
rather than pretending to be ready.

```bash
docker logs qnetd
```

### Permission denied when pvecm connects

If you are mounting `authorized_keys`, check the file is not empty and contains
the root public key of the node you are running `pvecm qdevice setup` from. The
entrypoint tightens the permissions on `/root/.ssh` at start, but a read only
mount cannot be changed, which it logs and carries on from. Read only mounts are
fine.

### Losing the nssdb directory

Worth calling out because it fails quietly. If the certificate database is lost,
the arbitrator comes back with a new CA that the nodes do not trust. Nothing
raises an error at that point. The cluster keeps running on node votes alone, and
the missing vote is only noticed the next time it is actually needed, which is
likely to be while nodes are powered down. Treat the volume as important and
include it in whatever backs up your appdata.

## Building locally

```bash
docker build -t corosync-qnetd:local .
```

The image runs `corosync-qnetd -f` as PID 1. The `-f` flag is the foreground
option, confirmed against the Debian trixie package rather than assumed: the unit
shipped at `/usr/lib/systemd/system/corosync-qnetd.service` uses
`ExecStart=/usr/bin/corosync-qnetd -f`, and running the binary without it returns
immediately and daemonises. Running the daemon as PID 1 rather than behind a
supervisor is what makes `docker stop` return promptly instead of timing out and
killing the container after ten seconds.

Built images are published by GitHub Actions on pushes to `main`, on `v*` tags,
and on a weekly schedule so that Debian security updates are picked up without a
commit.

## Licence

MIT. See [LICENSE](LICENSE).
