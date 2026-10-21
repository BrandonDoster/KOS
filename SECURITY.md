# Security policy

## Reporting a vulnerability

Report it privately through GitHub's private vulnerability reporting: the **Security** tab of this repository,
then **Report a vulnerability**. Please do not open a public issue for a security problem.

Include the board, the image file name, what an attacker needs (network access, physical access, a user account)
and the steps to reproduce.

## Supported versions

Only the latest release gets security fixes. Until the first release, that means the `main` branch.

## Deliberate defaults

These are intended, so they are not vulnerabilities on their own:

- **Anything Moonraker trusts is root.** Moonraker trusts clients on private (RFC1918), link-local and loopback
  addresses, the list Moonraker's installer suggests, with no login. Such a client can upload configuration
  (including `moonraker.conf`, whose update manager entries run code as `klipper`) and restart services, and
  `klipper` has passwordless `sudo`. So every device on your local network, phones, smart plugs and guest Wi-Fi
  included, can take full control of the printer's operating system. KOS is meant for a trusted local network; do
  not expose it to the internet, and keep untrusted devices on another network. An opt-in login for the web UI and
  API is planned.
- `klipper` has passwordless `sudo`, as on cloud images and other Klipper distributions. Root is locked.
- The user is always `klipper`. Its password is locked until `password=` is set in `kos.conf`.
- `kos.conf` is the only source of logins, applied on every boot: SSH accepts the keys from its `ssh_key=` lines and
  the password from `password=`. With neither set, nobody can log in over SSH. Removing a line revokes it on the next
  boot (or at once with `kos-ssh-key remove`). `~/.ssh/authorized_keys` is not read.
- The local console (`tty1`) logs in as `klipper` automatically. Physical access to the printer is treated as
  ownership of it.
- The `kos.conf` partition is FAT and readable by anyone who holds the SD card, including the Wi-Fi password. On the
  running printer it is readable only by `klipper` and root.
- Debian security updates install automatically while the printer is idle (never started during a print, never a
  reboot). The kernel and boot firmware (Armbian on CB1, Raspberry Pi on CM5) are not; they need a system update
  from Mainsail and a reboot.
- `ssh_key=` takes plain public keys only. A key with options (`from=`, `command=`, `restrict`, ...) or a certificate
  is refused with a warning, not installed without its restriction.

What KOS does to keep the network side narrow:

- Moonraker listens on `127.0.0.1` only: `kos-config` sets `host: 127.0.0.1` in `moonraker.conf`'s `[server]` on
  every boot, also after importing a config from another install, and warns when it had to. nginx on port 80 is the only way in, and it answers only to the hostname,
  `<hostname>.local`, the names in `allowed_hosts=` and IP addresses (against DNS rebinding). API and websocket
  requests that carry an `Origin` from another site are rejected (against cross-site requests from web pages).
- IPv4 only: IPv6 is disabled on the kernel command line, so nothing listens on global IPv6 addresses.
- Every image is built without SSH host keys; each printer generates its own on first boot.

A way around any of these (for example, logging in over SSH with no key and no password set, a key or password
still working after its line was removed from `kos.conf`, or reaching Moonraker from outside the trusted ranges,
including through a web page from another site) is a vulnerability. Please report it.
