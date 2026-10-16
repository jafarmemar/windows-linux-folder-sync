# windows-linux-folder-sync
One-way Windows-to-Linux folder synchronization using rsync over SSH, with incremental transfers, automatic deletion of removed files, and PowerShell automation.

## Installation

### Windows 11 (cwRsync 6.5.0)

1. Download [cwRsync 6.5.0 for Windows x64](https://itefix.net/downloads/cwrsync/cwrsync_6.5.0_x64_free.zip) from the [official Itefix website](https://itefix.net/cwrsync/).
2. From the folder containing the downloaded ZIP, verify its SHA-256 in PowerShell:

   ```powershell
   (Get-FileHash .\cwrsync_6.5.0_x64_free.zip -Algorithm SHA256).Hash.ToLowerInvariant()
   ```

   Expected: `8dc20afec889908c05c2abaa21d37f3fcad3e7ea5f3f37e95b25e6178f6b983a`.
3. Extract the ZIP contents directly to `%LOCALAPPDATA%\cwRsync`, preserving the folder structure. The executables should be at `%LOCALAPPDATA%\cwRsync\bin\rsync.exe` and `%LOCALAPPDATA%\cwRsync\bin\ssh.exe`.
4. Add the `bin` directory to your User PATH. Run this in PowerShell; it requires no Administrator access and avoids duplicate entries:

   ```powershell
   $bin = Join-Path $env:LOCALAPPDATA 'cwRsync\bin'
   foreach ($scope in @('User', 'Process')) {
       $path = [Environment]::GetEnvironmentVariable('Path', $scope)
       $entries = @($path -split ';' | Where-Object { $_ -and $_.Trim() })
       $exists = $entries | Where-Object {
           [Environment]::ExpandEnvironmentVariables($_.Trim()).TrimEnd('\') -ieq $bin.TrimEnd('\')
       }
       if (-not $exists) {
           [Environment]::SetEnvironmentVariable('Path', (@($entries) + $bin) -join ';', $scope)
       }
   }
   ```

5. Open a new PowerShell window and check the commands:

   ```powershell
   rsync --version
   ssh -V
   ```

`cwrsync.cmd` is a sample batch launcher that sets a temporary PATH and displays the rsync and SSH versions; it is not an installer. WSL and MSYS2 are not required.

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
