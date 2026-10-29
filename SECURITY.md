# Security policy

## Supported versions

Only the most recent release receives fixes. A release moves the `latest`,
`latest-uki`, `nvidia`, `nvidia-uki`, and `live` tags of
`ghcr.io/lucarickli/fedora-bootc`. Older releases and `build-SHA` tags receive
no fixes.

## Report a vulnerability

[Open a private security advisory](https://github.com/lucarickli/fedora-bootc/security/advisories/new).
Don't use an issue, a pull request, or a discussion, because they're public.

Include these details:

- What's affected: an image tag, a release, or a file or feature
- How to reproduce it
- What it allows

A patch is welcome. You get a reply in the advisory.

## How fixes are released

- Every build applies Fedora's stable updates first, and Renovate keeps pinned
  tools, GitHub Actions, and container images current, as described in
  [Dependency updates](docs/architecture/updates.md#dependency-updates). Every
  image must [pass a scan](docs/architecture/updates.md#scanning) before it's
  pushed.
- A release ships every Monday. When the published images lack a critical
  Fedora security update, a security release follows within a day.
- A machine takes a release only when you run
  [`sudo bootc upgrade`](README.md#operating-system) on it and reboot.

## Verify an image

CI [signs every image with cosign](docs/architecture/updates.md#signing). To
verify an image against `keys/cosign.pub`, run `just verify IMAGE` or this
command from a checkout of this repository:

```sh
cosign verify --key keys/cosign.pub --insecure-ignore-tlog=true \
  ghcr.io/lucarickli/fedora-bootc:latest-uki
```

The command passes `--insecure-ignore-tlog=true` because CI signs without a
transparency log entry. Machines verify every pull of these images the same
way, against their own copy of the key. With
[Secure Boot](docs/secureboot-tpm2.md) on, a sealed image boots only where the
[Secure Boot keys](keys/README.md) of `keys/` are enrolled.

## Scope

This policy covers the OS images, the live ISO, and the CI that builds, scans,
signs, and releases them. Report a bug in Fedora, bootc, a package, or another
upstream tool to that project.
