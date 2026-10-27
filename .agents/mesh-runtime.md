# The mesh as a runtime object

## Why this exists

The mesh works, and it is the hardest part of this tree to debug. A dropped
session took days to chase and the reason is structural, not incidental:

- **The mesh has no identity at runtime.** A `mesh:` block is expanded at parse
  time into one `tailnet-peer` outbound per device plus one shared listener, and
  nothing owns the result. Asking "what is this node's mesh doing right now?"
  means asking five outbounds, a listener, and a directory client that only
  find each other through a process-wide map.
- **Three connection lifetimes, none of them visible.** The directory client,
  the profile channel, and each peer tunnel are owned separately, log
  separately, at different levels. A failure appears in one of them and reads
  like a network fault in all three.
- **The dial path builds and caches a proxy object.** Holding one is what
  creates the "old proxy" that has to be closed, the TTL that decides when to
  rebuild it, and the invalidation that has to reach it. Every one of those is
  a place a live session can be cut by accident.

The goal is not fewer features. It is a mesh whose state can be asked for, and
whose connections have no shared lifetime to get wrong.

## What must not change

- The profile stays one `mesh:` block, shared by every device.
- Credentials stay derived from the directory token, in the core, in exactly
  one implementation.
- A device that runs the bare core stays a first-class node.
- The listener side stays the only inbound port; a dialling node adds none.
- Nothing here adds a relay. A peer that cannot be reached fails.

## Compatibility matrix

An audit of the current tree found **41 runtime behaviours** across 15 files
(~6,800 lines) and **99 test cases**. Every behaviour below must survive the
refactor; the test file that pins it is the acceptance check.

### Expansion (config/mesh.go, 570 lines)

| Behaviour | Pinned by |
|---|---|
| `expandMesh` runs first in `ParseRawConfig`, mutating the raw config in place | `config/mesh_test.go` (33 cases) |
| No-op guards: nil mesh, or no devices + not resolved + no url/token | `TestExpandMeshWithoutDevicesIsANoOp`, `...WithoutADirectoryStaysANoOp` |
| Derived protocol (VLESS + VLESS Encryption) when neither half is written | `TestExpandMeshDerivesTheProtocolWhenNoneIsWritten`, `...DerivesTheEncryptionBothEndsSpeak` |
| Identity from the token: `sha256("mesh:"+token)` as uuid, X25519 for the key pair | `TestMeshUUIDIsStableAndSeparatesTokens`, `TestMeshEncryptionKeysAreStableAndSeparateTokens` |
| Device discovery during the parse (`GET /api/devices`, 8s cap) | `TestExpandMeshDiscoversTheDevicesFromTheDirectory` |
| An unreadable directory warns and expands zero peers, never fails the parse | `TestExpandMeshSurvivesAnUnreadableDirectory` |
| Name resolution with fallback to the id, devices sorted by id | `TestExpandMeshFallsBackToTheID...`, `...ExpandsDiscoveredDevicesInIDOrder` |
| Port rules: `port` on the listener is an error; own entry's port wins; else all must agree; else 23333 | `config/mesh_test.go:846-898` |
| One shared `mesh` entry carrying `domains`, plus `DOMAIN,<domain>,mesh` rules prepended and sorted | `TestExpandMeshWritesAnEntryAndRulesForTheDevicesDomains`, `...PutsTheDomainRulesFirst` |
| An invalid domain is dropped with a warning rather than failing the profile | `TestExpandMeshDropsAnInvalidDomainRatherThanTheProfile` |

### Peer runtime (adapter/tailnet_peer.go, 466 lines)

| Behaviour | Pinned by |
|---|---|
| `requestedHost` lower-cases the name; `recordKey` maps it through `domains` to a record id | `adapter/tailnet_peer_mesh_test.go` |
| Resolution cache is keyed **per record**, not per outbound | `TestTailnetPeersShareOneDirectoryClient` |
| 30s TTL; a failed dial invalidates every record **and** calls `directory.ForgetPeer` | `tailnet_peer_test.go` |
| Self answers dial the local service (127.0.0.1 then ::1), falling back to DIRECT | `TestTailnetPeerDialsLocalServiceForItself`, `TestTailnetPeerDegradesToDirectForItself` |
| Inner proxy rebuilt per resolved address; a replaced one is retired, not closed | `tailnet_peer_test.go` |
| `SupportUDP`/`SupportUOT`/`IsL3Protocol` delegate to the inner proxy | — |

### ICMP over the tunnel (adapter/tailnet_peer_icmp.go + listener/sing_tun)

| Behaviour | Pinned by |
|---|---|
| `ICMPDestination`: self-and-target answers locally, self-and-other keeps the direct path, non-self redirects | `tailnet_peer_icmp_test.go` |
| `ExchangeICMP` refuses a non-self flow and builds a local reply otherwise | `tailnet_peer_icmp_test.go` |
| `destinationIsThePeer` matches a `domains` key or the peer name with an optional dot suffix | `tailnet_peer_host_test.go` |

**Reachability trap**: these interfaces are only reachable because
`ParseProxy` wraps every outbound in `autoCloseProxyAdapter`, which implements
`ProxyAdapterWrapper` so `ICMPCarrierOf`/`ICMPRedirectOf` can walk up to 8
decorators (`adapter/parser.go:248`, `adapter/outbound/base.go:393-397`).
Removing that wrapper silently disables ICMP over the mesh — no error, no log.

### Directory (adapter/outbound/peer_directory*.go, ~1,400 lines)

| Behaviour | Pinned by |
|---|---|
| `POST /report` with the chosen address, heartbeat cadence, 304 handling | `TestPeerDirectoryReportsAndFollowsTheObservedAddress`, `...SkipsAnUnchangedReport`, `...HeartbeatsWhenTheAddressIsUnchanged` |
| Address choice: underlay probe → platform finder → underlying route → socket probe → interface scan | `peer_directory_defaultroute_test.go` |
| `GET /lookup`: self answers locally, a cached answer is returned immediately, a stale one refreshes behind the dial | `TestPeerDirectoryLooksUpPeersAndAnswersForItself`, `TestPeerAddressDoesNotWaitOnASlowDirectory` |
| A cached self is never handed out as a peer | `TestCachedSelfIsNeverHandedOutAsAPeer` |
| Two routes with stickiness; only an unreachable route moves on | `TestPeerDirectoryFallsBackToDirectWhenTheProxyIsDown`, `...RemembersTheRouteThatWorked` |
| Persisted answers survive a restart | `TestPersistedPeerAnswersAfterRestart` |
| Network-change injection coalesces a burst | `TestNetworkChangeCoalescesARouteBurst` |
| One directory client shared per `(url, token, id, port, viaProxy)` — **the outbound name is not part of the key** | `TestPeerDirectoryRegistersItselfForPeersOutbounds` |
| Cachefile key namespace `peer-directory/<fnv1a16(url)>/<id>` | `TestCacheKeyDigestSeparatesDirectories` |

### Hub channel (component/hubprofile/, 922 lines)

| Behaviour | Pinned by |
|---|---|
| Pull with `If-None-Match`; 304 costs nothing; a 200 with the same ETag is skipped | `hubprofile_test.go` |
| Watch socket; bytes arriving with the 101 are replayed, never dropped | `watch_framing_test.go` |
| Backoff 2s → 2m, walking both routes from the remembered one | `fallback_test.go` |
| `applyYAML` writes before applying, so a restart returns on the pulled profile | `hubprofile_test.go` |
| `keep` merges with dotted keys descending into maps | `hubprofile_test.go` |
| A hand-written CONNECT dialer for the WebSocket (the core's HTTP proxy is a transport, unusable for a `net.Conn`) | `fallback_test.go` |

### Platform branches

| Platform | Behaviour |
|---|---|
| Android | underlay probe via a VpnService-protected socket; three netlink strategies (`uid-route`/`main-table`/`rpdb-main-rule`); `embedMode` disables `PUT/PATCH /configs` but **not** the hub apply path |
| Windows | virtual-interface classification by adapter type and description; default interface by gateway; ICMP via `IcmpSendEcho` |
| Other | virtual-interface classification by name prefix; unprivileged ICMP socket |

### Known dead code and contradictions (found by the audit)

| Item | Finding |
|---|---|
| `meshPeer.Port` (`config/mesh.go:130,433,506`) | Assigned, **never read**. The comment at `mesh.go:427-432` says a device is dialled where its entry says it serves, which contradicts the implementation (the peer's port comes from the directory at dial time). |
| `stalePeerTTL` + `usableStalePeer` (`peer_directory_cache.go:161-173`) | Declare a 24h bound on persisted answers, **never called**. The fallback at `peer_directory.go:404-416` applies no age check at all. |
| `peerCacheStorageKey` (`peer_directory_cache.go:28-34`) | Never called; the same string is inlined at three sites. |
| `peerdirectory.Lookup` (`registry.go:52-63`) | No production caller — the global registry is a dead end. |
| `ipv4Loopback`, `tailnetEchoTimeout` (`tailnet_peer_icmp.go:15,17-19`) | Declared, never used. |

### Structural defect: parse-time network I/O

`expandMesh` performs one **blocking** `GET <url>/api/devices` (8s cap,
`config/mesh.go:35,462-468`) when `devices` is empty and `directory-resolved`
is false. The hub-push path reaches it through
`applyYAML → executor.ParseWithBytes → hub.ApplyConfig`, so **a pushed profile
can block the parse on the network and then rebuild every outbound**. The app
writes `directory-resolved: true` into its own generated config, but the
profiles stored on the hub carry only `directory-url` and `directory-token` —
so this path is live on every device.

## Layer contracts

### Discovery — `component/mesh`

One type, `Directory`, owns: this node's id, the address it publishes, the
lookup cache, and the routes its requests take. It is constructed once per
running configuration and handed to whoever needs it. **The process-wide
registry is deleted**: a consumer is given the `Directory` it should use.

- Lookups never block a dial. An answer in hand is returned; a stale one is
  refreshed behind the caller.
- Every request walks the configured routes in order — proxy first when one is
  configured, direct behind it — and the route that answered is remembered.
- Every request reports its outcome to the runtime (see Observability), so a
  failing route is a state, not a log line nobody reads.

### Channel — `component/mesh`

The profile channel (pull, push socket, apply) moves into the same package as
the directory, because they are two halves of one relationship with the hub and
they must share one route policy. Today they are separate packages with
separate policies, which is why they disagreed.

- **Apply only on change.** A pull compares the body it received, not only an
  ETag: a hub that answers 200 with an unchanged body must cost nothing. The
  ETag is an optimisation on top, never the only guard.
- The watch socket opens with the revision this node runs, so an up-to-date
  device hears nothing.

### Peers — `adapter/tailnet_peer.go`

The outbound keeps: the inner protocol configuration (parsed once), the
`Directory`, and this node's own id.

**It does not keep a proxy object.** Each dial resolves the peer's address and
builds a dialer for that one connection:

```
addr, port, self := directory.PeerAddress(ctx, key)   // cached, never blocking
if self { dial the local service }
else    { dialer := inner.dialerFor(addr, port); return dialer.Dial(metadata) }
```

There is therefore no cached proxy, no "previous" proxy to close, no TTL that
decides when the cached one is wrong, and no shared lifetime between two
connections. A peer that moves costs the connections started after the move;
nothing already running is touched.

An address change must never be a reason to close anything, because nothing is
held open by this layer.

### Listener

Unchanged in shape: one shared `listeners:` entry, one protocol, one port.

## Observability

The runtime answers one question completely:

```
GET /mesh/status
{
  "id": "5790065b0b10",
  "address": "2408:...:d156",
  "port": 23333,
  "directory": { "url": "...", "route": "proxy", "lastOk": "...", "lastError": null },
  "channel":   { "route": "proxy", "etag": "...", "lastApply": "...", "applies": 3 },
  "peers": {
    "pc": { "address": "2408:...", "port": 23333, "source": "cache",
            "lastResolved": "...", "lastError": null, "active": 2 }
  },
  "connections": { "open": 2, "byPeer": { "pc": 2 } }
}
```

Rules for this surface:

- Every field is either a value the runtime holds or a timestamp of a real
  event. Nothing is inferred or estimated.
- `lastError` is cleared by the next success, and says which route it came from.
- `applies` counts configuration applications, so "is something reloading my
  config under me?" is one read.
- `active` is a live count of connections per peer, so a session that drops has
  a number to point at.

## Migration

Each step is shippable and leaves the tree working.

0. **This document.** No code.
1. **Observability only.** Add `/mesh/status` with the fields above, backed by
   counters the existing components already have or can cheaply hold. No
   behaviour changes. Use it to answer the open fault.
2. **One package for discovery and channel.** Move `component/hubprofile` and
   the directory client under `component/mesh`, share one route policy, delete
   the process-wide registry, inject the directory explicitly.
3. **The dial path stops holding a proxy.** `tailnet_peer` builds per
   connection; `peer_directory_cache.go` and the retired-proxy set are deleted
   rather than kept.
4. **Apply on change.** Content comparison in the pull path, with tests that
   pin a 200-with-unchanged-body costing nothing.

Step 1 is the one that unblocks debugging; 2-4 are the ones that stop this class
of fault from being possible.
