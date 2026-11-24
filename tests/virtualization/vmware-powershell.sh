#!/usr/bin/env bash
# note: virtualization/vmware-powershell.md
# env: leap
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=virtualization/vmware-powershell
cd "$(mktemp -d)"

# No vCenter here: the test parses the note's PowerShell, and checks every cmdlet and
# parameter against the real PowerCLI module. The official PowerShell image has no
# arm64 build, so PowerShell comes from the release tarball.
PWSH_VERSION=7.6.9
# Save-Module takes the newest dependencies (Common, Sdk, Vim): keep Core on their version,
# or the import fails with "Could not load file or assembly VMware.Vim".
POWERCLI_CORE_VERSION=13.5.2.25952617
zypper -n -q install --no-recommends libicu >/dev/null
case $(uname -m) in x86_64) arch=x64 ;; aarch64) arch=arm64 ;; esac
mkdir -p /opt/pwsh /opt/psmod
curl -fsSL "https://github.com/PowerShell/PowerShell/releases/download/v$PWSH_VERSION/powershell-$PWSH_VERSION-linux-$arch.tar.gz" |
  tar -xz -C /opt/pwsh
export PSModulePath=/opt/psmod
# The PowerShell Gallery download fails now and then: try three times.
for _ in 1 2 3; do
  /opt/pwsh/pwsh -NoProfile -Command "Set-PSRepository PSGallery -InstallationPolicy Trusted
    Save-Module VMware.VimAutomation.Core -RequiredVersion $POWERCLI_CORE_VERSION -Path /opt/psmod" >psget.log 2>&1 &&
    [[ -d /opt/psmod/VMware.VimAutomation.Core ]] && break
  sleep 10
done
[[ -d /opt/psmod/VMware.VimAutomation.Core ]] || sed 's/^/# Save-Module: /' psget.log
pwsh() { /opt/pwsh/pwsh -NoProfile -NonInteractive "$@"; }
pwsh -Command 'Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -Confirm:$false' >/dev/null

# check.ps1 FILE: fails on a parse error, or on a parameter that the command does not have.
cat >check.ps1 <<'EOF'
param([string]$File)
$errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$null, [ref]$errs)
if ($errs) { $errs | ForEach-Object { "parse error: $($_.Message)" }; exit 1 }
$bad = 0
foreach ($c in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true)) {
    $name = $c.GetCommandName()
    if (-not $name -or $name -like '.\*') { continue }
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if (-not $cmd) { "unknown command: $name"; $bad++; continue }
    $known = @($cmd.Parameters.Values | ForEach-Object { $_.Name; $_.Aliases })
    foreach ($p in $c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] }) {
        if ($known -notcontains $p.ParameterName) { "$name has no -$($p.ParameterName)"; $bad++ }
    }
}
exit $bad
EOF

n=$(grep -c '^ *\(> \)*```powershell' "$NOTES_ROOT/content/$NOTE.md")
section "Every PowerShell block"
for ((i = 1; i <= n; i++)); do
  note_block "$NOTE" "$i" >"block$i.ps1"
  check "block $i ($(head -1 "block$i.ps1" | cut -c1-40)) parses, and its cmdlets have these parameters" \
    pwsh -File check.ps1 "block$i.ps1"
done
check_fails "the check catches a parameter that does not exist" \
  pwsh -File check.ps1 <(echo 'Get-View -ViewType VirtualMachine -Location x')

section "Snapshotting them"
check_output "New-Snapshot has -Memory and -Quiesce" 'Memory.*Quiesce' \
  pwsh -Command '(Get-Command New-Snapshot).Parameters.Keys -join " "'
skip "-Memory and -Quiesce exclude each other in the vSphere Client" "needs a vCenter"
skip "Get-Snapshot -Name matches the name, not the description" "needs a vCenter"

section "Removing them"
# The original's en-dash: PowerShell reads it as a dash (the correction).
echo 'Remove-Snapshot –WhatIf' >endash.ps1
check "remove-snapshot –whatif, with an en-dash, parses and binds -WhatIf" pwsh -File check.ps1 endash.ps1
cat >endash-run.ps1 <<'EOF'
function Remove-Thing { [CmdletBinding(SupportsShouldProcess)] param() if ($PSCmdlet.ShouldProcess('x')) { 'deleted' } }
Remove-Thing –WhatIf
EOF
check_output "and –WhatIf works: nothing is deleted" '^What if: ' pwsh -File endash-run.ps1
check_fails "it does not print 'deleted'" bash -c "/opt/pwsh/pwsh -NoProfile -File endash-run.ps1 | grep -q deleted"
skip "running the snippets against VMs" "needs a vCenter"
