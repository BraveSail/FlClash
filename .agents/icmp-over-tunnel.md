# ICMP over the tunnel

## What a user gets

`ping <anything>` on a node that runs this build travels the path its rules select and reports a
real round trip:

- `ping pc.lan` on the PC answers from the PC itself, and from the phone it measures the tunnel:
  the echo is carried to the PC and answered there.
- `ping 223.5.5.5` follows `NETWORK,icmp,pc`, so a node with no IPv4 of its own still gets a real
  IPv4 round trip - the peer emits the echo.
- A flow the rules send to the node that asked is answered locally (`ping pc.lan` on the PC) or
  handed to the DIRECT path (`ping 223.5.5.5` on the PC), never to a fake reply.

Fake echoes remain only for flows no carrier claims, which is what every outbound but
`tailnet-peer` is today.

## What is in the tree

| Piece | Where |
| --- | --- |
| `C.ICMP` network type, `NETWORK,icmp` rules | `constant/metadata.go`, `rules/common/network_type.go` |
| `C.ICMPProxy` (carrier contract) and `ICMPCarrierOf` | `constant/adapters.go` |
| Rule lookup for a flow without a connection | `tunnel.MatchProxy` |
| TUN side: intercept, match, carry, write the reply | `listener/sing_tun/icmp_proxy.go`, `prepare.go` |
| Carrier: peer envelope over the inner proxy | `adapter/tailnet_peer_icmp.go`, `adapter/tailnet_peer.go` (`icmp-port`) |
| Envelope, echo, reply building | `component/icmptunnel/` |
| Responder inbound | `listener/inbound/icmp.go` (`type: icmp-responder`) |

sing-tun hands every echo to `PrepareConnection` before anything else: a non-nil destination
receives each packet whole and answers through the route context, and nil means the stack itself
replies - which is where the fake echo comes from. That hook is what the feature uses.

## The carried echo

ICMP cannot ride the inner protocol (VLESS has no field for it), so the message travels as one UDP
datagram through the tunnel:

```
magic(4) | version(1) | family(1) | target(4 or 16) | icmp message
```

- The rules pick the outbound. A rule may name a group: the group's current selection is read
  without touching it, and decorators around an outbound (the one that closes it when the config
  is replaced) are looked through - they embed the adapter interface and hide everything else.
- The envelope goes to the peer's **loopback** responder port (default `port + 1`), because what
  the peer does with the tunnel's UDP is run it through its own rules: the destination is loopback,
  so the profile's `IP-CIDR,127.0.0.0/8,DIRECT` rule hands it to the responder. The responder is
  therefore never exposed to the internet, and the tunnel's own authentication still stands in
  front of it.
- The responder puts a real echo on the wire - `IcmpSendEcho2`/`Icmp6SendEcho2` on Windows, which
  needs no administrator, and an unprivileged ICMP socket elsewhere - and answers with the reply
  envelope. Nothing is invented: a target that stays silent produces a ping timeout.
- A flow aimed at the peer itself carries the peer's loopback as the target, so the peer answers
  as itself and the round trip is the tunnel. A flow that only carries a fake-ip placeholder names
  a host, which is resolved to a real address of the message's family before the peer is asked.
- The reply is written back as a whole IP packet with the addresses swapped and the checksums
  recomputed (ICMPv6's pseudo header included). Identifier, sequence and payload travel untouched,
  so the ping tool matches its own request.

The outbound that *is* this node cannot carry the echo - a real echo from here would enter these
rules again - so it says so (`icmptunnel.ErrLocalPath`) and the TUN side falls back to the path it
uses when no outbound carries ICMP: sing-tun's own socket, bound to the interface the machine would
use, which leaves without a second trip through the rules. A fake-ip destination is resolved first,
so the fallback still measures the name that was pinged.

## Profile

The responder is one listener, and the rule is one line:

```yaml
rules:
  - NETWORK,icmp,pc        # every echo the rules did not already place
listeners:
  - name: icmp-in
    type: icmp-responder
    listen: 127.0.0.1      # only the peer's own rule engine can reach it
    port: 8444             # tailnet-peer's default icmp-port is the tunnel port + 1
```

`NETWORK,icmp` sits after the LAN/CIDR DIRECT rules and before the domain and geo rules, so every
ping that is not already placed goes through the carrier named there. Moving the line below
`GEOIP,CN,DIRECT` keeps Chinese addresses pinged locally instead of through the peer.

## Limits worth knowing

- Echo request/reply only. Traceroute and ICMP errors (TTL exceeded, fragmentation needed) are a
  later step: the envelope has a version byte for them.
- Both ends must run a build with this feature. An older peer sees an unknown UDP service, and the
  magic prefix makes that a clean "no answer" rather than a mis-parse.
- If the inner proxy loses `udp: true` (or the protocol has no UDP), the datagram cannot be sent
  and the ping fails; nothing falls back to a fake reply.
- Confidentiality is whatever the tunnel gives: the envelope rides inside the same VLESS
  Encryption stream, so an observer sees no more than for TCP payloads.
- The measured round trip is the whole path, `phone -> peer -> target -> peer -> phone`, which is
  the point.
- A peer that is asleep cannot answer: Android in deep sleep drops the tunnel's TCP dial, and the
  ping then reports a timeout - the honest answer for that path.

## Not built, and why

- **A VLESS protocol extension** (a new command carrying the echo) - the UDP envelope needs no
  protocol change, works with `udp: true` on any inner proxy, and cannot desynchronise a peer that
  predates it.
- **Other carriers** (`direct` as an explicit carrier, `wireguard`, `openvpn`, `masque`,
  `zerotier`): every one of them is L3 with a device already, so each needs the echo written into
  its device and the reply matched back. `C.ICMPProxy` is the place for them; none is required for
  this deployment.
- **A stock VPS exit.** Nothing there can emit ICMP and VLESS has no ICMP semantics to extend, so
  the only ways out are running this build there too, or OpenVPN-over-TCP with the ICMP half
  written on top of its TUN wiring (its outbound is TCP/UDP only today).
- **Resolving `pc.lan` to the peer's real address instead of carrying the echo.** It works in
  principle, but it makes every application's cached address load-bearing: for as long as a
  resolver or an application keeps an address, a missing mapping sends that connection straight to
  the peer, unencrypted, where the peer is not reachable that way.

## Testing

- `go test ./component/icmptunnel/` covers the envelope and a real echo to a public target.
- `go test ./listener/inbound/ -run TestResponderAnswersWithARealEcho` starts a responder, sends
  an envelope over UDP and checks the reply that comes back.
- `go test ./adapter/ -run TestTailnetPeer` covers the outbound as a config builds it (the
  decorator included) and the target an echo is carried for.
- `go test ./listener/sing_tun/` covers the TUN side: echo parsing, the swapped reply and both
  checksums.
- Manual, on Windows: `ping pc.lan` answers from the node itself (TTL 64, under a millisecond) and
  `ping 223.5.5.5` reports the real round trip (TTL from the target), with
  `[ICMP] ... using <outbound>` and the DIRECT fallback visible in the core log.
