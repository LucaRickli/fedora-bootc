# Virtualization

Virtual Machine Manager (`virt-manager`) uses the system's libvirt
(`qemu:///system`), as does `virt-install --connect qemu:///system`. Accounts
the installer created manage VMs without a password. For another account, run
this command and log in again:

```sh
sudo usermod -aG libvirt USERNAME
```
