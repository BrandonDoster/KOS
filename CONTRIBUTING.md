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
