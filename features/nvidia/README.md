# NVIDIA driver

The image has RPM Fusion's NVIDIA driver with the open kernel modules, which
support GTX 16 / RTX 20 series GPUs and newer. Without an NVIDIA GPU, the
modules don't load, and OpenGL and Vulkan programs use Mesa. An older NVIDIA
GPU gets `nouveau` once the system has started; the boot splash says so on
every boot.

The modules are signed with the Secure Boot db key, so they load with Secure
Boot on, through the kernel's platform keyring, without shim or a Machine Owner
Key (MOK). This is untested on hardware. To check it after you enroll the keys,
run:

```sh
lsmod | grep '^nvidia'                        # loaded
modinfo -F signer nvidia                      # the db certificate's name
journalctl -k -b | grep -i 'Loaded X.509'     # the db certificate among those the kernel took from the firmware
```

If the kernel refuses the modules, `nvidia-fallback.service` loads `nouveau`
instead, and `journalctl -b | grep -i nvidia` shows why.

> [!IMPORTANT]
> When you [enroll the Secure Boot keys](../../docs/secureboot-tpm2.md#enroll-the-keys),
> choose the `fedora-bootc-and-microsoft` set for a machine with an NVIDIA
> card. Microsoft signs the card's firmware, and without that set, the card
> might show no picture before the OS starts.
