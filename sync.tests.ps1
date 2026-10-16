[CmdletBinding()]
param([switch]$Integration)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
. (Join-Path $PSScriptRoot 'sync.ps1')
$script:Passed = 0
$script:Answers = New-Object 'Collections.Generic.Queue[string]'
$script:Prompts = New-Object 'Collections.Generic.List[string]'
$script:OnAnswer = $null
$originalReader = (Get-Item Function:\Read-SyncAnswer).ScriptBlock

function Assert-Test {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "FAILED: $Message" }
    $script:Passed++
    Write-Host "PASS: $Message"
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern, [string]$Message)
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
    Assert-Test ($null -ne $caught -and $caught -like $Pattern) "$Message (expected $Pattern; received $caught)"
}

function Set-TestAnswers {
    param([string[]]$Values)
    $script:Answers.Clear()
    $script:Prompts.Clear()
    $script:OnAnswer = $null
    foreach ($value in $Values) { $script:Answers.Enqueue($value) }
}

# Test-only prompt substitute: production has no approval-bypass parameter.
function Read-SyncAnswer {
    param([string]$Prompt, [switch]$NonInteractive)
    if ($NonInteractive) { throw "Interactive input is unavailable: $Prompt" }
    $script:Prompts.Add($Prompt)
    if (-not $script:Answers.Count) { throw "Unexpected prompt in test: $Prompt" }
    if ($null -ne $script:OnAnswer) {
        $hook = $script:OnAnswer
        $script:OnAnswer = $null
        & $hook | Out-Null
    }
    return $script:Answers.Dequeue()
}

function Write-TestText {
    param([string]$Path, [string]$Text)
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

$testRoot = Join-Path $env:TEMP ('wlfs-tests-' + [guid]::NewGuid().ToString('N'))
$remoteRoot = '/tmp/wlfs-integration-' + [guid]::NewGuid().ToString('N')
$remoteIdentity = ''
$transport = $null
$cleanupErrors = New-Object 'Collections.Generic.List[string]'
$failure = $null
$pathBefore = $env:Path
$machinePathBefore = [Environment]::GetEnvironmentVariable('Path', 'Machine')
$userPathBefore = [Environment]::GetEnvironmentVariable('Path', 'User')
$remoteProcessesBefore = @()
$sshFiles = @((Join-Path $env:USERPROFILE '.ssh\config'), (Join-Path $env:USERPROFILE '.ssh\known_hosts'))
$sshHashes = @{}
foreach ($path in $sshFiles) { if (Test-Path -LiteralPath $path) { $sshHashes[$path] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash } }

function Invoke-TestRemote {
    param([string]$ScriptText)
    $result = Invoke-SyncNative $transport.Tools.Ssh ($transport.Options + @($transport.HostAlias, 'sh -s')) $ScriptText
    Assert-SyncSuccess $result 'Integration remote command'
    return $result.Output.Trim()
}

function Get-TestAssignment {
    param([string]$Name, [string]$Value)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Value))
    return $Name + '=$(printf %s ' + $encoded + ' | base64 --decode)' + "`n"
}

function Assert-RemoteHash {
    param([string]$LocalPath, [string]$RemotePath, [string]$Message)
    $scriptText = (Get-TestAssignment 'file' $RemotePath) + 'sha256sum -- "$file"'
    $out = Invoke-TestRemote $scriptText
    $remoteHash = ($out -split '\s+')[0]
    $localHash = (Get-FileHash -LiteralPath $LocalPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-Test ($localHash -ceq $remoteHash) $Message
}

try {
    if (Test-Path -LiteralPath $testRoot) { throw 'Unique test root already exists.' }
    [void][IO.Directory]::CreateDirectory($testRoot)
    Assert-Test ((ConvertTo-CygwinPath 'C:\Folder with spaces\data') -ceq '/cygdrive/c/Folder with spaces/data') 'Cygwin drive and spaces conversion'
    Assert-Throws { ConvertTo-CygwinPath '\\server\share' } '*absolute Windows drive*' 'Reject UNC sources'
    foreach ($path in @('/', '/etc', '/etc/ssh', '/var/lib', '/var/log/nginx', '/var/cache/x', '/root/.ssh',
        '/home', '/home/alice', '/home/alice/.ssh/key', '/srv', '/opt', '/tmp', '/usr/local', '/proc/self',
        '/srv/a/../b', '/srv/./b', '/srv//b', '~/site', '/srv/~/b', 'relative', "`n/tmp/x")) {
        Assert-Throws { Get-SyncDestination $path } '*' "Reject protected/ambiguous destination $($path.Replace("`n", '<newline>'))"
    }
    foreach ($path in @('/srv/site', '/opt/site', '/home/alice/site', '/tmp/dedicated-test', "/srv/site space ' ; false ; #")) {
        Assert-Test ((Get-SyncDestination $path) -ceq $path) "Accept dedicated path $path"
    }
    Assert-Test ((Get-SyncDestination '/srv/site/') -ceq '/srv/site') 'Canonical trailing slash handling'
    Assert-Throws { Get-SyncSource 'C:\' $false } '*Drive roots*' 'Protect Windows drive root'
    Assert-Throws { Get-SyncSource $env:WINDIR $false } '*Protected Windows source*' 'Protect Windows system source'
    Assert-Throws { Get-SyncSource $env:USERPROFILE $false } '*profile root*' 'Protect Windows profile root'
    Assert-Throws { Get-SyncSource ($env:SystemDrive+'\Users') $false } '*users root*' 'Protect Windows users root'
    $empty = Join-Path $testRoot 'empty'
    [void][IO.Directory]::CreateDirectory($empty)
    Assert-Throws { Get-SyncSource $empty $true } '*no regular files*' 'Block deletion from an empty source'
    $credentialsSource = Join-Path $testRoot 'credentials-source'
    [void][IO.Directory]::CreateDirectory((Join-Path $credentialsSource '.ssh'))
    Assert-Throws { Get-SyncSource $credentialsSource $false } '*SSH credentials directory*' 'Do not transfer nested SSH credentials directories'
    Assert-Throws { Get-SyncSource (Join-Path $credentialsSource '.ssh') $false } '*SSH credentials directories are protected*' 'Reject SSH credentials directories as the source itself'

    $configFile = Join-Path $testRoot 'settings with spaces.json'
    $settings = [pscustomobject]@{ sourcePath = $testRoot; destinationPath = '/srv/test'; sshHost = 'apps'; transferModifiedFiles = $false; deleteRemovedFiles = $false }
    Write-TestText $configFile ($settings | ConvertTo-Json)
    Set-TestAnswers @()
    $loaded = Read-SyncConfiguration $configFile -NonInteractive
    Assert-Test (-not $loaded.transferModifiedFiles -and -not $loaded.deleteRemovedFiles -and $script:Prompts.Count -eq 0) 'Complete config preserves real false values without prompts'
    $settings.sourcePath = $testRoot + '\Unicode ' + [char]0x00e9
    Write-TestText $configFile ($settings | ConvertTo-Json)
    $loaded = Read-SyncConfiguration $configFile -NonInteractive
    Assert-Test ($loaded.sourcePath -ceq $settings.sourcePath) 'Read UTF-8 configuration without corrupting non-ASCII paths in Windows PowerShell'
    $settings.sourcePath = $testRoot
    Write-TestText $configFile '{"sourcePath":"D:\\Test","sshHost":"apps","transferModifiedFiles":false,"deleteRemovedFiles":false}'
    Set-TestAnswers @('/srv/test', 'n')
    $loaded = Read-SyncConfiguration $configFile
    Assert-Test ($script:Prompts.Count -eq 2 -and -not $loaded.transferModifiedFiles -and -not $loaded.deleteRemovedFiles) 'Incomplete config asks only for missing value and save approval'
    $absentConfig = Join-Path $testRoot 'absent.json'
    Set-TestAnswers @($testRoot, '/srv/test', 'apps', 'yes', 'no', 'n')
    $loaded = Read-SyncConfiguration $absentConfig
    Assert-Test ($script:Prompts.Count -eq 6 -and $loaded.transferModifiedFiles -and -not $loaded.deleteRemovedFiles -and -not (Test-Path $absentConfig)) 'No config asks five settings in order and does not save without approval'
    Set-TestAnswers @($testRoot, 'relative', '/etc', '/srv/test', 'apps', 'y', 'n', 'n')
    $loaded = Read-SyncConfiguration (Join-Path $testRoot 'invalid-path.json')
    Assert-Test ($loaded.destinationPath -ceq '/srv/test' -and $script:Prompts.Count -eq 8) 'Invalid and protected interactive paths are re-prompted'
    Set-TestAnswers @($testRoot, '/srv/test', 'bad host', 'apps', 'invalid', 'n', 'y', 'y')
    $loaded = Read-SyncConfiguration $absentConfig
    $saved = Get-Content $absentConfig -Raw | ConvertFrom-Json
    Assert-Test (-not $saved.transferModifiedFiles -and $saved.deleteRemovedFiles -and $script:Answers.Count -eq 0) 'Invalid answers are repeated; saving requires explicit approval'
    Write-TestText $configFile '{"sourcePath":"D:\\Test","destinationPath":"/srv/test","sshHost":"apps","transferModifiedFiles":"false","deleteRemovedFiles":false}'
    Set-TestAnswers @('n', 'n')
    $loaded = Read-SyncConfiguration $configFile
    Assert-Test (-not $loaded.transferModifiedFiles -and -not $loaded.deleteRemovedFiles -and $script:Prompts.Count -eq 2) 'String booleans are not silently accepted'
    Write-TestText $configFile '{broken json'
    $beforeHash = (Get-FileHash $configFile).Hash
    Assert-Throws { Read-SyncConfiguration $configFile } '*Cannot read JSON*' 'Malformed config fails clearly'
    Assert-Test ((Get-FileHash $configFile).Hash -eq $beforeHash) 'Malformed configuration remains untouched'
    Assert-Throws { Read-SyncConfiguration (Join-Path $testRoot 'missing.json') -NonInteractive } '*Interactive input is unavailable*' 'Missing unattended settings fail'
    Write-TestText $configFile '[]'
    Assert-Throws { Read-SyncConfiguration $configFile } '*JSON object*' 'Reject non-object JSON'
    Write-TestText $configFile '{"unexpected":true}'
    Assert-Throws { Read-SyncConfiguration $configFile } '*Unknown configuration*' 'Detect configuration typos'
    Assert-Test (-not (Test-SyncSetting 'sshHost' '-oProxyCommand=bad')) 'Reject host option injection'
    Assert-Test (-not (Test-SyncSetting 'sshHost' 'apps;false')) 'Reject shell syntax in SSH host alias'
    $sample = "SYNC|<f+++++++++|new.txt`nSYNC|<fc........|changed.txt`nSYNC|*deleting  |old|file.txt`nnoise"
    $events = @(Get-SyncEvents $sample)
    Assert-Test ($events.Count -eq 3 -and $events[2].Name -ceq 'old|file.txt') 'Parse actual itemized event format without splitting filenames on pipes'
    Assert-Throws { Get-SyncEvents 'SYNC|unexpected' } '*Unrecognized rsync*' 'Unknown itemized formats fail closed'
    Assert-Throws { Invoke-SyncNative (Join-Path $testRoot 'missing.exe') @() } '*' 'Missing executable does not mask the process-start error'
    $realNative = (Get-Item Function:\Invoke-SyncNative).ScriptBlock
    try {
        function Invoke-SyncNative {
            param($Executable, $Arguments, $Environment, $TimeoutSeconds, [switch]$Progress)
            $script:CapturedArguments = $Arguments
            $script:CapturedEnvironment = $Environment
            return [pscustomobject]@{ExitCode=0;Output='';Error=''}
        }
        $mockTransport = [pscustomobject]@{Tools=[pscustomobject]@{Rsync='never-executed';Bin='C:\safe bin'};Rsh='ssh';HostAlias='apps'}
        $mockSource = [pscustomobject]@{CygwinPath='/cygdrive/c/safe source/'}
        $mockRemote = [pscustomobject]@{Path='/tmp/safe-target';Identity='missing'}
        $null = Invoke-SyncRsync $mockTransport $mockSource $mockRemote $settings -Preview
        Assert-Test ($script:CapturedArguments[-3] -ceq '--' -and $script:CapturedArguments[-2] -ceq '/cygdrive/c/safe source/' -and
            $script:CapturedArguments[-1] -ceq 'apps:/tmp/safe-target/' -and '/' -notin $script:CapturedArguments) 'Production argument vector contains exactly one safe source and one remote destination'
        Assert-Test ('--max-delete=0' -in $script:CapturedArguments -and '--secluded-args' -in $script:CapturedArguments) 'No-delete cap and protected remote arguments are explicit'
        Assert-Test ($script:CapturedEnvironment.PATH.StartsWith('C:\safe bin;') -and $env:Path -ceq $pathBefore) 'cwRsync PATH priority is scoped to the rsync child only'
    }
    finally { Set-Item Function:\Invoke-SyncNative $realNative }
    $example = Get-Content (Join-Path $PSScriptRoot 'config.example.json') -Raw | ConvertFrom-Json
    foreach ($prop in $example.PSObject.Properties) { Assert-Test (Test-SyncSetting $prop.Name $prop.Value) "Example setting $($prop.Name) is valid" }

    if ($Integration) {
        $tools = Get-CwRsyncTools
        $transport = Get-SyncTransport $tools 'apps'
        $remoteProcessesBefore = @((Invoke-TestRemote 'pgrep -x rsync || true') -split '[\r\n]+' | Where-Object {$_})
        # Ownership is established only by successful exclusive creation and a returned inode.
        $createRoot = (Get-TestAssignment 'root' $remoteRoot) + @'
set -eu
test ! -e "$root"
test ! -L "$root"
mkdir -m 700 -- "$root"
stat -Lc '%d:%i' -- "$root"
'@
        $rootOutput = Invoke-TestRemote $createRoot
        if ($rootOutput -notmatch '^[0-9]+:[0-9]+$') { throw "Cannot prove ownership of remote test directory: $remoteRoot" }
        $remoteIdentity = $rootOutput
        $source = Join-Path $testRoot ("source space ' Unicode " + [char]0x00e9)
        [void][IO.Directory]::CreateDirectory((Join-Path $source 'nested'))
        Write-TestText (Join-Path $source 'alpha.txt') 'AAAA'
        Write-TestText (Join-Path $source "nested\space ' file.txt") 'nested payload'
        Write-TestText (Join-Path $source 'delete-me.txt') 'delete test payload'
        $destination = $remoteRoot + "/target space ' ; false ; # " + [char]0x00e9
        $settings = [pscustomobject]@{sourcePath=$source;destinationPath=$destination;sshHost='apps';transferModifiedFiles=$true;deleteRemovedFiles=$false}
        Set-TestAnswers @($destination)
        $first = Invoke-FolderSync $settings
        Assert-Test (@($first.Events | Where-Object { $_.Code -match '^<f\+{9}$' }).Count -eq 3) 'Create approved target and transfer three new files; spaces/apostrophes/shell characters are literal'
        Assert-RemoteHash (Join-Path $source 'alpha.txt') ($destination+'/alpha.txt') 'Initial alpha SHA-256 matches Ubuntu'
        Assert-RemoteHash (Join-Path $source "nested\space ' file.txt") ($destination+"/nested/space ' file.txt") 'Nested filename with spaces/apostrophe transfers correctly'

        # Same size and timestamp, different content: this must be detected by checksum.
        $alpha = Join-Path $source 'alpha.txt'
        $stamp = (Get-Item $alpha).LastWriteTimeUtc
        Write-TestText $alpha 'BBBB'
        (Get-Item $alpha).LastWriteTimeUtc = $stamp
        $changed = Invoke-FolderSync $settings -NonInteractive
        Assert-Test (@($changed.Events | Where-Object { $_.Code -match '^<fc' }).Count -eq 1) 'Checksum detects changed content with identical size and timestamp'
        Assert-RemoteHash $alpha ($destination+'/alpha.txt') 'Modified file SHA-256 matches Ubuntu'
        $expectedAlpha = Join-Path $testRoot 'expected-alpha.txt'
        Write-TestText $expectedAlpha 'BBBB'
        Write-TestText $alpha 'CCCC'
        Write-TestText (Join-Path $source 'new-only.txt') 'new only payload'
        $settings.transferModifiedFiles = $false
        $newOnly = Invoke-FolderSync $settings -NonInteractive
        Assert-Test (@($newOnly.Events | Where-Object { $_.Code -match '^<f\+{9}$' }).Count -eq 1) 'New-files-only mode transfers just the new file'
        Assert-RemoteHash $expectedAlpha ($destination+'/alpha.txt') 'New-files-only mode preserves differing existing destination content'
        [IO.File]::Delete((Join-Path $source 'delete-me.txt'))
        $null = Invoke-FolderSync $settings -NonInteractive
        $exists = Invoke-TestRemote ((Get-TestAssignment 'file' ($destination+'/delete-me.txt')) + 'test -f "$file"; printf retained')
        Assert-Test ($exists -ceq 'retained') 'Deletion-disabled mode preserves extra destination files'

        $settings.deleteRemovedFiles = $true
        $preview = Invoke-FolderSync $settings -DryRun -NonInteractive
        Assert-Test (@($preview.Events | Where-Object { $_.Code.StartsWith('*deleting') }).Count -eq 1) 'Mandatory dry run identifies the exact extra test file'
        Set-TestAnswers @('not-the-destination')
        Assert-Throws { Invoke-FolderSync $settings } '*cancelled*' 'Wrong path approval blocks the entire real synchronization'
        Assert-Throws { Invoke-FolderSync $settings -NonInteractive } '*Interactive input is unavailable*' 'Config delete=true never authorizes unattended deletion'
        $exists = Invoke-TestRemote ((Get-TestAssignment 'file' ($destination+'/delete-me.txt')) + 'test -f "$file"; printf retained')
        Assert-Test ($exists -ceq 'retained') 'Dry-run and rejected confirmations leave deletion candidate intact'
        Set-TestAnswers @($destination)
        $script:OnAnswer = { Invoke-TestRemote ((Get-TestAssignment 'file' ($destination+'/changed-plan.txt')) + ': > "$file"') }
        Assert-Throws { Invoke-FolderSync $settings } '*Deletion plan changed*' 'New deletion candidates appearing after approval stop the operation'
        $null = Invoke-TestRemote ((Get-TestAssignment 'file' ($destination+'/changed-plan.txt')) + 'rm -- "$file"')
        Set-TestAnswers @($destination)
        $deleted = Invoke-FolderSync $settings
        Assert-Test (@($deleted.Events | Where-Object { $_.Code.StartsWith('*deleting') }).Count -eq 1) 'Explicit full-path approval deletes exactly the previewed test file'
        $gone = Invoke-TestRemote ((Get-TestAssignment 'file' ($destination+'/delete-me.txt')) + 'test ! -e "$file"; printf absent')
        Assert-Test ($gone -ceq 'absent') 'Approved test file is absent on Ubuntu'
        Assert-RemoteHash $expectedAlpha ($destination+'/alpha.txt') 'Deletion and modified-file options operate independently'
        $repeat = Invoke-FolderSync $settings -DryRun -NonInteractive
        Assert-Test ($repeat.Events.Count -eq 0) 'Identical new-only/deletion rerun has no changes'
        $settings.deleteRemovedFiles = $false
        $settings.transferModifiedFiles = $true
        $null = Invoke-FolderSync $settings -NonInteractive
        Assert-RemoteHash $alpha ($destination+'/alpha.txt') 'Re-enabling updates synchronizes the differing file'
        $repeat = Invoke-FolderSync $settings -DryRun -NonInteractive
        Assert-Test ($repeat.Events.Count -eq 0) 'Checksum mode repeat has no unnecessary transfers'

        # File/directory collisions must not remove existing destination entries in no-delete mode.
        $collisionSource = Join-Path $testRoot 'collision source'
        [void][IO.Directory]::CreateDirectory((Join-Path $collisionSource 'source-dir'))
        Write-TestText (Join-Path $collisionSource 'source-file') 'collision test'
        $collisionTarget = $remoteRoot+'/collision-target'
        $null = Invoke-TestRemote ((Get-TestAssignment 'target' $collisionTarget) + 'mkdir -p -- "$target/source-file"; printf retained > "$target/source-dir"')
        $collisionSettings = [pscustomobject]@{sourcePath=$collisionSource;destinationPath=$collisionTarget;sshHost='apps';transferModifiedFiles=$true;deleteRemovedFiles=$false}
        foreach ($modifiedMode in @($true,$false)) {
            foreach ($deleteMode in @($true,$false)) {
                $collisionSettings.transferModifiedFiles = $modifiedMode
                $collisionSettings.deleteRemovedFiles = $deleteMode
                Assert-Throws { Invoke-FolderSync $collisionSettings -DryRun -NonInteractive } '*Destination entry type conflict*' "Type conflicts are rejected (modified=$modifiedMode, delete=$deleteMode)"
            }
        }
        $retained = Invoke-TestRemote ((Get-TestAssignment 'target' $collisionTarget) + 'test -d "$target/source-file" && test -f "$target/source-dir" && printf retained')
        Assert-Test ($retained -ceq 'retained') 'Type-conflict destinations retain their original entry types'

        $wrongIdentity = Get-RemoteGuardScript $destination -Protocol -ExpectedIdentity '1:1'
        Assert-Throws {
            $result = Invoke-SyncNative $tools.Ssh ($transport.Options + @('apps','sh -s')) $wrongIdentity
            Assert-SyncSuccess $result 'Remote launch guard'
        } '*Destination identity changed*' 'Remote launch guard rejects a replaced destination inode'

        # Exercise an SSH config path with spaces without copying keys or editing SSH files.
        $includeConfig = Join-Path $testRoot 'ssh config with spaces'
        $originalConfig = ConvertTo-CygwinPath (Join-Path $env:USERPROFILE '.ssh\config')
        Write-TestText $includeConfig ('Include "'+$originalConfig+'"'+"`n")
        $spacedOptions = @($transport.Options)
        $spacedOptions[1] = ConvertTo-CygwinPath $includeConfig
        $spacedTransport = [pscustomobject]@{Options=$spacedOptions;Rsh=('ssh '+(($spacedOptions | ForEach-Object {'"'+$_+'"'}) -join ' '));Tools=$tools;HostAlias='apps'}
        $remote = Get-SyncRemote $spacedTransport $destination
        $spaced = Invoke-SyncRsync $spacedTransport (Get-SyncSource $source $false) $remote $settings -Preview
        Assert-Test ($spaced.Events.Count -eq 0) 'cwRsync SSH transport supports a config pathname with spaces'

        $missingTarget = $remoteRoot+'/missing-target'
        $settings.destinationPath = $missingTarget
        $null = Invoke-FolderSync $settings -DryRun -NonInteractive
        $missing = Get-SyncRemote $transport $missingTarget
        Assert-Test ($missing.State -ceq 'missing') 'Dry run does not create a missing destination'
        Set-TestAnswers @('no')
        Assert-Throws { Invoke-FolderSync $settings } '*cancelled*' 'Missing destination creation requires exact path approval'
        Assert-Test ((Get-SyncRemote $transport $missingTarget).State -ceq 'missing') 'Rejected creation leaves destination absent'
        $settings.sourcePath = $empty
        $settings.deleteRemovedFiles = $true
        Assert-Throws { Invoke-FolderSync $settings } '*no regular files*' 'Real orchestration blocks empty-source deletion before SSH'

        foreach ($sensitive in @('/etc/ssh','/var/lib','/home','/srv','/tmp')) {
            Assert-Throws { Get-SyncRemote $transport $sensitive } '*Protected Linux destination*' "Remote guard independently protects $sensitive"
        }
        $link = $remoteRoot+'/dangerous-link'
        $null = Invoke-TestRemote ((Get-TestAssignment 'link' $link) + 'ln -s /etc -- "$link"')
        Assert-Throws { Get-SyncRemote $transport $link } '*Symlinked destinations*' 'Remote guard rejects a symlink to /etc'
        Assert-Throws { Get-SyncRemote $transport ($link+'/ssh') } '*Symlinked destinations*' 'Remote guard rejects symlinked parents'
        $notDirectory = $remoteRoot+'/plain-file'
        $null = Invoke-TestRemote ((Get-TestAssignment 'file' $notDirectory) + ': > "$file"')
        Assert-Throws { Get-SyncRemote $transport $notDirectory } '*not a directory*' 'Remote guard rejects regular files as destinations'
        Assert-Throws { Get-SyncRemote $transport ($remoteRoot+'/absent-parent/target') } '*parent must already exist*' 'Missing/unwritable parent fails clearly'

        # End-to-end CLI invocation uses a complete JSON file outside the repository.
        $settings.sourcePath = $source
        $settings.destinationPath = $destination
        $settings.deleteRemovedFiles = $false
        Write-TestText $configFile ($settings | ConvertTo-Json)
        $cli = Invoke-SyncNative (Join-Path $PSHOME 'powershell.exe') @('-NoProfile','-File',(Join-Path $PSScriptRoot 'sync.ps1'),'-ConfigPath',$configFile,'-NonInteractive','-DryRun') -TimeoutSeconds 120
        if ($cli.ExitCode -ne 0) { throw ('CLI dry run failed: '+$cli.Error) }
        Assert-Test ($cli.ExitCode -eq 0 -and $cli.Output.Contains('Dry run only')) 'PowerShell CLI reads config and completes a real SSH dry run'
        Write-TestText $configFile '{invalid'
        $cli = Invoke-SyncNative (Join-Path $PSHOME 'powershell.exe') @('-NoProfile','-File',(Join-Path $PSScriptRoot 'sync.ps1'),'-ConfigPath',$configFile,'-NonInteractive')
        Assert-Test ($cli.ExitCode -ne 0 -and $cli.Error.Contains('Cannot read JSON')) 'CLI returns failure for invalid configuration'
    }
}
catch { $failure = $_ }
finally {
    Set-Item Function:\Read-SyncAnswer $originalReader
    if ($remoteIdentity) {
        try {
            $cleanup = (Get-TestAssignment 'root' $remoteRoot) + (Get-TestAssignment 'expected' $remoteIdentity) + @'
set -eu
case "$root" in /tmp/wlfs-integration-*) ;; *) exit 70 ;; esac
test -d "$root" && test ! -L "$root"
test "$(realpath -e -- "$root")" = "$root"
test "$(stat -Lc '%d:%i' -- "$root")" = "$expected"
# find does not follow symlinks; -xdev prevents descent into another filesystem.
find "$root" -xdev -depth -delete
test ! -e "$root"
printf cleaned
'@
            $done = Invoke-TestRemote $cleanup
            if ($done -cne 'cleaned') { throw 'Remote cleanup response was not confirmed.' }
            $remaining = @((Invoke-TestRemote 'pgrep -x rsync || true') -split '[\r\n]+' | Where-Object {$_ -and $_ -notin $remoteProcessesBefore})
            if ($remaining.Count) { throw ('Unrecognized new rsync processes remain on Ubuntu: '+($remaining -join ', ')) }
            Write-Host "CLEANUP Ubuntu: removed owned test root $remoteRoot"
        }
        catch { $cleanupErrors.Add("Ubuntu: $remoteRoot - $($_.Exception.Message)") }
    }
    elseif ($Integration -and $null -ne $transport) {
        # If creation failed ambiguously, inspect, but never delete without ownership proof.
        try {
            $check = (Get-TestAssignment 'root' $remoteRoot) + 'if [ -e "$root" ] || [ -L "$root" ]; then printf uncertain; else printf absent; fi'
            if ((Invoke-TestRemote $check) -cne 'absent') { $cleanupErrors.Add("Ubuntu ownership uncertain; inspect manually: $remoteRoot") }
        }
        catch { $cleanupErrors.Add("Cannot confirm remote test-root absence: $remoteRoot") }
    }
    try {
        $fullRoot = [IO.Path]::GetFullPath($testRoot)
        $tempBase = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
        if (-not $fullRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($fullRoot) -notmatch '^wlfs-tests-[a-f0-9]{32}$') { throw 'Invalid cleanup root.' }
        if (Test-Path -LiteralPath $fullRoot) {
            if ((Get-Item -LiteralPath $fullRoot -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Test root became a reparse point.' }
            # Tests create no local reparse points. Refuse recursive cleanup if one appeared.
            $links = @(Get-ChildItem -LiteralPath $fullRoot -Force -Recurse | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
            if ($links.Count) { throw 'Unexpected reparse point in test directory.' }
            [IO.Directory]::Delete($fullRoot, $true)
        }
        if (Test-Path -LiteralPath $fullRoot) { throw 'Local test root still exists.' }
        Write-Host "CLEANUP Windows: removed owned test root $testRoot"
    }
    catch { $cleanupErrors.Add("Windows: $testRoot - $($_.Exception.Message)") }
    foreach ($path in $sshHashes.Keys) {
        try { if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $sshHashes[$path]) { $cleanupErrors.Add("SSH file changed unexpectedly: $path") } }
        catch { $cleanupErrors.Add("Could not verify SSH file: $path") }
    }
    if ($env:Path -cne $pathBefore -or [Environment]::GetEnvironmentVariable('Path','Machine') -cne $machinePathBefore -or
        [Environment]::GetEnvironmentVariable('Path','User') -cne $userPathBefore) { $cleanupErrors.Add('PATH changed unexpectedly.') }
    $ownedProcesses = @(Get-CimInstance Win32_Process -Filter "Name='rsync.exe' OR Name='ssh.exe'" | Where-Object {
        $_.CommandLine -and ($_.CommandLine.Contains($testRoot) -or $_.CommandLine.Contains($remoteRoot))
    })
    if ($ownedProcesses.Count) { $cleanupErrors.Add('Test processes remain; they were not stopped because ownership needs manual verification.') }
    foreach ($record in $script:SyncProcessLedger) {
        $live = Get-Process -Id $record.Id -ErrorAction SilentlyContinue
        if ($null -ne $live -and $live.StartTime -eq $record.Started) { $cleanupErrors.Add("A registered native child still exists: $($record.Id)") }
    }
}
Write-Host "Assertions passed: $script:Passed"
if ($cleanupErrors.Count) { throw ('Final environment cleanup/verification failed: '+($cleanupErrors -join '; ')) }
if ($null -ne $failure) { throw $failure }
Write-Host 'All requested tests passed; temporary resources were cleaned and SSH/PATH were preserved.'
