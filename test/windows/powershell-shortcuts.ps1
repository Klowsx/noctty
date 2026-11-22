param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path,
    [string]$IntegrationPath = ''
)

. (Join-Path $PSScriptRoot '..\..\scripts\windows-harness-history.ps1')
$windowsHarnessHistoryGuard = Start-WindowsHarnessHistoryGuard -Harness 'powershell-shortcuts.ps1'
try {

$ErrorActionPreference = 'Stop'
$script:AssertionCount = 0

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
    $script:AssertionCount++
}

function ConvertTo-PowerShellLiteralContent {
    param([string]$Value)
    $escaped = $Value.Replace("'", "''")
    foreach ($point in 0x2018..0x201B) {
        $quote = [string][char]$point
        $escaped = $escaped.Replace($quote, $quote + $quote)
    }
    return $escaped
}

$script:OriginalPrompt = $function:global:prompt
$script:OriginalShortcut = $function:global:shortcut
$script:OriginalCommandNotFound = $ExecutionContext.InvokeCommand.CommandNotFoundAction
$script:OriginalShortcutsPath = $env:NOCTTY_SHORTCUTS_PATH
$script:OriginalHistoryOptions = $null
$script:IntegrationPath = if ([string]::IsNullOrWhiteSpace($IntegrationPath)) {
    Join-Path $RepoRoot 'src\shell-integration\powershell\integration.ps1'
} else {
    (Resolve-Path -LiteralPath $IntegrationPath).Path
}
$script:TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("noctty-ps-shortcuts-" + [guid]::NewGuid().ToString('n'))

function Disable-ParentPSReadLineHistory {
    if ($null -eq $script:OriginalHistoryOptions) {
        $options = Get-PSReadLineOption
        $script:OriginalHistoryOptions = @{
            HistorySavePath = $options.HistorySavePath
            HistorySaveStyle = $options.HistorySaveStyle
        }
    }
    Set-PSReadLineOption -HistorySaveStyle SaveNothing
    Set-PSReadLineOption -HistorySavePath (Join-Path $script:TempDir 'parent-history.txt')
}

if (-not ('NocttyShortcutsChildOutput' -as [type])) {
    Add-Type -TypeDefinition @'
using System.IO;
using System.Text;
using System.Threading.Tasks;
public sealed class NocttyShortcutsChildOutput {
    private readonly StringBuilder text = new StringBuilder();
    public async Task DrainAsync(TextReader reader) {
        var buffer = new char[4096];
        int count;
        while ((count = await reader.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false)) != 0) {
            lock (text) { text.Append(buffer, 0, count); }
        }
    }
    public override string ToString() { lock (text) { return text.ToString(); } }
}
'@
}

try {
    New-Item -ItemType Directory -Force -Path $script:TempDir | Out-Null
    if (Get-Module PSReadLine) { Disable-ParentPSReadLineHistory }

    $psHost = (Get-Process -Id $PID).Path
    Assert-True (-not [string]::IsNullOrEmpty($psHost)) "Could not resolve the current PowerShell host path"
    $script:PsHost = $psHost

    function New-InjectedChildStartInfo {
        param(
            [Parameter(Mandatory)][string]$CaseName,
            [string]$Preamble = '',
            [string]$Postamble = '',
            [string]$WorkingDirectory = $script:TempDir,
            [string]$ShortcutsPath = '',
            [switch]$WithoutPSReadLine
        )
        $prefix = if ($WithoutPSReadLine) {
            'Remove-Module PSReadLine -Force -ErrorAction Ignore; '
        } else { '' }
        $childQuotedPath = ConvertTo-PowerShellLiteralContent $script:IntegrationPath
        $historyPath = ConvertTo-PowerShellLiteralContent (Join-Path $script:TempDir 'child-history.txt')
        $historyPrefix = "if (Get-Module PSReadLine) { Set-PSReadLineOption -HistorySaveStyle SaveNothing; Set-PSReadLineOption -HistorySavePath '$historyPath'; if ((Get-PSReadLineOption).HistorySaveStyle -ne 'SaveNothing' -or (Get-PSReadLineOption).HistorySavePath -ne '$historyPath') { throw 'Child history isolation failed' } }; [Console]::WriteLine('HISTORY' + '-ISOLATED'); "
        $payload = '[Console]::InputEncoding = [Text.UTF8Encoding]::new($false); ' + $historyPrefix + $prefix + $Preamble +
            "function global:prompt { 'NOCTTYPROBE> ' }; " +
            "& { `$__ghostty_utf8_console = `$false; . '$childQuotedPath' }; " +
            $Postamble

        $payloadErrors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($payload, [ref]$null, [ref]$payloadErrors)
        if ($payloadErrors.Count) {
            throw "Injected fixture ($CaseName) did not parse: $($payloadErrors[0].Message)"
        }

        $quotedPayload = [regex]::Replace($payload, '(\\*)"', '${1}${1}\"')
        $quotedPayload = [regex]::Replace($quotedPayload, '(\\+)$', '${1}${1}')
        $info = [System.Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $script:PsHost
        $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -NoExit -Command "' + $quotedPayload + '"'
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.WorkingDirectory = $WorkingDirectory
        if (-not [string]::IsNullOrEmpty($ShortcutsPath)) {
            $info.EnvironmentVariables['NOCTTY_SHORTCUTS_PATH'] = $ShortcutsPath
        }
        return $info
    }

    function Invoke-ShortcutsInjectedChild {
        param(
            [Parameter(Mandatory)][string]$CaseName,
            [string]$Preamble = '',
            [string]$Postamble = '',
            [string[]]$Lines = @('exit'),
            [string]$WorkingDirectory = $script:TempDir,
            [string]$ShortcutsPath = '',
            [switch]$WithoutPSReadLine,
            [ValidateRange(1, 30000)][int]$TimeoutMs = 30000
        )

        $info = New-InjectedChildStartInfo -CaseName $CaseName -Preamble $Preamble -Postamble $Postamble `
            -WorkingDirectory $WorkingDirectory -ShortcutsPath $ShortcutsPath -WithoutPSReadLine:$WithoutPSReadLine

        $parentInputEncoding = [Console]::InputEncoding
        try {
            [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
            $process = [System.Diagnostics.Process]::Start($info)
        } finally {
            [Console]::InputEncoding = $parentInputEncoding
        }

        try {
            $stderr = [NocttyShortcutsChildOutput]::new()
            $stderrTask = $stderr.DrainAsync($process.StandardError)
            $startupOutput = [Text.StringBuilder]::new()
            $startupDeadline = [DateTime]::UtcNow.AddSeconds(30)
            while ($true) {
                $ready = $process.StandardOutput.ReadLineAsync()
                $remainingMs = [Math]::Max(0, [int]($startupDeadline - [DateTime]::UtcNow).TotalMilliseconds)
                if (-not $ready.Wait($remainingMs) -or $null -eq $ready.Result) {
                    if (-not $process.HasExited) { $process.Kill() }
                    throw "Child did not confirm history isolation before input (case=$CaseName, startupChars=$($startupOutput.Length))"
                }
                [void]$startupOutput.AppendLine($ready.Result)
                $readyText = $ready.Result -replace '\x1B\[[0-?]*[ -/]*[@-~]', ''
                if ($readyText -eq 'HISTORY-ISOLATED') { break }
            }
            $stdout = [NocttyShortcutsChildOutput]::new()
            $stdoutTask = $stdout.DrainAsync($process.StandardOutput)
            foreach ($line in $Lines) { $process.StandardInput.WriteLine($line) }
            $process.StandardInput.Close()
            if (-not $process.WaitForExit($TimeoutMs)) {
                if (-not $process.HasExited) { $process.Kill() }
                [void]$process.WaitForExit(5000)
                throw "Injected PowerShell child timed out (case=$CaseName): $($startupOutput.ToString() + $stdout.ToString() + $stderr.ToString())"
            }
            [void]$stdoutTask.GetAwaiter().GetResult()
            [void]$stderrTask.GetAwaiter().GetResult()
            return [pscustomobject]@{
                ExitCode = $process.ExitCode
                Stdout = $startupOutput.ToString() + $stdout.ToString()
                Stderr = $stderr.ToString()
                Combined = $startupOutput.ToString() + $stdout.ToString() + $stderr.ToString()
            }
        } finally {
            $process.Dispose()
        }
    }

    # Test fixtures: isolated shortcuts store + repos + outside dir
    $storeInProc = Join-Path $script:TempDir 'store-inproc\shortcuts.json'
    $outsideDir = Join-Path $script:TempDir 'outside'
    $repoA = Join-Path $script:TempDir 'repoA'
    $repoASub = Join-Path $repoA 'src\app'
    $repoAGit = Join-Path $repoA '.git'
    $repoAGitObj = Join-Path $repoAGit 'objects'
    $repoB = Join-Path $script:TempDir 'repoB'
    $repoBGit = Join-Path $repoB '.git'
    $worktreeRepo = Join-Path $script:TempDir 'worktreeRepo'
    $worktreeSub = Join-Path $worktreeRepo 'nested'
    $worktreeGitFile = Join-Path $worktreeRepo '.git'

    foreach ($d in @($outsideDir, $repoASub, $repoAGitObj, $repoBGit, $worktreeSub)) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
    }
    [System.IO.File]::WriteAllText($worktreeGitFile, "gitdir: ../repoA/.git/worktrees/wt1`n", [System.Text.UTF8Encoding]::new($false))

    # ── Case 1: Zero startup I/O & clean startup under StrictMode/Stop/Confirm/WhatIf ──
    $startupStore = Join-Path $script:TempDir 'startup-io\shortcuts.json'
    $c1 = Invoke-ShortcutsInjectedChild -CaseName 'zero-startup-io' -WithoutPSReadLine -ShortcutsPath $startupStore `
        -Preamble 'Set-StrictMode -Version Latest; $ErrorActionPreference = ''Stop''; $ConfirmPreference = ''Low''; $WhatIfPreference = $true; ' `
        -Lines @(
            '$existsAfterLoad = Test-Path -LiteralPath $env:NOCTTY_SHORTCUTS_PATH',
            '"EXISTS=$existsAfterLoad;ERRCOUNT=$($Error.Count)"',
            'if (Get-Command shortcut -CommandType Function -ErrorAction SilentlyContinue) { "SC" + "-PRESENT" }',
            'if ($null -ne $ExecutionContext.InvokeCommand.CommandNotFoundAction) { "HOOK" + "-PRESENT" }',
            'exit'
        )
    Assert-True (-not (Test-Path -LiteralPath $startupStore)) "Case 1: startup must not create shortcuts.json"
    Assert-True ($c1.Combined.Contains('EXISTS=False;ERRCOUNT=0')) "Case 1: expected EXISTS=False;ERRCOUNT=0, got: $($c1.Combined)"
    Assert-True ($c1.Combined.Contains('SC-PRESENT')) "Case 1: shortcut CLI missing under StrictMode/Confirm/WhatIf"
    Assert-True ($c1.Combined.Contains('HOOK-PRESENT')) "Case 1: CommandNotFoundAction missing under StrictMode/Confirm/WhatIf"

    # ── Case 12: User-owned shortcut function/alias politeness (child scope) ──
    $c12fn = Invoke-ShortcutsInjectedChild -CaseName 'user-owned-fn' -WithoutPSReadLine -ShortcutsPath $startupStore `
        -Preamble "function global:shortcut { 'user-owned-fn' }; " `
        -Lines @(
            '"VAL=" + (shortcut)',
            'exit'
        )
    Assert-True ($c12fn.Combined.Contains('noctty PowerShell shortcut CLI skipped: a profile function or alias owns shortcut.')) "Case 12 (fn): expected warning, got: $($c12fn.Combined)"
    Assert-True ($c12fn.Combined.Contains('VAL=user-owned-fn')) "Case 12 (fn): user function overwritten: $($c12fn.Combined)"

    $c12alias = Invoke-ShortcutsInjectedChild -CaseName 'user-owned-alias' -WithoutPSReadLine -ShortcutsPath $startupStore `
        -Preamble "function global:__user_sc_target { 'user-owned-alias' }; Set-Alias -Name shortcut -Value __user_sc_target -Scope Global; " `
        -Lines @(
            '"VAL=" + (shortcut)',
            'exit'
        )
    Assert-True ($c12alias.Combined.Contains('noctty PowerShell shortcut CLI skipped: a profile function or alias owns shortcut.')) "Case 12 (alias): expected warning, got: $($c12alias.Combined)"
    Assert-True ($c12alias.Combined.Contains('VAL=user-owned-alias')) "Case 12 (alias): user alias overwritten: $($c12alias.Combined)"

    # ── Case 2 (child): Global CRUD + immediate same-prompt effect ──
    $crudStore = Join-Path $script:TempDir 'crud\shortcuts.json'
    $c2 = Invoke-ShortcutsInjectedChild -CaseName 'global-crud' -WithoutPSReadLine -WorkingDirectory $outsideDir -ShortcutsPath $crudStore `
        -Lines @(
            'shortcut add dev4 "Write-Output ''port=3004''"',
            '"OUT1=" + (dev4)',
            '"LIST1=" + ((shortcut list) -join ";")',
            'shortcut add dev4 "Write-Output ''port=4004''"',
            '"OUT2=" + (dev4)',
            'shortcut remove dev4',
            '"LIST2=" + ((shortcut list) -join ";")',
            'try { $null = dev4; "STILL" + "-FOUND" } catch { "GONE" + "-OK" }',
            'exit'
        )
    Assert-True ($c2.Stdout.Contains('OUT1=port=3004')) "Case 2: immediate invocation failed: $($c2.Combined)"
    Assert-True ($c2.Stdout.Contains("LIST1=dev4 -> Write-Output 'port=3004'")) "Case 2: list failed: $($c2.Combined)"
    Assert-True ($c2.Stdout.Contains('OUT2=port=4004')) "Case 2: updated invocation failed: $($c2.Combined)"
    Assert-True ($c2.Stdout.Contains('LIST2=No global shortcuts.')) "Case 2: list after remove failed: $($c2.Combined)"
    Assert-True ($c2.Stdout.Contains('GONE-OK')) "Case 2: removed shortcut still resolved: $($c2.Combined)"

    # ── Case 3: Persistence across shell restart (child #1 -> child #2) ──
    $persistStore = Join-Path $script:TempDir 'persist\shortcuts.json'
    $c3a = Invoke-ShortcutsInjectedChild -CaseName 'persist-write' -WithoutPSReadLine -WorkingDirectory $repoA -ShortcutsPath $persistStore `
        -Lines @(
            'shortcut add gpers "Write-Output ''global-persisted''"',
            'shortcut add --project ppers "Write-Output ''project-persisted''"',
            'exit'
        )
    Assert-True (Test-Path -LiteralPath $persistStore) "Case 3: shortcuts.json was not created on disk"
    Assert-True ($c3a.Combined.Contains("Saved global shortcut 'gpers'")) "Case 3: global save message missing: $($c3a.Combined)"
    Assert-True ($c3a.Combined.Contains("Saved project shortcut 'ppers'")) "Case 3: project save message missing: $($c3a.Combined)"

    $c3b = Invoke-ShortcutsInjectedChild -CaseName 'persist-read' -WithoutPSReadLine -WorkingDirectory $repoA -ShortcutsPath $persistStore `
        -Lines @(
            'gpers',
            'ppers',
            'exit'
        )
    Assert-True ($c3b.Stdout.Contains('global-persisted')) "Case 3: global shortcut did not persist across restart: $($c3b.Combined)"
    Assert-True ($c3b.Stdout.Contains('project-persisted')) "Case 3: project shortcut did not persist across restart: $($c3b.Combined)"

    # ── Cases 4 & 5 (child): Git repo root, subdirs, .git file, .git dir, project priority & dynamic cd ──
    $projStore = Join-Path $script:TempDir 'proj\shortcuts.json'
    $qOutside = ConvertTo-PowerShellLiteralContent $outsideDir
    $qRepoA = ConvertTo-PowerShellLiteralContent $repoA
    $qRepoASub = ConvertTo-PowerShellLiteralContent $repoASub
    $qRepoAGit = ConvertTo-PowerShellLiteralContent $repoAGit
    $qRepoAGitObj = ConvertTo-PowerShellLiteralContent $repoAGitObj
    $qRepoB = ConvertTo-PowerShellLiteralContent $repoB
    $qWtRoot = ConvertTo-PowerShellLiteralContent $worktreeRepo
    $qWtSub = ConvertTo-PowerShellLiteralContent $worktreeSub
    $c45 = Invoke-ShortcutsInjectedChild -CaseName 'git-root-and-cd-switching' -WithoutPSReadLine -WorkingDirectory $outsideDir -ShortcutsPath $projStore `
        -Lines @(
            'shortcut add --project dev "Write-Output ''nope''" 2>&1 | ForEach-Object { "OUTSIDE_ADD=$_" }',
            'shortcut list --project 2>&1 | ForEach-Object { "OUTSIDE_LIST=$_" }',
            'shortcut remove --project dev 2>&1 | ForEach-Object { "OUTSIDE_RM=$_" }',
            '"STORE_EXISTS=" + (Test-Path -LiteralPath $env:NOCTTY_SHORTCUTS_PATH)',
            "Set-Location '$qRepoASub'",
            'shortcut add --project dev "Write-Output ''port=3004''"',
            '"SUB_A=" + (dev)',
            '"SUB_LIST=" + ((shortcut list --project) -join ";")',
            "Set-Location '$qRepoA'",
            '"ROOT_A=" + (dev)',
            "Set-Location '$qRepoAGit'",
            'shortcut list --project 2>&1 | ForEach-Object { "GITDIR_LIST=$_" }',
            'try { $null = dev; "GITDIR_DEV=FOUND" } catch { "GITDIR_DEV=MISSED" }',
            "Set-Location '$qRepoAGitObj'",
            'try { $null = dev; "GITOBJ_DEV=FOUND" } catch { "GITOBJ_DEV=MISSED" }',
            "Set-Location '$qWtSub'",
            'shortcut add --project wtcmd "Write-Output ''wt-ok''"',
            '"WT_SUB=" + (wtcmd)',
            "Set-Location '$qWtRoot'",
            '"WT_ROOT=" + (wtcmd)',
            'shortcut remove --project wtcmd',
            'shortcut add dev "Write-Output ''port=3000''"',
            "Set-Location '$qRepoB'",
            'shortcut add --project dev "Write-Output ''port=3005''"',
            "Set-Location '$qRepoA'",
            '"SW_1=" + (dev)',
            "Set-Location '$qRepoASub'",
            '"SW_2=" + (dev)',
            "Set-Location '$qRepoB'",
            '"SW_3=" + (dev)',
            "Set-Location '$qOutside'",
            '"SW_4=" + (dev)',
            "Set-Location '$qRepoA'",
            '"SW_5=" + (dev)',
            'exit'
        )
    Assert-True ($c45.Stdout.Contains('OUTSIDE_ADD=') -and $c45.Stdout.Contains('Not inside a Git repository')) "Case 4: add --project outside repo failed: $($c45.Combined)"
    Assert-True ($c45.Stdout.Contains('OUTSIDE_LIST=')) "Case 4: list --project outside repo failed: $($c45.Combined)"
    Assert-True ($c45.Stdout.Contains('OUTSIDE_RM=')) "Case 4: remove --project outside repo failed: $($c45.Combined)"
    Assert-True ($c45.Stdout.Contains('STORE_EXISTS=False')) "Case 4: failed --project outside repo created shortcuts.json: $($c45.Combined)"
    Assert-True ($c45.Stdout.Contains('SUB_A=port=3004')) "Case 4: subdir project shortcut failed: $($c45.Combined)"
    Assert-True ($c45.Stdout.Contains("SUB_LIST=dev -> Write-Output 'port=3004'")) "Case 4: subdir list --project failed: $($c45.Combined)"
    Assert-True ($c45.Stdout.Contains('ROOT_A=port=3004')) "Case 4: root project shortcut failed: $($c45.Combined)"
    Assert-True ($c45.Stdout.Contains('GITDIR_LIST=') -and $c45.Stdout.Contains('GITDIR_DEV=MISSED')) "Case 4: .git dir treated as working tree: $($c45.Combined)"
    Assert-True ($c45.Stdout.Contains('GITOBJ_DEV=MISSED')) "Case 4: .git\objects treated as working tree: $($c45.Combined)"
    Assert-True ($c45.Stdout.Contains('WT_SUB=wt-ok') -and $c45.Stdout.Contains('WT_ROOT=wt-ok')) "Case 4: .git file worktree failed: $($c45.Combined)"
    Assert-True ($c45.Stdout.Contains('SW_1=port=3004')) "Case 5: RepoA root switch failed: $($c45.Combined)"
    Assert-True ($c45.Stdout.Contains('SW_2=port=3004')) "Case 5: RepoA subdir switch failed: $($c45.Combined)"
    Assert-True ($c45.Stdout.Contains('SW_3=port=3005')) "Case 5: RepoB switch failed: $($c45.Combined)"
    Assert-True ($c45.Stdout.Contains('SW_4=port=3000')) "Case 5: outside global fallback failed: $($c45.Combined)"
    Assert-True ($c45.Stdout.Contains('SW_5=port=3004')) "Case 5: return to RepoA failed: $($c45.Combined)"

    # ── Cases 6, 7, 8 (--force), 10, 11, 13 in real Runspace child ──
    $execStore = Join-Path $script:TempDir 'exec\shortcuts.json'
    $cExec = Invoke-ShortcutsInjectedChild -CaseName 'exec-args-coll-rec-exit' -WithoutPSReadLine -WorkingDirectory $repoA -ShortcutsPath $execStore `
        -Preamble '$Global:__test_unmatched = [System.Collections.Generic.List[string]]::new(); $ExecutionContext.InvokeCommand.CommandNotFoundAction = { param($s,$e) $Global:__test_unmatched.Add($e.CommandName) }; ' `
        -Lines @(
            # Case 11: idempotent re-source + chaining
            "& { `$__ghostty_utf8_console = `$false; . '$($script:IntegrationPath.Replace("'", "''"))' }",
            "& { `$__ghostty_utf8_console = `$false; . '$($script:IntegrationPath.Replace("'", "''"))' }",
            '$Global:__test_unmatched.Clear()',
            'try { no_such_cmd_chain_test } catch {}',
            '$exactChain = @($Global:__test_unmatched | Where-Object { $_ -eq ''no_such_cmd_chain_test'' })',
            '"CHAIN_COUNT=$($exactChain.Count);TOTAL=$($Global:__test_unmatched.Count)"',
            # Case 6: quotes, typographic quotes, pipeline, Set-Location, env var
            'shortcut add qdouble ''Write-Output "hello ''''world''''"''',
            '"QDOUBLE=" + (qdouble)',
            '$tl = [string][char]0x2018; $tr = [string][char]0x2019; shortcut add qtypo ("Write-Output `"a" + $tl + "b" + $tr + "c`"")',
            '"QTYPO_OK=" + ((qtypo) -ceq ("a" + [char]0x2018 + "b" + [char]0x2019 + "c"))',
            'shortcut add ptest ''Write-Output "a","b","c" | Measure-Object | ForEach-Object Count''',
            '"PTEST=" + (ptest)',
            "shortcut add cdsub `"Set-Location '$qRepoASub'`"",
            'cdsub',
            '"AFTER_CD=" + ($PWD.ProviderPath)',
            'shortcut add setenv ''$env:NOCTTY_TEST_SC = "ok"''',
            'setenv',
            '"AFTER_ENV=" + ($env:NOCTTY_TEST_SC)',
            # Case 7: extra argument forwarding + compound fallback
            'function global:__noctty_arg_echo { "COUNT=$($args.Count);ARGS=$($args -join ''|'')" }',
            'shortcut add echoargs ''__noctty_arg_echo''',
            '"ARG_FWD=" + (echoargs --host "my host" -Command foo)',
            'shortcut add echocompound ''(__noctty_arg_echo $args[0] $args[1])''',
            '"ARG_COMP=" + (echocompound "first arg" "-Command")',
            # Case 8 (--force): native Get-Date still resolves first
            'shortcut add --force Get-Date "Write-Output ''forced-date''" 3>&1 | ForEach-Object { "FORCE_WARN=$_" }',
            '"DATE_IS_DT=" + ((Get-Date) -is [datetime])',
            # Case 10: recursion limit guard
            'shortcut add selfrec ''selfrec''',
            'try { selfrec } catch { "SELF_REC=" + $_.Exception.Message }',
            'shortcut add recA ''recB''',
            'shortcut add recB ''recA''',
            'try { recA } catch { "MUTUAL_REC=" + $_.Exception.Message }',
            '"DEPTH_AFTER=" + $Global:__ghostty_shortcut_depth',
            '"AFTER_REC_OK=" + (ptest)',
            # Bug A regression: failed lookup inside try/catch must not stick __ghostty_shortcut_in_lookup
            'try { no_such_cmd_bug_a } catch {}',
            '"BUG_A_AFTER=" + (ptest)',
            # Case 13: exit status & error propagation (real PowerShell CommandNotFoundAction semantics)
            'shortcut add failnative ''cmd.exe /d /c exit 7''',
            '$Global:__ghostty_prev_exitcode = 0',
            'failnative; $nCode = $LASTEXITCODE; $nOscD = __ghostty_exit_code $true',
            '"NATIVE_EXIT=$nCode;NATIVE_OSC_D=$nOscD"',
            'shortcut add failps "Write-Error ''boom'' -ErrorAction Continue"',
            '$errBefore = $Error.Count',
            'failps 2>$null',
            '$errAfter = $Error.Count',
            '"PS_ERR_ADDED=$($errAfter -gt $errBefore);PS_ERR_MSG=$($Error[0].Exception.Message)"',
            'shortcut add failthrow "throw ''hard-fail''"',
            'failthrow; "THROW_REACHED=" + "True"',
            '"THROW_OK=$?;THROW_ERR=$($Error[0].Exception.Message)"',
            'shortcut add okcmd "Write-Output ''ok''"',
            '$null = okcmd; $oOk = $?',
            '"OK_STATUS=$oOk"',
            'exit'
        )
    Assert-True ($cExec.Stdout.Contains('CHAIN_COUNT=1;')) "Case 11: chaining/idempotent re-source failed: $($cExec.Combined)"
    Assert-True ($cExec.Stdout.Contains("QDOUBLE=hello 'world'")) "Case 6: double/single quotes failed: $($cExec.Combined)"
    Assert-True ($cExec.Stdout.Contains('QTYPO_OK=True')) "Case 6: typographic quotes failed: $($cExec.Combined)"
    Assert-True ($cExec.Stdout.Contains('PTEST=3')) "Case 6: pipeline shortcut failed: $($cExec.Combined)"
    Assert-True ($cExec.Stdout.Contains("AFTER_CD=$repoASub")) "Case 6: Set-Location shortcut failed: $($cExec.Combined)"
    Assert-True ($cExec.Stdout.Contains('AFTER_ENV=ok')) "Case 6: env var mutation failed: $($cExec.Combined)"
    Assert-True ($cExec.Stdout.Contains('ARG_FWD=COUNT=4;ARGS=--host|my host|-Command|foo')) "Case 7: arg forwarding failed: $($cExec.Combined)"
    Assert-True ($cExec.Stdout.Contains('ARG_COMP=COUNT=2;ARGS=first arg|-Command')) "Case 7: compound fallback failed: $($cExec.Combined)"
    Assert-True ($cExec.Stdout.Contains('FORCE_WARN=') -and $cExec.Stdout.Contains('collides with existing')) "Case 8: --force warning missing: $($cExec.Combined)"
    Assert-True ($cExec.Stdout.Contains('DATE_IS_DT=True')) "Case 8: native Get-Date did not win: $($cExec.Combined)"
    Assert-True ($cExec.Stdout.Contains('SELF_REC=noctty shortcut recursion limit (8) exceeded')) "Case 10: self-recursion failed: $($cExec.Combined)"
    Assert-True ($cExec.Stdout.Contains('MUTUAL_REC=noctty shortcut recursion limit (8) exceeded')) "Case 10: mutual recursion failed: $($cExec.Combined)"
    Assert-True ($cExec.Stdout.Contains('DEPTH_AFTER=0') -and $cExec.Stdout.Contains('AFTER_REC_OK=3')) "Case 10: depth reset / recovery failed: $($cExec.Combined)"
    Assert-True ($cExec.Stdout.Contains('BUG_A_AFTER=3')) "Bug A regression: shortcut lookup got stuck after failed try/catch lookup: $($cExec.Combined)"
    Assert-True ($cExec.Stdout.Contains('NATIVE_EXIT=7;NATIVE_OSC_D=7')) "Case 13: native exit status failed: $($cExec.Combined)"
    Assert-True ($cExec.Stdout.Contains('PS_ERR_ADDED=True;PS_ERR_MSG=boom')) "Case 13: PowerShell Write-Error `$Error recording failed: $($cExec.Combined)"
    Assert-True (-not $cExec.Stdout.Contains('THROW_REACHED=True')) "Case 13: terminating throw did not halt pipeline: $($cExec.Combined)"
    Assert-True ($cExec.Stdout.Contains('THROW_OK=False;THROW_ERR=hard-fail')) "Case 13: terminating throw `$? / `$Error failed: $($cExec.Combined)"
    Assert-True ($cExec.Stdout.Contains('OK_STATUS=True')) "Case 13: succeeding shortcut `$? failed: $($cExec.Combined)"

    # ── Case 9: Multi-session cache freshness (mtime/length) ──
    $freshStore = Join-Path $script:TempDir 'fresh\shortcuts.json'
    $c9Seed = Invoke-ShortcutsInjectedChild -CaseName 'cache-seed' -WithoutPSReadLine -ShortcutsPath $freshStore `
        -Lines @(
            'shortcut add fresh "Write-Output ''v1''"',
            'exit'
        )
    Assert-True ($c9Seed.Combined.Contains("Saved global shortcut 'fresh'")) "Case 9: seed failed: $($c9Seed.Combined)"

    $readyFile = Join-Path $script:TempDir 'c9-ready.flag'
    $goFile = Join-Path $script:TempDir 'c9-go.flag'
    $qReady = ConvertTo-PowerShellLiteralContent $readyFile
    $qGo = ConvertTo-PowerShellLiteralContent $goFile
    $c9Info = New-InjectedChildStartInfo -CaseName 'cache-reader' -WithoutPSReadLine -ShortcutsPath $freshStore
    $parentInputEncoding = [Console]::InputEncoding
    try {
        [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
        $c9Proc = [System.Diagnostics.Process]::Start($c9Info)
    } finally {
        [Console]::InputEncoding = $parentInputEncoding
    }
    try {
        $c9Err = [NocttyShortcutsChildOutput]::new()
        $c9ErrTask = $c9Err.DrainAsync($c9Proc.StandardError)
        $startupDeadline = [DateTime]::UtcNow.AddSeconds(30)
        while ($true) {
            $ready = $c9Proc.StandardOutput.ReadLineAsync()
            $remainingMs = [Math]::Max(0, [int]($startupDeadline - [DateTime]::UtcNow).TotalMilliseconds)
            if (-not $ready.Wait($remainingMs) -or $null -eq $ready.Result) {
                if (-not $c9Proc.HasExited) { $c9Proc.Kill() }
                throw "Case 9 reader child did not confirm history isolation"
            }
            $readyText = $ready.Result -replace '\x1B\[[0-?]*[ -/]*[@-~]', ''
            if ($readyText -eq 'HISTORY-ISOLATED') { break }
        }
        $c9Out = [NocttyShortcutsChildOutput]::new()
        $c9OutTask = $c9Out.DrainAsync($c9Proc.StandardOutput)
        $c9Proc.StandardInput.WriteLine('"BEFORE=" + (fresh)')
        $c9Proc.StandardInput.WriteLine("New-Item -ItemType File -Path '$qReady' -Force | Out-Null; while (-not (Test-Path -LiteralPath '$qGo')) { Start-Sleep -Milliseconds 25 }")
        $c9Proc.StandardInput.WriteLine('"AFTER=" + (fresh)')
        $c9Proc.StandardInput.WriteLine('exit')
        $c9Proc.StandardInput.Close()

        $waitDeadline = [DateTime]::UtcNow.AddSeconds(20)
        while (-not (Test-Path -LiteralPath $readyFile)) {
            if ($c9Proc.HasExited -or [DateTime]::UtcNow -ge $waitDeadline) {
                throw "Case 9 reader child did not reach ready gate: $($c9Out.ToString() + $c9Err.ToString())"
            }
            Start-Sleep -Milliseconds 25
        }

        $c9Writer = Invoke-ShortcutsInjectedChild -CaseName 'cache-writer' -WithoutPSReadLine -ShortcutsPath $freshStore `
            -Lines @(
                'shortcut add fresh "Write-Output ''v2-updated''"',
                'exit'
            )
        Assert-True ($c9Writer.Combined.Contains("Saved global shortcut 'fresh'")) "Case 9: writer failed: $($c9Writer.Combined)"
        New-Item -ItemType File -Path $goFile -Force | Out-Null

        if (-not $c9Proc.WaitForExit(20000)) {
            if (-not $c9Proc.HasExited) { $c9Proc.Kill() }
            throw "Case 9 reader child timed out: $($c9Out.ToString() + $c9Err.ToString())"
        }
        [void]$c9OutTask.GetAwaiter().GetResult()
        [void]$c9ErrTask.GetAwaiter().GetResult()
        $c9Combined = $c9Out.ToString() + $c9Err.ToString()
        Assert-True ($c9Combined.Contains('BEFORE=v1')) "Case 9: initial value mismatch: $c9Combined"
        Assert-True ($c9Combined.Contains('AFTER=v2-updated')) "Case 9: cache did not refresh on mtime/length change: $c9Combined"
    } finally {
        $c9Proc.Dispose()
    }

    # ── In-process checks: CLI validation, collision rejections, and Internal CommandOrigin safety ──
    $env:NOCTTY_SHORTCUTS_PATH = $storeInProc
    function global:prompt { 'NOCTTYPROBE> ' }
    & {
        $__ghostty_utf8_console = $false
        . $script:IntegrationPath
    }

    $helpOut = (shortcut --help) -join "`n"
    Assert-True ($helpOut.Contains('shortcut add')) "In-proc: shortcut --help missing usage"

    $null = shortcut add inproc_sc "Write-Output 'from-inproc'"
    Assert-True (((shortcut list) -join "`n").Contains("inproc_sc -> Write-Output 'from-inproc'")) "In-proc: shortcut list missing inproc_sc"

    # Negative control: CommandOrigin.Internal (inside a script file) must NOT resolve shortcuts
    $internalMissed = $false
    try {
        $null = inproc_sc
    } catch {
        $internalMissed = $true
    }
    Assert-True $internalMissed "In-proc: shortcut must not hijack CommandOrigin.Internal script calls"

    # Case 8: Collision & invalid name rejections in-process
    function global:__noctty_test_user_fn { 'from-fn' }
    Set-Alias -Name __noctty_test_user_alias -Value __noctty_test_user_fn -Scope Global
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        foreach ($coll in @('Get-Date', '__noctty_test_user_fn', '__noctty_test_user_alias', 'cmd.exe')) {
            $errOut = $null
            $null = shortcut add $coll "Write-Output 'shadowed'" 2>&1 | Tee-Object -Variable errOut | Out-Null
            Assert-True ("$errOut".Contains('already occupied')) "Case 8: collision '$coll' was not rejected: $errOut"
        }

        foreach ($badName in @('shortcut', '', '   ', 'dev*', 'd?v', 'a/b', 'a\b', 'a;b', 'a|b')) {
            $errOut = $null
            $null = shortcut add $badName "Write-Output 'bad'" 2>&1 | Tee-Object -Variable errOut | Out-Null
            Assert-True ("$errOut".Contains('Invalid shortcut name')) "Case 8: invalid name '$badName' was not rejected: $errOut"
        }

        $rmMissingErr = $null
        $null = shortcut remove does_not_exist 2>&1 | Tee-Object -Variable rmMissingErr | Out-Null
        Assert-True ("$rmMissingErr".Contains('not found in global shortcuts')) "In-proc: remove missing should error: $rmMissingErr"
    } finally {
        $ErrorActionPreference = $prevEap
        Remove-Item -LiteralPath 'Function:\__noctty_test_user_fn' -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath 'Alias:\__noctty_test_user_alias' -Force -ErrorAction SilentlyContinue
    }

    # ── Finding 2 regressions: Concurrent store transactions, locks, and corrupt JSON ──
    function Invoke-BarrierPair {
        param(
            [Parameter(Mandatory)][string]$CaseName,
            [Parameter(Mandatory)][string]$StorePath,
            [Parameter(Mandatory)][string]$DirA,
            [Parameter(Mandatory)][string]$DirB,
            [Parameter(Mandatory)][string[]]$CommandsA,
            [Parameter(Mandatory)][string[]]$CommandsB,
            [int]$Rounds = 1
        )
        $readyAName = 'Local\noctty-sc-readyA-' + [guid]::NewGuid().ToString('n')
        $readyBName = 'Local\noctty-sc-readyB-' + [guid]::NewGuid().ToString('n')
        $goNames = @(for ($r = 0; $r -lt $Rounds; $r++) { 'Local\noctty-sc-go-' + $r + '-' + [guid]::NewGuid().ToString('n') })

        $readyA = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::AutoReset, $readyAName)
        $readyB = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::AutoReset, $readyBName)
        $goEvents = @(foreach ($gn in $goNames) { [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::ManualReset, $gn) })

        try {
            $infoA = New-InjectedChildStartInfo -CaseName ($CaseName + '-A') -WithoutPSReadLine -WorkingDirectory $DirA -ShortcutsPath $StorePath
            $infoB = New-InjectedChildStartInfo -CaseName ($CaseName + '-B') -WithoutPSReadLine -WorkingDirectory $DirB -ShortcutsPath $StorePath

            $parentInputEncoding = [Console]::InputEncoding
            try {
                [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
                $procA = [System.Diagnostics.Process]::Start($infoA)
                $procB = [System.Diagnostics.Process]::Start($infoB)
            } finally {
                [Console]::InputEncoding = $parentInputEncoding
            }

            try {
                $errA = [NocttyShortcutsChildOutput]::new()
                $errB = [NocttyShortcutsChildOutput]::new()
                $errATask = $errA.DrainAsync($procA.StandardError)
                $errBTask = $errB.DrainAsync($procB.StandardError)

                foreach ($pair in @(@($procA, 'A'), @($procB, 'B'))) {
                    $p = $pair[0]
                    $tag = $pair[1]
                    $deadline = [DateTime]::UtcNow.AddSeconds(30)
                    while ($true) {
                        $lineTask = $p.StandardOutput.ReadLineAsync()
                        $rem = [Math]::Max(0, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
                        if (-not $lineTask.Wait($rem) -or $null -eq $lineTask.Result) {
                            if (-not $p.HasExited) { $p.Kill() }
                            throw "$CaseName child $tag did not confirm history isolation"
                        }
                        $txt = $lineTask.Result -replace '\x1B\[[0-?]*[ -/]*[@-~]', ''
                        if ($txt -eq 'HISTORY-ISOLATED') { break }
                    }
                }

                $outA = [NocttyShortcutsChildOutput]::new()
                $outB = [NocttyShortcutsChildOutput]::new()
                $outATask = $outA.DrainAsync($procA.StandardOutput)
                $outBTask = $outB.DrainAsync($procB.StandardOutput)

                $qReadyA = ConvertTo-PowerShellLiteralContent $readyAName
                $qReadyB = ConvertTo-PowerShellLiteralContent $readyBName
                $procA.StandardInput.WriteLine("`$__ra = [System.Threading.EventWaitHandle]::OpenExisting('$qReadyA')")
                $procB.StandardInput.WriteLine("`$__rb = [System.Threading.EventWaitHandle]::OpenExisting('$qReadyB')")

                for ($r = 0; $r -lt $Rounds; $r++) {
                    $qGo = ConvertTo-PowerShellLiteralContent $goNames[$r]
                    $procA.StandardInput.WriteLine("`$__go$r = [System.Threading.EventWaitHandle]::OpenExisting('$qGo'); [void]`$__ra.Set(); if (-not `$__go$r.WaitOne(20000)) { throw 'go timeout A' }; `$__go$r.Dispose()")
                    $procB.StandardInput.WriteLine("`$__go$r = [System.Threading.EventWaitHandle]::OpenExisting('$qGo'); [void]`$__rb.Set(); if (-not `$__go$r.WaitOne(20000)) { throw 'go timeout B' }; `$__go$r.Dispose()")
                    $procA.StandardInput.WriteLine($CommandsA[$r])
                    $procB.StandardInput.WriteLine($CommandsB[$r])
                }

                $procA.StandardInput.WriteLine('"ERRCOUNT_A=" + $Error.Count; $__ra.Dispose(); exit')
                $procB.StandardInput.WriteLine('"ERRCOUNT_B=" + $Error.Count; $__rb.Dispose(); exit')
                $procA.StandardInput.Close()
                $procB.StandardInput.Close()

                for ($r = 0; $r -lt $Rounds; $r++) {
                    Assert-True ($readyA.WaitOne(20000)) "$CaseName round $r`: child A did not reach barrier"
                    Assert-True ($readyB.WaitOne(20000)) "$CaseName round $r`: child B did not reach barrier"
                    [void]$goEvents[$r].Set()
                }

                if (-not $procA.WaitForExit(20000)) {
                    if (-not $procA.HasExited) { $procA.Kill() }
                    throw "$CaseName child A timed out"
                }
                if (-not $procB.WaitForExit(20000)) {
                    if (-not $procB.HasExited) { $procB.Kill() }
                    throw "$CaseName child B timed out"
                }
                [void]$outATask.GetAwaiter().GetResult()
                [void]$errATask.GetAwaiter().GetResult()
                [void]$outBTask.GetAwaiter().GetResult()
                [void]$errBTask.GetAwaiter().GetResult()

                return [pscustomobject]@{
                    CombinedA = $outA.ToString() + $errA.ToString()
                    CombinedB = $outB.ToString() + $errB.ToString()
                    ExitCodeA = $procA.ExitCode
                    ExitCodeB = $procB.ExitCode
                }
            } finally {
                $procA.Dispose()
                $procB.Dispose()
            }
        } finally {
            $readyA.Dispose()
            $readyB.Dispose()
            foreach ($ge in $goEvents) { $ge.Dispose() }
        }
    }

    # Finding 2a: Concurrent add/add (global) behind EventWaitHandle barrier (3 rounds)
    $raceAddStore = Join-Path $script:TempDir 'race-add\shortcuts.json'
    $raceAddRes = Invoke-BarrierPair -CaseName 'race-add-add' -StorePath $raceAddStore -DirA $outsideDir -DirB $outsideDir -Rounds 3 `
        -CommandsA @(
            'shortcut add rev_race_a1 "Write-Output ''a1''"',
            'shortcut add rev_race_a2 "Write-Output ''a2''"',
            'shortcut add rev_race_a3 "Write-Output ''a3''"'
        ) `
        -CommandsB @(
            'shortcut add rev_race_b1 "Write-Output ''b1''"',
            'shortcut add rev_race_b2 "Write-Output ''b2''"',
            'shortcut add rev_race_b3 "Write-Output ''b3''"'
        )
    Assert-True ($raceAddRes.ExitCodeA -eq 0 -and $raceAddRes.ExitCodeB -eq 0) "Finding 2a: barrier children exited non-zero: A=$($raceAddRes.CombinedA) B=$($raceAddRes.CombinedB)"
    Assert-True ($raceAddRes.CombinedA.Contains('ERRCOUNT_A=0') -and $raceAddRes.CombinedB.Contains('ERRCOUNT_B=0')) "Finding 2a: retry polluted `$Error: A=$($raceAddRes.CombinedA) B=$($raceAddRes.CombinedB)"
    $raceAddVerify = Invoke-ShortcutsInjectedChild -CaseName 'race-add-verify' -WithoutPSReadLine -WorkingDirectory $outsideDir -ShortcutsPath $raceAddStore `
        -Lines @(
            '"LIST=" + ((shortcut list) -join ";")',
            'rev_race_a1; rev_race_b1; rev_race_a2; rev_race_b2; rev_race_a3; rev_race_b3',
            'exit'
        )
    foreach ($expectedKey in @('rev_race_a1', 'rev_race_b1', 'rev_race_a2', 'rev_race_b2', 'rev_race_a3', 'rev_race_b3')) {
        Assert-True ($raceAddVerify.Stdout.Contains("$expectedKey ->")) "Finding 2a: lost '$expectedKey' in concurrent add/add: $($raceAddVerify.Combined)"
    }

    # Finding 2b: Concurrent add/remove behind EventWaitHandle barrier
    $raceAddRmStore = Join-Path $script:TempDir 'race-add-rm\shortcuts.json'
    $seedAddRm = Invoke-ShortcutsInjectedChild -CaseName 'race-add-rm-seed' -WithoutPSReadLine -WorkingDirectory $outsideDir -ShortcutsPath $raceAddRmStore `
        -Lines @(
            'shortcut add seed_keep "Write-Output ''keep''"',
            'shortcut add seed_drop "Write-Output ''drop''"',
            'exit'
        )
    Assert-True ($seedAddRm.Combined.Contains("Saved global shortcut 'seed_drop'")) "Finding 2b: seed failed: $($seedAddRm.Combined)"
    $raceAddRmRes = Invoke-BarrierPair -CaseName 'race-add-remove' -StorePath $raceAddRmStore -DirA $outsideDir -DirB $outsideDir -Rounds 1 `
        -CommandsA @('shortcut remove seed_drop') `
        -CommandsB @('shortcut add race_added "Write-Output ''added-ok''"')
    Assert-True ($raceAddRmRes.ExitCodeA -eq 0 -and $raceAddRmRes.ExitCodeB -eq 0) "Finding 2b: barrier children failed: A=$($raceAddRmRes.CombinedA) B=$($raceAddRmRes.CombinedB)"
    $raceAddRmVerify = Invoke-ShortcutsInjectedChild -CaseName 'race-add-rm-verify' -WithoutPSReadLine -WorkingDirectory $outsideDir -ShortcutsPath $raceAddRmStore `
        -Lines @(
            '"LIST=" + ((shortcut list) -join ";")',
            'exit'
        )
    Assert-True ($raceAddRmVerify.Stdout.Contains('seed_keep ->') -and $raceAddRmVerify.Stdout.Contains('race_added ->') -and (-not $raceAddRmVerify.Stdout.Contains('seed_drop ->'))) `
        "Finding 2b: unexpected set after concurrent add/remove: $($raceAddRmVerify.Combined)"

    # Finding 2c: Concurrent add --project in two different Git repos behind EventWaitHandle barrier
    $raceProjStore = Join-Path $script:TempDir 'race-proj\shortcuts.json'
    $raceProjRes = Invoke-BarrierPair -CaseName 'race-add-project' -StorePath $raceProjStore -DirA $repoA -DirB $repoB -Rounds 1 `
        -CommandsA @('shortcut add --project proj_race_a "Write-Output ''pa''"') `
        -CommandsB @('shortcut add --project proj_race_b "Write-Output ''pb''"')
    Assert-True ($raceProjRes.ExitCodeA -eq 0 -and $raceProjRes.ExitCodeB -eq 0) "Finding 2c: barrier children failed: A=$($raceProjRes.CombinedA) B=$($raceProjRes.CombinedB)"
    $raceProjVerify = Invoke-ShortcutsInjectedChild -CaseName 'race-proj-verify' -WithoutPSReadLine -WorkingDirectory $repoA -ShortcutsPath $raceProjStore `
        -Lines @(
            '"LIST_A=" + ((shortcut list --project) -join ";")',
            "Set-Location '$qRepoB'",
            '"LIST_B=" + ((shortcut list --project) -join ";")',
            'exit'
        )
    Assert-True ($raceProjVerify.Stdout.Contains('proj_race_a ->') -and $raceProjVerify.Stdout.Contains('proj_race_b ->')) `
        "Finding 2c: lost project shortcut in concurrent add --project: $($raceProjVerify.Combined)"

    # Finding 2d: Held lock timeout leaves store untouched and does not poison cache
    $lockTimeoutStore = Join-Path $script:TempDir 'lock-timeout\shortcuts.json'
    $env:NOCTTY_SHORTCUTS_PATH = $lockTimeoutStore
    $Global:__ghostty_shortcut_cache = $null
    $null = shortcut add before_lock "Write-Output 'untouched'"
    $beforeBytes = [System.IO.File]::ReadAllText($lockTimeoutStore, [System.Text.Encoding]::UTF8)
    $lockFilePath = $lockTimeoutStore + '.lock'
    $heldLock = [System.IO.FileStream]::new($lockFilePath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        $timedOutMsg = ''
        try {
            __ghostty_mutate_shortcuts -LockTimeoutMs 200 -Mutation {
                param($d)
                $d.Global.set_Item('should_not_exist', 'bad')
                return $true
            }
        } catch {
            $timedOutMsg = $_.Exception.Message
        }
        Assert-True ($timedOutMsg.Contains('Timed out after 200ms')) "Finding 2d: expected lock timeout error, got: $timedOutMsg"
        $afterBytes = [System.IO.File]::ReadAllText($lockTimeoutStore, [System.Text.Encoding]::UTF8)
        Assert-True ($beforeBytes -ceq $afterBytes) "Finding 2d: shortcuts.json was modified on lock timeout"
        $cacheAfterTimeout = $Global:__ghostty_shortcut_cache
        Assert-True ($null -ne $cacheAfterTimeout -and $cacheAfterTimeout.Global.ContainsKey('before_lock') -and (-not $cacheAfterTimeout.Global.ContainsKey('should_not_exist'))) `
            "Finding 2d: shortcut cache was poisoned on lock timeout"
    } finally {
        $heldLock.Dispose()
    }

    # Finding 2e: Killed lock-holder recovery (OS releases lock when holder process dies)
    $killLockStore = Join-Path $script:TempDir 'kill-lock\shortcuts.json'
    $killLockPath = $killLockStore + '.lock'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $killLockStore) | Out-Null
    $killReadyName = 'Local\noctty-kill-lock-' + [guid]::NewGuid().ToString('n')
    $killReady = [System.Threading.EventWaitHandle]::new($false, [System.Threading.EventResetMode]::AutoReset, $killReadyName)
    try {
        $qKillLock = ConvertTo-PowerShellLiteralContent $killLockPath
        $qKillReady = ConvertTo-PowerShellLiteralContent $killReadyName
        $holderScript = "`$fs = [System.IO.FileStream]::new('$qKillLock', [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None); `$ev = [System.Threading.EventWaitHandle]::OpenExisting('$qKillReady'); [void]`$ev.Set(); Start-Sleep -Seconds 30"
        $holderInfo = [System.Diagnostics.ProcessStartInfo]::new()
        $holderInfo.FileName = $script:PsHost
        $holderInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -Command "' + $holderScript + '"'
        $holderInfo.UseShellExecute = $false
        $holderInfo.CreateNoWindow = $true
        $holderProc = [System.Diagnostics.Process]::Start($holderInfo)
        try {
            Assert-True ($killReady.WaitOne(15000)) "Finding 2e: lock-holder child did not signal ready"
            $holderProc.Kill()
            [void]$holderProc.WaitForExit(5000)
        } finally {
            $holderProc.Dispose()
        }
        $afterKillRes = Invoke-ShortcutsInjectedChild -CaseName 'after-kill-lock' -WithoutPSReadLine -WorkingDirectory $outsideDir -ShortcutsPath $killLockStore `
            -Lines @(
                'shortcut add after_kill "Write-Output ''lock-released''"',
                '"OUT=" + (after_kill)',
                'exit'
            )
        Assert-True ($afterKillRes.Stdout.Contains('OUT=lock-released')) "Finding 2e: failed to acquire lock after holder was killed: $($afterKillRes.Combined)"
    } finally {
        $killReady.Dispose()
    }

    # Finding 2f: Corrupt JSON ({broken and []) fails cleanly without wiping file or poisoning cache
    foreach ($corruptPayload in @('{broken', '[]')) {
        $corruptStore = Join-Path $script:TempDir ('corrupt-' + [guid]::NewGuid().ToString('n') + '\shortcuts.json')
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $corruptStore) | Out-Null
        [System.IO.File]::WriteAllText($corruptStore, $corruptPayload, [System.Text.UTF8Encoding]::new($false))
        $corruptChild = Invoke-ShortcutsInjectedChild -CaseName 'corrupt-json' -WithoutPSReadLine -WorkingDirectory $outsideDir -ShortcutsPath $corruptStore `
            -Lines @(
                '$Global:__ghostty_shortcut_cache = [pscustomobject]@{ Sentinel = "kept" }',
                'try { shortcut add after_corrupt "Write-Output ''nope''"; "ADD_UNEXPECTED_OK" } catch { "ADD_THREW=" + $_.Exception.Message }',
                '"CACHE_SENTINEL=" + $Global:__ghostty_shortcut_cache.Sentinel',
                'exit'
            )
        $diskAfterCorrupt = [System.IO.File]::ReadAllText($corruptStore, [System.Text.Encoding]::UTF8)
        Assert-True ($diskAfterCorrupt -ceq $corruptPayload) "Finding 2f ($corruptPayload): corrupt store was wiped or overwritten: $diskAfterCorrupt"
        Assert-True ($corruptChild.Stdout.Contains('ADD_THREW=')) "Finding 2f ($corruptPayload): expected error on corrupt JSON, got: $($corruptChild.Combined)"
        Assert-True ($corruptChild.Stdout.Contains('CACHE_SENTINEL=kept')) "Finding 2f ($corruptPayload): cache was poisoned on corrupt JSON: $($corruptChild.Combined)"
    }

    # ── Finding 5 regressions: Hashtable member collisions (global and --project) ──
    $collNames = @('keys', 'count', 'values', 'item', 'isreadonly', 'syncroot', 'containskey', 'get_keys', 'get_count')
    $collInvokeNames = @('keys', 'count', 'values', 'isreadonly', 'syncroot', 'containskey', 'get_keys', 'get_count')
    $collStore = Join-Path $script:TempDir 'hashtable-collisions\shortcuts.json'
    $collLines = [System.Collections.Generic.List[string]]::new()
    $collLines.Add('shortcut add normal_sc "Write-Output ''normal-ok''"')
    foreach ($cn in $collNames) {
        $collLines.Add("shortcut add $cn `"Write-Output 'g-$cn'`"")
    }
    $collLines.Add('"GLIST=" + ((shortcut list) -join ";")')
    foreach ($cn in $collInvokeNames) {
        $collLines.Add("`"GINV_$cn=`" + ($cn)")
    }
    $collLines.Add('"GINV_normal=" + (normal_sc)')
    $collLines.Add('shortcut add count "Write-Output ''g-count-updated''"')
    $collLines.Add('"GUPD_count=" + (count)')
    foreach ($cn in $collNames) {
        $collLines.Add("shortcut remove $cn")
    }
    $collLines.Add('"GLIST_AFTER=" + ((shortcut list) -join ";")')
    $collLines.Add('shortcut add --project normal_sc "Write-Output ''pnormal-ok''"')
    foreach ($cn in $collNames) {
        $collLines.Add("shortcut add --project $cn `"Write-Output 'p-$cn'`"")
    }
    $collLines.Add('"PLIST=" + ((shortcut list --project) -join ";")')
    foreach ($cn in $collInvokeNames) {
        $collLines.Add("`"PINV_$cn=`" + ($cn)")
    }
    $collLines.Add('"PINV_normal=" + (normal_sc)')
    $collLines.Add('shortcut add --project count "Write-Output ' + "'p-count-updated'" + '"')
    $collLines.Add('"PUPD_count=" + (count)')
    foreach ($cn in $collNames) {
        $collLines.Add("shortcut remove --project $cn")
    }
    $collLines.Add('"PLIST_AFTER=" + ((shortcut list --project) -join ";")')
    $collLines.Add('exit')

    $cColl = Invoke-ShortcutsInjectedChild -CaseName 'hashtable-collisions' -WithoutPSReadLine -WorkingDirectory $repoA -ShortcutsPath $collStore -Lines $collLines.ToArray()
    Assert-True ($cColl.ExitCode -eq 0) "Finding 5: child exited non-zero: $($cColl.Combined)"
    Assert-True ($cColl.Stdout.Contains("GLIST=") -and $cColl.Stdout.Contains("normal_sc -> Write-Output 'normal-ok'")) "Finding 5: global list missing normal_sc: $($cColl.Combined)"
    Assert-True ($cColl.Stdout.Contains("PLIST=") -and $cColl.Stdout.Contains("normal_sc -> Write-Output 'pnormal-ok'")) "Finding 5: project list missing normal_sc: $($cColl.Combined)"
    foreach ($cn in $collNames) {
        Assert-True ($cColl.Stdout.Contains("$cn -> Write-Output 'g-$cn'")) "Finding 5: global list missing '$cn': $($cColl.Combined)"
        Assert-True ($cColl.Stdout.Contains("$cn -> Write-Output 'p-$cn'")) "Finding 5: project list missing '$cn': $($cColl.Combined)"
    }
    foreach ($cn in $collInvokeNames) {
        Assert-True ($cColl.Stdout.Contains("GINV_$cn=g-$cn")) "Finding 5: global invoke failed for '$cn': $($cColl.Combined)"
        Assert-True ($cColl.Stdout.Contains("PINV_$cn=p-$cn")) "Finding 5: project invoke failed for '$cn': $($cColl.Combined)"
    }
    Assert-True ($cColl.Stdout.Contains('GUPD_count=g-count-updated')) "Finding 5: global update of 'count' failed: $($cColl.Combined)"
    Assert-True ($cColl.Stdout.Contains('PUPD_count=p-count-updated')) "Finding 5: project update of 'count' failed: $($cColl.Combined)"
    Assert-True ($cColl.Stdout.Contains("GLIST_AFTER=normal_sc -> Write-Output 'normal-ok'")) "Finding 5: global list after removes unexpected: $($cColl.Combined)"
    Assert-True ($cColl.Stdout.Contains("PLIST_AFTER=normal_sc -> Write-Output 'pnormal-ok'")) "Finding 5: project list after removes unexpected: $($cColl.Combined)"

    Write-Host ("All PowerShell shortcuts tests passed ({0} assertions)." -f $script:AssertionCount) -ForegroundColor Green
} finally {
    $ExecutionContext.InvokeCommand.CommandNotFoundAction = $script:OriginalCommandNotFound
    $function:global:prompt = $script:OriginalPrompt
    $function:global:shortcut = $script:OriginalShortcut
    $env:NOCTTY_SHORTCUTS_PATH = $script:OriginalShortcutsPath
    if ($null -ne $script:OriginalHistoryOptions) {
        Set-PSReadLineOption -HistorySaveStyle $script:OriginalHistoryOptions.HistorySaveStyle
        Set-PSReadLineOption -HistorySavePath $script:OriginalHistoryOptions.HistorySavePath
    }
    if (Test-Path -LiteralPath $script:TempDir) {
        Remove-Item -LiteralPath $script:TempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

} finally {
    Assert-WindowsHarnessHistoryGuard -Guard $windowsHarnessHistoryGuard
}
