# Boot

Boot shows a splash screen. To see the boot messages, press Esc. To show the
boot menu, hold Space at power-on.

The first boot of an image with a newer systemd-boot puts it on the EFI system
partition. `journalctl -b -u systemd-boot-update` shows what it did.
