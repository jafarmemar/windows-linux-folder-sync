# Usage

Open PowerShell in the repository root. Administrator access is not required.

```powershell
.\sync.ps1
```

## Settings

Copy the example and edit the paths and SSH alias:

```powershell
Copy-Item .\config.example.json .\config.json
notepad .\config.json
```

`config.json` sits beside the script and is ignored by Git. Keep passwords and private keys out of it.

- `sourcePath`: an existing Windows directory, such as `D:\Projects\MyProject`.
- `destinationPath`: a dedicated, absolute Linux directory, such as `/srv/myproject`.
- `sshHost`: an existing Windows SSH alias, such as `apps`.
- `transferModifiedFiles`: `true` transfers new files and updates files whose content checksum differs; `false` adds new files while leaving existing destination files untouched.
- `deleteRemovedFiles`: `true` removes destination entries missing from the source, after preview and explicit approval; `false` preserves them.

Use JSON booleans (`true`/`false`), without quotes. With no config, the script asks for these five settings in order; with an incomplete config, it asks only for missing or invalid values. Press Enter for the displayed Y/n default. Saving the answers requires approval. Malformed JSON is reported and never overwritten automatically.

An alternate config can be selected with `-ConfigPath C:\path\settings.json`. For unattended runs, supply all five settings and `-NonInteractive`. Unattended deletion is intentionally unavailable.

## Preview and synchronize

```powershell
.\sync.ps1 -DryRun
.\sync.ps1
```

Every run previews changes with actual rsync counts. `-DryRun` stops there and does not create a destination. A normal run transfers the **contents** of the source directly into the destination. An identical rerun transfers no file content.

When deletion is enabled, review the listed entries and type the full canonical destination path exactly when prompted. A mismatch or unavailable interactive input cancels the entire synchronization. The script checks the destination and deletion plan again before transfer and caps deletions at the approved count. New-files-only mode with deletion enabled is not a complete mirror: existing destination content stays unchanged.

File/directory type conflicts and symlinks at source-matching destination paths are rejected before synchronization. Resolve these conflicts manually; disabling deletion does not authorize replacing a directory with a file or vice versa.

If the destination is missing, its parent must already exist and be writable. A normal run asks you to type the full path before creating that directory. No directory is created during a dry run.

## SSH and path safety

The script uses cwRsync's `ssh.exe` for both checks and transfers. It reads the current Windows user's `.ssh\config` and `.ssh\known_hosts`, preserving aliases such as `apps` and configured keys. Host-key checking stays enabled; SSH files and the session/system PATH are not changed. Paths with spaces are supported. Connections must authenticate without password/passphrase prompts (for example, with a configured available key).

Windows drive paths are converted to `/cygdrive/c/...` internally. Drive roots, Windows system folders, the profile root, SSH folders, and sources containing symlinks/junctions are rejected. UNC sources are unsupported.

Before launching rsync, the script checks the complete argument vector: only approved options, exactly one non-root Windows source and one remote destination are accepted. Missing/extra operands, standalone `/` operands and inconsistent path conversions stop execution. This prevents a malformed command from starting a local receiver.

Linux system roots, sensitive system subtrees, user home roots and `.ssh` directories are protected. Dedicated subdirectories under `/srv`, `/opt`, `/home/<user>` and `/tmp` may be used. Symlinked destinations or parents and destinations containing filesystem mounts are rejected. Checks run before preview, before transfer and inside the remote rsync launcher. Deletion is blocked when the source has no regular files. Use trusted, dedicated directories; do not modify their paths or mounts during synchronization.

### Transfer options and source metadata

- `-rt` recursively transfers files and preserves **destination file modification times**; `--omit-dir-times` excludes directory times. Owner, group, ACL and extended-attribute preservation are not enabled. No source-removal or source-writing options are permitted.
- `--one-file-system` limits traversal; source junctions/symlinks are separately rejected. `--secluded-args`, `-e` and `--rsync-path` carry literal paths through the checked SSH transport and remote guard; `--` separates options from the two operands.
- `--checksum` detects content changes; `--ignore-existing` implements new-files-only mode. `--delete-delay` applies approved destination deletions; `--max-delete` caps their number. The cap alone does not prevent type replacement, so conflicts are checked separately.
- `--dry-run` previews; `--itemize-changes`, `--out-format`, `--stats` and `--info=progress2` report changes and progress.

The Windows source is the sender, never the receiver. Reads can still update last-access times under Windows/filesystem policy. `--open-noatime` requests suppression where supported; unsupported systems silently ignore it ([rsync manual](https://download.samba.org/pub/rsync/rsync.1.html)). Directory enumeration and other software may also affect access times. Unchanged access times are not guaranteed, and the script never attempts to restore metadata.

## Troubleshooting

- **Unknown host/key or authentication failure:** check `ssh apps` with your existing Windows SSH setup and verify the server fingerprint. The script does not accept unknown host keys or change SSH security settings.
- **Missing cwRsync/remote rsync:** follow [Installation](./README.md#installation); dependencies are never installed automatically.
- **Permission or protected-path error:** choose a dedicated readable source and writable Linux destination. Do not select a system directory.
- **Changed destination/deletion plan:** inspect the paths and rerun to obtain a fresh preview. A failed or interrupted transfer may leave partial progress; rerun after resolving the reported error.

## Developer checks

```powershell
.\sync.tests.ps1
.\sync.tests.ps1 -Integration
```

The integration suite requires the existing `apps` alias. It operates only in unique temporary Windows and Ubuntu directories and cleans resources it creates, including after failures. It does not change SSH configuration or install tools.
