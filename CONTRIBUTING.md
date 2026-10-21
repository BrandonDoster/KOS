# Contributing to KOS

Bug reports, board support and fixes are welcome. For anything larger than a fix, open an issue first so the
design can be agreed before you build it. The reasons behind every current decision are in
[docs/plan.md](docs/plan.md).

## Building

You need Docker with arm64 emulation (Docker Desktop has it). One board takes about 35 minutes on an x86 Mac.

```sh
build/build.sh cb1      # or: build/build.sh cm5
# output: out/kos-<board>-<date>.img
```

The build runs upstream code as root (Klipper's `make`, pip, Debian and vendor maintainer scripts) in a privileged
container; mmdebstrap needs `--privileged` for its chroot mounts. On a Linux host that is root on the host, so build
on a machine you trust. The repository is mounted read-only and only `out/` is writable.

## Pinned versions

`build/pins.env` fixes what a fresh image starts with: the Klipper, Moonraker and `mainsail-config` commits, the
Mainsail release and the sha256 of its `mainsail.zip`, the `msgspec` and `uvloop` versions, and the `debian:trixie`
build container by digest. The values on `main` are the ones the last tested build used.

On a running printer, Moonraker's update manager keeps updating Klipper, Moonraker and Mainsail past these pins (the
checkouts stay on their branches). The pins only decide what a newly flashed card contains.

`build/bump-pins.sh` points every pin at the latest upstream (master heads, the latest Mainsail release, PyPI, the
current `debian:trixie` digest) and prints what moved. It leaves the file alone when nothing did. Run it by hand to
try newer upstreams locally; the weekly workflow runs it on its own.

## Weekly builds and releases

- **Weekly (`.github/workflows/weekly.yml`, Mondays and on demand):** runs `build/bump-pins.sh` and `tests/run.sh`
  on `main`. If a pin moved and the tests pass, a bot commit `build(pins): ...` goes straight to `main`. Then the run
  starts a second run of the same workflow on `main` (`stage: build`), so that the build and its attestation name the
  commit with the new pins; that run refuses to build if `main` has moved on since. It builds both boards, checks
  each image with `tests/inspect_image.sh` (owners, and the modes sshd and sudo insist on) before uploading it, and
  publishes a **prerelease** tagged `weekly-YYYYMMDD`, with the `.img.xz` files, the `.sha256` files and the
  provenance attestation. A weekly is built even when no pin moved, because Debian's own
  updates still change the image. Weeklies are built and tested in CI only; nobody has booted them.
- **Release:** boot a weekly on real hardware, then push a `v*` tag on the same commit:

  ```sh
  git fetch --tags && git tag v1.0.0 weekly-20261026 && git push origin v1.0.0
  ```

  `.github/workflows/release.yml` finds the weekly prerelease for that commit, checks its `.sha256` files and that
  each image's attestation comes from this repository's `build.yml`, run on `main` at exactly that commit, and publishes the same files as the release without rebuilding, so the bytes you tested are the
  bytes users get. A `v*` tag on a commit with no weekly builds fresh images instead.
- **By hand:** running `build images` from the Actions tab builds both boards and keeps them as workflow artifacts,
  with no release.

The image build job gets a read-only token that is not kept in `.git/config`; only the publish job, which runs no
repository code, can write. Every action is pinned to a full commit SHA with its version in a comment; bump them
together. Users can check that an image came from this repository's workflow with
`gh attestation verify kos-cb1-<date>.img.xz -R <owner>/klipperOS --signer-workflow <owner>/klipperOS/.github/workflows/build.yml`.

A second weekly run on the same day fails at publishing, because the `weekly-YYYYMMDD` tag already exists. Delete
that prerelease and its tag first if you really want to rebuild it.

### Repository settings these workflows need

- **Actions, General:** workflow permissions "Read repository contents" (the default for new repositories). Each
  job asks for what it needs.
- **`main`:** the weekly bot pushes to `main` with `GITHUB_TOKEN`. Classic branch protection that requires pull
  requests or status checks blocks that push. Use a ruleset instead and add the GitHub Actions app as a bypass actor,
  or leave `main` unprotected. Pushes made with `GITHUB_TOKEN` do not trigger other workflows, so `tests` does not run
  again on the bot commit; the weekly job has already run `tests/run.sh` on it.
- **Tags:** a tag ruleset on `v*` so that only maintainers can create release tags, and on `weekly-*` so that only
  the GitHub Actions app can.
- **Releases:** turn on **immutable releases** (Settings, General, Releases). A published weekly's files and its
  `weekly-*` tag can then no longer be swapped between hardware testing and the `v*` tag that republishes them.
  `release.yml` relies on it: its attestation check binds the files to the commit, not to one particular weekly.
- **Security:** turn on private vulnerability reporting (see [SECURITY.md](SECURITY.md)).
- In a public repository, GitHub turns scheduled workflows off after 60 days with no activity. Re-enable `weekly` in the
  Actions tab if that happens.

## Checks

Run these before you open a pull request:

```sh
sh tests/run.sh                          # shell syntax, Python self-tests, config parser (no hardware, no Docker)
sh tests/mkimage_docker.sh               # real mkfs/sfdisk round-trip of the partitioning code (needs Docker)
sh tests/inspect_image.sh out/kos-cb1-*.img   # offline inspection of a built image (needs Docker)
```

`tests/run.sh` also runs in CI on every push and pull request. On macOS it skips `test_cm5_carrier.sh`, which needs
GNU sed; CI runs it.

`tests/device/` holds checks that run on a booted KOS box, and `bench/scripts/` the benchmark scripts. Both need
hardware and are described in their header comments and in [docs/benchmarks.md](docs/benchmarks.md).

If you changed behaviour on a board, say in the pull request which board you booted it on, or that you did not.

## Where things go

- **A new board:** a directory under `build/boards/<board>/` with a `board.sh` (apt source, kernel packages,
  partition layout, bootloader) and its boot files, following `cb1/` and `cm5/`. Nothing outside `build/boards/`
  should branch on the board; if it has to, explain why in the pull request.
- **Files in the image:** `overlay/`, copied into the root filesystem as-is.
- **Packages:** `build/packages.txt` for every board; board-only packages in that board's `board.sh`.
- **Settings users edit:** a documented key in `build/config-partition/kos.conf`, read with `cfg` from
  `overlay/usr/lib/kos/lib.sh`.

KOS does not ship third-party vendor files. If an idea comes from another image or project, write it yourself and
name the source in a comment or the docs.

## Commits

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/), as the history does:
`feat:`, `fix:`, `docs:`, `test:`, `build:`, `chore:`, with an optional scope, for example
`test(bench): benchmark KOS against stock on CM5 and CB1`.

## License

KOS is AGPL-3.0-or-later. By contributing you agree that your contribution is licensed the same way.
