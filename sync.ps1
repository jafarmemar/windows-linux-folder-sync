[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [switch]$DryRun,
    [switch]$NonInteractive
)

Set-StrictMode -Version 2.0
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'config.json' }
$script:SyncProcessLedger = New-Object 'Collections.Generic.List[object]'

function Stop-SyncChildTree {
    param([int]$ProcessId)
    # Called only for a still-running process created by Invoke-SyncNative.
    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$ProcessId" -ErrorAction SilentlyContinue)
    foreach ($child in $children) { Stop-SyncChildTree $child.ProcessId }
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

function ConvertTo-CygwinPath {
    param([string]$Path)
    if ($Path -notmatch '^[A-Za-z]:[\\/]' -or $Path -match '[\x00-\x1f\x7f"<>|?*]' -or $Path.Substring(2).Contains(':')) {
        throw 'Use an absolute Windows drive path, such as D:\Projects\Site. UNC paths are not supported.'
    }
    $full = [IO.Path]::GetFullPath($Path).Replace('\', '/')
    return '/cygdrive/' + $full.Substring(0, 1).ToLowerInvariant() + $full.Substring(2)
}

function ConvertTo-NativeArgument {
    param([AllowEmptyString()][string]$Value)
    # Windows CommandLineToArgvW rules; preserve quotes inside rsync's -e argument.
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Invoke-SyncNative {
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [string]$StandardInput = '',
        [hashtable]$Environment = @{},
        [int]$TimeoutSeconds = 60,
        [switch]$Progress
    )
    # Fail closed even for direct helper calls: never start a local receiver or a root scan.
    if ([IO.Path]::GetFileName($Executable) -ieq 'rsync.exe') { Assert-SyncRsyncArguments $Arguments }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.Arguments = (($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $info.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
    foreach ($key in $Environment.Keys) { $info.EnvironmentVariables[$key] = $Environment[$key] }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $info
    $started = $false
    try {
        if (-not $process.Start()) { throw "Could not start $Executable." }
        $started = $true
        $script:SyncProcessLedger.Add([pscustomobject]@{ Id=$process.Id; Started=$process.StartTime })
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if ($StandardInput) { $process.StandardInput.Write($StandardInput.Replace("`r`n", "`n")) }
        $process.StandardInput.Close()
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while (-not $process.WaitForExit(200)) {
            if ($TimeoutSeconds -gt 0 -and $watch.Elapsed.TotalSeconds -gt $TimeoutSeconds) {
                throw "Command timed out after $TimeoutSeconds seconds: $Executable"
            }
            if ($Progress) { Write-Progress -Activity 'Synchronizing Windows to Linux' -Status 'rsync is running' }
        }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $stdout.Result; Error = $stderr.Result }
    }
    finally {
        if ($Progress) { Write-Progress -Activity 'Synchronizing Windows to Linux' -Completed }
        # Only the child started by this invocation may be stopped.
        if ($started -and -not $process.HasExited) { Stop-SyncChildTree $process.Id; $process.WaitForExit() }
        $process.Dispose()
    }
}

function Assert-SyncSuccess {
    param($Result, [string]$Action)
    if ($Result.ExitCode -ne 0) {
        throw ("{0} failed (exit {1}). {2}" -f $Action, $Result.ExitCode, $Result.Error.Trim())
    }
}

function Read-SyncAnswer {
    param([string]$Prompt, [switch]$NonInteractive)
    if ($NonInteractive -or [Console]::IsInputRedirected) {
        throw "Interactive input is unavailable: $Prompt Provide a complete config; deletion always requires an interactive confirmation."
    }
    try { return Read-Host -Prompt $Prompt -ErrorAction Stop }
    catch { throw "Interactive input is unavailable: $Prompt $($_.Exception.Message)" }
}

function Read-SyncBoolean {
    param([string]$Prompt, [bool]$Default, [switch]$NonInteractive)
    while ($true) {
        $answer = Read-SyncAnswer $Prompt -NonInteractive:$NonInteractive
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        switch ($answer.Trim().ToLowerInvariant()) {
            { $_ -in @('y', 'yes') } { return $true }
            { $_ -in @('n', 'no') } { return $false }
            default { Write-Host 'Please enter y or n.' }
        }
    }
}

function Get-SyncDestination {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not $Path.StartsWith('/') -or
        $Path -match '[\x00-\x1f\x7f]' -or $Path.Contains('//') -or
        @($Path.Split('/') | Where-Object { $_ -in @('.', '..', '~') }).Count) {
        throw 'Linux destination must be an absolute path without control characters, //, ., .. or ~ components.'
    }
    $normalized = $Path.TrimEnd('/')
    if (-not $normalized) { $normalized = '/' }
    $roots = @('/', '/bin', '/boot', '/dev', '/etc', '/home', '/lib', '/lib64',
        '/lost+found', '/media', '/mnt', '/opt', '/proc', '/root', '/run', '/sbin',
        '/snap', '/srv', '/sys', '/tmp', '/usr', '/var')
    $trees = @('/bin', '/boot', '/dev', '/etc', '/lib', '/lib64', '/lost+found',
        '/proc', '/root', '/run', '/sbin', '/snap', '/sys', '/usr',
        '/var/lib', '/var/log', '/var/cache', '/var/run', '/var/spool', '/var/lock', '/var/backups')
    if ($normalized -cin $roots -or $normalized -cmatch '(^|/)\.ssh(/|$)' -or
        $normalized -cmatch '^/home/[^/]+$') { throw "Protected Linux destination: $normalized" }
    foreach ($tree in $trees) {
        if ($normalized -ceq $tree -or $normalized.StartsWith($tree + '/', [StringComparison]::Ordinal)) {
            throw "Protected Linux destination: $normalized"
        }
    }
    return $normalized
}

function Test-SyncSetting {
    param([string]$Name, $Value)
    if ($Name -in @('transferModifiedFiles', 'deleteRemovedFiles')) { return $Value -is [bool] }
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value) -or $Value -match '[\x00-\x1f\x7f]') { return $false }
    if ($Name -eq 'sshHost') { return $Value -cmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' }
    if ($Name -eq 'sourcePath') { return $Value -match '^[A-Za-z]:[\\/]' }
    return $true
}

function Read-SyncConfiguration {
    param([string]$Path, [switch]$NonInteractive)
    $config = [pscustomobject]@{}
    if (Test-Path -LiteralPath $Path) {
        try { $config = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
        catch { throw "Cannot read JSON configuration '$Path'. Check file access and JSON syntax. The file was not changed." }
        if ($null -eq $config -or $config.GetType() -ne [Management.Automation.PSCustomObject]) { throw 'Configuration must be a JSON object.' }
    }
    $names = @('sourcePath', 'destinationPath', 'sshHost', 'transferModifiedFiles', 'deleteRemovedFiles')
    $unknown = @($config.PSObject.Properties | ForEach-Object Name | Where-Object { $_ -notin $names })
    if ($unknown.Count) { throw ('Unknown configuration setting(s): ' + ($unknown -join ', ')) }
    $prompts = @{
        sourcePath = 'Windows source folder'; destinationPath = 'Linux destination folder'; sshHost = 'SSH host alias (for example apps)'
        transferModifiedFiles = 'Transfer modified files? [Y/n]'; deleteRemovedFiles = 'Delete files missing from source? [y/N]'
    }
    $values = [ordered]@{}
    $asked = $false
    foreach ($name in $names) {
        $property = $config.PSObject.Properties[$name]
        $value = $null
        if ($null -ne $property) { $value = $property.Value }
        while ($true) {
            if (Test-SyncSetting $name $value) {
                if ($name -ne 'destinationPath') { break }
                try { $value = Get-SyncDestination $value; break }
                catch {
                    if ($NonInteractive) { throw }
                    Write-Host $_.Exception.Message
                }
            }
            $asked = $true
            if ($name -in @('transferModifiedFiles', 'deleteRemovedFiles')) {
                $value = Read-SyncBoolean $prompts[$name] ($name -eq 'transferModifiedFiles') -NonInteractive:$NonInteractive
            }
            else { $value = Read-SyncAnswer $prompts[$name] -NonInteractive:$NonInteractive }
        }
        $values[$name] = $value
    }
    $values.destinationPath = Get-SyncDestination $values.destinationPath
    if ($asked -and -not $NonInteractive -and
        (Read-SyncBoolean 'Save these settings to config.json? [y/N]' $false)) {
        try {
            $json = [pscustomobject]$values | ConvertTo-Json
            [IO.File]::WriteAllText([IO.Path]::GetFullPath($Path), $json + "`n", (New-Object Text.UTF8Encoding($false)))
        }
        catch { throw "Could not save configuration: $($_.Exception.Message)" }
    }
    return [pscustomobject]$values
}

function Get-SyncSource {
    param([string]$Path, [bool]$Deleting)
    [void](ConvertTo-CygwinPath $Path)
    try {
        $folder = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not $folder.PSIsContainer) { throw 'Not a directory.' }
        if ($folder.Name -ieq '.ssh') { throw 'SSH credentials directories are protected.' }
        $full = $folder.FullName.TrimEnd('\')
        if ($full -ieq [IO.Path]::GetPathRoot($folder.FullName).TrimEnd('\')) { throw 'Drive roots are protected.' }
        $protected = @($env:WINDIR, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData,
            (Join-Path $env:USERPROFILE '.ssh'), ($env:SystemDrive+'\System Volume Information'),
            ($env:SystemDrive+'\$Recycle.Bin'), ($env:SystemDrive+'\Recovery')) | Where-Object { $_ }
        if ($full -ieq ($env:SystemDrive+'\Users')) { throw 'The Windows users root is protected.' }
        if ($full -ieq $env:USERPROFILE.TrimEnd('\')) { throw 'The Windows profile root is protected.' }
        foreach ($root in $protected) {
            $root = $root.TrimEnd('\')
            if ($full -ieq $root -or $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw "Protected Windows source: $full"
            }
        }
        $ancestor = $folder
        while ($null -ne $ancestor) {
            if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Source paths with symlinks or junctions are not supported.' }
            $ancestor = $ancestor.Parent
        }
        $pending = New-Object 'Collections.Generic.Stack[IO.DirectoryInfo]'
        $entries = New-Object 'Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
        $pending.Push($folder)
        $fileCount = 0
        while ($pending.Count) {
            $directory = $pending.Pop()
            foreach ($entry in $directory.GetFileSystemInfos()) {
                if ($entry.Name -ieq '.ssh') { throw 'The source contains an SSH credentials directory.' }
                if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The source contains a symlink or junction; remove it from the selected source.' }
                $relative = $entry.FullName.Substring($full.Length + 1).Replace('\', '/')
                if ($entry -is [IO.DirectoryInfo]) { $pending.Push($entry); $entries.Add($relative, 'd') }
                else { $fileCount++; $entries.Add($relative, 'f') }
            }
        }
        if ($Deleting -and $fileCount -eq 0) { throw 'Deletion is blocked because the source contains no regular files.' }
        return [pscustomobject]@{ Path = $full; CygwinPath = (ConvertTo-CygwinPath $full).TrimEnd('/') + '/'; FileCount = $fileCount; Entries = $entries }
    }
    catch { throw "Source folder is not usable: $($_.Exception.Message)" }
}

function Get-CwRsyncTools {
    $rsync = Join-Path $env:ProgramFiles 'cwRsync\bin\rsync.exe'
    if (-not (Test-Path -LiteralPath $rsync -PathType Leaf)) {
        $command = Get-Command rsync.exe -CommandType Application -ErrorAction SilentlyContinue
        if ($null -eq $command) { throw 'cwRsync is not installed. Follow README Installation.' }
        $rsync = $command.Source
    }
    $bin = Split-Path -Parent $rsync
    $ssh = Join-Path $bin 'ssh.exe'
    if (-not (Test-Path -LiteralPath $ssh -PathType Leaf)) { throw "cwRsync SSH is missing from $bin." }
    $rv = Invoke-SyncNative $rsync @('--version')
    Assert-SyncSuccess $rv 'Windows rsync version check'
    $sv = Invoke-SyncNative $ssh @('-V')
    Assert-SyncSuccess $sv 'cwRsync SSH version check'
    Write-Host ('Windows rsync : ' + ($rv.Output -split '[\r\n]+')[0] + " [$rsync]")
    Write-Host ('Windows SSH   : ' + ($sv.Error + $sv.Output).Trim() + " [$ssh]")
    return [pscustomobject]@{ Rsync = $rsync; Ssh = $ssh; Bin = $bin }
}

function Get-SyncTransport {
    param($Tools, [string]$HostAlias)
    $profilePath = $env:USERPROFILE
    $configFile = Join-Path $profilePath '.ssh\config'
    $knownHosts = Join-Path $profilePath '.ssh\known_hosts'
    if (-not (Test-Path -LiteralPath $knownHosts -PathType Leaf)) {
        throw 'Windows .ssh\known_hosts is missing. Verify the server fingerprint using your existing Windows SSH setup first.'
    }
    $options = @('-o', ('UserKnownHostsFile=' + (ConvertTo-CygwinPath $knownHosts)),
        '-o', 'StrictHostKeyChecking=yes', '-o', 'UpdateHostKeys=no', '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=2',
        '-o', 'ControlMaster=no', '-o', 'ControlPath=none')
    if (Test-Path -LiteralPath $configFile -PathType Leaf) { $options = @('-F', (ConvertTo-CygwinPath $configFile)) + $options }
    $effective = Invoke-SyncNative $Tools.Ssh ($options + @('-G', $HostAlias))
    Assert-SyncSuccess $effective 'SSH alias configuration check'
    # Add equivalent Cygwin paths for configured Windows/~/ identity paths, without reading keys.
    foreach ($line in ($effective.Output -split '[\r\n]+')) {
        if ($line -match '^identityfile (.+)$') {
            $identity = $Matches[1]
            if ($identity -match '^~[/\\]') { $identity = Join-Path $profilePath $identity.Substring(2) }
            if ($identity -match '^[A-Za-z]:[/\\]' -and (Test-Path -LiteralPath $identity -PathType Leaf)) {
                $options += @('-i', (ConvertTo-CygwinPath $identity))
            }
        }
    }
    $rshWords = @('ssh') + @($options | ForEach-Object {
        if ($_ -match '["\r\n]') { throw 'Unsupported quote or newline in SSH argument.' }
        '"' + $_ + '"'
    })
    return [pscustomobject]@{ Options = $options; Rsh = ($rshWords -join ' '); Tools = $Tools; HostAlias = $HostAlias }
}

function Get-RemoteGuardScript {
    param([string]$Destination, [switch]$Create, [switch]$Protocol, [string]$ExpectedIdentity = '', [switch]$ListEntries)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Destination))
    $template = @'
set -eu
fail() { printf '%s\n' "$1" >&2; exit 40; }
for tool in rsync realpath base64 stat dirname mountpoint; do
    command -v "$tool" >/dev/null 2>&1 || fail "Required Ubuntu tool is missing: $tool"
done
target=$(printf '%s' '__TARGET__' | base64 --decode) || fail 'Cannot decode destination.'
safe_path() {
    case "$1" in
      /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/lost+found|/media|/mnt|/opt|/proc|/root|/run|/sbin|/snap|/srv|/sys|/tmp|/usr|/var) return 1 ;;
      /bin/*|/boot/*|/dev/*|/etc/*|/lib/*|/lib64/*|/lost+found/*|/proc/*|/root/*|/run/*|/sbin/*|/snap/*|/sys/*|/usr/*) return 1 ;;
      /var/lib|/var/lib/*|/var/log|/var/log/*|/var/cache|/var/cache/*|/var/run|/var/run/*|/var/spool|/var/spool/*|/var/lock|/var/lock/*|/var/backups|/var/backups/*) return 1 ;;
      */.ssh|*/.ssh/*) return 1 ;;
    esac
    case "$1" in /home/*) rest=${1#/home/}; case "$rest" in */*) ;; *) return 1 ;; esac ;; esac
    return 0
}
case "$target" in /*) ;; *) fail 'Destination must be absolute.' ;; esac
case "$target/" in *'//'*|*'/../'*|*'/./'*|*'/~/'*) fail 'Ambiguous destination path.' ;; esac
safe_path "$target" || fail 'Protected Linux destination.'
part=$target
while [ "$part" != / ]; do
    [ ! -L "$part" ] || fail 'Symlinked destinations or parents are not allowed.'
    part=$(dirname -- "$part")
done
canonical=$(realpath -m -- "$target") || fail 'Cannot resolve destination.'
safe_path "$canonical" || fail 'Resolved destination is protected.'
[ "$canonical" = "$target" ] || fail 'Destination is not canonical.'
if [ -e "$target" ]; then
    [ -d "$target" ] || fail 'Destination is not a directory.'
    [ -r "$target" ] && [ -w "$target" ] && [ -x "$target" ] || fail 'Destination is not readable/writable/searchable.'
    mountpoint -q -- "$target" && fail 'A filesystem mount root cannot be the destination.'
    [ -r /proc/self/mountinfo ] || fail 'Cannot inspect destination mounts.'
    while IFS=' ' read -r mid mparent mdev mroot mounted remaining; do
        mounted=$(printf '%b' "$mounted")
        case "$mounted" in "$target"|"$target"/*) fail 'Destination contains a filesystem mount; use a dedicated unmounted directory.' ;; esac
    done < /proc/self/mountinfo
    state=exists
else
    parent=$(dirname -- "$target")
    [ -d "$parent" ] && [ -w "$parent" ] && [ -x "$parent" ] || fail 'Destination parent must already exist and be writable.'
    state=missing
fi
if [ '__CREATE__' = yes ] && [ "$state" = missing ]; then
    mkdir -m 700 -- "$target" || fail 'Cannot create destination.'
    state=exists
fi
identity=missing
if [ "$state" = exists ]; then identity=$(stat -Lc '%d:%i' -- "$target"); fi
if [ -n '__EXPECTED__' ] && [ "$identity" != '__EXPECTED__' ]; then fail 'Destination identity changed; run a fresh preview.'; fi
if [ '__PROTOCOL__' = yes ]; then
    exec rsync "$@"
fi
if [ '__LIST__' = yes ]; then
    if [ "$state" = exists ]; then
        command -v find >/dev/null 2>&1 || fail 'Required Ubuntu tool is missing: find'
        find -P "$target" -xdev -printf '%y/%P\0'
    fi
    exit 0
fi
printf 'SYNC_STATE|%s\n' "$state"
printf 'SYNC_ID|%s\n' "$identity"
printf 'SYNC_PATH|'; printf '%s' "$canonical" | base64 -w 0; printf '\n'
printf 'SYNC_VERSION|'; rsync --version | head -n 1
'@
    if ($ExpectedIdentity -and $ExpectedIdentity -notmatch '^(missing|[0-9]+:[0-9]+)$') { throw 'Invalid destination identity.' }
    return $template.Replace('__TARGET__', $encoded).Replace('__CREATE__', $(if ($Create) { 'yes' } else { 'no' })).Replace('__PROTOCOL__', $(if ($Protocol) { 'yes' } else { 'no' })).Replace('__LIST__', $(if ($ListEntries) { 'yes' } else { 'no' })).Replace('__EXPECTED__', $ExpectedIdentity)
}

function Assert-SyncEntryTypes {
    param($Transport, $Source, $Remote)
    # rsync may unlink mismatched entry types even without --delete/with --ignore-existing.
    # Inspect without following links, using NUL records to preserve literal filenames.
    $scan = Get-RemoteGuardScript $Remote.Path -ExpectedIdentity $Remote.Identity -ListEntries
    $result = Invoke-SyncNative $Transport.Tools.Ssh ($Transport.Options + @($Transport.HostAlias, 'sh -s')) $scan
    Assert-SyncSuccess $result 'Destination entry-type validation'
    $seen = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($record in $result.Output.Split(@([char]0), [StringSplitOptions]::RemoveEmptyEntries)) {
        if ($record.Length -lt 2 -or $record[1] -ne '/') { throw 'Cannot interpret destination entry types safely.' }
        $relative = $record.Substring(2)
        if (-not $relative) { continue }
        if (-not $seen.Add($relative)) { throw 'Ambiguous destination filenames; refusing synchronization.' }
        if ($Source.Entries.ContainsKey($relative) -and $Source.Entries[$relative] -cne $record.Substring(0,1)) {
            throw "Destination entry type conflict at '$relative'. Resolve the file/directory/symlink conflict manually; no synchronization was performed."
        }
    }
}

function Get-SyncRemote {
    param($Transport, [string]$Destination, [switch]$Create)
    $scriptText = Get-RemoteGuardScript $Destination -Create:$Create
    $result = Invoke-SyncNative $Transport.Tools.Ssh ($Transport.Options + @($Transport.HostAlias, 'sh -s')) $scriptText
    Assert-SyncSuccess $result 'SSH/Ubuntu destination validation'
    $data = @{}
    foreach ($line in ($result.Output -split '[\r\n]+')) {
        if ($line -match '^SYNC_(STATE|ID|PATH|VERSION)\|(.*)$') { $data[$Matches[1]] = $Matches[2] }
    }
    foreach ($key in @('STATE', 'ID', 'PATH', 'VERSION')) { if (-not $data.ContainsKey($key)) { throw 'Unexpected response from remote destination validation.' } }
    $canonical = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($data.PATH))
    if ($canonical -cne $Destination) { throw 'The remote canonical path differs from the approved destination.' }
    [void](Get-SyncDestination $canonical)
    return [pscustomobject]@{ Path = $canonical; State = $data.STATE; Identity = $data.ID; Version = $data.VERSION }
}

function ConvertTo-PosixLiteral {
    param([string]$Value)
    return "'" + $Value.Replace("'", "'" + '"' + "'" + '"' + "'") + "'"
}

function Get-SyncEvents {
    param([string]$Output)
    $events = @()
    foreach ($line in ($Output -split '[\r\n]+')) {
        if ($line -match '^SYNC\|(.{11})\|(.*)$') {
            $events += [pscustomobject]@{ Code = $Matches[1]; Name = $Matches[2] }
        }
        elseif ($line.StartsWith('SYNC|')) { throw 'Unrecognized rsync itemized output; refusing to infer a deletion plan.' }
    }
    return $events
}

function Assert-SyncRsyncArguments {
    param([string[]]$Arguments)
    if ($Arguments.Count -eq 1 -and $Arguments[0] -ceq '--version') { return }
    $invalid = 'Unsafe rsync arguments; expected approved options, --, one non-root Windows source and one remote destination.'
    $fixed = @('-rt', '--omit-dir-times', '--open-noatime', '--one-file-system', '--secluded-args',
        '--itemize-changes', '--out-format=SYNC|%i|%n%L', '--stats', '-e')
    if ($Arguments.Count -lt 16) { throw $invalid }
    for ($i = 0; $i -lt $fixed.Count; $i++) {
        if ($Arguments[$i] -cne $fixed[$i]) { throw $invalid }
    }
    if ([string]::IsNullOrWhiteSpace($Arguments[9]) -or
        -not $Arguments[10].StartsWith('--rsync-path=sh -c ')) { throw $invalid }
    $i = 11
    if ($Arguments[$i++] -cnotin @('--checksum', '--ignore-existing')) { throw $invalid }
    if ($Arguments[$i] -ceq '--delete-delay') {
        $i++
        if ($Arguments[$i] -cmatch '^--max-delete=[0-9]+$') { $i++ }
    }
    elseif ($Arguments[$i++] -cne '--max-delete=0') { throw $invalid }
    if ($Arguments[$i++] -cnotin @('--dry-run', '--info=progress2')) { throw $invalid }
    if ($Arguments.Count -ne $i + 3 -or $Arguments[$i++] -cne '--') { throw $invalid }
    $source = $Arguments[$i++]
    if ($source -cnotmatch '^/cygdrive/[a-z]/[^/].*/$' -or
        $source -match '[\x00-\x1f\x7f"\\]' -or $source.Contains('//')) { throw $invalid }
    $windows = $source.Substring(10,1) + ':\' + $source.Substring(12).Replace('/', '\')
    if ((ConvertTo-CygwinPath $windows) -cne $source) { throw $invalid }
    $destination = $Arguments[$i]
    if ($destination -notmatch '^([^:]+):(/.+/)$') { throw $invalid }
    if (-not (Test-SyncSetting 'sshHost' $Matches[1])) { throw $invalid }
    [void](Get-SyncDestination $Matches[2])
}

function Invoke-SyncRsync {
    param($Transport, $Source, $Remote, $Settings, [switch]$Preview, [int]$MaxDelete = -1)
    $expectedSource = (ConvertTo-CygwinPath $Source.Path).TrimEnd('/') + '/'
    if ($Source.CygwinPath -cne $expectedSource) { throw 'Source conversion mismatch; refusing rsync.' }
    $guard = Get-RemoteGuardScript $Remote.Path -Protocol -ExpectedIdentity $Remote.Identity
    $remoteCommand = 'sh -c ' + (ConvertTo-PosixLiteral $guard) + ' sync-guard'
    $arguments = @('-rt', '--omit-dir-times', '--open-noatime', '--one-file-system', '--secluded-args', '--itemize-changes',
        '--out-format=SYNC|%i|%n%L', '--stats', '-e', $Transport.Rsh, ('--rsync-path=' + $remoteCommand))
    if ($Settings.transferModifiedFiles) { $arguments += '--checksum' }
    else { $arguments += '--ignore-existing' }
    if ($Settings.deleteRemovedFiles) {
        $arguments += '--delete-delay'
        if ($MaxDelete -ge 0) { $arguments += ('--max-delete=' + $MaxDelete) }
    }
    else { $arguments += '--max-delete=0' }
    if ($Preview) { $arguments += '--dry-run' } else { $arguments += '--info=progress2' }
    $arguments += @('--', $Source.CygwinPath, ($Transport.HostAlias + ':' + $Remote.Path.TrimEnd('/') + '/'))
    Assert-SyncRsyncArguments $arguments
    $environment = @{ PATH = $Transport.Tools.Bin + ';' + $env:Path }
    $result = Invoke-SyncNative $Transport.Tools.Rsync $arguments -Environment $environment -TimeoutSeconds 0 -Progress:(-not $Preview)
    Write-Host $result.Output.TrimEnd()
    Assert-SyncSuccess $result 'rsync transfer/preview'
    if ($result.Error.Trim()) { Write-Host $result.Error.Trim() }
    return [pscustomobject]@{ Events = @(Get-SyncEvents $result.Output); Output = $result.Output }
}

function Show-SyncSummary {
    param($Result)
    $newFiles = @($Result.Events | Where-Object { $_.Code -match '^[<>]f\+{9}$' }).Count
    $modified = @($Result.Events | Where-Object { $_.Code -match '^[<>]f' -and $_.Code -notmatch '^..\+{9}$' }).Count
    $deleted = @($Result.Events | Where-Object { $_.Code.StartsWith('*deleting') })
    Write-Host "New files: $newFiles; modified files: $modified; deleted entries (files/directories): $($deleted.Count)"
    foreach ($entry in $deleted) { Write-Host ('Delete: ' + $entry.Name) }
}

function Confirm-SyncPath {
    param([string]$Prompt, [string]$Path, [switch]$NonInteractive)
    $answer = Read-SyncAnswer ($Prompt + " Type the full path exactly: $Path") -NonInteractive:$NonInteractive
    if ($answer -cne $Path) { throw 'Operation cancelled: the full destination path was not confirmed. No synchronization was performed.' }
}

function Invoke-FolderSync {
    param($Settings, [switch]$DryRun, [switch]$NonInteractive)
    foreach ($name in @('sourcePath', 'destinationPath', 'sshHost', 'transferModifiedFiles', 'deleteRemovedFiles')) {
        $property = $Settings.PSObject.Properties[$name]
        if ($null -eq $property -or -not (Test-SyncSetting $name $property.Value)) { throw "Invalid or missing setting: $name" }
    }
    $destination = Get-SyncDestination $Settings.destinationPath
    $source = Get-SyncSource $Settings.sourcePath $Settings.deleteRemovedFiles
    $tools = Get-CwRsyncTools
    $transport = Get-SyncTransport $tools $Settings.sshHost
    $remote = Get-SyncRemote $transport $destination
    Write-Host "Ubuntu rsync  : $($remote.Version)"
    Write-Host "SSH connection: $($Settings.sshHost) [OK]"
    Write-Host "Source        : $($source.Path) [OK]"
    Write-Host "Destination   : $($Settings.sshHost):$($remote.Path) [$($remote.State)]"
    if (-not $Settings.transferModifiedFiles -and $Settings.deleteRemovedFiles) {
        Write-Host 'New files and deletions only: existing destination files are retained, so the result is not a complete mirror.'
    }
    if ($remote.State -eq 'missing' -and -not $DryRun) {
        Confirm-SyncPath 'Create this destination directory?' $remote.Path -NonInteractive:$NonInteractive
        $remote = Get-SyncRemote $transport $destination -Create
    }
    Assert-SyncEntryTypes $transport $source $remote
    $preview = Invoke-SyncRsync $transport $source $remote $Settings -Preview
    Show-SyncSummary $preview
    Write-Host 'Preview completed.'
    if ($DryRun) { Write-Host 'Dry run only; no synchronization was performed.'; return $preview }
    if ($Settings.deleteRemovedFiles) {
        Write-Host "Deletion approval for SSH host $($Settings.sshHost), canonical destination $($remote.Path)"
        Confirm-SyncPath 'Approve synchronization with deletion?' $remote.Path -NonInteractive:$NonInteractive
    }
    $checkedSource = Get-SyncSource $Settings.sourcePath $Settings.deleteRemovedFiles
    $checkedRemote = Get-SyncRemote $transport $destination
    if ($checkedSource.Path -cne $source.Path -or $checkedRemote.Identity -cne $remote.Identity) {
        throw 'Source or destination changed after preview; run again.'
    }
    Assert-SyncEntryTypes $transport $checkedSource $checkedRemote
    $maxDelete = -1
    if ($Settings.deleteRemovedFiles) {
        $recheck = Invoke-SyncRsync $transport $checkedSource $checkedRemote $Settings -Preview
        $before = @($preview.Events | Where-Object { $_.Code.StartsWith('*deleting') } | ForEach-Object Name | Sort-Object)
        $after = @($recheck.Events | Where-Object { $_.Code.StartsWith('*deleting') } | ForEach-Object Name | Sort-Object)
        if (($before -join "`n") -cne ($after -join "`n")) { throw 'Deletion plan changed after approval; run a fresh preview.' }
        $maxDelete = $before.Count
    }
    $completed = Invoke-SyncRsync $transport $checkedSource $checkedRemote $Settings -MaxDelete $maxDelete
    Show-SyncSummary $completed
    Write-Host 'Synchronization completed successfully.'
    return $completed
}

if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    try {
        $settings = Read-SyncConfiguration $ConfigPath -NonInteractive:$NonInteractive
        $null = Invoke-FolderSync $settings -DryRun:$DryRun -NonInteractive:$NonInteractive
        exit 0
    }
    catch { Write-Error $_.Exception.Message -ErrorAction Continue; exit 1 }
}
