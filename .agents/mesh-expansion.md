# Where the Mesh Is Expanded

## Problem

A profile runs on every device of a mesh, so none of them can name itself in it. The `mesh:` block was
introduced for that: the block carries the directory coordinates and a device list, and each device
expands it into the listener it serves and an outbound per peer. The core does the expanding, which
keeps the mechanism in one place - but the core cannot tell which device it is, and it needs that to
answer one question: **which port do I serve on?**

The first attempt answered it by requiring every device entry to name the same port. That works until
two devices need different ports, which is exactly what happened when one device's port collided with
a service the host already ran: the colliding device has to move and the others do not, and a rule
that every entry must agree makes a one-device-at-a-time migration impossible. Worse, the failure is
total and quiet: the parse refuses the whole file, so the node binds nothing, the app's window still
opens, and the generated config is left truncated.

So the choice was: move the expansion to the app, which knows its own device id and can therefore name
per-device ports, or teach the core which entry is its own.

## Decision

**Keep the expansion in the core, and let it recognise itself.**

The app-side expansion was tried and reverted. What it costs is not obvious until it is written down:

- **The derivation has to exist twice.** The uuid and the VLESS Encryption pair are derived from the
  directory token by `sha256` over a prefixed token, with the digest clamped as an X25519 private key.
  Moving the expansion to the app means reimplementing that derivation in Dart (and, for a hub that
  answers the credentials over HTTP, in the Worker too). Two implementations of the same derivation
  have to stay byte-identical forever, and the failure when they drift is a TCP connection that
  completes and then dies in the handshake **with nothing in either log** - the single most expensive
  failure mode this system has. The core can derive; the app cannot; so the derivation belongs where
  the capability is.
- **A device that runs the core without the app becomes a special case.** A gateway node runs mihomo
  directly and has no app to expand anything. Under app-side expansion it cannot express a mesh at
  all: its config has to spell out the credentials and every peer by hand, and it stops following a
  device renamed on the dashboard. The core-side expansion keeps that node's profile the same two
  lines as everyone else's.
- **The port question is answerable in the core.** The block already carries `directory-id` - the id
  this device reports under - because the app has to tell the directory who is reporting. The entry
  whose id equals it is this device, so the entry names the port this device serves on, and every
  other entry names the port that peer is dialled at.

The core-side expansion is therefore a strictly smaller change: `meshPort` returns the port of the
entry matching `directory-id`, and each peer keeps its own port instead of being handed the single
settled value.

What must not change:

- the profile stays `directory-url` + `directory-token` (plus `directory-id`, which is per device);
- one implementation of the derivation, in the core;
- the ports are per device, so devices migrate one at a time;
- a profile that names no `directory-id` keeps working under the old rule - all entries agree - since
  nothing else can say which entry is this device.

## Ports

`meshPort` picks the port this device serves on:

| profile carries | port this device serves on |
|---|---|
| an entry whose id is `directory-id`, with a port | that port |
| no `directory-id`, entries agreeing on a port | that port |
| neither | `meshDefaultPort` (23333) |

`meshPeers` then gives each peer the port **its own** entry names, falling back to the settled one for
an entry that names none. A port a host already uses is no longer a reason to move every device: the
one that collides moves, reports its new port to the directory, and the others keep dialling the entry
they already had.

## Why the app still knows about the mesh

The app does not expand anything, but it does two things the core cannot:

- it computes the per-device id from the machine id and writes it as `directory-id`, because the id is
  a property of the device and not of the shared profile;
- it carries the name and the system the directory should show (`device-name`, `device-os`), which a
  phone cannot read from its own host name.

Both are per-device facts written into a shared file at load time, which is the shape the block was
designed around.
