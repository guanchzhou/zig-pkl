# Security policy

## Supported versions

| Version | Supported |
| --- | --- |
| 0.1.x | yes |

Before 1.0, only the latest minor release line receives fixes.

## Reporting a vulnerability

Use [private vulnerability reporting](https://github.com/guanchzhou/zig-pkl/security/advisories/new).

Do not open a public issue for a suspected vulnerability. Include the Zig version, Pkl version, operating system, and a reproduction. Please allow a fix to be prepared before public discussion.

## Release integrity

Annotated release tags are signed by Andrey Maltsev. The signing key id is `2B1FC5CCF0740068`.

A release `vX.Y.Z` includes a source archive, SHA-256 checksums, SPDX and CycloneDX SBOMs, a keyless cosign bundle over the checksums, and GitHub artifact attestations. The Pkl package `zig` is published from the same commit as the GitHub release `zig@X.Y.Z`. Before a release is published, the workflow checks the signature, builds a consumer package against the archive with `zig fetch`, and compares the archive's package hash with the tag's.

To verify a downloaded release:

```sh
git verify-tag v0.1.0
sha256sum --check --ignore-missing SHA256SUMS
cosign verify-blob SHA256SUMS --bundle SHA256SUMS.bundle \
  --certificate-identity https://github.com/guanchzhou/zig-pkl/.github/workflows/release.yml@refs/tags/v0.1.0 \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
gh attestation verify zig-pkl-0.1.0.tar.gz --repo guanchzhou/zig-pkl
```
