# Tailnet Peer Outbound

## Problem

Two nodes of the same deployment need to reach each other's services directly - the phone's RustDesk
client reaching RustDesk on the PC's TCP port 23333 is the driving case - while:

- underlay addresses change without warning: the ISP re-delegates the home IPv6 prefix, and the
  phone moves between Wi-Fi and cellular;
- the shared Clash profile cannot carry a dynamic address: whatever the subscription contains is
  fixed until the next refresh, and DDNS lags the address change by minutes;
- the phone cannot accept inbound connections on cellular, so only the phone can start a
  connection.

Tailscale's own direct path needs UDP in both directions, which these networks do not provide, and
the relay it fell back to is what carried the traffic. What that deployment actually used tailscale
for is the directory half: "peer X is currently at <address>", refreshed in seconds.

## Decision

Keep the directory, drop the tunnel it came with. Two mihomo outbounds carry the feature, and every
protocol detail stays in mihomo:

- `peer-directory` publishes this node's current address to a directory service, and answers where
  the other ids are;
- `tailnet-peer` carries an inner proxy configuration (`proxy: {type: vless, ...}`) and replaces its
  `server` and `port` for each connection with the address the directory reports for that peer.

What travels on the wire is whatever the inner protocol sends - for this deployment, VLESS
Encryption, which is TCP-only, needs no certificate, and keeps the payload confidential between the
two nodes. The node that is reachable (the PC) also runs the matching `listeners:` entry
(`type: vless`, `decryption: ...`); the services behind it - RustDesk on 23333, a LAN admin panel -
never need to be reachable from the internet.

The directory is a Cloudflare Worker (`BraveSail/peer-directory`): `POST /report` records the
address a node publishes, `GET /lookup` answers for one or many ids, `GET /watch` pushes changes over
a WebSocket, and a record is kept until the node changes it (a week without a report expires it).

## Address source

The address is the node's own claim, not something the service infers:

- the report carries the smallest global unicast IPv6 address the node finds on a real interface;
  ULA, link-local, loopback and private addresses are refused, and a report with no address leaves
  the stored one in place;
- the worker never records the address a request came from, so a report that travelled through a
  proxy cannot publish the proxy's address;
- a report leaves the machine only when the address it would publish changed, so the directory is a
  change log rather than a heartbeat;
- `injectNetworkChange` - the app's connectivity callback, an interface switch or a reconnected VPN -
  republishes immediately instead of waiting for the next polling pass;
- `tailnet-peer` resolves through a short cache, and when the directory is unreachable it keeps
  using the address it saw a moment ago rather than failing every dial.

## Naming

A device is named once. `directory-id` is the name this node reports under, and the profile's
`directory-id-by-platform` map (keyed by `runtime.GOOS`: `windows`, `android`, `linux`, `darwin`)
gives every device its own name without a per-device setting; the app's own name, when set, wins
over the map. `directory-peer` is the name this outbound asks for, defaulting to `peer`.

A peer whose name is this node's own name degrades to `DIRECT`, so the entry that dials "pc" on the
PC reaches the local service instead of dialing itself through the listener.

## One profile for every device

The deployment shares a single subscription across all devices, so the profile has to be correct on
every node without per-device edits: the profile lists one `tailnet-peer` outbound per node, each
carrying the directory inline (`directory-url`, `directory-token`) plus the platform map, and one
shared `listeners:` entry. Every node therefore both serves its peers and can reach the others, and
no device needs a directory name in its own settings.

Keys are shared on purpose: one VLESS Encryption server key fills every node's listener
`decryption`, and one derived client key fills every outbound's `encryption`, so any node can reach
any other node with the same profile.

## Invariants

- The outbound never dials an address that did not come from the directory, and never a port other
  than its own `port`.
- A peer that is this node degrades to `DIRECT` instead of dialing itself through the listener.
- It never rewrites the profile or the inner proxy's own options: only `server` and `port` are
  substituted.
- Only the node running the listener needs an inbound port. The dialing node adds none, and a peer
  behind cellular is reachable in the direction it started.
- One directory client per (url, token, id, port) is shared by every outbound that names it, so a
  node reports itself once however many peers the profile lists.

## Exposure

Only the listener side is reachable from the internet, and what answers there is the inner protocol
- VLESS Encryption in this deployment - so the port carries ciphertext and authenticates the client
by UUID before any payload is accepted. Services behind it stay private: RustDesk's 23333 can be
firewalled to the LAN, and nothing about this design asks for a public business port.

## Out of scope

- UDP mappings. RustDesk's direct path is TCP; a UDP mapping needs a session table first.
- Relay fallback. When a peer's address is unreachable the connection fails; routing it through a
  VPS relay is a later addition behind the same interface.
- Hole punching. Neither side of this feature changes how the underlay paths are chosen.

## Testing

- Unit: the directory registry (a replacement is kept, every directory sees a network-change
  injection), address selection, the shared directory client, resolution through an inline
  directory, the self shortcut, and the loopback path a self peer dials.
- Manual: with the PC's RustDesk on TCP 23333, the phone dials its own rule for `pc` on cellular and
  reaches the PC; moving the PC to a new IPv6 prefix is picked up by the next connection.
