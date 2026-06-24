# Security Policy

LittleLove is an end-to-end encrypted messenger for couples, built by Coding
with Court LLC. Security is the product, so we take reports seriously and we
welcome scrutiny of the code.

## Reporting a vulnerability

**Please do not open a public issue for security problems.** Disclosing a
vulnerability publicly before it is fixed puts users at risk.

Instead, report it privately:

- **Email:** privacy@littlelove.dev
- Or use GitHub's **"Report a vulnerability"** button under the repository's
  Security tab (private vulnerability reporting), if enabled.

Please include enough detail to reproduce the issue: affected component
(client, server, or the crypto layer), version or commit, steps to reproduce,
and the impact you think it has. A proof of concept is helpful but not required.

## What to expect

We are a very small team, so we cannot promise enterprise response times, but we
will:

- Acknowledge your report within a few days.
- Keep you updated as we investigate and fix.
- Credit you when the fix ships, if you would like (let us know).

We do not run a paid bug bounty at this time.

## Scope

Most valuable are issues that affect the confidentiality or integrity of user
data, for example:

- Anything that would let the server, us, or a third party read message
  content, listen to calls, or view shared media (the end-to-end encryption
  guarantee).
- Weaknesses in key generation, key exchange, or the authenticated encryption
  (X25519, Ed25519, HKDF-SHA256, XChaCha20-Poly1305).
- Authentication or pairing flaws (for example, a way to pair with or
  impersonate someone you are not).
- Ways for one partner to act on another's behalf without authorization.
- Server-side issues that expose metadata beyond what is necessary to route
  messages.

Out of scope: reports that require a fully compromised or jailbroken device,
social engineering of a user, or physical access to an unlocked phone.

## Coordinated disclosure

We ask that you give us a reasonable chance to fix an issue before disclosing it
publicly. We are happy to coordinate timing and to acknowledge your work once a
fix is released.

## Verifying our claims

The source is public so anyone can check how LittleLove handles your data. The
encryption and message-routing code is the right place to start if you want to
confirm that the server only ever sees ciphertext it cannot read.
