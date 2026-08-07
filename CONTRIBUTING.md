# Contributing

Issues and pull requests are welcome.

## Reporting a problem

Corosync problems are usually environmental, so please include:

- The Proxmox VE version and the output of `pvecm status` from a node.
- The output of `docker exec qnetd corosync-qnetd-tool -s` from the QDevice host.
- The container logs, `docker logs qnetd`.
- How the container is networked, since the most common causes are port 5403
  being mapped as UDP rather than TCP, and the container not having its own IP
  address.

Please redact addresses and hostnames you would rather not publish.

## Pull requests

- Branch from `main` and open a pull request. Please do not push to `main`.
- Keep to British English in documentation and comments, and do not use em
  dashes.
- Check package names and command flags against the actual trixie packages
  rather than from memory. If something cannot be verified, say so in the pull
  request rather than guessing.
- Run `shellcheck entrypoint.sh` before submitting.

## Testing a change

Build and run it before opening a pull request:

```console
docker build -t corosync-qnetd:local .
docker volume create qnetd-test
docker run -d --name qnetd-test \
  -e ROOT_PASSWORD=testing \
  -v qnetd-test:/etc/corosync/qnetd/nssdb \
  corosync-qnetd:local
```

Then confirm all of the following:

- `docker exec qnetd-test corosync-qnetd-tool -s` reports the listener on 5403.
- `docker inspect --format '{{.State.Health.Status}}' qnetd-test` is `healthy`.
- `docker stop qnetd-test` returns in well under ten seconds and exits `0`,
  which is what proves the daemon is PID 1 and receives SIGTERM.
- Removing and recreating the container against the same volume leaves the CA
  unchanged, which you can check with
  `sha256sum /etc/corosync/qnetd/nssdb/qnetd-cacert.crt` before and after.

Multi-architecture changes should also build for arm64:

```console
docker buildx build --platform linux/amd64,linux/arm64 .
```

## Docker Hub metadata

The Hub description and overview are not updated by the publish workflow. If you
change how the image is used, update `scripts/update-dockerhub-metadata.ps1` in
the same pull request. Running it needs push rights to the `cloudsprocket`
namespace.
