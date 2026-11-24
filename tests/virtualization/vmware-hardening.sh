#!/usr/bin/env bash
# note: virtualization/vmware-hardening.md
# env: leap
# timeout: 900
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=virtualization/vmware-hardening
cd "$(mktemp -d)"

# No vCenter here: the test parses the note's PowerShell, checks every cmdlet and
# parameter against the real PowerCLI module, and runs the script with Get-View
# replaced by a stub that records the calls. The official PowerShell image has no
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
check_fails "Get-View has no -Location (the correction)" \
  pwsh -File check.ps1 <(echo 'Get-View -ViewType VirtualMachine -Location x')

section "The script"
note_block "$NOTE" "The script" >harden-vm.ps1
cat >run.ps1 <<'EOF'
Import-Module VMware.VimAutomation.Core
$global:calls = @()
# Stub: two VMs whose ReconfigVM_Task records the spec it gets.
function Get-View {
    param($ViewType, $Property, $Filter, $SearchRoot)
    $global:filter = $Filter
    foreach ($n in 'vm-a', 'vm-b') {
        $o = [pscustomobject]@{ Name = $n }
        $o | Add-Member ScriptMethod ReconfigVM_Task { param($spec) $global:calls += , @($this.Name, $spec) }
        $o
    }
}
'piped-vm' | . ./harden-vm.ps1
"filter: $($global:filter.Keys)=$($global:filter.Values)"
foreach ($c in $global:calls) {
    "reconfigured: $($c[0]) with $($c[1].GetType().FullName) and $($c[1].ExtraConfig.Count) keys"
}
$keys = $global:calls[0][1].ExtraConfig | ForEach-Object Key
"duplicates: $(($keys | Group-Object | Where-Object Count -gt 1).Count)"
"keys: $($keys -join ' ')"
EOF
out=$(pwsh -File run.ps1 2>&1) || true
keys=$(grep -c '^ *"[A-Za-z]' harden-vm.ps1)
assert_match "the script runs and prints one line per VM" $'vm-a - changed\nvm-b - changed' "$out"
assert_match "it reconfigures each VM with one VirtualMachineConfigSpec" \
  "reconfigured: vm-b with VMware.Vim.VirtualMachineConfigSpec and $keys keys" "$out"
assert_match "every key of the hash table is in ExtraConfig, once" '^duplicates: 0$' "$out"
assert_match "it skips templates (Config.Template = false)" '^filter: Config.Template=false$' "$out"
assert_match "piped input is ignored: the stub's VMs are the targets (the note's warning)" \
  'reconfigured: vm-a' "$out"
assert_no_match "no X/Y placeholder keys are left" 'keys: .*(floppyX|ideX|parallelX|serialX)' "$out"
for k in floppy0 parallel0 serial0; do
  assert_match "$k.present replaces the placeholder" "keys: .*\\b$k\\.present\\b" "$out"
done
skip "the settings apply after a power cycle" "needs ESXi"

section "Verifying afterwards"
check_output "New-AdvancedSetting -Force replaces an existing value" 'Force' \
  pwsh -Command '(Get-Command New-AdvancedSetting).Parameters.Keys -join " "'
skip "reading the settings back from VMs" "needs a vCenter"
