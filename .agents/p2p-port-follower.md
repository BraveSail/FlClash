# P2P Port Follower

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

Add a symmetric peer port follower inside FlClash. Every node runs the same code and the same
configuration; client and server are not roles a device is assigned.

- For every peer and every configured port the follower binds a distinct loopback address,
  `127.0.0.<peerIndex>:<port>`, and accepts TCP connections there.
- On accept it reads the peer's current underlay address from the tailnet status, dials
  `<address>:<port>`, and pipes the connection both ways, including half-close.
- Programs on the device dial the loopback address, so their own configuration never contains a
  dynamic address: the phone's RustDesk client always dials `127.0.0.2:23333`.
- Services stay where they already listen. No node adds a `listeners:` or `tunnels:` entry for
  this; the follower only decides which address a connection is sent to.

Reachability differences stay in the dial path rather than in separate roles: a peer behind
cellular answers no inbound dial, so a connection towards it fails fast (and, later, can fall back
to a relay) while connections the peer itself starts keep working.

## Address source

`CoreMethod.getTailscaleStatus` is the only source. The follower resolves a peer to its addresses
in this order:

1. `curAddr` when the peer row reports `directVerified` - a direct path inside the 6.5 second
   trust window that tailscale itself is already using;
2. any of the peer's `addrs` that parses as an IPv6 address, preferring ones that share a prefix
   with a local interface (same LAN) before global ones;
3. the remaining `addrs`.

The address is resolved per connection, never cached across connections, so a peer that changed
networks is reached by the next connection attempt. The status poll is the same one the connections
page already uses, so no new core method or event is introduced.

## Loopback layout

Peer index comes from the peer's tailscale identity (`id` when present, otherwise its first
tailscale IP), sorted and assigned deterministically, so every device computes the same index for
the same peer and `127.0.0.<index>` means the same peer everywhere. Index 1 is reserved for the
local node.

## Invariants

- The follower binds loopback addresses only. It must never expose a service to the LAN or the
  tailnet; that is what the profile's listeners are for.
- It never starts, stops, or restarts the core, and it never writes the profile. Its input is the
  existing status snapshot; its output is a socket.
- A port mapping is a device-local app setting, not a profile key: the shared profile stays free of
  device-specific state.
- Disabled mappings close their listeners; a failed dial fails that one connection and leaves the
  listener ready for the next attempt.

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
