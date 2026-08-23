# Carrier notes: VOXI UK (Vodafone MVNO, MCC/MNC 234-15)

A worked example for the main README. **These values are VOXI/Vodafone UK's** — for
another carrier the shapes stay the same and the numbers do not. Included because
seeing one filled-in instance makes it much clearer what you need to find for yours.

Device context: Redmi K50 Ultra, ported HyperOS / Android 17, physically outside the
UK (so roaming), connecting over ordinary WiFi.

## Values you would need to find for your own carrier

| What | VOXI UK value | How to find yours |
|---|---|---|
| MCC/MNC | `234-15` | `getprop gsm.operator.numeric`, or the IMSI's first 5 digits |
| ePDG FQDN | `epdg.epc.mnc015.mcc234.pub.3gppnetwork.org` | standard 3GPP form; substitute your MCC/MNC |
| ePDG addresses seen | `88.82.11.208`, `88.82.11.221`, `148.252.188.96` | resolve the FQDN; **expect several and expect them to rotate** |
| IMS realm | `ims.mnc015.mcc234.3gppnetwork.org` | same 3GPP form |
| SMSC number | `447785016005` | read it from the TS 24.011 field of a real outbound SMS; do **not** hardcode, decode it |
| SMS-SC PSI | `ipsmms1mc05.ims.mnc015.mcc234.3gppnetwork.org` | learn it from the `From:` header of an inbound SMS |
| Registration expiry granted | `3590s` | whatever the `200 OK` to your REGISTER says — **read it, don't assume** |
| Free test number | `191` (Vodafone/VOXI customer service) | your carrier's own free service number |

The last two matter more than they look:

**Registration expiry:** we asked for `Expires: 600000` and the network granted
**3590s**. Upstream refreshed on a fixed 3000s alarm, which sounds safe but is not
once the OS defers the alarm — MIUI's app-standby pushed it out by over 30 minutes
and the binding lapsed. Inbound SMS was then dropped **by the network** with
nothing logged locally. Read the granted value and refresh at half of it, with an
exact alarm.

**SMSC encoding:** the field is TS 24.011 — a length byte, then TON/NPI, then the
number in nibble-swapped BCD. We wasted a version hardcoding the number because we
first mis-read it as "the number is missing a digit". It was not; the decoding was
wrong. `447785016005` above is what correct decoding yields.

## Roaming specifics

- The ePDG SA's local address is **`wlan0` itself**, not a VPN/tunnel interface.
  Consequence: a local HTTP/SOCKS proxy or a VPN app **cannot** intercept this
  traffic — our Iwlan uses the default network and binds its own sockets, so
  proxy logs show zero hits for VoWiFi. We verified this twice from opposite
  directions; do not spend time trying to route it through a proxy.
- The P-CSCF address and even the SIP bearer's address family **change between
  reconnects** (we saw both IPv4 and IPv6, and several P-CSCF addresses). Never
  treat them as constants — in particular, never grep logs or `ss` output by peer
  IP; filter by port or by pid.
- `data_roaming1` (the **per-subscription** key, not `data_roaming`) had to be `1`
  to *establish* the tunnel. It does **not** need to stay 1 — verified running with
  it at 0, tunnel and calls intact. So you need not leave roaming data enabled and
  accrue charges.
- The P-CSCF drops the control connection about **once an hour, on the hour**. That
  is convenient: you do not need luck to test reconnect handling, just wait for the
  next hour boundary.

## Billing, measured — not read off the rate card

**This is the part most worth copying as a method, not as numbers.**

| Action | Result | How known |
|---|---|---|
| Call `191` | **free** | measured |
| Outbound SMS while roaming | **£0.24 per message** | measured (an accidental send) |
| Inbound SMS | free | measured, 3 separate messages |
| Receiving a call, ROW zone 1 | **£0.36/min**, 1-minute minimum | carrier's published table |

The plan includes "unlimited calls and texts" — but that is annotated **UK only**,
and for Rest-of-World zones VOXI requires a Global Roaming Pass (8 days £16 = 100
min / 100 texts / 2GB) before any allowance applies.

We initially reasoned from Vodafone's statement that *"There's no extra charge for
using WiFi calling. All calls and texts are rated as per your price plan"* and
concluded outbound SMS would be free. **That was wrong** — a real message cost
£0.24.

The reason the rate card cannot answer this: Vodafone's own terms say **"The use of
Wi-Fi Calling whilst roaming is prohibited and is not supported."** We are on a path
the carrier does not define, so no table covers it. **Measure with account balance
before and after; do not infer.**

Also note receiving is *not* free here. Do not assume the inbound direction is
free just because inbound SMS is.

## Things that turned out not to be the problem

Recorded because each one absorbed real time:

- **Geo-blocking at the IKE layer.** Our IKE_AUTH completed fine from outside the
  UK — the SA came up with a genuine Vodafone UK ePDG address. The blocker was
  never IKE.
- **Routing VoWiFi through a UK exit.** Two experiments, apparently contradictory,
  reconciled to the same guidance: with a local proxy the traffic never reaches it;
  with an upstream bridge it does reach it and IKE then times out. Either way:
  **do not try to proxy this.**
- **The MBN / modem config.** Not an obstacle for this approach, since the whole
  stack moved to the application processor.
- **`*#*#869434#*#*`** and similar engineering menus do not exist on this ROM.

## One correction worth carrying

An early outbound SMS reached `RP-ACK` and we recorded that as "SMS works". It was
sent to a **mistyped number**. `RP-ACK` proves the signalling path works; it does
**not** prove delivery to the intended recipient. Correct-number end-to-end
delivery is still unverified here (deliberately — it costs £0.24 a try).
