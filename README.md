# nftables use in Kubernetes

- [The problem](#the-problem)
- [Investigation](#investigation)
- [Solution](#solution)
- [How kube-proxy currently works](#how-kube-proxy-currently-works)
  - [ClusterIP -> endpoint - current](#clusterip---endpoint---current)
- [Proposed design: shared dispatch chains + one endpoints map](#proposed-design-shared-dispatch-chains--one-endpoints-map)
  - [ClusterIP -> endpoint - suggested](#clusterip---endpoint---suggested)

## The problem

Issue [#139513](https://github.com/kubernetes/kubernetes/issues/139513) was filed with evidence that nftables programming time grows super-limiearly with the number of Services within Kubernetes.

At 44k services, it took nftables over 1 minute to program the kernel.

## Investigation

I managed to reproduce this on a local VM. I found that the issue seems to be usage of maps in nftables.

I used `perf` to measure this:

```console
root@308f9efce777:/# perf record -g --call-graph dwarf -- nft -f kube-proxy-nft-45k.commands
[ perf record: Woken up 47626 times to write data ]
Warning:
Processed 1489197 events and lost 3 chunks!

Check IO/CPU overload!

[ perf record: Captured and wrote 11907.591 MB perf.data (1435605 samples) ]
```

That allowed me to figure out what was going on when `nft` was running
Using `perf report --stdio -i perf.data-raw-commands --no-children -g none --percent-limit 5` I got this output:

```
# Total Lost Samples: 61
#
# Samples: 1M of event 'task-clock:ppp'
# Event count (approx.): 358901250000
#
# Overhead  Command  Shared Object          Symbol
# ........  .......  .....................  ...........................................................
#
    42.26%  nft      [nf_tables]            [k] nft_set_lookup_global
    16.29%  nft      [nf_tables]            [k] __nft_set_trans_bind.isra.0
    10.16%  nft      [kernel.kallsyms]      [k] _parse_integer_limit
     9.92%  nft      [kernel.kallsyms]      [k] nla_strcmp
     8.30%  nft      [kernel.kallsyms]      [k] strlen
```

It seems that `nft_set_lookup_global` is the top consumer. Inspecting it with `perf report -i perf.data-raw-commands --stdio -g callee --symbol-filter=nft_set_lookup_global`:

```
# Samples: 1M of event 'task-clock:ppp'
# Event count (approx.): 358901250000
#
# Children      Self  Command  Shared Object  Symbol
# ........  ........  .......  .............  .....................................
#
    47.24%    42.26%  nft      [nf_tables]    [k] nft_set_lookup_global
            |
            ---nft_set_lookup_global
               |
               |--23.71%--nf_tables_newsetelem
               |          nfnetlink_rcv_batch
               |          nfnetlink_rcv
               |          netlink_unicast
               |          netlink_sendmsg
               |          __sock_sendmsg
               |          ____sys_sendmsg
               |          ___sys_sendmsg
               |          __sys_sendmsg
               |          __arm64_sys_sendmsg
               |          invoke_syscall
               |          el0_svc_common.constprop.0
               |          do_el0_svc
               |          el0_svc
               |          el0t_64_sync_handler
               |          el0t_64_sync
               |          sendmsg
               |          0xfd28121b09ff
               |          0xfd28121b09ff
               |
                --23.53%--nft_lookup_init
                          nf_tables_newrule
                          nfnetlink_rcv_batch
                          nfnetlink_rcv
                          netlink_unicast
                          netlink_sendmsg
                          __sock_sendmsg
                          ____sys_sendmsg
                          ___sys_sendmsg
                          __sys_sendmsg
                          __arm64_sys_sendmsg
                          invoke_syscall
                          el0_svc_common.constprop.0
                          do_el0_svc
                          el0_svc
                          el0t_64_sync_handler
                          el0t_64_sync
                          sendmsg
                          0xfd28121b09ff
                          0xfd28121b09ff
```

Both `nf_tables_newsetelem` and `nft_lookup_init` seem to be the root cause here.

What those two functions do:

- `nf_tables_newsetelem` handles **adding an element to a set or map** - every
  `add element ...` and every `{ 0 : ep1, 1 : ep2 }` entry inside an anonymous map.
- `nft_lookup_init` builds a **lookup expression**, i.e. any rule that references a
  set or map (`vmap @service-ips`, `dnat to ... map { ... }`). One of these runs
  for every per-Service chain.

Both have to answer "which set/map is this?" and both do it through
`nft_set_lookup_global`, which is 42% of the self-time above. That function walks
the table's list of sets and string-compares names until it finds a match (which
is why `nla_strcmp` and `strlen` also appear in the profile). It is a linear scan.

kube-proxy creates one anonymous map per Service, so with ~45k Services there are
~45k sets in the table, and every one of the ~45k lookup rules and element adds
scans that list. That is $O(N^2)$ work, which is the super-linear growth reported
in the issue. Hence the conclusion: the number of *maps* is the problem, not the
number of rules or elements as such.

## Solution

It seems that by reducing the number of maps that kube-proxy uses, we can decrease the time taken to program nftables.

For this particular user's case, they had a single endpoint per service, so as a stop-gap, PR [#140723](https://github.com/kubernetes/kubernetes/pull/140723) was made.

This changes single-endpoint Services to DNAT directly, rather than doing a map lookup.

## How kube-proxy currently works

Conceptually, kube-proxy's nftables backend does one big map lookup to find the Service,
then jumps to a per-Service chain that does another (anonymous) map lookup to pick an endpoint.

### ClusterIP -> endpoint - current

Example with four Services:

- svc-A - 1 endpoint
- svc-B - 2 endpoints
- svc-C - 3 endpoints
- svc-D - 2 endpoints

```
        packet to  <clusterIP>:<port>
                    |
                    v
          +-------------------+
          |  chain: services  |
          +-------------------+
                    |
                    |  lookup  dst . proto . port
                    v
          +------------------------------------------+
          |  map: @service-ips      (ONE shared map) |
          |                                          |
          |   type ipv4_addr . inet_proto            |
          |        . inet_service : verdict          |
          |                                          |
          |   172.30.0.41 . tcp . 80  -> svc-A       |
          |   172.30.0.42 . tcp . 80  -> svc-B       |
          |   172.30.0.43 . tcp . 80  -> svc-C       |
          |   172.30.0.44 . tcp . 80  -> svc-D       |
          |   ...           one row per Service      |
          +------------------------------------------+
           |                |                |                |
           | goto           | goto           | goto           | goto
           v                v                v                v
   +----------------+  +----------------+  +----------------+  +----------------+
   | chain: svc-A   |  | chain: svc-B   |  | chain: svc-C   |  | chain: svc-D   |
   |                |  |                |  |                |  |                |
   | dnat to        |  | dnat to        |  | dnat to        |  | dnat to        |
   |  numgen random |  |  numgen random |  |  numgen random |  |  numgen random |
   |  mod 1 map {   |  |  mod 2 map {   |  |  mod 3 map {   |  |  mod 2 map {   |
   |   0:10.0.1.1:80|  |   0:10.0.2.1:80|  |   0:10.0.3.1:80|  |   0:10.0.4.1:80|
   |  }             |  |   1:10.0.2.2:80|  |   1:10.0.3.2:80|  |   1:10.0.4.2:80|
   |                |  |  }             |  |   2:10.0.3.3:80|  |  }             |
   |                |  |                |  |  }             |  |                |
   +----------------+  +----------------+  +----------------+  +----------------+
           |                |                |                |
           v                v                v                v
     endpoint pod     endpoint pod     endpoint pod     endpoint pod
```

Each `svc-*` box above is a dedicated chain containing its own anonymous map,
so the number of chains and maps grows one-for-one with the number of Services.
Note that svc-B and svc-D have identical rules apart from the endpoint IPs, yet
each still gets its own chain and map.

## Proposed design: shared dispatch chains + one endpoints map

Instead of a chain and an anonymous map per Service, this design keeps a
fixed set of `dispatch-N` chains (one per *endpoint count*, shared by every
Service with that many endpoints) and a single shared `@endpoints` map that is
keyed by the Service plus a random bucket number.

### ClusterIP -> endpoint - suggested

Example with four Services:

- svc-A - 1 endpoint
- svc-B - 2 endpoints
- svc-C - 3 endpoints
- svc-D - 2 endpoints

```
    packet to  <clusterIP>:<port>
                |
                v
      +-------------------+
      |  chain: services  |
      +-------------------+
                |
                |  lookup  dst . proto . port
                v
      +------------------------------------------+
      |  map: @service-ips      (ONE shared map) |
      |                                          |
      |   type ipv4_addr . inet_proto            |
      |        . inet_service : verdict          |
      |                                          |
      |   172.30.0.41 . tcp . 80  -> dispatch-1  |   # svc-A
      |   172.30.0.42 . tcp . 80  -> dispatch-2  |   # svc-B
      |   172.30.0.43 . tcp . 80  -> dispatch-3  |   # svc-C
      |   172.30.0.44 . tcp . 80  -> dispatch-2  |   # svc-D - shared with svc-B, which also has 2 endpoints
      |   ...        one row per Service, value  |
      |              is just "how many endpoints"|
      +------------------------------------------+
                            |
                 +----------+------------------------+-----------------------------------+
                 |                                   |                                   |
                 | goto                              | goto                              | goto
                 | (svc-A)                           | (svc-B, svc-D)                    | (svc-C)
                 v                                   v                                   v
+--------------------------------+  +--------------------------------+  +--------------------------------+
| chain: dispatch-1              |  | chain: dispatch-2              |  | chain: dispatch-3              |
|                                |  |                                |  |                                |
| ct mark = numgen random mod 1  |  | ct mark = numgen random mod 2  |  | ct mark = numgen random mod 3  |
|                                |  |                                |  |                                |
| dnat to dst . proto . port     |  | dnat to dst . proto . port     |  | dnat to dst . proto . port     |
|         . ct mark              |  |         . ct mark              |  |         . ct mark              |
|         map @endpoints         |  |         map @endpoints         |  |         map @endpoints         |
+--------------------------------+  +--------------------------------+  +--------------------------------+
                 |                                   |                                   |
                 +-----------------------------+-----+-----------------------------------+
                                               |
                                               |  lookup  dst . proto . port . bucket
                                               v
      +--------------------------------------------------------------------------------+
      |  map: @endpoints                                              (ONE shared map) |
      |                                                                                |
      |   type ipv4_addr . inet_proto . inet_service . mark : ipv4_addr . inet_service |
      |                                                                                |
      |   172.30.0.41 . tcp . 80 . 0 -> 10.0.1.1:80    # svc-A                         |
      |                                                                                |
      |   172.30.0.42 . tcp . 80 . 0 -> 10.0.2.1:80    # svc-B                         |
      |   172.30.0.42 . tcp . 80 . 1 -> 10.0.2.2:80                                    |
      |                                                                                |
      |   172.30.0.43 . tcp . 80 . 0 -> 10.0.3.1:80    # svc-C                         |
      |   172.30.0.43 . tcp . 80 . 1 -> 10.0.3.2:80                                    |
      |   172.30.0.43 . tcp . 80 . 2 -> 10.0.3.3:80                                    |
      |                                                                                |
      |   172.30.0.44 . tcp . 80 . 0 -> 10.0.4.1:80    # svc-D                         |
      |   172.30.0.44 . tcp . 80 . 1 -> 10.0.4.2:80                                    |
      |   ...        one row per endpoint                                              |
      +--------------------------------------------------------------------------------+
                                               |
                                               v
                                         endpoint pod
```

The `dispatch-N` chains are not per Service: svc-B and svc-D both have two
endpoints, so both `goto dispatch-2` and are told apart only by their rows in
`@endpoints`. Only as many chains exist as there are distinct endpoint counts
in the cluster.
