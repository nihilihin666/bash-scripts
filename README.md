# bash-scripts

Personal Bash utilities for Linux: file and image processing, downloads,
diagnostics, application launchers, and Fedora setup and maintenance.
System and desktop setup scripts encode personal preferences; review their
changes before applying them to another machine.

## Running scripts

Use Bash or execute the scripts directly through their `#!/usr/bin/env bash`
shebang. The `.sh` extension is intentional; do not run them with `sh`.
Some scripts require Bash 4 features, including associative arrays. Linux tools
and package-manager support vary by script; this is not a POSIX shell suite.

Examples assume the current directory is the parent of `bash-scripts`:

```bash
./bash-scripts/image.sh --help
bash ./bash-scripts/image.sh --help
```

Scripts can also be invoked by absolute path from another directory. Default
output paths are anchored under `$HOME`, independently of the repository's
location. Explicit relative input/output arguments are resolved from the working
directory according to each script's interface.

Use each script's `--help` for complete options. Run as your normal user unless
a script requires sudo. Some scripts automatically install dependencies using
elevated privileges; help does not install anything. Only scripts advertising
a dry-run mode support it.

## Script catalog

Paths below are relative to the repository root. Dependencies listed are the
main requirements, not an exhaustive list of Linux utilities.

| Script | Purpose and requirements | Privileges, changes, and output |
| --- | --- | --- |
| [image.sh](image.sh) | Process static JPEG, PNG, and WebP images with ImageMagick and exiv2. Can install dependencies on Ubuntu/Fedora. | Normal user; installation may need sudo. Results/backups under `$HOME/bash-scripts-output/image/<timestamp>/`. Supports `--inspect`, `--dry-run`, and `--no-install`. |
| [files-to-dash-case.sh](files-to-dash-case.sh) | Rename files, optionally recursively, with lowercase/camel-case conversion. | Normal user with write access. Renames in place, skips existing destinations, and attempts rollback on failure. No persistent undo map. |
| [randomise-filenames.sh](randomise-filenames.sh) | Recursively randomise filenames or restore them with an undo map. | Normal user with write access. Renames in place; saves maps under `$HOME/bash-scripts-output/` by default. |
| [youtube-download.sh](youtube-download.sh) | Download video or MP3 audio using Python, pipx, ffmpeg, and yt-dlp; installs missing dependencies through supported package managers. | Run as normal user; system dependency installation may need sudo. Saves media under `$HOME/bash-scripts-output/youtube-downloaded/`. Optional browser cookies provide authentication. |
| [ssh.sh](ssh.sh) | Start/reuse ssh-agent and load a key; requires OpenSSH client tools. | Normal user. Uses `$HOME/.ssh/agent.env`; defaults to the `id_ed25519` key in `$HOME/.ssh`. |
| [system-info.sh](system-info.sh) | Collect best-effort Linux diagnostics; attempts to install missing tools using apt/dnf. | Normal user; installation may need sudo. Console output; `--print-all` writes `$HOME/bash-scripts-output/system-info.txt`. |
| [codex-update.sh](codex-update.sh) | Update Codex through npm; requires npm and network access. | Must run without root/sudo. Uses a writable npm prefix, falling back to `$HOME/.local`; reports any PATH changes needed. |
| [t3code.sh](t3code.sh) | Install/update and launch an extracted Linux T3 Code AppImage. Can install missing helper tools on supported apt/dnf systems. | Normal user; dependency installation may need sudo. Uses `$HOME/.local/opt/t3code` and `$HOME/.local/bin/t3code`. Network needed for installation/update. |
| [other/dir-tree.sh](other/dir-tree.sh) | Recursively list a directory using find or tree. | Normal user. Console output; `--tree` can install missing tree using apt/dnf with sudo. |
| [other/file-contents.sh](other/file-contents.sh) | Combine text files below a directory, skipping selected generated/binary content. | Normal user. Prints to stdout or writes the explicitly supplied output filename inside the input directory. |
| [test-bash-scripts.sh](test-bash-scripts.sh) | Discover Bash syntax, ShellCheck, and ordinary Python unittest checks recursively. Requires Bash, Python 3, and ShellCheck. | Normal user; terminal results, no installation or persistent report. Runtime exclusions use `.test-runner-ignore` markers. |
| [update-bash-scripts.sh](update-bash-scripts.sh) | Download the latest default-branch version of this repository over public HTTPS. Requires Git and network access. | Normal user; updates this directory, without a GitHub login. Plain folder copies are backed up under `$HOME/bash-scripts-output/repository-backups/` before replacement. |
| [os/dd.sh](os/dd.sh) | Write an ISO to a selected removable/USB whole disk; uses GNU/Linux disk tools. | Real writes require root and destroy target data. `--dry-run` previews without unmounting or writing. |
| [other/danger/erase-all-data.sh](other/danger/erase-all-data.sh) | Verified overwrite of eligible native ATA/SATA HDDs; other devices receive manual guidance. Uses embedded Python and storage tools. | Root for inventory/erasure; help needs no root. Destructive; separate qualification requirements below. No persistent reports in the home output directory. |

Fedora-specific scripts:

| Script | Purpose | Privileges and changes |
| --- | --- | --- |
| [os/fedora/fedora-update-all.sh](os/fedora/fedora-update-all.sh) | Update dnf packages, available Flatpak/Snap installations, and firmware through fwupdmgr; report restart requirements. | Root for real updates. Supports `--dry-run`; does not automatically reboot. |
| [os/fedora/setup/fedora-setup-01-base.sh](os/fedora/setup/fedora-setup-01-base.sh) | Install base packages, third-party repositories, applications, and shell tools. | Run through sudo from your normal account. Modifies system configuration and the invoking user's environment. Supports `--dry-run`. |
| [os/fedora/setup/fedora-setup-02-kde-settings.sh](os/fedora/setup/fedora-setup-02-kde-settings.sh) | Configure Fedora KDE Plasma 6 Wayland preferences, with optional window/panel settings and Yakuake installation. | Logged-in desktop user, without sudo. Optional Yakuake installation uses sudo. Supports `--dry-run`. |
| [os/fedora/setup/fedora-setup-02-xfce-settings.sh](os/fedora/setup/fedora-setup-02-xfce-settings.sh) | Configure XFCE preferences, keyboard/session behavior, and optional panel/background settings. | Logged-in desktop user with sudo available for system changes. Supports `--dry-run`; some keyboard behavior is X11-specific. |
| [os/fedora/setup/fedora-setup-03-dev.sh](os/fedora/setup/fedora-setup-03-dev.sh) | Install Docker and development tools, with optional language and GUI tools. | Run through sudo from your normal account. Changes packages, repositories, and development configuration. Supports `--dry-run`. |

## Common examples

Inspect images or preview resizing without installing missing tools:

```bash
./bash-scripts/image.sh --inspect --no-install "$HOME/Pictures"
./bash-scripts/image.sh --dry-run --max-width 1920 "$HOME/Pictures"
```

Write resized results while keeping source images:

```bash
./bash-scripts/image.sh --no-install --max-width 1920 "$HOME/Pictures"
```

Load an SSH key and import the agent environment into the current shell:

```bash
eval "$(./bash-scripts/ssh.sh --print-env)"
```

List a directory or print its combined text-file contents:

```bash
./bash-scripts/other/dir-tree.sh "$HOME/Projects"
./bash-scripts/other/file-contents.sh "$HOME/Projects/example"
```

## Updating this repository

Run as your normal user, without sudo:

```bash
./bash-scripts/update-bash-scripts.sh
```

This example assumes the parent directory of `bash-scripts`. The updater also
works by absolute path from any working directory, and follows the location of
the script rather than assuming the directory is named `bash-scripts`.

Git and network access are required. The updater installs no software. It uses
the fixed public HTTPS source `https://github.com/nihilihin666/bash-scripts.git`;
no GitHub account, login, or SSH key is needed. An existing SSH-based `origin`
is left unchanged. The published default branch is discovered automatically.

- **Git checkout:** downloads and fast-forwards a clean checkout of the default
  branch. Already-current copies report success. Local edits, staged or untracked
  files, local commits, other branches, detached HEAD, and unfinished Git
  operations cause refusal. Ignored files are retained, and collisions with
  published files block replacement. There is no automatic stash, reset, rebase,
  or conflict resolution. Keep your working copy and download a separate fresh
  copy from GitHub if you want updates without resolving local Git changes.
- **Folder copy or extracted ZIP without `.git`:** downloads a fresh checkout
  first, copies the entire old folder to a unique backup under
  `$HOME/bash-scripts-output/repository-backups/backup-*/repository`, then replaces
  the folder. This includes local files absent from the published version; those
  files remain in the backup rather than the updated folder. Future updates use
  the new Git checkout. If your terminal was inside the old folder, use the
  printed `cd` command to enter the replacement before continuing.
  Backups are not deleted automatically. To restore one,
  move the updated folder aside and copy the backup's `repository` directory back
  to the original location.

The parent directory must be writable. An empty `.<folder-name>.update-lock`
directory beside the folder prevents overlapping updater runs. Normal exits and
handled signals remove it; after a forced kill or power loss, remove it with
`rmdir` only after confirming no updater is running. Folder replacement uses a
temporary sibling directory; ordinary failures and handled interruptions attempt
to restore the original folder. If restoration cannot complete, the error prints
the retained recovery path. Keep the reported backup until you have checked the
new copy. A forced kill or power loss can require restoring that backup manually.

## Outputs and recovery

Default persistent results go under `$HOME/bash-scripts-output`, not relative to
the script or working directory. Exceptions include explicitly selected outputs,
in-place operations, application installation/state, and system configuration.

- Image runs use `image/<timestamp>/result` and `image/<timestamp>/backup`.
  Unchanged images are not copied. `--overwrite` changes sources after validating
  output and backs them up unless `--no-backup` is supplied. Existing destination
  files are not overwritten. Output and backup directories can be overridden.
- Random filename undo maps are `randomise-filenames-*.map` files. Keep the map
  reported by the script. Restore using
  `./bash-scripts/randomise-filenames.sh --reverse /absolute/path/to/map-file`.
  `--no-manifest` removes the persistent recovery map after a successful rename.
- Dash-case renaming attempts rollback on failure but has no undo command for a
  successful run. Keep a separate backup when original names matter.
- Downloads go below `youtube-downloaded/`; the optional diagnostic report is
  `system-info.txt`. Review diagnostics and combined text listings before sharing:
  they can contain private paths, identifiers, configuration, or file contents.

Output directories from earlier versions are not moved automatically. Preserve
needed reports, backups, and undo maps separately.

## Fedora setup sequence

Review the package lists and personal desktop preferences first. Start with
`--dry-run`. To apply setup, use this order:

1. Run `sudo bash ./bash-scripts/os/fedora/setup/fedora-setup-01-base.sh`.
2. In the intended desktop session, run either
   `bash ./bash-scripts/os/fedora/setup/fedora-setup-02-kde-settings.sh` or
   `bash ./bash-scripts/os/fedora/setup/fedora-setup-02-xfce-settings.sh` as your
   normal user.
3. Run `sudo bash ./bash-scripts/os/fedora/setup/fedora-setup-03-dev.sh` if you
   want the development environment.

Some settings require a new login or reboot. Read each script's summary.

## T3 Code launcher

Run `./bash-scripts/t3code.sh --bg` to install if needed and launch T3 Code.
Use `--update` to download the latest release. Running the repository script
refreshes its installed copy at `$HOME/.local/opt/t3code/launcher.sh`.
The `$HOME/.local/bin/t3code` command points to this copy, so moving the
repository does not break it. Ensure `$HOME/.local/bin` is on PATH.

The launcher maintains `t3code-launcher.desktop` under
`$HOME/.local/share/applications`. It restores URL-handler registration after
successful startup or forwarding to an existing instance, because T3 Code can
register its own generated entry during startup. An explicitly selected unrelated
handler is preserved. Application state and extracted releases remain outside
the repository.

The Chromium sandbox fallback requires explicit `--allow-no-sandbox`.
`--recover` stops matching T3 Code processes; use it only when recovery is needed.

## Destructive disk operations

`os/dd.sh` overwrites the selected whole USB disk. Check its displayed identity
and plan before confirming; `--dry-run` previews its choices.

`other/danger/erase-all-data.sh` can permanently destroy drive data. Automatic
overwrite is restricted to eligible native ATA/SATA HDDs with resolved identity,
usage, and boot/system protection. USB HDDs, SSD/NVMe hardware erasure, and
unresolved boot/live-image layouts do not have qualified automatic backends.
Read its help, [review notes](other/danger/tests/REVIEW-NOTES.txt), and
[release checklist](other/danger/tests/RELEASE-CHECKLIST.txt).

**Erasure runtime and physical qualification remain pending.** Passing ordinary
tests, syntax checks, or lint does not qualify it for a real batch. Its runtime
suites must run only on the separate disposable machine/VM required by the
checklist, never on the working computer or a VM hosted on it. Physical
qualification requires a separate test machine and sacrificial drives.

## Development and validation

Run the automatic test runner as your normal user:

```bash
./bash-scripts/test-bash-scripts.sh
```

This example assumes the parent directory of `bash-scripts`; an absolute path
works from any working directory. The runner locates the repository from its own
path, checks every `.sh` file with `bash -n` and ShellCheck, and runs ordinary
Python unittest files named `test_*.py` in every discovered directory. Add new
test files using that naming convention; no directory list needs updating.
Each directory runs in a separate Python process, and nested suites run once.
Python caches are disabled. Requires Bash, Python 3, and ShellCheck; missing tools
produce an error without installing anything.

A `.test-runner-ignore` file excludes its directory and all descendants from
runtime test discovery. Bash static checks still apply there. The erasure runtime
test directory carries this marker. Keep tests requiring a separate machine or
special setup in marked subtrees. The runner does not follow symlinks or traverse
Git metadata, Python caches, or virtual environments containing `pyvenv.cfg`.

The runner continues after ordinary failures, prints a summary, and exits with
status 1 if any check fails or no test suites are found. Usage, missing-tool, and
discovery errors return 2. Expected test skips do not cause failure. Results go
to the terminal; no persistent report is written.

For individual checks, run these commands from the repository root. Bash and
ShellCheck perform static checks without running script operations:

```bash
find . -type f -name '*.sh' -print0 |
  while IFS= read -r -d '' script; do
    bash -n "$script" || exit
  done

find . -type f -name '*.sh' -print0 | xargs -0 shellcheck
```

The ordinary tests use Python's standard-library unittest, temporary files, and
mocked external operations:

```bash
python3 -m unittest discover -s tests -v
python3 -m unittest discover -s os/fedora/tests -v
python3 -m unittest discover -s os/fedora/setup/tests -v
```

When invoking unittest directly, run all three explicitly; root discovery does
not cover every directory.

The root suite includes disposable-file rename/restore and rollback tests,
image validation/replacement tests, and mocked disk-write, launcher, SSH-agent,
npm updater, and combined-file-output regressions. These do not install software,
launch applications, or write to real devices. The npm root-refusal case skips
when tests run as a normal user; do not elevate the suite just to run that case.
Disk tests cover mocked orchestration and selected refusal paths, not actual
block-device discovery, full storage topology, or hardware qualification.

The root CLI suite invokes `--help` and `-h` for every `.sh` script, including
the erasure script. Help must remain side-effect-free. Do not include the
separate erasure runtime suites in ordinary local testing.

See [AGENTS.md](AGENTS.md) for editing rules and
[other/danger/AGENTS.md](other/danger/AGENTS.md) for erasure-specific constraints.
