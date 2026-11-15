# Cockpit

Cockpit listens on loopback only. To turn it on, run
`sudo systemctl enable --now cockpit.socket` and open <http://localhost:9090>.
From another machine, tunnel to it with
`ssh -L 9090:localhost:9090 USERNAME@MACHINE`. It has no page for docker
containers, and its Metrics page is off.
