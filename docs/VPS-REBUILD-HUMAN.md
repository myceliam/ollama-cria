# 🛰️ Rebuilding the VPS: your walkthrough

**For:** you, Liam, when **only the VPS is lost** and your PC still works.
**Pairs with:** [`VPS-REBUILD-AI.md`](VPS-REBUILD-AI.md), the agent's runbook. The steps have the same numbers, so when the agent says "V6", it means V6 here.
**If your PC is gone too:** use [`FULL-REBUILD-HUMAN.md`](FULL-REBUILD-HUMAN.md) instead.

---

## ▶️ How to start

Open Claude (or another assistant) on your PC and say:

> "My VPS is gone. Rebuild it with `docs/VPS-REBUILD-AI.md` from the `ollama-cria` repo."

The agent does the typing. It stops whenever it needs you, and says which step it's on. Each step below has:

- 🤖 **The agent:** what it's doing, in plain words.
- 👤 **You:** only where you're needed.
- ✅ **You should see:** how to tell it worked.
- 🧯 **If it goes wrong:** what to check, or what to tell the agent.

**Where are we up to?** The agent keeps a copy of this page at `E:\recovery-state\vps-rebuild\PROGRESS.md` and ticks the table below in it as each step passes. Open that file any time.

---

## ✅ Progress

| Step | Done | What happens | Your part |
|---|---|---|---|
| V0 | ⬜ | The agent checks only the VPS is lost, and gets ready | Answer one question |
| V1 | ⬜ | A new server | Rebuild or order it in IONOS; open its console |
| V2 | ⬜ | The agent writes a setup script for the new server | Nothing |
| V3 | ⬜ | The setup script runs on the server | Paste it in; read out one line |
| V4 | ⬜ | The server joins Tailscale as `vps`, with its old address | Six clicks in Tailscale |
| V5 | ⬜ | Your PC learns to trust the new server | Nothing |
| V6 | ⬜ | Docker, the firewall, and SSH locked to Tailscale | Nothing |
| V7 | ⬜ | The VPS's settings files go in place | Nothing |
| V8 | ⬜ | The keys: Mullvad, Brave, SearXNG | Bitwarden, or new keys typed in by you |
| V9 | ⬜ | The agent checks the WireGuard settings match the firewall | Nothing, usually |
| V10 | ⬜ | The firewall guard starts first, then everything else | Nothing |
| V11 | ⬜ | Proof: multihop, both kill switches, nothing exposed | Say OK first |
| V12 | ⬜ | The PC side, and a test from Open WebUI | Try search, read aloud and dictation |
| V13 | ⬜ | A new backup | Upload it to Bitwarden, download it back |
| V14 | ⬜ | Log it and tidy up | Delete the old server in IONOS |

---

## 🛡️ What you get back

The same setup as before, so neither your PC nor the VPS is ever the address a website sees:

```text
Your PC ──Tailscale──▶ VPS ──WireGuard──▶ Mullvad Stockholm ──▶ Mullvad Zurich ──▶ Brave and websites
                                          (entry)              (exit)
```

- 🔁 **Multihop:** traffic goes in at Stockholm (`se-sto-wg-202`) and out at Zurich (`ch-zrh-wg-003`).
- 🧱 **Kill switch 1, gluetun:** nothing leaves the VPN container except through the tunnel.
- 🧱 **Kill switch 2, the guard:** a firewall on the VPS itself. It lets the search services reach only Tailscale and the one Mullvad entry server, blocks IPv6, and stops them opening connections to your PC.
- ⏱️ **Boot order:** Docker won't start until the guard is up.
- 🔒 **Tailscale only:** everything on the VPS, SSH included, answers only on Tailscale. From the internet, only Tailscale's own port is open.

---

## 🔐 Your secrets: what you handle, and where they go

| Secret | Where you get it | Where it goes | Does the agent see it? |
|---|---|---|---|
| Mullvad account number | Bitwarden | The mullvad.net login page, only | ❌ No |
| WireGuard key (new keys only) | Mullvad's config generator | You type it into the VPS yourself | ❌ No |
| Brave API key (new keys only) | Brave's dashboard | You type it into the VPS yourself | ❌ No |
| SearXNG secret | Made on the VPS | Stays there | ❌ Nobody does |
| The backup bundle (saved keys only) | Bitwarden | `E:\recovery-secrets\`, then the VPS | ❌ Only its checksum |
| The server's fingerprint | The server console | You read it out | ✅ Yes: it's public, not a secret |
| Mullvad's entry address and port | The Mullvad file | Only if V9 needs it | ✅ Yes: it's a public server address |

---

## The steps

### V0 · Is it only the VPS?

🤖 **The agent** checks the VPS doesn't answer and Open WebUI still runs on your PC. It downloads the latest guides, makes a work folder, and copies this page there to tick off.

👤 **You** answer one question: did the old server just die, or might someone have got into it?
- **It just died** (provider fault, deleted, broken update): it reuses your saved keys from Bitwarden. Quickest.
- **It might have been hacked, or you're not sure:** you make new Mullvad and Brave keys, and at the end it lists the other keys to change.

🧯 **If it goes wrong:** if Open WebUI is down too, this is the wrong guide. Tell the agent to use `START-HERE.md`.

### V1 · A new server

👤 **You,** in the IONOS control panel:
1. If the old server still runs and might have been hacked, power it off. Don't delete it yet.
2. Rebuild it, or order a new VPS, with **Ubuntu 24.04 LTS**, in the UK. The same size as before is safest.
3. Open its remote console and log in as **root**. The panel shows the root password.

✅ **You should see** a prompt like `root@...:~#`. Tell the agent.

### V2 · The setup script

🤖 **The agent** fills in a short setup script with your username, the name `vps` and your PC's public key, then opens it in Notepad for you. The public key is safe to share; it's the half that lets your PC in.

✅ **You should see** Notepad open with the script.

### V3 · Run the setup script

👤 **You:** in Notepad, press **Ctrl+A** then **Ctrl+C**. Paste into the server's root console and press **Enter**. It takes a minute or two. It creates your `liam` account, lets your PC's key in, and installs Tailscale.

✅ **You should see** a line with `SHA256:` in it at the end. Send that line to the agent. It's the server's fingerprint: public, not a secret. **Don't** run the `tailscale up` line yet.

🧯 **If it goes wrong:**
- **The console won't paste:** open your own PowerShell window, run `ssh root@<the server's address from the IONOS panel>`, type the root password, and paste there instead.
- **It says the lock is held:** Ubuntu is updating itself. Wait two minutes and paste again. It's safe to run twice.

### V4 · Tailscale: the same name, the same address

Keeping the old **address** means nothing on your PC or in Open WebUI needs changing.

👤 **You,** on the Machines page of the Tailscale admin console:
1. Find the old **vps** machine and copy its `100.x.x.x` address into Notepad.
2. Its ⋯ menu → **Remove**.
3. In the server's console, run `tailscale up --hostname=vps`, open the link it prints, and connect the machine.
4. Check the new machine is called exactly **vps**, with no `-1`. If not: ⋯ → **Edit machine name**.
5. ⋯ → **Edit machine IPv4**, and paste the old address from step 1.
6. ⋯ → **Disable key expiry**.
7. If the old machine had tags, give the new one the same tags.

Tell the agent when it's done, and whether step 5 worked.

✅ **You should see** the agent report that the new VPS has the address your PC's stack expects.
🧯 **If step 5 isn't possible:** carry on. The agent updates five files on your PC and two Open WebUI settings at V12 instead.

### V5 · Your PC trusts the new server

🤖 **The agent** fetches the new server's key and checks it matches the fingerprint you read out. Only then does it swap the old server's key for the new one in your PC's SSH settings, keeping a copy of the old file.

✅ **You should see** the agent say `ssh vps` now logs in.
🧯 **If the fingerprint doesn't match,** the agent stops. That means something other than your new server answered. Read the fingerprint again from the console (V3); if it still doesn't match, don't go on.

### V6 · Docker, the firewall, and SSH locked to Tailscale

🤖 **The agent** sets the server up as your old one was: Docker at the same versions, the firewall (everything blocked except Tailscale), automatic security updates, and SSH that listens only on Tailscale. This one takes a few minutes.

✅ **You should see** the agent report every check passed. From now on, `ssh root@<public address>` from V3 stops working. That's on purpose.

### V7 · The VPS's settings files

🤖 **The agent** copies every VPS file from the repo into place, with the Tailscale addresses filled in: the VPN container's settings, the firewall guard, SearXNG, the Brave/Jina gateway, Kokoro and the dictation relay. Each file is checked after the trip.

✅ **You should see** one `PLACED new` line per file.

### V8 · The keys

Your answer in V0 picks the path.

**8A · It just died: saved keys from Bitwarden**

👤 **You:** in Bitwarden, open the item with `stack-secrets-<date>.zip`. Save the attachment **straight into `E:\recovery-secrets\`**, not Downloads. Send the agent the SHA-256 from the item's notes.

🤖 **The agent** checks the file against that checksum, then copies just the VPS's key file across, readable only by your `liam` account on the VPS.

**8B · Might have been hacked: new keys**

🤖 **The agent** first makes an empty key file on the VPS, with a fresh SearXNG secret already in it that nobody ever sees. (If you're only changing keys on a VPS that already has them, the file is already there: you replace the six values in part 3.)

👤 **You, part 1, Mullvad:**
1. Log in at mullvad.net with your account number from Bitwarden.
2. In your account's **Devices** list, remove the old VPS's device if it's there.
3. Open the WireGuard configuration generator: https://mullvad.net/account/wireguard-config?platform=linux
4. **Generate a key.** That makes a new device.
5. Location: **Switzerland → Zurich → ch-zrh-wg-003** (the exit).
6. In the advanced settings, turn on **Multihop** and pick the entry: **Sweden → Stockholm → se-sto-wg-202**. Choose IPv4 only if it offers it. Its kill switch option doesn't matter, because the VPS has its own two.
7. Download the file and open it in Notepad. **Don't send it to the agent:** it holds your private key.

👤 **You, part 2, Brave:** at https://api-dashboard.search.brave.com/app/keys, create a new key and copy it into Notepad too. Then revoke the old key.

👤 **You, part 3, typing them in:** open a PowerShell window of your own and run:

```powershell
ssh vps -t nano /home/liam/owui-web-egress/.env
```

After each `=`, paste the value, with no spaces and no quotes:

| Line | What goes after the `=` |
|---|---|
| `VPN_ENDPOINT_IP` | From `Endpoint`, the part **before** the colon |
| `VPN_ENDPOINT_PORT` | From `Endpoint`, the number **after** the colon |
| `WIREGUARD_PUBLIC_KEY` | `PublicKey`, in the `[Peer]` part |
| `WIREGUARD_PRIVATE_KEY` | `PrivateKey`, in the `[Interface]` part |
| `WIREGUARD_ADDRESSES` | From `Address`, only the first part, the one ending in `/32` |
| `BRAVE_API_KEY` | Your new Brave key |

Leave `SEARXNG_SECRET` alone. Save with **Ctrl+O**, **Enter**, then **Ctrl+X**. Close the window and tell the agent "saved". Then delete the Mullvad file with **Shift+Delete**, and close Notepad without saving.

**Both paths end the same way**

🤖 **The agent** checks each of the seven lines has the right shape (length and characters, never the value) and that only `liam` can read the file.

✅ **You should see** seven `ok` lines and `600 liam`.
🧯 **A line says `EMPTY` or `WRONG SHAPE`:** open the file again (part 3) and fix that one line. The usual causes are a space, quotes, or the whole `Address` line pasted in.

### V9 · Do the WireGuard settings match the firewall?

The firewall guard names your Mullvad entry server too, as the one place the VPN may connect to. If the two don't match, the VPN can't connect. Nothing leaks, but search stays down.

🤖 **The agent** compares them without showing either.

✅ **You should see** `MATCH`.
🧯 **MISMATCH:** first check your two `VPN_ENDPOINT` lines against the file's `Endpoint` line. If they're right, Mullvad has changed that server's address, or you picked another one. The agent asks you for just the `Endpoint` line (a public server address, not a secret), updates the guard in the repo with a pull request, and puts the new guard in place.

### V10 · The guard first, then everything else

🤖 **The agent** starts the firewall guard and proves it's loaded **before** anything else runs. Then it downloads every program at the exact version recorded, builds the two it makes itself (Jina Reader is the slow one), and starts the VPN container, SearXNG, Jina, the Brave/Jina gateway, Kokoro and the dictation relay. It waits until all of them report healthy.

✅ **You should see** the agent report it finished with exit code 0.
🧯 **The VPN container never turns healthy:** the keys or the entry server are wrong. The agent checks V8 and V9 again, then the VPN container's log.

### V11 · Proof it's safe

👤 **You:** say OK when the agent asks. Web search drops out for a few minutes during these tests.

🤖 **The agent** proves, one at a time:
1. **Everything runs,** and every service answers only on Tailscale.
2. **Multihop works:** it asks Mullvad's own checker from inside the VPN, which must say "Mullvad, Zurich, `ch-zrh`". A Stockholm answer would mean single hop.
3. **It survives a restart,** with the guard up before Docker.
4. **Kill switch 2:** with the guard broken on purpose, Docker must refuse to start. Then it puts it back.
5. **Kill switch 1:** with the VPN tunnel stopped, every search, page read, proxy, direct connection and DNS lookup must fail. Then it restarts the tunnel and checks search works again.
6. **Nothing answers from the internet** on the VPS's public address.
7. **The VPN side can't reach into your PC:** the VPS itself can reach your PC over Tailscale, but the search services can't.

✅ **You should see** each one reported as passed.
🧯 **The kill-switch test reports a leak:** the agent stops and names it. Don't use web search until it's fixed.

### V12 · Your PC, and a test from Open WebUI

🤖 **The agent,** if the VPS kept its old address, changes nothing on your PC. It runs a search, a page read and a SearXNG search through your PC's relay to prove the whole chain.
If the address changed, it asks before changing five files on your PC and restarting the stack. Then you change two settings in Open WebUI: **Admin Panel → Settings → Audio**, the text-to-speech and speech-to-text addresses.

👤 **You,** in Open WebUI:
1. Ask something that needs a web search, for example "search the web for today's UK headlines".
2. Press the speaker icon under an answer.
3. Press the microphone and dictate a sentence.

✅ **You should see** all three work. Tell the agent which did.

### V13 · A new backup

The backup in Bitwarden still holds the old server's key, and on the new-keys path the old Mullvad and Brave keys too.

🤖 **The agent** makes a new backup ZIP and gives you its path and SHA-256.

👤 **You:**
1. In Bitwarden, open the bundle's item. Replace the old attachment with the new ZIP, and replace the SHA-256 in the notes.
2. Download it back from Bitwarden into `E:\recovery-secrets\roundtrip\`, and tell the agent.

✅ **You should see** the agent say the round trip matches.

### V14 · Log it and tidy up

🤖 **The agent** shows you the list of plain copies of your keys on the PC (the bundle, the new backup's folder, the round-trip copy) and deletes them once you say yes. It skips the Recycle Bin. It adds a row to your AI change log. If V9 changed the guard, it makes sure that pull request is merged.

On the new-keys path, it also lists what else the old server held, so you can change those keys too: the **Groq key** (it passes through the dictation relay) and the **Open WebUI backups** kept on the VPS, which hold your provider keys (OpenAI, Anthropic and the rest).

👤 **You:** once you're happy, delete the old server in the IONOS panel.

✅ **You should see** every row in the progress table ticked. 🎉
