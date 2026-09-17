# ICMP over the tunnel

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
