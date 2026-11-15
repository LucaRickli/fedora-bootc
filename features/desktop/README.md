# Desktop

Every session has gcr's SSH agent, which offers the keys in `~/.ssh`. For a
key with a passphrase, run `ssh-add` once after login. Flatpaks with SSH
access, such as VS Code, sign through the agent.
