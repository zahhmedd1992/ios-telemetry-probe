# Runbook — getting the probe onto your iPhone from Windows

Every step below was verified against current (2026) sources, not from memory. Where a step exists
only to avoid a specific known failure, the failure is named — skipping it produces an error whose
message will not tell you what you did wrong.

**Time: about 25 minutes the first time, 2 minutes every time after.**

---

## One-time setup on the Windows PC

### 1. Install iTunes and iCloud — from apple.com, NOT the Microsoft Store

This is the single most common cause of "it just doesn't work."

The Microsoft Store builds of iTunes and iCloud are sandboxed, and the sandbox hides the folder
where Apple's *anisette* authentication data lives. Sideloadly then fails with **"invalid anisette
data"** or a generic connection error, and nothing in that message points at the Store.

- If you already have the Store versions: uninstall them first.
- Install from `apple.com/itunes/download/win64` and `apple.com/icloud/download` (the web installers).

### 2. Install Sideloadly

From `sideloadly.io` (v0.60.0 or later). Windows 10/11.

### 3. Pick one machine and one tool, permanently

A free Apple ID has a very small code-signing certificate budget. Signing the same app from a
second computer, or with a second tool, can make Apple issue a new certificate and **revoke the old
one** — which instantly breaks every app signed by it and forces you to re-trust on the phone.

This laptop + Sideloadly is the signer of record. Don't casually add AltServer on another machine.

---

## Installing the probe

### 4. Get the IPAs

They're already downloaded to `ipa/` in this project folder. (They also live as artifacts on the
GitHub Actions run, for 30 days.)

Four files, same app, escalating entitlements:

| File | Entitlements | What it tests |
|---|---|---|
| `Probe-tier0.ipa` | none provisioned | should always install — proves the toolchain works |
| `Probe-tier1.ipa` | HealthKit + App Groups | **the $99 question** |
| `Probe-tier2.ipa` | + Wi-Fi info, Family Controls, SensorKit | expected to fail; the error is the finding |
| `Probe-unsigned.ipa` | none at all | control, only if the others misbehave |

### 5. Sideload **tier0** first

1. Plug the iPhone in with a cable. Unlock it. Tap **Trust This Computer** if asked.
2. Open Sideloadly. Drag `Probe-tier0.ipa` onto the window.
3. Enter your **Apple ID**. Use the real password plus 2FA — app-specific passwords only work on
   *paid* developer accounts, so a free account must use the real one. Sideloadly sends credentials
   to Apple only.
4. Click **Start**. Wait for "Done".

### 6. Trust the certificate on the phone

**Settings → General → VPN & Device Management → Developer App → Trust.**

You're trusting the certificate, not the app, so weekly refreshes won't re-prompt.

### 7. Run it and save the report

Open **Probe**, tap **Run full probe**, and **grant every permission prompt** — there will be many.
A denial is recorded as a denial, which is a different (and less useful) result than a missing
capability.

When it finishes, tap **Share** and AirDrop/email the JSON to yourself. **Do this before installing
the next tier** — all four IPAs share one bundle ID, so each install replaces the last.

### 8. Repeat for tier1, then tier2

Same steps. What happens is the finding:

| What you see | What it means |
|---|---|
| Installs and HealthKit prompts appear | HealthKit works on a free Apple ID — you don't need the $99 |
| **`0xe8008016`** / "Entitlements are not valid" | The signer kept an entitlement your free profile refuses. That capability needs the paid account. |
| Installs fine, but the API fails at first use | The signer silently *stripped* the entitlement to match the profile. Same conclusion, quieter failure. |
| Sideloadly errors before install | Read the message — it usually names the offending capability |

Tier2 is *expected* to fail. That failure is worth ten minutes because it's cheaper to be told "no"
by the signing toolchain than to design an architecture around a capability we can't have.

---

## The 7-day problem

A free Apple ID's provisioning profile expires after **7 days**. For a normal app that's an
annoyance. For this one it's the central design problem, because:

- The app stops launching — "Unable to Verify App", icon greys out.
- **Background collection stops silently.** Background wake-ups work by iOS *relaunching* the app,
  and that relaunch fails against an expired profile with no error, no notification, nothing. You
  find out days later from a hole in the data.

Mitigations, in order:

1. **Re-sign weekly.** Plug in, drag the IPA onto Sideloadly, Start. Two minutes. Your data is
   preserved as long as you use the *same* Apple ID — the container is keyed to bundle ID plus your
   Team ID, so a same-ID reinstall keeps everything and a different-ID reinstall wipes it.
2. **The app alarms on its own staleness.** Every background wake writes a heartbeat row, and gaps
   are recorded as explicit facts rather than as absence of data.
3. **$99 makes it a year instead of a week.** This is the real argument for paying — more than any
   individual entitlement.

---

## Budget limits you can actually hit

| Limit | Value | Why it matters here |
|---|---|---|
| Apps installed at once | **3** | The probe is 1. Keep two slots free. |
| App IDs registered | **10 per rolling 7 days** | All four IPAs share one bundle ID, so the ladder costs ~1. But **every app extension consumes its own App ID** — an app plus widget plus Watch app can burn 4–5 in one install. Design for one extension, or zero. |
| Test devices | 3 per platform | Not a constraint for you. |

---

## What is dead regardless of money

- **TrollStore** — would have solved permanent signing, the 7-day expiry, and arbitrary entitlements
  in one move. It only ever worked up to iOS 17.0 and will never support 17.0.1+. Your phone can't
  use it. Don't plan around it.
- **Push notifications** — `aps-environment` cannot be provisioned on a free Apple ID. Verbatim
  Apple error: *"Personal development teams do not support the Push Notifications capability."*
  This also kills silent-push background wake-ups on the free tier.
- **Screen Time / Family Controls** — requires an explicit approval request to Apple **even on a
  paid account**, and Apple lists the capability as development-only. This is not a $99 question;
  it's unavailable either way. Per-app usage has to come from Shortcuts automations instead.
