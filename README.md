# windows-linux-folder-sync
One-way Windows-to-Linux folder synchronization using rsync over SSH, with incremental transfers, automatic deletion of removed files, and PowerShell automation.

## Installation

### Windows 11 (cwRsync 6.5.0)

1. Download [cwRsync 6.5.0 for Windows x64](https://itefix.net/downloads/cwrsync/cwrsync_6.5.0_x64_free.zip) from the [official Itefix website](https://itefix.net/cwrsync/).
2. Open PowerShell as **Administrator**. Save the ZIP in your Downloads folder (or update `$zip` below), then run:

   ```powershell
   $ErrorActionPreference = 'Stop'
   $zip = Join-Path $env:USERPROFILE 'Downloads\cwrsync_6.5.0_x64_free.zip'
   $destination = 'C:\Program Files\cwRsync'
   $bin = Join-Path $destination 'bin'
   $expectedHash = '8dc20afec889908c05c2abaa21d37f3fcad3e7ea5f3f37e95b25e6178f6b983a'

   $actualHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
   if ($actualHash -ne $expectedHash) { throw 'SHA-256 mismatch; extraction stopped.' }

   $rsyncExe = Join-Path $bin 'rsync.exe'
   $sshExe = Join-Path $bin 'ssh.exe'
   $installed = $false
   if ((Test-Path -LiteralPath $rsyncExe -PathType Leaf) -and (Test-Path -LiteralPath $sshExe -PathType Leaf)) {
       $rsyncVersion = (& $rsyncExe --version 2>&1 | Out-String)
       $sshVersion = (& $sshExe -V 2>&1 | Out-String)
       $installed = $rsyncVersion -match 'rsync version 3\.5\.1' -and $sshVersion -match 'OpenSSH_10\.6p1'
   }
   if ($installed) {
       Write-Host 'cwRsync 6.5.0 is already present; skipping extraction.'
   } else {
       New-Item -ItemType Directory -Path $destination -Force | Out-Null
       Expand-Archive -LiteralPath $zip -DestinationPath $destination -Force
   }

   if (-not (Test-Path -LiteralPath $rsyncExe -PathType Leaf) -or -not (Test-Path -LiteralPath $sshExe -PathType Leaf)) {
       throw 'Expected executables were not found under C:\Program Files\cwRsync\bin.'
   }

   $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
   $machineEntries = @($machinePath -split ';' | Where-Object { $_ -and $_.Trim() })
   $machineHasBin = $machineEntries | Where-Object {
       [Environment]::ExpandEnvironmentVariables($_.Trim()).TrimEnd('\') -ieq $bin.TrimEnd('\')
   }
   if (-not $machineHasBin) {
       [Environment]::SetEnvironmentVariable('Path', (@($machineEntries) + $bin) -join ';', 'Machine')
   }

   $processEntries = @($env:Path -split ';' | Where-Object {
       $_ -and ([Environment]::ExpandEnvironmentVariables($_.Trim()).TrimEnd('\') -ine $bin.TrimEnd('\'))
   })
   $env:Path = (@($bin) + $processEntries) -join ';'
   ```

   The ZIP has `bin/` at its root, so extraction places the executables directly under `C:\Program Files\cwRsync\bin`. The script adds this directory to Machine PATH without duplicating it.
3. Verify in the elevated PowerShell window:

   ```powershell
   rsync --version
   & 'C:\Program Files\cwRsync\bin\ssh.exe' -V
   ```

The SSH check uses cwRsync's executable directly, avoiding Windows' built-in OpenSSH. `cwrsync.cmd` is a sample batch launcher, not an installer. WSL and MSYS2 are not required.

### Ubuntu Server (rsync + OpenSSH)

1. On a server that needs these packages, install them and start SSH:

   ```bash
   sudo apt update
   sudo apt install -y rsync openssh-server
   sudo systemctl enable --now ssh
   ```

   OpenSSH Server accepts secure SSH connections from Windows. If OpenSSH is already installed and `ssh` is active, leave it and its configuration unchanged; skip the setup block. If only `rsync` is missing, install it with `sudo apt install -y rsync`.
2. Verify the installation and service:

   ```bash
   rsync --version
   systemctl is-active ssh
   ```
