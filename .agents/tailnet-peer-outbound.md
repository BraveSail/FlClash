# Tailnet Peer Outbound

## Problem

Two nodes of the same tailnet need to reach each other's services directly - the phone's RustDesk
client reaching RustDesk on the PC's TCP port 23333 is the driving case - while:

- underlay addresses change without warning: the ISP re-delegates the home IPv6 prefix, and the
  phone moves between Wi-Fi and cellular;
- the shared Clash profile cannot carry a dynamic address: whatever the subscription contains is
  fixed until the next refresh, and DDNS lags the address change by minutes;
- the phone cannot accept inbound connections on cellular, so only the phone can start a
  connection;
- tailscale's own direct path needs UDP in both directions, which these networks do not provide,
  and DERP is reachable but relayed.

The tailnet already supplies the missing piece. The core's `getTailscaleStatus` reports every
peer's current underlay addresses in real time (the fork's peer rows carry `addrs`, `curAddr`,
`directVerified` and the DERP drop counters). What is missing is the step from "peer X is currently
at <address>" to "a program on this device can reach peer X's service on a fixed local address".

## Decision

Add a thin mihomo outbound, `type: tailnet-peer`, that keeps every protocol detail in mihomo and
owns exactly one thing: the server address of a peer whose underlay address changes.

- The outbound carries an inner proxy configuration (`proxy: {type: vless, ...}`) and replaces its
  `server` and `port` for each connection with the peer's current address. What travels on the wire
  is whatever the inner protocol sends - for this deployment, VLESS with `encryption`
  (VLESS Encryption), which is TCP-only, needs no certificate, and keeps the payload confidential
  between the two nodes.
- The peer's address comes from the tailscale status the core already has: `component/tailnet`
  gains a registry where each tailscale outbound publishes its `StatusProvider`, and this outbound
  reads the peer row from it. Ordering matches the follower rules below: a verified direct path,
  then IPv6 sharing a /64 with a local interface, then other IPv6, then IPv4.
- The inner proxy is rebuilt only when the resolved address changes, and rebuilt again when a dial
  fails, so a peer that moved networks is reached by the next connection attempt.
- The node that is reachable (the PC) runs the matching `listeners:` entry
  (`type: vless`, `decryption: ...`). That listener is the only public surface this design adds,
  and it carries ciphertext plus a UUID; the services behind it - RustDesk on port 23333, a LAN
  admin panel - never need to be reachable from the internet.
- No UDP anywhere: the carrier is TCP, VLESS Encryption protects it, and `udp: true` on the inner
  proxy moves UDP payloads inside that TCP stream when an application needs them.

Reachability differences stay in the dial path rather than in separate roles: a peer behind
cellular answers no inbound dial, so a connection towards it fails fast while connections the peer
itself starts keep working.

The earlier loopback follower (`lib/common/p2p_follower.dart`) dialed services directly and is
superseded by this outbound; its code stays until the outbound lands, then it is removed from the
tree.

## Address source

The core's tailscale status is the only source. The outbound resolves a peer to its addresses in
this order:

1. `curAddr` when the peer row reports `directVerified` - a direct path inside the 6.5 second
   trust window that tailscale itself is already using;
2. any of the peer's `addrs` that parses as an IPv6 address, preferring ones that share a prefix
   with a local interface (same LAN) before global ones;
3. the remaining `addrs`.

The address is re-resolved for each new connection (with a short cache so a burst of connections
does not re-read the status), so a peer that changed networks is reached by the next connection
attempt.

## Naming

`peer` accepts the peer's hostname, its MagicDNS name, or any of its tailscale IPs. The first
matching peer row wins, which keeps one outbound per remote service (a phone may have several:
RustDesk, a NAS panel, an SSH port).

## Invariants

- The outbound never dials an address that did not come from the tailscale status of a peer it was
  configured with, and never a port other than its own `port`.
- It never rewrites the profile or the inner proxy's own options: only `server` and `port` are
  substituted.
- Only the node running the listener needs an inbound port. The dialing node adds none.
- The inner proxy's configuration is the source of truth for everything except the address, so
  switching the tunnel protocol (VLESS Encryption today, something else later) is a config change.

## Exposure

Only the listener side is reachable from the internet, and what answers there is the inner
protocol - VLESS Encryption in this deployment - so the port carries ciphertext and authenticates
the client by UUID before any payload is accepted. Services behind it stay private: RustDesk's
23333 can be firewalled to the tailnet or the LAN, and nothing about this design asks for a public
business port.

The dialing side adds no listener at all.

## Out of scope for the first version

- UDP mappings. RustDesk's direct path is TCP; a UDP mapping needs a session table first.
- Relay fallback. When a peer's address is unreachable the connection fails; routing it through a
  VPS relay is a later addition behind the same interface.
- Hole punching. Neither side of this feature changes tailscale's own path selection.

## Testing

- Unit: address ordering (verified direct before LAN before global), deterministic peer indexes,
  loopback address formatting, port parsing and validation.
- Unit: the pipe's half-close behaviour and its cleanup on dial failure or listener shutdown.
- Manual: with the PC's RustDesk on TCP 23333, the phone dials `127.0.0.2:23333` on cellular and
  reaches the PC; moving the PC to a new IPv6 prefix is picked up by the next connection.
