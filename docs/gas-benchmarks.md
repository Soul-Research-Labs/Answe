# Gas Benchmarks

Measured via `snforge test` on Cairo 2.16.0 / snforge 0.57.0.
All values are approximate L2 gas units.

## Methodology

- **Tool**: `snforge test` with gas reporting enabled.
- **Environment**: Cairo 2.16.0, snforge 0.57.0, dev profile.
- **L2 Gas**: Execution gas consumed by the Starknet VM.
- **L1 Data Gas**: Calldata / state-diff gas charged for L1 data availability.
- **Note**: Values are per-test-case measurements and may vary slightly with
  different compiler optimizations or contract sizes. Production gas may differ
  due to sequencer overhead and storage proofs.

## Core Pool Operations

| Operation                              |     L2 Gas | L1 Data Gas |
| -------------------------------------- | ---------: | ----------: |
| Deploy + initial state query           | ~1,504,084 |      ~3,648 |
| `deposit` (single)                     | ~2,755,512 |      ~4,128 |
| `transfer` (2-in-2-out)                | ~6,825,036 |      ~4,704 |
| `withdraw`                             | ~5,837,148 |      ~4,608 |
| Deposit + root change check            | ~2,731,972 |      ~4,128 |
| Multiple deposits (3x)                 | ~5,470,628 |      ~4,320 |
| Full cycle (deposit→transfer→withdraw) | ~8,948,127 |      ~4,992 |
| Double-spend rejection                 | ~6,737,946 |      ~4,704 |

## Stealth Operations

| Operation               |     L2 Gas | L1 Data Gas |
| ----------------------- | ---------: | ----------: |
| Registry initial state  |   ~292,030 |         ~96 |
| Register meta-address   |   ~520,800 |        ~288 |
| Publish ephemeral key   |   ~653,340 |        ~384 |
| Register + publish      |   ~842,450 |        ~576 |
| Multiple ephemeral keys | ~1,359,010 |        ~768 |
| Stealth + pool deposit  | ~3,452,995 |      ~4,704 |

## Bridge / Epoch Operations

| Operation                    |     L2 Gas | L1 Data Gas |
| ---------------------------- | ---------: | ----------: |
| Epoch initial state          |   ~590,070 |        ~384 |
| Record nullifier             |   ~749,332 |        ~672 |
| Record 3 nullifiers          | ~1,497,016 |        ~864 |
| Advance epoch                | ~1,376,924 |        ~768 |
| Advance multiple epochs      | ~2,546,268 |      ~1,344 |
| Publish epoch root           |   ~579,360 |        ~576 |
| Publish multiple epoch roots | ~1,214,670 |        ~768 |
| Lock for bridge              |   ~459,860 |        ~576 |

## Compliance Operations

| Operation                  |   L2 Gas | L1 Data Gas |
| -------------------------- | -------: | ----------: |
| Sanctions initial state    | ~332,420 |        ~192 |
| Add sanctioned address     | ~621,800 |        ~288 |
| Remove sanctioned address  | ~795,500 |        ~192 |
| Multiple addresses         | ~911,270 |        ~384 |
| Check deposit (allowed)    | ~334,760 |        ~192 |
| Check deposit (blocked)    | ~508,860 |        ~288 |
| Check withdrawal (allowed) | ~334,760 |        ~192 |
| Check transfer             | ~330,370 |        ~192 |

## Circuit Verification (On-Chain Proof Verification)

These measure the on-chain cost of verifying ZK proofs via the `MockVerifier`.
Production costs with `StarkVerifier` may differ.

| Operation                   |     L2 Gas |
| --------------------------- | ---------: |
| Transfer circuit valid      | ~2,268,934 |
| Transfer + fee              | ~2,268,934 |
| Withdraw full amount        | ~2,258,978 |
| Note commitment             |    ~27,969 |
| Nullifier domain separation |    ~41,951 |

## Governance Operations

| Operation                                              |     L2 Gas | L1 Data Gas |
| ------------------------------------------------------ | ---------: | ----------: |
| Timelock deploy + initial state                        |   ~340,250 |        ~288 |
| Timelock `queue` operation                             |   ~956,743 |        ~864 |
| Timelock `execute` (with cross-contract call)          | ~1,567,845 |        ~864 |
| Timelock `cancel`                                      |   ~999,573 |        ~864 |
| Timelock `update_min_delay`                            |   ~582,280 |        ~288 |
| MultiSig deploy + initial state                        | ~1,034,770 |        ~864 |
| MultiSig `propose` (auto-approves)                     |   ~997,900 |      ~1,440 |
| MultiSig `approve` (reaches threshold)                 | ~1,338,990 |      ~1,536 |
| MultiSig `revoke` approval                             | ~1,742,540 |      ~1,440 |
| MultiSig `set_timelock`                                |   ~897,050 |      ~1,248 |
| MultiSig `forward_to_timelock`                         | ~2,585,243 |      ~2,592 |
| Full governance flow (propose→approve→forward→execute) | ~3,245,945 |      ~2,592 |

---

## Cost Estimates (at Typical Gas Prices)

The following estimates use representative Starknet gas prices for context.
Actual costs depend on network conditions.

| Assumption            | Value                                |
| --------------------- | ------------------------------------ |
| L2 gas price          | 25 gwei (0.000000025 ETH per unit)   |
| L1 data gas price     | 50 gwei (0.00000005 ETH per unit)    |
| ETH price             | $3,000                               |

| Operation    | Est. Cost (ETH) | Est. Cost (USD) |
| ------------ | ---------------:| ---------------:|
| Deposit      |       ~0.069    |         ~$0.21  |
| Transfer     |       ~0.171    |         ~$0.51  |
| Withdraw     |       ~0.146    |         ~$0.44  |
| Full cycle   |       ~0.224    |         ~$0.67  |
| Governance   |       ~0.081    |         ~$0.24  |

> **Disclaimer**: These are rough estimates for planning purposes only.
> Always check current gas prices on the Starknet block explorer.
