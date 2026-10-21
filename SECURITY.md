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

- The user is always `klipper`, and it has no password until `password=` is set in `kos.conf`. Root is locked.
- SSH accepts a key from `ssh_key=` or the password from `password=`; with neither set, nobody can log in over SSH.
- `klipper` has passwordless `sudo`, as on cloud images and other Klipper distributions.
- The local console (`tty1`) logs in as `klipper` automatically. Physical access to the printer is treated as
  ownership of it.
- Moonraker trusts clients on private (RFC1918), link-local and loopback addresses, the list Moonraker's installer
  suggests. KOS is meant for a trusted local network; do not expose it to the internet.
- The `kos.conf` partition is FAT and readable by anyone who holds the SD card, including the Wi-Fi password.

A way around any of these (for example, logging in over SSH with no key and no password set, or reaching Moonraker
from outside the trusted ranges) is a vulnerability. Please report it.
