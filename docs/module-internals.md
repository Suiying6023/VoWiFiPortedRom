# VoWiFi stack — KernelSU module

Deploys the whole WiFi-calling stack in one flash: **registration, two-way SMS,
and voice calls**, all verified working on a Redmi K50 Ultra running a ported
HyperOS / Android 17 with a UK VOXI eSIM.

## What's inside and why it's three packages, not one

| Package | Role | uid / `reqid` |
|---|---|---|
| `com.google.android.iwlan` | AOSP Iwlan — builds the ePDG IPsec tunnel | tunnel SAs |
| `me.phh.ims` | phh floss-ims — SIP, MMTEL, SMS, voice media | sec-agree transport SAs |
| `com.voxi.minqns` | minimal QualifiedNetworksService — tells the framework "IMS goes over IWLAN" | — |

Merging these into a single APK is technically possible (checked: no
`Build.VERSION`, `PendingIntent` or foreground-service dependency anywhere, so
they can share targetSdk 28) but **deliberately not done**. Separate uids are
what make `ip xfrm state`'s `reqid` field distinguish tunnel SAs from transport
SAs, and that is the single most useful diagnostic in this project. They also
stay independently switchable for A/B testing. One module already solves the
"deploy in one step" problem without giving that up.

## Install

Flash in the KernelSU manager, then **reboot** — privileged permissions are
evaluated from the priv-app manifest when the package is scanned at boot, so
they cannot take effect before one.

After boot, check what happened:

```sh
su -c 'sh /data/local/tmp/phh_status.sh'      # one screen, whole stack
cat /data/local/tmp/vowifi_stack_boot.log     # what service.sh did
```

A healthy idle state looks like: 1–2 established sockets, 1 listening, `SAs: 6`
split across two `reqid`s, `dangling: 0`, `capabil.: 11`.

## The part that is not a file overlay

Three APKs and two privapp allowlists are a plain `system/` overlay. The seven
**carrier-config overrides are not** — they live in `com.android.phone`'s runtime
cache under `/data/user_de/0/com.android.phone/files`, in a file whose name
contains the SIM's ICCID, and the platform rebuilds it. So `service.sh` waits for
boot plus 30s and re-injects them each boot. It derives the filename by glob
rather than hardcoding the ICCID, keeps a `.bak.vowifi_stack` copy, skips the
write when the keys are already present, and refuses to commit if its own edit
does not look right.

The keys come in **(package, class) pairs** — injecting half a pair silently
leaves the framework on the stock component, which looks like "the module did
nothing".

## Uninstall

`uninstall.sh` restores the carrier config from that backup. This matters: simply
deleting the module unmounts the APKs but would leave the framework pointed at
packages that no longer exist, which can leave the phone with **no working IMS at
all**.

## What this module does NOT do

- It does not configure your carrier's ePDG address, APN or IMS APN — those come
  from the SIM and the carrier config, and they are carrier-specific.
- It does not enable the watchdog. `service.sh` will start
  `/data/local/tmp/phh_watchdog.sh` only if you put it there yourself, because
  that script can `force-stop` the IMS service and that is not a decision a
  module should make for you.
- It does not touch `data_roaming`. Worth knowing: the tunnel was established
  with `data_roaming1=1`, but it **keeps running with it at 0** — verified — so
  you do not need to leave roaming data on and accrue charges.

## Billing, measured not assumed

- Calls to `191` (Vodafone/VOXI customer service): **free**, confirmed.
- Outbound SMS while roaming: **charged**. One message cost £0.24 — it does not
  come out of the plan's "unlimited UK texts", which is UK-only.
- Inbound SMS: free.
- Vodafone's own terms say Wi-Fi Calling while roaming is "prohibited and not
  supported", so this is an undefined-by-the-carrier path. Do not assume plan
  allowances apply; measure before relying on it.

## Built from

`floss-ims-local.patch` against `github.com/phhusson/ims` commit `c180bdf`
(note: the repo is `phhusson/ims`, not `phhusson/floss-ims`). The phh APK here is
v39. Voice needs `targetSdk 28` (for the MAX-TARGET-O hidden APIs) **and**
`RECORD_AUDIO`, both of which come from the hand-written manifest in the build
pipeline, not from the patch.
