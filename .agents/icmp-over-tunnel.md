# ICMP through mihomo

## What a user gets

`ping <anything>` on a node that runs this build reports the truth: a real round trip when the
path exists, and a network error when it does not.

- `ping pc.lan` sends the tool's own echo message to the address the directory publishes for the
  peer. The peer's stack answers it, exactly as it would if both nodes shared a network. Nothing is
  wrapped and no message is re-typed, so the measured time is the path that was asked about.
- `ping t.cn` keeps the same message too: the placeholder the resolver handed out is swapped for the
  address the name stands for on the way out, and the answer is written back as the placeholder on
  the way in. It runs the direct path a raw address runs, so a name costs what an address costs.
- An echo that cannot be put on the wire as it stands - the tool asked in IPv4 while the peer only
  has an IPv6 address, or the rules sent the echo to a node that is not the target - is answered
  with the ICMP error a router would send. `ping` prints `Destination host unreachable` instead of
  waiting for an answer that can never come.

Nothing is invented: a target that stays silent, a peer that blocks ICMP from the outside, or a
peer that is asleep all produce a timeout, because that is what happened.

## What is in the tree

| Piece | Where |
| --- | --- |
| `C.ICMP` network type, `NETWORK,icmp` rules | `constant/metadata.go`, `rules/common/network_type.go` |
| `C.ICMPProxy` (carrier contract) and `ICMPCarrierOf` | `constant/adapters.go` |
| Rule lookup for a flow without a connection | `tunnel.MatchProxy` |
| TUN side: intercept, match, carry, write the reply | `listener/sing_tun/icmp_proxy.go`, `prepare.go` |
| Carrier: an echo sent to the peer's own address | `adapter/tailnet_peer_icmp.go` |
| Echo, reply building, the error a router sends | `component/icmptunnel/`, `listener/sing_tun/icmp_proxy.go` |

sing-tun hands every echo to `PrepareConnection` before anything else: a non-nil destination
receives each packet whole and answers through the route context, and nil means the stack itself
replies - which is where the fake echo comes from. That hook is what the feature uses.

## How an echo travels

- The rules pick the outbound. A rule may name a group: the group's current selection is read
  without touching it, and decorators around an outbound (the one that closes it when the config is
  replaced) are looked through - they embed the adapter interface and hide everything else.
- `tailnet-peer` names the address an echo aimed at it has to travel to (`C.ICMPRedirect`), and the
  flow keeps the tool's own message: only the address on the wire changes, so the peer's kernel -
  not this node - produces the answer.
- An outbound that moves no echo (every proxy protocol: they carry TCP and UDP streams, not ICMP)
  leaves the flow on the path it would have had without this feature. A name is resolved once and
  sent to the address it stands for; a raw address keeps sing-tun's DIRECT socket; the TUN's own
  ranges keep the stack's reply.
- The outbound that *is* this node says so (`icmptunnel.ErrLocalPath`), and the TUN side sends the
  tool's own echo to the address the name stands for - which for this node is its own network.
- A flow pinged as a placeholder is answered as the placeholder: the direct path's answers are
  readdressed to the address the tool pinged (v4 header and ICMPv6 pseudo-header checksums
  recomputed), because a tool drops an answer from an address it never pinged.
- An echo that cannot be delivered as it stands returns `icmptunnel.ErrUnreachable`, and the TUN
  side writes the ICMP error a router would write (v4 type 3 code 1, v6 type 1 code 0) with the
  original header and message quoted inside it.
- The reply is written back as a whole IP packet with the addresses swapped and the checksums
  recomputed (ICMPv6's pseudo header included). Identifier, sequence and payload travel untouched,
  so the ping tool matches its own request.

## Profile

```yaml
rules:
  - DOMAIN,pc.lan,pc       # a ping at the peer's name goes to the peer
```

No listener is needed and no rule has to send every echo anywhere: an echo that is not aimed at a
peer is answered on the node that sent it.

## Limits worth knowing

- The echo is not wrapped, so a peer has to answer ICMP from the outside, the way any host on a
  shared network does. A peer behind a carrier that blocks inbound ICMP (a phone on cellular, for
  one) cannot be pinged; the ping times out, which is the truth about that path.
- A name costs one resolution per ping run: the address it resolves to is kept for the flow, so a
  run of pings resolves once and then runs the same path an address runs.
- The tool's family has to match the peer's address family. `ping pc.lan` that resolves to an
  IPv4 placeholder while the peer only has an IPv6 address gets a `host unreachable` error, not an
  invented ICMPv6 echo; `ping -6 pc.lan` - or a DNS answer that offers only the peer's family - is
  the pure pass-through.
- Echo request/reply only. Traceroute and other ICMP errors are a later step.
- A stock VPS exit cannot do this at all: a proxy protocol carries TCP and UDP streams, not ICMP,
  and the server has no way to emit an echo for you. The client-only way to reach a stock server is
  an L3 tunnel (WireGuard, OpenVPN) whose server's own stack answers.
- No confidentiality is added: the echo is what the tool sent, on the wire.

## Leftovers

- `listener/inbound/icmp.go` (`type: icmp-responder`) and the envelope in
  `component/icmptunnel/` are the remains of a carried-echo design that was removed: the client no
  longer wraps anything. The inbound is kept so a profile that still configures it keeps loading,
  and is not part of the shipping profile.

## Testing

- `go test ./component/icmptunnel/` covers the envelope and a real echo to a public target.
- `go test ./listener/inbound/ -run TestResponderAnswersWithARealEcho` starts a responder, sends
  an envelope over UDP and checks the reply that comes back.
- `go test ./adapter/ -run "TestTailnetPeer|TestDirectEcho|TestEchoSpeaksFor"` covers the outbound
  as a config builds it (the decorator included), the echo it sends to a peer, and the refusal of a
  message whose family the peer does not speak.
- `go test ./listener/sing_tun/` covers the TUN side: echo parsing, the swapped reply and both
  checksums, and the unreachable error that quotes the packet it could not deliver.
- Manual, on Windows: `ping pc.lan` answers from the node itself (under a millisecond), `ping t.cn`
  reports the real round trip through a name, and `ping localtest.lan` against an IPv6-only peer
  prints `Destination host unreachable` - with `[ICMP] ... sent to <address> as it is` and
  `answering unreachable` visible in the core log.
