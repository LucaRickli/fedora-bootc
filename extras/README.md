# Extras

What only some machines get, each an image of its own: `extras/<name>/` is
the OS plus the features in its `features/`, in the format of
[`features/`](../features/README.md) (without `build.sh`), and gets the tags
`<name>` and `<name>-uki`. Every folder here is one: `just images` lists
them, CI builds, scans and publishes each, and a release moves its tags. A
name is the image's tags, so it may not be one that is taken: `latest`,
`live`, `base`, `*-uki`, `*-split`, `build-*`.

[`image/extra.Containerfile`](../image/extra.Containerfile) builds every extra
on top of the OS: its packages in one transaction, a signing step, its
overlays, then the same `finalize.sh` as the OS. An extra adds files and
replaces none of the OS's: an overlay path the OS already has fails the
build. An extra's feature can have one file more:

| File      | What it is                                                                  | When it runs                                                                                                  |
| --------- | --------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `sign.sh` | what needs the Secure Boot db key (nvidia signs its kernel modules with it) | after the transaction, in a step of its own with the key and no network ([`image/sign.sh`](../image/sign.sh)) |

`just build <name> [flavor]` builds and seals one; `flavor` reaches its
`sign.sh` and `setup.sh` as `$FLAVOR`. An image that combines extras is a
folder of its own whose features are links to theirs, so its packages
resolve in one transaction:

```sh
mkdir -p extras/nvidia-gaming/features
ln -s ../../nvidia/features/nvidia extras/nvidia-gaming/features/nvidia
ln -s ../../gaming/features/gaming extras/nvidia-gaming/features/gaming
```

| Extra    |                                                                                                                                                                      |
| -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `nvidia` | the NVIDIA driver, its kernel module built and signed at build time; the installer puts it on the GPUs its open modules support ([docs/os.md](../docs/os.md#nvidia)) |
