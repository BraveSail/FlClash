# ICMP over the tunnel

## The goal in one line

`ping <anything>` on any mihomo node should travel the real path its rules select and report a
real round trip. Today it cannot: mihomo answers ICMP itself (fake echo for a fake-ip) or sends it
DIRECT through a raw socket, and the proxy chain never sees it. The design below turns that into
"ICMP is a connection like any other", with the carriers that can actually move it.

## The hook that already exists

sing-tun hands every ICMP echo to the handler before anything else:

```go
PrepareConnection(network, source, destination, routeContext, timeout) (DirectRouteDestination, error)
```

- a non-nil destination receives each packet whole (`WritePacket(*buf.Buffer)`) and answers through
  `routeContext.WritePacket(fullIPPacket)`;
- nil means "the stack answers it", which is how the fake echo happens today;
- mihomo's handler uses exactly two outcomes: `ping.ConnectDestination` (a raw DIRECT socket) or
  nil. Nothing else is possible, because `C.ProxyAdapter.IsL3Protocol` - whose own comment says it
  marks an adapter working in L3 - has no caller anywhere in this tree.

So the plumbing is: match the rules for the ICMP flow, and when the winning outbound can carry
ICMP, return a destination backed by that outbound instead of a raw socket.

## Design

1. **Rule matching**: the tunnel exposes what it already does for TCP and UDP -
   `MatchProxy(metadata)` - so the TUN handler can ask which outbound an ICMP flow would use, with
   the domain restored from a fake-ip or a host entry first.
2. **Capability**: an outbound that can move an echo announces it:
   `ExchangeICMP(ctx, metadata, icmpMessage) (icmpMessage, error)`. The contract is the ICMP
   message alone - no IP header - because every carrier puts its own header around it.
3. **Carriers**:
   - `direct`: the raw socket path that exists today (`ping.ConnectDestination`), now reached
     through the same interface, so behaviour is unchanged but the plumbing is uniform;
   - `vless` (our extension): a new command in the VLESS request - the destination address is
     already in the header, so the client sends the echo message and the mihomo *listener* on the
     peer side puts a real echo on the wire to that destination and streams the reply back. Both
     ends are mihomo, so no third party has to understand it, and nothing extra listens;
   - `openvpn` (TCP) / `wireguard` / `zerotier` / `masque`: their L3 device already exists
     (`ipConn.WritePacket`, `ipLink.WritePacket`, the ovpn tun) - each needs the echo written into
     it and the reply matched back;
   - `tailnet-peer`: delegates to its inner proxy, and for an echo aimed at the peer itself passes
     the peer's own address as the destination, so the far end answers as itself.
4. **Reply**: the destination builds the reply IP packet (source = what was pinged, destination =
   the original source, payload = the returned echo reply, checksum recomputed) and hands it to
   `routeContext`. The identifier and sequence travel untouched, so the ping tool matches them.

## What this gives

- `ping pc.lan` -> tunnel -> the peer answers -> real RTT of the tunnel.
- `ping 223.5.5.5` when the rules send it to a peer -> the *peer* emits the echo -> real RTT of
  `phone -> peer -> target -> peer -> phone`, and IPv4 works from a node whose carrier only gave it
  IPv6.
- Any outbound that can carry ICMP works, so the feature is mihomo-wide, not a peer-to-peer trick.

## What it does not give

- A stock VLESS/SS server that predates the extension cannot answer the new command; the ping then
  falls back to today's DIRECT/fake behaviour instead of failing the config.
- Echo only, in the first version.

## The idea

`ping pc.lan` should measure the real round trip to the peer. VLESS carries a stream (TCP) and,
with `udp: true` on the inner proxy, UDP datagrams (UDP-over-TCP). It does not carry ICMP, and
more importantly mihomo never hands ICMP to a proxy at all - but neither fact is a dead end: the
ICMP message is just bytes. Wrap an echo request in a UDP datagram, send it through the tunnel
the same way any other UDP payload travels, unwrap it on the peer, and let the peer's own stack
produce the echo reply. Nothing in this needs a raw socket, root or an administrator.

## Where it is blocked today

- `listener/sing_tun/prepare.go`: ICMP is answered only through `PrepareConnection`, which has
  exactly two outcomes - a local fake echo (destination in the TUN's own ranges or in the fake-ip
  pool) or a DIRECT raw socket. **ICMP never reaches the rule engine.**
- `C.ProxyAdapter.IsL3Protocol(metadata)` exists (`adapter/outbound/base.go`), and
  `direct`/`wireguard`/`openvpn`/`zerotier`/`masque` implement it, but nothing in this tree calls
  it: the "hand an L3 connection to an outbound" path is unfinished. That path is what this
  design completes, for ICMP only.

## Design

1. **TUN handler** (`PrepareConnection`, ICMP): resolve the destination back to a name with
   `resolver.FindHostByIP` (a fake-ip or a host entry answers), match the rules for that name the
   way `tunnel` does, and look at the outbound that wins. If it reports ICMP support, encapsulate;
   otherwise keep today's behaviour (fake echo or DIRECT), so nothing regresses.
2. **Encapsulation**: `magic(4) | version(1) | kind(1) | icmp message`, carried as one UDP
   datagram to the peer's responder port (a config value, default `8443 + 1`). The echo
   identifier, sequence number and payload travel untouched, so the ping tool accepts the reply.
3. **Responder** on the peer: a new inbound (`type: icmp-responder`) that turns a request into a
   reply - swap source and destination, recompute the checksum, send it back the way it came. The
   peer is the target, so its own stack is the honest source of the reply; no privileges needed.
4. **Phone side**: the reply arrives as a UDP datagram on the same session, is unwrapped and
   written into the TUN with source = the address that was pinged and destination = this node's
   TUN address. `ping` then reports the real round trip: tunnel out, peer's local echo, tunnel
   back.

## Cost

- `listener/sing_tun`: ICMP branch, rule lookup, encapsulation, TUN injection (~120 lines).
- `tailnet-peer`: forward the wrapped message through the inner proxy and carry the answer back
  (~80 lines), plus a `SupportICMP()`-style answer that is true only when the inner proxy has UDP.
- New `icmp-responder` inbound (~120 lines) and unit tests for the envelope, the checksum and the
  outbound selection (~150 lines). No new dependencies.

## Limits worth knowing

- Echo request/reply only. Traceroute and ICMP errors (TTL exceeded, fragmentation needed) are a
  later step; they need the same envelope with more kinds.
- Both ends must run a build with this feature. An older peer sees an unknown UDP service; the
  magic prefix makes that a clean "no answer" rather than a mis-parse.
- If the inner proxy loses `udp: true` (or the protocol has no UDP), the outbound reports no ICMP
  support and the old fake/DIRECT behaviour comes back automatically.
- Confidentiality is whatever the tunnel gives: the envelope rides inside the same VLESS
  Encryption stream, so an observer sees no more than for TCP payloads.
- The measured RTT is the tunnel's, which is the point. It says nothing about the peer's path to
  somewhere else.

## Why not resolve the name to the peer's real address instead

That was the first attempt: answer `pc.lan` with the address the directory holds, let ICMP go
DIRECT, and rely on mihomo mapping the address back to the name so TCP still matches the DOMAIN
rule. It works in principle (`dns/middleware.go` records `IP -> host` for every answer,
`tunnel/tunnel.go` restores it), but it makes every application's cached address load-bearing: for
as long as a resolver or the application keeps an address, a missing mapping sends that
connection straight to the peer, unencrypted, and the peer is not reachable that way. Wrapping
ICMP keeps the tunnel as the only path, which is what the deployment is for.

## Pinging something that is not the peer

The same envelope answers "ping an address the phone cannot reach itself": put the address the
originator wanted to reach in the envelope, and the peer sends the echo for real.

```
magic(4) | version(1) | kind(1) | family(1) | target(4 or 16) | icmp message
```

- The rules decide which peer asks: a destination that matches a rule whose outbound is a node
  running the responder is encapsulated, everything else keeps today's behaviour.
- The responder performs a real echo to `target` (not to itself) and relays whatever comes back,
  so the round trip the phone measures is genuinely `phone -> peer -> target -> peer -> phone`.
  A timeout is relayed as a timeout; nothing is invented.
- Sending that echo needs no privileges: Windows has `Icmp6SendEcho2`/`IcmpSendEcho2`, Linux and
  Android have unprivileged ICMP sockets. Both are the same primitives the system ping uses.
- The identifier in the ICMP header is owned by the ping tool, and the OS echo API rewrites it.
  The tunnel side therefore maps the identifier on the way out and restores it on the way back,
  or the reply never matches the request.

What it buys: IPv4 ICMP from a node whose carrier only gives IPv6, a reachability check from the
peer's network instead of the phone's, and a real RTT for both. What it does not buy: a way to
exit through a node that is not running the responder (a plain VLESS node to a VPS has nobody to
answer), and it still covers echo only.

## Can one side alone be enough?

ICMP has to leave from the exit's network, so *something* at the exit must emit it. What can vary
is how much of that "something" has to be custom code, and the answer depends on what the exit is:

- **The exit runs FlClash (this deployment).** Then no extra deployment exists to avoid: the
  responder is one more inbound type in the same binary, shipped by the same update the peers
  already take. One codebase, no second service, and the peer's configuration needs nothing at
  all - that is as close to "one side" as a real ICMP can get.
- **The exit is a plain VLESS/SS node on a VPS.** There is nothing there to emit ICMP, and VLESS
  has no ICMP semantics to extend, so no client-side trick can help. Two ways out:
  - run the same FlClash (or just a responder) there - a second deployment, however small;
  - or use a protocol whose *server* already speaks layer 3, and implement only the client half
    here. `masque` (HTTP/3) and `zerotier` already contain the packet path in this tree
    (`ipConn.WritePacket`, `ipLink.WritePacket`) but are UDP-based, which these networks block;
    `openvpn` runs over **TCP** and is the remaining candidate, except that its outbound only
    implements TCP and UDP today - the ICMP half would be ours to write (~80 lines) on top of the
    TUN wiring (~150 lines), and the exit would be a stock OpenVPN server.
- **No code at all**: `ssh exit 'ping ...'`, or a public reachability API. Real ICMP, but not a
  local `ping`, and the round trip it reports belongs to the exit's network, not to this path.

So: with FlClash on both ends, the responder is the "one side" answer. With a stock VPS exit, the
choice is OpenVPN-over-TCP (client work, stock server) or accepting a second deployment.
