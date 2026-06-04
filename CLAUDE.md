# Velox — Project Conventions

Velox is a lightweight, open-source Docker Desktop alternative for macOS. The
host supervisor is 100% Swift driving Apple's `Virtualization.framework`; the
guest is a minimal LinuxKit image running stock `dockerd`. See `README.md` for
the phased build status.

The following conventions are **binding** — keep them true in all future work.

## 1. User-facing CLI is `vlcmd`, never `docker`

Velox must coexist with an existing Docker install, so it never takes over the
`docker` command. The Docker-CLI-equivalent for Velox is **`vlcmd`**
(`Scripts/vlcmd`), a thin wrapper that runs `docker -H unix://~/.velox/docker.sock`.

- Examples shown to users: `vlcmd ps -a`, `vlcmd run …`, `vlcmd network create …`.
- Docs, `velox` CLI hints, and messages reference `vlcmd`, not `DOCKER_HOST`.
- Internal API/socket naming stays "docker" (it *is* the Docker API):
  `~/.velox/docker.sock`, `DockerSocketProxy`, etc. `vlcmd` is only the
  user-facing front door (chosen to be easy to find/replace later).
- Velox never *auto*-hijacks `docker`, but the user may opt in at launch:
  `velox start --bind vlcmd|docker|both`. `docker`/`both` bind the standard
  `docker` CLI via a Docker **context** named `velox` (no root, no /var/run
  conflict — like Colima) and restore the previous context on stop. See
  `CLIBinding.swift`. Default is `vlcmd`.

## 2. All version numbers live in ONE place: `versions.env`

`versions.env` (repo root) is the single source of truth for **every** version:
Velox's own version, the guest kernel ("OS version"), every LinuxKit package,
the Docker Engine (dind) image, and the relay build toolchain. Nothing else may
hard-code a version.

- Swift reads versions via `Sources/Velox/Support/Versions.swift`, which is
  **generated** from `versions.env` by `Scripts/gen-versions.sh` (run by
  `Scripts/build.sh`). Never hand-edit `Versions.swift`.
- The guest spec is **generated**: edit `guest/velox.yml.tmpl` (with `${VAR}`
  placeholders); `Scripts/make-guest.sh` renders `guest/velox.yml` from it using
  values in `versions.env`. Never hand-edit the generated `guest/velox.yml`.
- Updating Velox to newer components = editing `versions.env` only.

## 3. Built-in updater pointing at GitHub releases

Velox ships an updater so a future UI "Update" button (and the CLI today) can
pull a newer build. It is backed by `velox update`:

- `velox update` checks `https://api.github.com/repos/<VELOX_GITHUB_REPO>/releases/latest`
  (repo set in `versions.env`) and reports whether a newer version exists.
- `velox update --apply` downloads and installs the new release.
- Any UI added later must wire its "Update" button to this same code path
  (`Updater` in `Sources/Velox/Support/Updater.swift`) — do not fork the logic.

## 4. Custom kernel for VirtioFS / Rosetta

Apple's Virtualization.framework shares files only via **VirtioFS**, and the
stock `linuxkit/kernel` is built without `CONFIG_VIRTIO_FS`. So — like Docker
Desktop and OrbStack — Velox builds its **own** kernel with VirtioFS enabled
(`Scripts/build-kernel.sh`, from base `KERNEL_BASE` in versions.env, retagged to
`KERNEL_IMAGE`). Both VirtioFS `-v` mounts and Rosetta x86 depend on this kernel.
Don't switch back to a stock kernel expecting `-v`/Rosetta to work.

## Build / run quick reference

```bash
./Scripts/build.sh          # gen versions + swift build + ad-hoc codesign
./Scripts/make-guest.sh     # build/render + build LinuxKit guest, install to ~/.velox
./Scripts/install-vlcmd.sh  # put vlcmd on PATH
velox start                 # boot the engine
vlcmd ps                    # talk to it
```

Only `com.apple.security.virtualization` is required for signing (NOT
`com.apple.security.hypervisor`, which is for raw Hypervisor.framework).
