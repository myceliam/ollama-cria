# 🧪 The VM test: trying the rebuild on two virtual machines

**For:** you, Liam, and the assistant helping you, if you ever want to try the rebuild before a real disaster.
**Optional, and separate.** Nothing in [`FULL-REBUILD-HUMAN.md`](FULL-REBUILD-HUMAN.md), [`VPS-REBUILD-HUMAN.md`](VPS-REBUILD-HUMAN.md) or [`RESTORE.md`](RESTORE.md) needs this test to have run. The rebuild guides work on their own; this page only lets you find their mistakes early, on throwaway machines.
**Last checked:** 8 October 2026. Never run yet.

---

## 🧭 What it is

Two virtual machines on your PC stand in for the lost machines: **Windows 11** as the PC, and **Ubuntu 24.04** as the VPS. The assistant then runs the real rebuild inside them.

| Mode | You need | It runs | It proves |
|---|---|---|---|
| **A · Software only** | The Windows VM; the Ubuntu VM only for its first script | Stages 1, 3 and 6 in the Windows VM; the setup script in the Ubuntu VM | The bundle unpacks, every app installs at its version, every model and weight downloads and checks out |
| **B · Everything** | Both VMs and a **second, throwaway Tailscale account** | Every stage, 1 to 11 | The whole chain: the VPN with multihop, both kill switches, Open WebUI with your tools, the backup |

**Why Mode A stops at Stage 6:** Stage 2 puts the VPS on the tailnet under the name `vps`, and everything after it builds on that. Your real tailnet already has a `vps` and a PC with your PC's name, so the test machines can't join it. Stages 3 and 6 don't need the tailnet; Stage 7 waits for the VPS stages.

**Why a throwaway Tailscale account for Mode B:** the test machines need the exact old names, in a tailnet of their own. A free second account (another email, or a GitHub login) is enough. Your phone's Tailscale app can switch between the two accounts for the phone checks.

### What the test can't prove

| Not tested | Why | The rebuild guides cover it by |
|---|---|---|
| The graphics card | A VM has no NVIDIA card | Answering `-Accept gpu` here; checkpoint 3 on the real PC |
| The IONOS console | You use Hyper-V's console instead | The same script, pasted the same way |
| Probes from the internet (10b) | Both VMs share your home's internet address | Stage 10b on the real machines |
| Keeping the VPS's old Tailscale address | Only matters in the real tailnet | VPS-REBUILD V4 |

---

## ⚠️ Before you start

- **The VMs hold your real keys.** Stage 1 unpacks your real bundle inside the Windows VM. Its `E:` drive has BitLocker on, and T9 deletes both VMs and their disks.
- **RAM.** The Windows VM needs 16 GB and the Ubuntu VM 8 GB, out of your PC's 32 GB. For Mode B, pause your live stack while the test runs (T6).
- **One Mullvad key can't run in two places.** The test VPS uses the same WireGuard key as your live VPS, from your bundle. Two tunnels with one key knock each other off, so in Mode B your live VPS's VPN pauses while the test VPS runs it (T6). Web search on your real setup is off until T9.
- **Disk and downloads.** Stage 6 downloads every model and weight again: hundreds of gigabytes. The VM's `E:` disk needs that much room on a real drive.
- **Never in the repo:** the test tailnet's names and addresses, like the real ones.

---

## ✅ Progress

The assistant on your PC keeps a copy of this page in the test folder (T3) as `PROGRESS.md`, and ticks it. Inside the Windows VM, the rebuild keeps its own copy of `FULL-REBUILD-HUMAN.md` as usual.

| Step | Done | What happens | Your part |
|---|---|---|---|
| T0 | ⬜ | Pick the mode; check RAM and disk | Choose A or B |
| T1 | ⬜ | Hyper-V on | One admin prompt; restart |
| T2 | ⬜ | Download Windows 11 and Ubuntu Server | Two downloads |
| T3 | ⬜ | Make both VMs | Say yes to the commands |
| T4 | ⬜ | Install Windows 11 and Ubuntu in them | Click through two installers |
| T5 | ⬜ | The throwaway Tailscale account (Mode B) | Sign up |
| T6 | ⬜ | Pause your live setup (Mode B) | Say yes |
| T7 | ⬜ | Run the rebuild inside the VMs | As in FULL-REBUILD-HUMAN, with the changes below |
| T8 | ⬜ | Optional: the VPS-only rebuild too | As in VPS-REBUILD-HUMAN |
| T9 | ⬜ | Delete everything; bring your live setup back | Say yes; check web search |

---

## The steps

### T0 · Pick the mode, check the PC

🤖 **The assistant** (on your PC, not in a VM) checks the free RAM, and how much the models take today:

```powershell
"{0:N0} GB of RAM" -f ((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
$sum = 0
foreach ($p in 'E:\ollama-models', 'E:\ai\comfyui\ComfyUI\models') { $sum += (Get-ChildItem -LiteralPath $p -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum }
"models and weights: {0:N0} GB; the VM's E: disk needs this plus 100 GB" -f ($sum / 1GB)
Get-Volume | Where-Object DriveLetter | Select-Object DriveLetter, @{ n = 'FreeGB'; e = { [math]::Round($_.SizeRemaining / 1GB) } }
```

👤 **You** pick **A** or **B**, and the drive for the test folder (one with room for both VMs; not inside `E:\ai` or `E:\ollama-models`).

### T1 · Hyper-V on

Windows 11 Pro includes Hyper-V; it's just switched off.

🤖 **The assistant** checks first, then asks you to run the second line in an **admin** PowerShell window if it's off:

```powershell
(Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-All).State
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
```

👤 **You:** run it, then restart.
✅ **You should see** `Enabled`. Docker Desktop and WSL keep working alongside it.

### T2 · Two downloads

👤 **You** download, into the test folder:
1. **Windows 11** (the ISO, "Download Windows 11 Disk Image"): https://www.microsoft.com/software-download/windows11
2. **Ubuntu Server 24.04 LTS:** https://ubuntu.com/download/server

### T3 · Make both VMs

🤖 **The assistant** fills in the three paths and runs this in an admin window, with your yes. Both VMs use Hyper-V's built-in **Default Switch**, which gives them the internet and lets them reach each other.

```powershell
$dir = '<the test folder from T0>'
$winIso = Join-Path $dir '<the Windows 11 ISO file name>'
$ubuntuIso = Join-Path $dir '<the Ubuntu Server ISO file name>'
$eSizeGB = 600   # from T0: models and weights plus 100 GB

# The PC: Windows 11 needs a TPM; WSL and Docker Desktop need nested virtualisation, which needs fixed memory
$pc = 'cria-test-pc'
New-VM -Name $pc -Generation 2 -MemoryStartupBytes 16GB -NewVHDPath (Join-Path $dir "$pc-c.vhdx") -NewVHDSizeBytes 128GB -SwitchName 'Default Switch' -Path $dir | Out-Null
Set-VM -Name $pc -ProcessorCount 8 -StaticMemory -AutomaticCheckpointsEnabled $false
Set-VMProcessor -VMName $pc -ExposeVirtualizationExtensions $true
Set-VMKeyProtector -VMName $pc -NewLocalKeyProtector
Enable-VMTPM -VMName $pc
New-VHD -Path (Join-Path $dir "$pc-e.vhdx") -SizeBytes ($eSizeGB * 1GB) -Dynamic | Out-Null
Add-VMHardDiskDrive -VMName $pc -Path (Join-Path $dir "$pc-e.vhdx")
Add-VMDvdDrive -VMName $pc -Path $winIso
Set-VMFirmware -VMName $pc -FirstBootDevice (Get-VMDvdDrive -VMName $pc)

# The VPS: Ubuntu boots with Secure Boot set to the UEFI certificate authority
$vps = 'cria-test-vps'
New-VM -Name $vps -Generation 2 -MemoryStartupBytes 8GB -NewVHDPath (Join-Path $dir "$vps.vhdx") -NewVHDSizeBytes 60GB -SwitchName 'Default Switch' -Path $dir | Out-Null
Set-VM -Name $vps -ProcessorCount 4 -StaticMemory -AutomaticCheckpointsEnabled $false
Set-VMFirmware -VMName $vps -SecureBootTemplate MicrosoftUEFICertificateAuthority
Add-VMDvdDrive -VMName $vps -Path $ubuntuIso
Set-VMFirmware -VMName $vps -FirstBootDevice (Get-VMDvdDrive -VMName $vps)

$repo = '<the clone of ollama-cria on this PC>'
Copy-Item (Join-Path $repo 'docs/VM-TEST.md') (Join-Path $dir 'PROGRESS.md')
Get-VM -Name $pc, $vps | Select-Object Name, State, ProcessorCount, @{ n = 'MemoryGB'; e = { $_.MemoryStartup / 1GB } }
```

✅ **You should see** both VMs listed, `Off`.
🧯 **"Default Switch" not found:** restart once more after T1. **Not enough memory to start:** stop Docker Desktop on your PC first, or give the PC VM 12 GB.

### T4 · Install the two systems

👤 **You,** in Hyper-V Manager (Start → Hyper-V Manager), connect to each VM and start it. Press a key when it says "Press any key to boot from CD or DVD".

**The Windows VM:**
1. Install **Windows 11 Pro**. Without a product key it runs unactivated, which is fine for a test.
2. Sign in as the account that will own the stack. A local account or your Microsoft account both work.
3. In Disk Management, make the second disk a new volume with the letter **E:**.
4. Turn **BitLocker** on for `E:`.
5. Install PowerShell 7: `winget install --id Microsoft.PowerShell --exact --source winget`.

**The Ubuntu VM:**
1. Install **Ubuntu Server**, with the defaults.
2. For the user, pick a name that **isn't** `liam`, such as `setup`. The rebuild's script creates `liam` itself.
3. Tick **Install OpenSSH server**. Skip the extra "snaps".
4. After the restart, log in, and run `ip -4 addr show eth0` to see its address. You'll paste the setup script over SSH from the Windows VM, which is easier than Hyper-V's console.

✅ **You should see** Windows ready with `E:` encrypted, and Ubuntu at a login prompt.

### T5 · The throwaway Tailscale account (Mode B)

👤 **You:**
1. Sign up for Tailscale with a **different** login from your real one.
2. On your phone, add that account in the Tailscale app. You can switch between the two; switch back when you're done.

Skip this in Mode A.

### T6 · Pause your live setup (Mode B)

Mode B runs a second copy of your stack and your VPN, so the real ones pause.

🤖 **The assistant** asks first, then:
1. Quits Docker Desktop and Ollama on your PC (right-click their tray icons → Quit), which stops your live stack and frees its memory.
2. Pauses the VPN on your live VPS, so the test VPS can use the same Mullvad key. You type your password if `sudo` asks:
   ```powershell
   ssh -t vps 'cd ~/owui-web-egress && sudo docker compose stop'
   ```

✅ **You should see** Docker Desktop closed, and `docker compose stop` report each container stopped.
Skip this in Mode A; your live setup keeps running.

### T7 · Run the rebuild inside the VMs

👤 **You,** inside the **Windows VM**, follow [`FULL-REBUILD-HUMAN.md`](FULL-REBUILD-HUMAN.md) from Stage 0, with these changes:

| Stage | What's different in the test |
|---|---|
| 0 | Sign in to the **throwaway** Tailscale account (Mode B), and name this VM in it exactly like your real PC. In Mode A, install Tailscale but don't sign in |
| 1 | The same: your real bundle and its SHA-256 |
| 2, 3, 6 (Mode A) | Tell the assistant: "There's no tailnet. After Stage 1, run `-Execute -Stage 2` once to write the setup script, then `-Execute -Stage 3` and `-Execute -Stage 6`." Paste the setup script into the Ubuntu VM (as in the Stage 2 row below) to prove it runs, but don't run its `tailscale up` line. Then go to T9 |
| 2 | Instead of IONOS: from the Windows VM, `ssh setup@<the Ubuntu VM's address>`, then `sudo -i`, then paste the setup script. Name the Ubuntu VM `vps` in the throwaway tailnet. If the assistant says the `vps` alias points elsewhere, that's expected: your SSH settings name the real tailnet, so it updates `~/.ssh/config` in the VM |
| 3 | No NVIDIA card: answer with `-Accept gpu` |
| 6 | The longest stage. Every model and weight downloads again |
| 8, 9, 10 | For the phone checks, switch your phone's Tailscale app to the throwaway account. `local-chat` answers on the CPU, not 100% GPU: accept it anyway |
| 10b | Proves little here: both VMs share your home's address |
| 10e | Upload the test's ZIP to a **new** Bitwarden item, such as "VM test bundle". **Never** replace your real bundle with it |
| 11 | Don't commit the test's Open WebUI seed. The change log row says it was a VM test |

👤 **You, all the way through:** whenever a step goes differently from the guide, tell the assistant. That's the point of the test: it fixes the guides (`RESTORE.md`, the walkthroughs, `START-HERE.md`) on a branch and opens a pull request.

### T8 · Optional: the VPS-only rebuild too (Mode B)

With the test PC working, you can also try [`VPS-REBUILD-HUMAN.md`](VPS-REBUILD-HUMAN.md):
1. In Hyper-V Manager, turn off `cria-test-vps`, delete it and its `.vhdx`, then make and install it again (T3's VPS half and T4).
2. Inside the Windows VM, tell the assistant: "My VPS is gone. Rebuild it with `docs/VPS-REBUILD-AI.md`." Follow along from V0, using the Ubuntu VM's console instead of IONOS, and pick "It just died" (saved keys).

### T9 · Delete everything; bring your live setup back

🤖 **The assistant** asks first, then, in an admin window:

```powershell
$dir = '<the test folder from T0>'
foreach ($vm in 'cria-test-pc', 'cria-test-vps') {
    if (Get-VM -Name $vm -ErrorAction SilentlyContinue) { Stop-VM -Name $vm -TurnOff -Force; Remove-VM -Name $vm -Force }
}
Get-ChildItem -LiteralPath $dir -Filter '*.vhdx' | Select-Object Name, @{ n = 'GB'; e = { [math]::Round($_.Length / 1GB) } }
```

Removing a VM leaves its disks, which hold your real keys. Delete the `.vhdx` files in the test folder with **Shift+Delete**, so nothing waits in the Recycle Bin, once you've checked the list.

👤 **You:**
1. **Mode B:** in Bitwarden, delete the "VM test bundle" item. In the throwaway Tailscale account, remove both machines (or delete the account). On your phone, switch Tailscale back to your real account.
2. **Mode B:** start your live VPS's VPN again, and your live stack:
   ```powershell
   ssh -t vps 'cd ~/owui-web-egress && sudo docker compose start'
   ```
   Then start Docker Desktop on your PC and run `E:\ai\ollama\start-stack.ps1`, or just restart the PC.
3. Ask Open WebUI something that needs a web search, to check the VPN is back.

✅ **You should see** no VMs left, no `.vhdx` files, and web search working again. 🎉
