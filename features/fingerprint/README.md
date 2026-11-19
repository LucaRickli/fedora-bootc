# Fingerprint

With a fingerprint reader that libfprint drives, `sudo`, polkit prompts, and
the lock screen accept a finger as well as the password. Until you enroll a
finger, every prompt asks for the password, as on a machine without a
reader. To enroll one, run `fprintd-enroll` in a terminal of your desktop
session at the machine, enter your password when it asks, and touch the
reader until it reports `enroll-completed`:

```sh
fprintd-enroll                       # The right index finger
fprintd-enroll -f left-index-finger  # Another finger
fprintd-verify                       # Check that a finger matches
fprintd-list "$USER"                 # The readers found, and your enrolled fingers
fprintd-delete "$USER"               # Delete all your fingerprints
```

If `fprintd-list` finds no reader although the machine has one, libfprint
has no driver for it. Its
[list of supported devices](https://fprint.freedesktop.org/supported-devices.html)
names the readers it drives by USB ID.

- The login screen and logins on the console ask for the password only. The
  password unlocks the login keyring; a finger can't.
- `sudo` asks for a finger first: touch the reader, or press Ctrl+C to type
  the password. A polkit prompt asks for the password once the reader has
  waited 30 seconds.
- On the lock screen, touch the reader or type the password. To use only the
  password there, turn off **Fingerprint Unlock** in the Noctalia shell's
  settings, under **Lock Screen**.
- SSH and RDP logins, and `sudo` in their sessions, take the password only.
- A machine whose authselect configuration was changed by hand keeps it when
  it updates. If `sudo` asks for no finger there, run
  `sudo authselect enable-feature with-fingerprint`.
