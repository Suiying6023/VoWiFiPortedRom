# Getting VoWiFi (WiFi Calling) working on a ported ROM

This is a field report plus working code from making WiFi calling — **registration,
SMS both ways, and voice calls** — run on a phone whose ROM does not support it.

Reference device: Redmi K50 Ultra running a ported HyperOS / Android 17, UK VOXI
eSIM, physically located outside the UK. But **the hard parts are not specific to
that combination**, and this document is organised so you can tell which parts are
general and which are ours.

## Read this first: do you actually need any of this?

Try the cheap things before porting anything:

1. **Is your ROM's own IMS stack simply disabled by carrier config?** Check
   `dumpsys carrier_config` for `carrier_volte_available_bool`,
   `carrier_wfc_ims_available_bool`, `carrier_wfc_supports_wifi_only_bool`. If your
   ROM has a working IMS service and the carrier config just says no, overriding a
   few keys is the whole job. That is a completely different (and much smaller)
   problem than what this document describes.
2. **Does your ROM ship a real `ims.apk`?** Many ported ROMs ship a stripped one
   that explicitly refuses IWLAN voice. `dexdump`/`jadx` it and grep for
   `VOICE_OVER_WIFI`. If the string is absent, the ROM's IMS will never offer WiFi
   calling no matter what you configure.
3. **Does a modem-side toggle exist?** Some devices have engineering menus or MBN
   configs that enable it. Worth ten minutes before committing to a port.

You need this document only when **the ROM's IMS stack cannot do WiFi calling and
cannot be made to** — at which point the answer is to replace the pieces.

## The architecture, and the one insight that matters

Four things must be true, and they are **independent**. Most of the time lost on
this kind of project comes from confusing one for another.

```
1. TUNNEL     something must run IKEv2/EAP-AKA against the carrier's ePDG
              and build an IPsec tunnel                        -> AOSP Iwlan
2. ROUTING    the framework must believe IMS should go over WLAN, not cellular
                                                               -> QualifiedNetworksService
3. SIGNALLING something must speak SIP/MMTEL inside that tunnel -> phh floss-ims
4. IDENTITY   the framework must bind YOUR service as the MMTEL provider
                                                               -> carrier config override
```

**The decisive insight of the whole project:** on a Qualcomm device the modem
normally owns all four, and you cannot reach into it. But Android's telephony
framework lets a *carrier app* take over each one — `ImsResolver` will bind an
arbitrary package as the MMTEL provider, and `IwlanDataService` is ordinary
AOSP Java. So you move the whole stack to the application processor and leave the
modem out of it. That is why the approach works on a device whose modem refuses.

### The hard judgement criterion

Almost every log line lies to you at some point in this project. **These do not:**

```sh
ip xfrm state      # non-empty = an IPsec SA really exists
ip xfrm policy     # the kernel really will route through it
ip -s xfrm state   # non-zero counters both ways = it is really being used
```

`dumpsys` will happily report `isVowifiEnabled=true` while nothing works, and the
radio log will show hopeful-looking messages for a stack that is dead. Trust
`ip xfrm` and packet counters; treat everything else as a hint.

**`reqid` in `ip xfrm state` is the owning uid.** With the three components as
separate packages, this is what tells you whether an SA belongs to the tunnel
(Iwlan) or to SIP's sec-agree (your IMS service) — the single most useful
diagnostic here, and a reason not to merge them into one APK.

## Phase order, with acceptance criteria

Do these in order. Each one has a test that either passes or does not — no
"looks right".

| # | Phase | Done when |
|---|---|---|
| 1 | Port AOSP Iwlan, install as priv-app | `ip xfrm state` non-empty after enabling WiFi calling |
| 2 | QualifiedNetworksService reports IWLAN for IMS | log shows `onQualifiedNetworkTypesChanged ... networks = [IWLAN]` |
| 3 | Your IMS service gets bound as MMTEL | your service's `createMmTelFeature` runs |
| 4 | Capabilities reach the framework | `isVowifiEnabled=true` **and** `ImsPhoneCallTracker` agrees |
| 5 | SIP REGISTER succeeds | `200 OK`, and `ip -s xfrm state` shows ESP both ways |
| 6 | SMS | inbound arrives; outbound gets `RP-ACK` |
| 7 | Voice | `200 OK` on INVITE + RTP flowing both directions |

If a phase fails, the fix is almost never in a later phase. Go back.

## What actually cost us time — read these before starting

### Deployment: privileged permissions are a scan-time decision

Your IMS service needs `CONNECTIVITY_USE_RESTRICTED_NETWORKS` (IMS is a restricted
capability, so `requestNetwork` is **silently** refused without it) plus
`READ_PRIVILEGED_PHONE_STATE` and `MODIFY_PHONE_STATE`. Iwlan needs
`MANAGE_IPSEC_TUNNELS`.

Those are privileged permissions: they are granted only to an app in `priv-app`
**with a matching allowlist XML**, and they are evaluated when the package is
scanned at boot. Consequences that each cost us a debugging round:

- **A `/data/app` install can never hold them.** You need a `priv-app` base.
- **A same-signature `/data/app` update on top of a `priv-app` base is fine** and
  lets you iterate without rebooting — but the **permission set comes from the
  base's manifest**, so adding a permission means updating the base and rebooting.
- **The package manager caches the parsed manifest by directory.** Replacing the
  APK in place is not enough — after a reboot it still reported the old
  `targetSdk` and old permissions. **Rename the containing directory** to force a
  rescan.
- **SELinux label matters.** An APK left as `adb_data_file` is silently ignored at
  boot. `chcon u:object_r:system_file:s0`.

### hidden API: check whether you can lower targetSdk before writing reflection

We burned six build iterations on increasingly elaborate reflection to reach a
`MAX-TARGET-O` member, including trying to self-exempt via `VMRuntime` (which is
itself blocked). The actual solution was **one line of packaging: targetSdk 28**.
Below API 29 the blocklist is a warning, not a wall.

**Look at targetSdk first. It is one line and it beats five rounds of reflection.**

### Vendor framework signatures differ from AOSP

HyperOS's `notifyCapabilitiesStatusChanged` takes a different parameter type than
AOSP's. Compile against your ROM's actual `framework.jar`, not the SDK, and expect
to need a small Java shim to reach protected members without tripping the
blocklist. **Do not assume AOSP source matches your vendor's binary.**

### Carrier config overrides live in a runtime cache, not a file

The keys that redirect the framework to your components are in
`/data/user_de/0/com.android.phone/files/carrierconfig-<ICCID>-<mccmnc>.xml`, and
the platform **rebuilds it**. So you cannot ship them as a file overlay — you need
a boot script that re-injects them. See `code/module/service.sh`.

They come in **(package, class) pairs**. Injecting half a pair silently leaves the
framework on the stock component, which looks exactly like "my change did nothing":

```
carrier_data_service_wlan_{package,class}_override_string      -> Iwlan
carrier_network_service_wlan_{package,class}_override_string   -> Iwlan
carrier_qualified_networks_service_{package,class}_override_*  -> your QNS
config_ims_mmtel_package_override_string                       -> your IMS service
```

## The client-side bugs you will hit

`phh/floss-ims` is the only free MMTEL implementation we know of, and it works —
but it was written against a specific carrier and **assumes the process lives
exactly as long as one connection**. Everything in `code/patches/` falls out of
that. The patch header lists each fix; these are the ones worth knowing about
before you start, because they are *classes* of bug, not one-offs:

**The registration dies but the process lives.** The main socket's read loop
discarded the "this socket is finished" return value, so when the P-CSCF closed
the connection (hourly, for us) the reader spun at 100% CPU forever. Process alive,
no crash, logs scrolling — and no working registration. **Adding reconnect logic is
the fix, but see the next point.**

**Adding reconnect to code that never reconnected wakes up a whole family of
bugs.** The original author could reasonably not free resources, cache objects in
fields, and `return` on failure paths — because process lifetime *was* connection
lifetime. Once you reconnect, those become: leaked IPsec SAs (sec-agree SAs carry
no lifetime, so the kernel never reclaims them), coroutines serving the wrong
generation of object, and a full resource leak per failed attempt.
**When you add reconnect, draw the "connection" and "process" lifetimes separately
and ask of every field: is it still correct after a reconnect?**

**Long-lived threads must not read fields that get reassigned.** A
`while (true) { serverSocket.accept() }` loop that outlives its connection starts
serving the *new* listener and races the fresh reader for the same messages.
Capture the object in a local and gate on a generation counter. This race does not
error — it intermittently loses messages, which may be an incoming call.

**Bare threads: an uncaught exception kills the whole process.** We added resource
cleanup to the media threads and introduced a crash, because the try did not cover
the loop *before* the main loop. A crash is far worse than the leak it replaced —
the leak wastes memory, the crash drops the registration. **Cover the entire thread
body.**

**Protocol fields with direction are a trap.** RFC 3312's `local`/`remote` in SDP
are from the *sender's* viewpoint, so in a message the peer sends you, `local`
means *them*. Reading it literally made us do nothing when the network was waiting
for our confirmation, and the call failed with `580 Precondition Failure`.

**Never answer by editing the peer's message and sending it back.** SDP contains
the connection address and port — echoing it advertises *their* address as yours.
We got `403 Forbidden` for that.

**Same file, right and wrong versions side by side.** The outgoing SDP builders
used the correct `o=- 1 2 IN IP4 ...`; the incoming one had `o=<imsi> 1 2 ...` —
five fields where RFC 4566 requires six. Every incoming call was cancelled by the
network with `Reason: ...text="Invalid SDP"`. **When reviewing one protocol
construction, diff it against every sibling in the same file.**

**Watch for state that nobody resets.** After we made every teardown path set a
"stopped" flag, nothing cleared it when a new *outgoing* call started (the incoming
path always did). The next call's encode thread saw it already set and skipped
opening the microphone: connected, one-way audio. **The signature "first call after
restart is fine, second is broken" almost always means leftover cross-call state.**

## Monitoring: the criteria are harder than they look

`code/diagnostics/` has our scripts. The lessons behind them generalise:

**"The process is running" proves nothing.** A dead registration keeps the process
alive. Check several independent things: your own process's established sockets,
its *listening* socket, CPU ticks, log growth rate, whether the refresh alarm is
queued, and dangling IPsec policies.

**A monitor must distinguish "broken" from "busy".** We used "log grows >300
lines/3s" to detect the spin loop — but a normal voice call also logged ~100
lines/second, so the watchdog force-stopped a working 3m35s call. **Before shipping
a threshold, ask what that metric reads during the system's busiest healthy state.**
Better still, reduce the monitored program's noise (log the stream once, not each
packet) instead of raising the threshold.

**Automatic recovery needs a veto.** The watchdog now refuses to force-stop while a
call is up: no fault it can detect is worth dropping a call. **Make the remedy's
destructiveness proportional to the fault.**

**Hardcoded identifiers in monitoring scripts are time bombs**: a uid (`u0a268`
changes on reinstall), a port literal (ephemeral ports move), a peer IP (they
rotate). They do not error when they go stale — they return 0 forever and look like
"this check has always been fine". Derive them: uid from `/proc/<pid>`, sockets
from `ss -tnp | grep "pid=$PID,"`.

**Judge leaks by dangling references, not totals.** Totals move for benign reasons
(dual-stack policies, sockets rebuilt on reconnect). We chased a non-existent leak
for two rounds and shipped an unnecessary release. The real test is "is there a
policy whose SPI has no live SA":

```sh
comm -13 <(ip xfrm state  | grep -oE 'spi 0x[0-9a-f]+' | sort -u) \
         <(ip xfrm policy | grep -oE 'spi 0x[0-9a-f]+' | sort -u)
```

**Also: don't count with `grep -c` until you know how many lines one unit occupies.**
Counting matched *lines* instead of policies gave us a wrong number that supported a
wrong conclusion.

**When two rounds of changes produce no numerical difference, question the
diagnosis, not the fix.**

## Deployment: one KernelSU module

`code/module/` holds a module that installs all three packages plus their
allowlists and re-injects the carrier config on each boot. `uninstall.sh` restores
the carrier config from a backup — **this is not optional**: removing the module
unmounts the APKs but would leave the framework pointed at packages that no longer
exist, potentially leaving the phone with no working IMS at all.

We considered merging the three into one APK. It is technically fine (none of them
depend on `Build.VERSION`, `PendingIntent` mutability, or typed foreground
services, so they can share targetSdk 28) but we chose not to: separate uids are
what make `reqid` attribute IPsec SAs to a component, and they stay independently
switchable for A/B testing. **A module already solves one-step deployment without
giving that up.**

## Working environment traps

- `adb shell "su -c '...'"` **eats `$`, `^` and nested quotes.** This produced a
  silently empty CPU reading, a `grep -c "^src"` that returned 0 and made us think
  the tunnel had dropped, and a `cp` that wrote to `/`. **Put any logic containing
  those characters in a device-side script and have the host read only its output.**
- `pgrep -f foo.sh` **matches the command running it** when invoked through
  `adb shell`, because the wrapper's command line contains the pattern. Anchor on
  the interpreter: `ps -A -o ARGS | grep -c "^sh /path/foo.sh"`.
- `stat /proc/<pid>` is **not** process start time (it is inode mtime). Use field
  22 of `/proc/<pid>/stat`: `age = uptime - starttime/100`.
- After replacing a running daemon, **verify the old one actually died**. Editing
  the file does not affect a process that already loaded it, and `pkill -f` may
  miss. We once had two watchdogs fighting each other.
- Clean `.orig`/`.rej` files before regenerating a patch, or `diff -ruN` writes
  them in as new files. Or use `-x '*.orig'`.
- **Read the peer's stated reason before guessing.** `Reason: ...text="Invalid SDP"`
  and `404 Not Found` each pinpointed a bug immediately. Vague symptoms like "the
  call drops instantly" often have an exact answer in the protocol trace.

## What is in here

```
code/patches/floss-ims-local.patch   all source changes, against a stated upstream commit
code/build/                          build pipeline (aapt2 -> javac/kotlinc -> d8 -> sign)
code/build/AndroidManifest.xml       hand-written manifest: targetSdk 28 + RECORD_AUDIO
code/module/                         KernelSU module: 3 packages + boot-time config injection
code/minqns/                         minimal QualifiedNetworksService (source)
code/diagnostics/                    health/status/watchdog + test scripts
carrier-notes/voxi-uk.md             our carrier's concrete values, as a worked example
```

`code/patches/floss-ims-local.patch` names its exact upstream base commit and has
been verified to apply with zero fuzz and round-trip to the source the working APKs
were built from. Its header lists every change and why.

**Not included, deliberately:** signing keystores, `android.jar` with hidden APIs,
and `framework.jar`/dex extracted from a ROM. You need your own ROM's framework
jar anyway, and it is not ours to redistribute.

## Honest scope

- Voice calls: **outgoing verified working** (connected, two-way AMR audio, correct
  call timer). **Incoming is code-reviewed and fixed but not yet verified end to
  end** — the bug that broke it was found from a real failed call and fixed, but
  the fix has not been re-tested with another inbound call.
- Everything here is **one device, one carrier**. The framework mechanisms are
  general; the specific values are not.
- Nothing here is novel research. AOSP Iwlan, phh's floss-ims and the carrier
  config override mechanism all pre-date us. What is written down here is the
  integration work and the failure modes.
- Your carrier may forbid this. Ours states that WiFi Calling while roaming is
  "prohibited and not supported", which also means **billing behaviour is
  undefined** — measure it rather than reasoning from the rate card.
