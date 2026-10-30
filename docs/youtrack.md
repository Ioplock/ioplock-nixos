# YouTrack

Mimosa enables `myYoutrack`, which configures the native NixOS
`services.youtrack` service and a Traefik route for `youtrack.ioplock.su`.
The service listens on loopback port 8081, with a 768m JVM heap and a 1G
systemd memory cap.

## Image mirror decision (2026-10-30)

The nixpkgs YouTrack package extracts the application from JetBrains' Docker
image during its build; the resulting service runs directly with Java.
Direct requests to Docker Hub authentication timed out on Mimosa. Requests
through sing-box worked, but builds should not depend on a local VPN/proxy.
The exact pinned manifest was reachable directly through Timeweb (HTTP 200),
but full Skopeo downloads stalled. Disabling HTTP/2 improved progress but
still left slow transfers. Google's `mirror.gcr.io` completed the full
image fetch on Mimosa with the standard Skopeo transport and the unchanged
nixpkgs archive hash. We selected Google's mirror based on this full fetch,
rather than the manifest-only test of Timeweb.

A repeat Google download also stalled on Mimosa, so this decision removes
the observed Docker Hub authentication dependency but does not establish
that large downloads are consistently reliable on this network. The
successful archive was reused for the package build check. No proxy or
HTTP transport workaround is configured by this feature.

`modules/features/youtrack.nix` therefore builds `packages.myYoutrack` by
overriding only the package's `dockerTools.pullImage` registry endpoint to
`mirror.gcr.io`. This override is local to YouTrack. Docker daemon
registry mirror settings do not affect this fetch, which uses Skopeo.

The image digest, architecture, version, and fixed-output archive hash remain
owned by the pinned nixpkgs package. `finalImageName` preserves the original
image name inside the archive, since changing it would change the archive
hash. A mirror must serve the expected content: Nix still verifies the
upstream hash, and TLS verification remains enabled. There is no automatic
fallback to Docker Hub, which would reintroduce the failing network path.

The mirror adds a third-party availability dependency. Google caches popular
public images and may evict them; it does not guarantee that a particular
digest will remain cached. New YouTrack versions may not be cached yet.
If it stops serving the pinned image, select another reachable registry
serving the same image, or remove the override once direct Docker Hub access
is reliable. Do not
replace the upstream hash merely to accept different mirror content.

After updating nixpkgs, inspect its YouTrack package for fetch API changes
and verify the complete image download and package build, not just the
manifest. The NixOS module also overrides the package's `statePath`; the
package override must continue to support this.

Validation on 2026-10-30: `nix flake check` and both host dry-builds passed.
The complete Google mirror image fetch passed the upstream fixed-output
hash check. The subsequent package build was stopped after the nixpkgs
QEMU image-export step stopped showing progress; extraction, the final
package, and service startup have not been verified. Nothing was activated.

```bash
nix flake check
nixos-rebuild dry-build --flake .#acrux
nixos-rebuild dry-build --flake .#mimosa
nix build --no-link .#myYoutrack
```

References:

- [Google Docker Hub cache documentation](https://cloud.google.com/artifact-registry/docs/pull-cached-dockerhub-images)
- [Timeweb registry mirror documentation](https://timeweb.cloud/tutorials/docker/ispolzovanie-storonnego-reestra-docker)
- [Nixpkgs dockerTools.pullImage documentation](https://github.com/NixOS/nixpkgs/blob/master/doc/build-helpers/images/dockertools.section.md)
- [JetBrains installation documentation](https://www.jetbrains.com/help/youtrack/server/youtrack-docker-installation.html)
