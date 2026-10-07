# Test stand-in for 'tailscale status --json' and 'tailscale serve status
# --json', used by the tests of the tools that read the tailnet. Every
# address and name is put together here at run time, so none is ever
# written to a file. What 'status' reports depends on $env:CRIA_FAKE_TAILSCALE:
#   down    fails, as when Tailscale is not running
#   no-vps  the VPS is not in the tailnet
#   anything else: this PC, the VPS, a phone, and an exit node that belongs
#   to another domain (named EXT_ by the collector)
# What 'serve status' reports depends on $env:CRIA_FAKE_SERVE:
#   funnel   one port is open to the internet
#   text     an HTTPS handler serves text rather than proxying
#   tailnet  one TCP rule forwards to the VPS's tailnet address
#   anything else: two HTTPS proxies and one TCP forward, all to loopback
if ($env:CRIA_FAKE_TAILSCALE -eq 'down') { exit 1 }
$domain = 'example-tailnet' + '.ts' + '.net'
if ($args.Count -ge 1 -and $args[0] -eq 'serve') {
    $mode = $env:CRIA_FAKE_SERVE
    $loop = @('127', '0', '0', '1') -join '.'
    $forward = if ($mode -eq 'tailnet') { (@('100', '64', '0', '8') -join '.') + ':8090' } else { "${loop}:11434" }
    $root = if ($mode -eq 'text') { @{ Text = 'hello' } } else { @{ Proxy = "http://${loop}:3000" } }
    [ordered]@{
        TCP         = [ordered]@{ '11434' = @{ TCPForward = $forward }; '443' = @{ HTTPS = $true }; '8443' = @{ HTTPS = $true } }
        Web         = [ordered]@{
            "pc.${domain}:443"  = @{ Handlers = @{ '/' = $root } }
            "pc.${domain}:8443" = @{ Handlers = [ordered]@{ '/' = @{ Proxy = "http://${loop}:8090" }; '/api' = @{ Proxy = "http://${loop}:8091" } } }
        }
        AllowFunnel = @{ "pc.${domain}:443" = ($mode -eq 'funnel') }
    } | ConvertTo-Json -Depth 6
    exit 0
}
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
