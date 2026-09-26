# 3-Core MESI Cache-Coherence System

A synthesizable Verilog implementation of the MESI cache-coherence protocol for three processor cores. The project supports both direct-mapped and 4-way set-associative caches and includes a self-checking directed testbench.

## Features

- Three cores sharing one serialized coherence bus.
- MESI states: `I` (Invalid), `S` (Shared), `E` (Exclusive), and `M` (Modified).
- Direct-mapped cache configuration: `WAYS=1`.
- Four-way set-associative configuration: `WAYS=4`.
- Four sets per core and one 32-bit word per cache line.
- Peer snooping, invalidation, intervention, and modified-line writeback.
- Round-robin arbitration for simultaneous core requests.
- Deterministic backing memory for simulation.
- Directed data checks, MESI invariant checks, functional bins, and latency measurement.

## Architecture

```text
                 Core 0 request/response
                           |
                 Core 1 request/response
                           |       +----------------------+
                 Core 2 request/response --->|              |
                                             |  Round-robin  |
                                             |   arbitration  |
                                             +--------+-------+
                                                      |
                                             +--------v-------+
                                             |  MESI control  |
                                             | lookup/snoop   |
                                             | state machine  |
                                             +---+--------+---+
                                                 |        |
                                  +--------------+        +--------------+
                                  |                                       |
                    +-------------v-------------+           +-----------v-----------+
                    | Per-core cache arrays     |           | Backing memory         |
                    | tag / state / data       |           | deterministic model    |
                    | WAYS=1 or WAYS=4        |           | writeback destination  |
                    +--------------------------+           +------------------------+
```

The implementation allows one blocking coherence transaction at a time. The controller accepts one core request, checks the requesting cache, snoops the other cores when required, accesses backing memory on a miss, and returns one response pulse.

### Address format

The default configuration uses 8-bit byte addresses:

```text
Address[7:4] : tag
Address[3:2] : set index (4 sets)
Address[1:0] : byte offset
```

Requests are aligned 32-bit word accesses, so each cache line contains one data word.

### MESI behavior

| Request condition | Result |
|---|---|
| Read hit in `S`, `E`, or `M` | Return local data |
| Read miss with no peer copy | Fill in `E` |
| Read miss with a peer copy | Peer supplies data; copies become `S` |
| Write hit in `E` or `M` | Update locally and enter `M` |
| Write hit in `S` | Invalidate peer copies, then enter `M` |
| Write miss | Obtain data from memory or a peer, then enter `M` |
| Eviction of `M` line | Write data back to backing memory |

## Repository layout

```text
rtl/mesi_system.v       Parameterized MESI controller and cache arrays.
rtl/mesi_wrappers.v     Direct-mapped and 4-way synthesis tops.
tb/tb_mesi.v            Self-checking testbench for both configurations.
README.md               Project documentation.
```
