<#
.SYNOPSIS
Sets the Docker Hub short description and overview for cloudsprocket/corosync-qnetd.

.DESCRIPTION
Docker Hub metadata is not part of the image push, so it does not update itself
when the workflow publishes. This script applies it from a single source, in the
same shape as the equivalent script in CloudSprocket/ansible-lab-images.

Credentials come from the Docker Desktop credential helper, so no token is
stored here or passed on the command line.

Runs as a dry run by default and reports what is currently live. Pass -Apply to
write the changes.

.EXAMPLE
./scripts/update-dockerhub-metadata.ps1
Shows what is live now without changing anything.

.EXAMPLE
./scripts/update-dockerhub-metadata.ps1 -Apply
Writes the description and overview to Docker Hub.
#>
param(
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'

$namespace = 'cloudsprocket'
$repository = 'corosync-qnetd'
$server = 'https://index.docker.io/v1/'

$credentialJson = $server | & docker-credential-desktop.exe get
if ($LASTEXITCODE -ne 0) {
    throw 'Docker Desktop did not return Docker Hub credentials.'
}

$credential = $credentialJson | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($credential.Username) -or [string]::IsNullOrWhiteSpace($credential.Secret)) {
    throw 'The Docker Hub credential is incomplete.'
}

$tokenRequest = @{
    identifier = $credential.Username
    secret     = $credential.Secret
} | ConvertTo-Json

$tokenResponse = Invoke-RestMethod `
    -Method Post `
    -Uri 'https://hub.docker.com/v2/auth/token' `
    -ContentType 'application/json' `
    -Body $tokenRequest

if ([string]::IsNullOrWhiteSpace($tokenResponse.access_token)) {
    throw 'Docker Hub authentication did not return an access token.'
}

$headers = @{ Authorization = "Bearer $($tokenResponse.access_token)" }

# Docker Hub caps the short description at 100 characters.
$description = 'External Corosync QDevice for Proxmox VE clusters, built on Debian 13 trixie.'

$overview = @'
# corosync-qnetd

External Corosync QDevice arbitrator for Proxmox VE 9 clusters. Supplies the extra quorum vote that lets an even numbered cluster, or a cluster running with some of its nodes powered down, stay quorate.

Built on `debian:trixie-slim`, because Proxmox VE 9 is itself trixie based. That keeps the qnetd server on the same corosync 3.0.x branch as the `corosync-qdevice` clients on the nodes.

## Supported platforms

- `linux/amd64`
- `linux/arm64`

## Tags

- `latest`: current build
- `trixie`: the same build, named for the Debian release it is built on
- `vX.Y.Z`: immutable release, published on tagged builds

## Use

```console
docker run -d \
  --name qnetd \
  --restart unless-stopped \
  --network br0 \
  --ip 192.168.1.50 \
  -v /mnt/user/appdata/qnetd/nssdb:/etc/corosync/qnetd/nssdb \
  -v /mnt/user/appdata/qnetd/authorized_keys:/root/.ssh/authorized_keys:ro \
  cloudsprocket/corosync-qnetd:trixie
```

Then, from one Proxmox node, with `corosync-qdevice` installed on every node:

```console
pvecm qdevice setup 192.168.1.50
```

## Notes

- **Port 5403 is TCP, not UDP.** Mapping it as UDP produces a QDevice that never connects, and nothing in the logs explains why.
- **Persist `/etc/corosync/qnetd/nssdb`.** It holds the CA and the signed node certificates. Losing it does not raise an error, it just silently stops the QDevice voting.
- The container needs SSH access on port 22 for `pvecm qdevice setup`. Mount an `authorized_keys` file, or set `ROOT_PASSWORD` for the initial `ssh-copy-id`. It refuses to start if neither is configured.
- No CA and no root password are baked into the image. A fresh CA is generated on first start.

## Links

- Source, documentation and release notes: https://github.com/Ali-Shaikh/corosync-qnetd
- Contributing guidelines: https://github.com/Ali-Shaikh/corosync-qnetd/blob/main/CONTRIBUTING.md
- Project website: https://labs.cloudsprocket.org/
'@

if ($description.Length -gt 100) {
    throw "Description is $($description.Length) characters, over Docker Hub's 100-character limit."
}

$payload = @{
    description      = $description
    full_description = $overview.Trim()
} | ConvertTo-Json

$uri = "https://hub.docker.com/v2/repositories/$namespace/$repository/"

if ($Apply) {
    $null = Invoke-RestMethod -Method Patch -Uri $uri -Headers $headers -ContentType 'application/json' -Body $payload
}

$current = Invoke-RestMethod -Method Get -Uri $uri
[pscustomobject]@{
    repository      = "$namespace/$repository"
    applied         = [bool]$Apply
    public          = -not [bool]$current.is_private
    description     = $current.description
    overview_length = ([string]$current.full_description).Length
}
