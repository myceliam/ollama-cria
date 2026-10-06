# Test stand-in for 'tailscale status --json', used only by
# tests/Collect-StackSecrets.Tests.ps1. Every address and name is put
# together here at run time, so none is ever written to a file. What it
# reports depends on $env:CRIA_FAKE_TAILSCALE:
#   down    fails, as when Tailscale is not running
#   no-vps  the VPS is not in the tailnet
#   anything else: this PC, the VPS, a phone, and an exit node that belongs
#   to another domain (named EXT_ by the collector)
if ($env:CRIA_FAKE_TAILSCALE -eq 'down') { exit 1 }
$domain = 'example-tailnet' + '.ts' + '.net'
function Get-FakeNode([string]$Label, [string]$Last) {
    [ordered]@{
        HostName     = $Label
        DNSName      = "$Label.$domain."
        TailscaleIPs = @((@('100', '64', '0', $Last) -join '.'), ('fd7a:' + '115c:' + 'a1e0::' + $Last))
    }
}
$peers = [ordered]@{}
if ($env:CRIA_FAKE_TAILSCALE -ne 'no-vps') { $peers['nodekey:a'] = Get-FakeNode 'vps' '8' }
$peers['nodekey:b'] = Get-FakeNode 'fold' '9'
$peers['nodekey:c'] = [ordered]@{ HostName = 'exit'; DNSName = 'gb-lon-wg-001.mullvad' + '.ts' + '.net.'; TailscaleIPs = @('100.' + '65.0.1') }
[ordered]@{ MagicDNSSuffix = $domain; Self = (Get-FakeNode 'pc' '7'); Peer = $peers } | ConvertTo-Json -Depth 5
