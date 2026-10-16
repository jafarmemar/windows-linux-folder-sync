# windows-linux-folder-sync
One-way Windows-to-Linux folder synchronization using rsync over SSH, with incremental transfers, automatic deletion of removed files, and PowerShell automation.

## Installation

### Windows 11 (cwRsync)

1. Download the **Latest Version** cwRsync ZIP from the [official Itefix website](https://itefix.net/cwrsync/). Compare its checksum with the value published there for that release.
2. Extract the ZIP file.
3. Open PowerShell as **Administrator** and navigate to the extracted folder containing the package's top-level `bin` directory.
4. Run these commands to install cwRsync system-wide:

   ```powershell
   $ErrorActionPreference = 'Stop'
   $source = (Get-Location).Path
   $sourceBin = Join-Path $source 'bin'
   $destination = 'C:\Program Files\cwRsync'
   $targetBin = Join-Path $destination 'bin'

   if (-not (Test-Path -LiteralPath (Join-Path $sourceBin 'rsync.exe') -PathType Leaf) -or
       -not (Test-Path -LiteralPath (Join-Path $sourceBin 'ssh.exe') -PathType Leaf)) {
       throw 'The current folder must contain bin\rsync.exe and bin\ssh.exe.'
   }

   New-Item -ItemType Directory -Path $destination -Force | Out-Null
   Copy-Item -Path (Join-Path $source '*') -Destination $destination -Recurse -Force

   if (-not (Test-Path -LiteralPath (Join-Path $targetBin 'rsync.exe') -PathType Leaf) -or
       -not (Test-Path -LiteralPath (Join-Path $targetBin 'ssh.exe') -PathType Leaf)) {
       throw 'cwRsync files were not copied successfully.'
   }

   $binKey = $targetBin.TrimEnd('\')
   $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
   $machineEntries = @($machinePath -split ';' | Where-Object { $_ -and $_.Trim() })
   $hasMachineBin = $machineEntries | Where-Object {
       [Environment]::ExpandEnvironmentVariables($_.Trim()).TrimEnd('\') -ieq $binKey
   }
   if (-not $hasMachineBin) {
       [Environment]::SetEnvironmentVariable('Path', (@($machineEntries) + $targetBin) -join ';', 'Machine')
   }

   $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
   $hasMachineBin = $machinePath -split ';' | Where-Object {
       $_ -and [Environment]::ExpandEnvironmentVariables($_.Trim()).TrimEnd('\') -ieq $binKey
   }
   if (-not $hasMachineBin) { throw 'Could not add cwRsync to Machine PATH.' }

   $processEntries = @($env:Path -split ';' | Where-Object {
       $_ -and ([Environment]::ExpandEnvironmentVariables($_.Trim()).TrimEnd('\') -ine $binKey)
   })
   $env:Path = (@($targetBin) + $processEntries) -join ';'

   & (Join-Path $targetBin 'ssh.exe') -V 2>&1
   if ($LASTEXITCODE -ne 0) { throw 'cwRsync SSH check failed.' }
   rsync --version
   if ($LASTEXITCODE -ne 0) { throw 'rsync version check failed.' }
   ```

5. Confirm the commands display cwRsync's SSH and rsync versions without errors.

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
