# VoWiFi (WiFi Calling) on a ported ROM

Working WiFi calling — **SIP registration, SMS both ways, and voice calls** — on a
phone whose ROM does not support it, with no modem changes and no platform signing
key.

Ships as a single KernelSU module. Also included: the full porting guide, every
source patch, the build pipeline, and the diagnostic scripts.

> ### ⚠️ Read this before flashing
>
> **The prebuilt module was built and tested on exactly one target:**
>
> | | |
> |---|---|
> | Device | **Redmi K50 Ultra / 12T Pro** (`diting`, `22081212C`) |
> | ROM | **HyperOS 4 port by Coolapk [@江南烟雨断桥殇](https://www.coolapk.com/)** |
> | Android | **17 (API 37)** |
> | Carrier | UK VOXI (Vodafone MVNO, 234-15), roaming, over ordinary WiFi |
>
> **Same device and same ROM?** Flash it and it should work.
>
> **Anything else?** The installer will warn you but still let you try — nothing
> here touches a partition, and you can remove the module again. Expect it *not* to
> work as-is, most likely with the framework never reporting
> `isVowifiEnabled=true`. **[PORTING-GUIDE.md](PORTING-GUIDE.md) is written for
> exactly that case** — it explains which parts are general and what you have to
> rebuild for your own ROM (at minimum, the IMS APK against *your*
> `framework.jar`).
>
> This is not an official build of anything, comes with no warranty, and your
> carrier may forbid it. See [Legal and scope](#legal-and-scope).

## Quick start (matching device)

1. Flash `code/module/vowifi-stack-v6.zip` in the KernelSU manager.
2. **Reboot.** Privileged permissions are evaluated when packages are scanned at
   boot, so they cannot take effect before one.
3. Enable WiFi calling in Settings.
4. Check it: press **Action** on the module in the KernelSU manager, or run
   ```sh
   su -c 'sh /data/local/tmp/phh_status.sh'
   ```

A healthy idle state looks like: 1–2 established sockets plus 1 listening,
`SAs` non-zero split across two `reqid`s, `dangling: 0`, `capabil.: 11`.

If `SAs` is 0, the tunnel never came up. If `capabil.` is not `11`, the IMS service
is not reaching the framework — check `/data/local/tmp/vowifi_stack_boot.log` for
permission warnings.

## What it actually does

Four things have to be true, and they are **independent** — most time lost on this
kind of project comes from confusing one for another:

| | What | Provided by |
|---|---|---|
| 1 | Build an IPsec tunnel to the carrier's ePDG (IKEv2 + EAP-AKA) | AOSP `Iwlan`, ported |
| 2 | Convince the framework IMS belongs on WLAN, not cellular | a minimal `QualifiedNetworksService` |
| 3 | Speak SIP/MMTEL inside that tunnel | [phh's floss-ims](https://github.com/phhusson/ims), patched |
| 4 | Get the framework to bind *your* service as MMTEL | carrier-config overrides |

**The insight that makes it possible:** on a Qualcomm device the modem normally owns
all four and you cannot reach into it. But Android's telephony framework lets a
carrier app take over each one — `ImsResolver` will bind an arbitrary package as the
MMTEL provider, and `IwlanDataService` is ordinary AOSP Java. So the whole stack
moves to the application processor and the modem is left out of it. That is why this
works on a device whose modem refuses.

## Status

| | |
|---|---|
| SIP registration over a real ePDG tunnel | ✅ verified, survives the hourly P-CSCF reconnect |
| Inbound SMS | ✅ verified |
| Outbound SMS | ✅ verified to `RP-ACK` |
| **Outgoing calls** | ✅ **verified** — connected, two-way AMR audio, correct call timer |
| **Incoming calls** | ⚠️ the bug that broke them is found and fixed, **but the fix has not been re-tested with a real inbound call** |

Everything above is one device and one carrier. The framework mechanisms are
general; the specific values are not.

## Repository layout

```
PORTING-GUIDE.md              the actual guide: architecture, phase order,
                              and every trap that cost us time
docs/carrier-voxi-uk.md       one carrier's concrete values, as a worked example
docs/module-internals.md      how the module works and why service.sh exists

code/module/                  the KernelSU module (+ prebuilt zip)
code/patches/                 all source changes to floss-ims, one patch
code/build/                   build pipeline: aapt2 → javac/kotlinc → d8 → sign
code/minqns/                  minimal QualifiedNetworksService (source)
code/diagnostics/             health / status / watchdog + test scripts
```

`code/patches/floss-ims-local.patch` states its exact upstream base commit and has
been verified to apply with **zero fuzz** and to round-trip to the source the working
APKs were built from. Its header lists every change and the reason for it.

## If you want to adapt this to your device

Start with [PORTING-GUIDE.md](PORTING-GUIDE.md). The short version of what is
device-specific:

- **The IMS APK must be rebuilt against your ROM's `framework.jar`.** Vendor
  framework signatures differ from AOSP — HyperOS's
  `notifyCapabilitiesStatusChanged` takes a different parameter type, and that call
  is what tells the framework the stack can do WiFi calling.
- **`targetSdk 28` is load-bearing**, not an accident. It is what makes the
  `MAX-TARGET-O` hidden APIs reachable. We burned six build iterations on reflection
  before realising one packaging line replaced all of it.
- **Your carrier's ePDG/IMS values come from the SIM and carrier config**, not from
  this module. `docs/carrier-voxi-uk.md` shows what to look for.

And before porting anything, check whether you need to at all — a ROM whose IMS
stack works but is merely disabled by carrier config is a much smaller problem. The
guide opens with how to tell.

## Credits

- **[phhusson/ims](https://github.com/phhusson/ims)** — the floss-ims MMTEL/SIP
  implementation this builds on. Without it none of this exists. GPL-2.0.
- **AOSP `packages/services/Iwlan`** — the ePDG/IKEv2 implementation. Apache-2.0.
- **Coolapk @江南烟雨断桥殇** — the HyperOS 4 port for `diting` that this targets.
- The patches and integration work here are ours; see the patch header for what
  each change is and why.

Nothing here is novel research. AOSP Iwlan, floss-ims and the carrier-config
override mechanism all pre-date this work. What is written down is the integration
and the failure modes.

## Legal and scope

- floss-ims is GPL-2.0; the patch in `code/patches/` is a derivative and carries the
  same licence. Our own scripts and the module are provided under GPL-2.0 as well
  for simplicity.
- **Not included, deliberately:** signing keystores, an `android.jar` with hidden
  APIs, and any `framework.jar`/dex extracted from a ROM. You need your own ROM's
  framework jar anyway, and redistributing a vendor's is not ours to do.
- **No IMSI, ICCID or phone numbers** appear anywhere in this repo; they were
  scrubbed from patch comments and replaced with placeholders.
- **Your carrier may prohibit this.** Ours states that WiFi Calling while roaming is
  "prohibited and not supported" — which also means **billing behaviour is
  undefined**. Measure it rather than reasoning from the rate card; we have a
  measured example in `docs/carrier-voxi-uk.md`, including one case where our
  reasonable inference was simply wrong.
- No warranty. This modifies how your phone places calls, including potentially
  emergency calls. Understand that before relying on it.
