# dae

To turn on dae, write its configuration to `/etc/dae/config.dae` with mode
0600, since dae refuses a configuration that others can read, and run
`sudo systemctl enable --now dae`. `/etc/dae/example.dae` shows the format.

Upstream signs nothing, so a dae update fails its build until someone checks
the release and pins its RPM's SHA-256 in `build.sh`; the build's error prints
the value.
