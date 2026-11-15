# Tailscale

Tailscale runs from upstream's container image, `ghcr.io/tailscale/tailscale`.
The OS image contains no Tailscale software; a machine pulls the container
image when it first starts the service:

```sh
sudo systemctl start tailscaled
sudo tailscale up
```

To also start it at every boot, run the following command. `systemctl enable`
refuses this service, because quadlet generates it.

```sh
sudo ln -s /run/systemd/generator/tailscaled.service /etc/systemd/system/multi-user.target.wants/
```

`sudo systemctl disable tailscaled` undoes that. A machine that had
`tailscaled` enabled before keeps starting it at boot, as the same node.

- `tailscale serve` and `funnel` share ports, not the machine's files or
  folders.
- Tailscale SSH is off and can't be turned on, because its sessions would run
  in the container, not on the machine. On a machine that had it on, the
  service turns the setting off. `ssh` over the tailnet reaches the machine's
  own SSH server.
- The container updates itself daily to Tailscale's newest stable release
  (`podman-auto-update.timer`).
