# StarkPrivacy Protocol Specification

> Revision 1.2 — March 2026

## 1. Overview

StarkPrivacy is a UTXO-based privacy protocol for the Starknet ecosystem.
Users deposit assets into a shared pool, perform shielded transfers and
withdrawals using STARK proofs, and optionally bridge notes across L1, L2,
and Madara appchains.

### Design goals

| Goal                | Mechanism                                             |
| ------------------- | ----------------------------------------------------- |
| Transaction privacy | Nullifier-based spend model; Merkle commitment scheme |
| Unlinkability       | Stealth addresses, encrypted note scanning            |
| Compliance          | Pluggable sanctions oracle (opt-in)                   |
| Metadata resistance | Fixed-size 64-felt envelopes with dummy padding       |
| Cross-chain privacy | Epoch-root syncing across L1 ↔ Starknet ↔ Madara      |
| Scalability         | Depth-32 Poseidon Merkle tree (~4 billion leaves)     |

---

## 2. Cryptographic Primitives

### 2.1 Hash Functions

| Function                      | Use                          | Definition                         |
| ----------------------------- | ---------------------------- | ---------------------------------- |
| `poseidon_hash_2(a, b)`       | Merkle nodes, commitments    | Starknet Poseidon (sponge, rate 2) |
| `poseidon_hash_4(a, b, c, d)` | Note commitments, nullifiers | Chained: `H(H(a,b), H(c,d))`       |
| `pedersen_hash(a, b)`         | Legacy compatibility         | Starknet Pedersen                  |

All arithmetic is over the STARK field $\mathbb{F}_p$ where:

$$p = 2^{251} + 17 \cdot 2^{192} + 1$$

### 2.2 Note Commitment

A note $N$ has fields $(value, asset\_id, owner\_hash, blinding)$. The
commitment is:

$$C = \text{poseidon\_hash\_4}(value, asset\_id, owner\_hash, blinding)$$

where $blinding \xleftarrow{R} \mathbb{F}_p$ is a random blinding factor and
$owner\_hash = \text{poseidon\_hash\_2}(spending\_key, 0)$.

### 2.3 Nullifier

To spend a note with commitment $C$, the owner produces:

$$nf = \text{poseidon\_hash\_4}(spending\_key, C, chain\_id, app\_id)$$

The nullifier is published on-chain. Since it includes the spending key, only
the note owner can produce the correct nullifier. Domain separation via
`chain_id` and `app_id` prevents cross-protocol replay attacks.

---

## 3. Merkle Tree

A **depth-32 Poseidon Merkle tree** stores note commitments.

- **Zero hashes**: $z_0 = 0$, $z_{i+1} = \text{poseidon\_hash\_2}(z_i, z_i)$
- **Leaf insert**: Append commitment at the next available index.
- **Root history**: The pool stores a ring buffer of 100 recent roots to allow
  concurrent transactions.
- **Proof**: A Merkle proof is a 32-element sibling path plus a leaf index.
  Verification recomputes the root from the leaf to the tree top.

---

## 4. Circuits

### 4.1 Transfer Circuit

Proves knowledge of two input notes and creates two output notes without
revealing values or identities.

**Public inputs**: `merkle_root`, `nullifier_0`, `nullifier_1`, `out_cm_0`, `out_cm_1`

**Private inputs**: `spending_key`, input note fields × 2, Merkle proofs × 2,
output note fields × 2

**Constraints**:

1. Each input commitment recomputes correctly from its fields.
2. Each nullifier matches `poseidon_hash_4(sk, C_i, chain_id, app_id)`.
3. Each Merkle proof verifies against `merkle_root`.
4. Value conservation: $v_{in_0} + v_{in_1} = v_{out_0} + v_{out_1} + fee$.
5. Output commitments recompute correctly.

### 4.2 Withdraw Circuit

Proves ownership of two input notes and exits a portion of value to a public
address.

**Public inputs**: `merkle_root`, `nullifier_0`, `nullifier_1`, `change_cm`,
`exit_value`, `recipient`

**Constraints**: Same as Transfer, except one output is an on-chain balance
transfer of `exit_value` to `recipient`.

---

## 5. Contracts

### 5.1 PrivacyPool

The main entry point for deposits, transfers, and withdrawals.

| Function                                                              | Description                                          |
| --------------------------------------------------------------------- | ---------------------------------------------------- |
| `deposit(commitment, amount, asset_id)`                               | Inserts commitment into tree, escrows `amount`       |
| `transfer(proof, root, nullifiers, out_cms)`                          | Verifies proof, records nullifiers, inserts outputs  |
| `withdraw(proof, root, nullifiers, change_cm, exit_value, recipient)` | Same as transfer + sends `exit_value` to `recipient` |

### 5.2 NullifierRegistry

Tracks spent nullifiers across the pool. `is_spent(nf) -> bool` and
`mark_spent(nf)`.

### 5.3 Verifier

On-chain STARK verifier that checks proof validity:
`verify(proof_type, merkle_root, nullifiers, commitments, proof_data) -> bool`.

### 5.4 Compliance (SanctionsOracle)

Optional hook: `is_allowed(address) -> bool`. If deployed, pool checks callers
against the oracle before deposits.

### 5.5 Security Components

| Component         | Purpose                                           |
| ----------------- | ------------------------------------------------- |
| `RateLimiter`     | Per-address deposit/transfer/withdraw rate limits |
| `ReentrancyGuard` | Prevents reentrant calls during withdraw          |

### 5.6 Governance Contracts

| Contract            | Purpose                                                                                             |
| ------------------- | --------------------------------------------------------------------------------------------------- |
| `MultiSig`          | M-of-N signer approval for governance proposals (`propose`, `approve`, `forward_to_timelock`)       |
| `Timelock`          | Delayed execution queue — enforces minimum delay between queue and execute (`queue`, `execute`, `cancel`) |
| `UpgradeableProxy`  | Delegating proxy with governor / emergency-governor roles for contract upgrades                       |

### 5.7 Kakarot Adapter

A pure proxy that routes EVM-originated calls to the underlying `PrivacyPool`.

| Function                             | Description                                           |
| ------------------------------------ | ----------------------------------------------------- |
| `evm_deposit(commitment, amount)`    | EVM-compatible deposit route                          |
| `evm_transfer(proof, root, ...)`     | EVM-compatible transfer route                         |
| `evm_withdraw(proof, root, ...)`     | EVM-compatible withdraw route                         |
| `estimate_evm_fee(amount, gas)`      | Stateless fee estimation (view)                       |
| `pause() / unpause()`               | Emergency pause mechanism (owner-only)                |
| `set_gas_price_factor(factor)`       | Configurable gas price multiplier (owner-only, capped)|

---

## 6. Stealth Addresses

### 6.1 Derivation

A recipient publishes a **meta-address** $(S, V)$ where $S$ is the spending
public key and $V$ is the viewing public key.

The sender:

1. Samples ephemeral scalar $r$.
2. Computes shared secret $s = \text{poseidon\_hash\_2}(r \cdot V, \text{label})$.
3. Computes stealth spending key hash $P = \text{poseidon\_hash\_2}(S, s)$.
4. Publishes ephemeral public key $R = r \cdot G$ on the
   `StealthRegistry` contract.

The recipient scans $R$ values: $s' = \text{poseidon\_hash\_2}(v \cdot R, \text{label})$
and checks whether $\text{poseidon\_hash\_2}(S, s') = P$.

### 6.2 Encrypted Note

An `EncryptedNote` includes the encrypted note payload XORed with
`poseidon_hash_2(shared_secret, epoch)`, enabling per-epoch scanning.
Payloads are padded to a fixed 8-field width to prevent length leakage.

---

## 7. Bridge Architecture

### 7.1 Epoch Manager

Manages privacy set epochs. Each epoch accumulates deposits, and an operator
can finalise an epoch by publishing the Merkle root commitment.

| Function                        | Description                          |
| ------------------------------- | ------------------------------------ |
| `advance_epoch(new_root)`       | Advances epoch counter, stores root  |
| `get_epoch_root(epoch)`         | Returns stored Merkle root for epoch |
| `register_nullifier(nf, epoch)` | Records nullifier used in epoch      |

### 7.2 Bridge Router

Routes deposits and withdrawals across epochs:

- `deposit_to_epoch(commitment, epoch)` — assigns to a specific epoch
- `publish_epoch_root(epoch, root)` — publishes finalised root

### 7.3 L1 Bridge Adapter

Sends/receives messages to/from Ethereum L1 using Starknet's native
messaging (`send_message_to_l1_syscall`).

| Function                                                  | Description                   |
| --------------------------------------------------------- | ----------------------------- |
| `send_commitment_to_l1(commitment, amount, l1_recipient)` | Bridges commitment to L1      |
| `receive_from_l1(commitment, amount)`                     | Accepts inbound L1 commitment |

### 7.4 Madara Appchain Adapter

Cross-chain privacy messaging for Madara L3 appchains:

| Function                                                                        | Description                               |
| ------------------------------------------------------------------------------- | ----------------------------------------- |
| `register_peer(chain_id, adapter_address)`                                      | Register a peer appchain                  |
| `lock_for_appchain(commitment, target_chain, nullifiers, encrypted)`            | Lock commitment for cross-chain transfer  |
| `receive_from_appchain(commitment, source_chain, epoch, epoch_root, encrypted)` | Receive from peer after root verification |
| `sync_epoch_root(peer_chain, epoch, root)`                                      | Sync Merkle root from peer                |

---

## 7a. Operation Sequence Diagrams

### Deposit Flow

```
User                   SDK                    Relayer              PrivacyPool
 │                      │                       │                      │
 │── deposit(amt) ─────>│                       │                      │
 │                      │── generate commitment │                      │
 │                      │── build envelope ────>│                      │
 │                      │                       │── deposit(cm, amt) ─>│
 │                      │                       │                      │── insert leaf
 │                      │                       │                      │── update root
 │                      │                       │<── tx_hash ─────────│
 │<── tx_hash ─────────│<── confirmation ──────│                      │
```

### Withdraw Flow

```
User                   SDK                    Relayer              PrivacyPool
 │                      │                       │                      │
 │── withdraw(addr,amt)>│                       │                      │
 │                      │── select 2 input notes│                      │
 │                      │── generate ZK proof   │                      │
 │                      │── pad to 64-felt env  │                      │
 │                      │── submit envelope ───>│                      │
 │                      │                       │── withdraw(proof) ──>│
 │                      │                       │                      │── verify proof
 │                      │                       │                      │── mark nullifiers
 │                      │                       │                      │── send exit_value
 │                      │                       │<── tx_hash ─────────│
 │<── tx_hash ─────────│<── confirmation ──────│                      │
```

### Governance Flow (MultiSig → Timelock → Target)

```
Signer 1               MultiSig               Timelock             Target Contract
 │                       │                       │                      │
 │── propose(target,     │                       │                      │
 │   selector, calldata)>│                       │                      │
 │                       │── auto-approve ──────>│                      │
 │                       │                       │                      │
Signer 2                 │                       │                      │
 │── approve(prop_id) ──>│ (reaches threshold)   │                      │
 │                       │                       │                      │
Signer 1                 │                       │                      │
 │── forward_to_timelock>│── queue(op) ─────────>│                      │
 │                       │                       │── wait delay ───────>│
 │                       │                       │                      │
 │── execute(op, data) ─>│                       │                      │
 │                       │               execute>│── call_contract ────>│
 │                       │                       │                      │── apply change
```

---

## 8. SDK Architecture

```
┌─────────────────────────────────────────────────┐
│                StarkPrivacyClient                │
│  (deposit, transfer, withdraw, balance, scan)    │
├─────────────┬──────────────┬────────────────────┤
│  KeyManager │  NoteManager │  EventIndexer      │
│  (keys.ts)  │  (notes.ts)  │  (indexer.ts)      │
├─────────────┼──────────────┼────────────────────┤
│  Prover     │  Relayer     │  Metadata           │
│  (prover.ts)│  (relayer.ts)│  (metadata.ts)     │
├─────────────┴──────────────┴────────────────────┤
│  Stone-Prover / S-Two Backend  (stone-prover.ts) │
│  (LocalProver | StoneProver | S2Prover)          │
├──────────────────────────────────────────────────┤
│  Crypto (poseidon, pedersen, commitments)         │
│  Stealth (derivation, scanning, encrypted notes)  │
└──────────────────────────────────────────────────┘
```

### 8.1 Proof Generation

The `ProverBackend` interface abstracts proof generation:

| Backend       | Description                                     |
| ------------- | ----------------------------------------------- |
| `LocalProver` | In-process witness assembly (development / MVP) |
| `StoneProver` | Remote stone-prover HTTP endpoint               |
| `S2Prover`    | Remote S-Two prover with async job polling      |

### 8.2 Metadata Resistance

All proofs are wrapped in fixed-size 64-felt envelopes. Batches are padded
with dummy envelopes to a configurable batch size. Relay timing is jittered
to prevent timing-based deanonymisation.

---

## 9. Security Model

### Threat Model

| Threat                   | Mitigation                                                          |
| ------------------------ | ------------------------------------------------------------------- |
| Double-spend             | Nullifier uniqueness enforced on-chain                              |
| Front-running            | MEV protection via encrypted mempool (future)                       |
| Merkle root manipulation | Root history ring buffer; proof must validate against a stored root |
| Metadata analysis        | Fixed-size envelopes, dummy padding, relay jitter                   |
| Replay attacks           | Domain-separated nullifiers (chain_id, app_id)                      |
| Reentrancy               | ReentrancyGuard component on withdraw                               |
| Denial of service        | Per-address rate limiting                                           |
| Sanctions evasion        | Optional compliance oracle check on deposit                         |

### Trust Assumptions

1. The Starknet sequencer is live and correctly orders transactions.
2. The STARK proof system is computationally sound.
3. Poseidon hash is collision-resistant over $\mathbb{F}_p$.
4. The sanctions oracle, if deployed, is operated honestly.
5. Cross-chain epoch roots are synced by an honest relayer set (see §9.1).

### 9.1 Relayer Trust Model

The **relayer** is an off-chain service that submits ZK-proven transactions
on behalf of users to preserve sender anonymity. Users never call the
Starknet sequencer directly — the relayer is the sole `msg.sender`.

#### Properties

| Property                  | Guarantee                                                                                                  | Mechanism                                                                                                                                         |
| ------------------------- | ---------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Correctness**           | A relayer **cannot** steal funds, forge proofs, or double-spend.                                           | All state transitions are verified by the on-chain proof verifier and nullifier registry. A malicious relayer can only submit well-formed proofs. |
| **Censorship resistance** | A single relayer **can** censor (refuse to submit) a user's transaction.                                   | Mitigated by allowing multiple independent relayers. Any relayer with the user's signed proof can submit it.                                      |
| **Privacy**               | A relayer learns the proof envelope but **cannot** link sender ↔ recipient beyond what is public on-chain. | Fixed-size envelopes, dummy padding, relay jitter, and batch shuffling (see §8.2).                                                                |
| **Liveness**              | A relayer may go offline.                                                                                  | SDK supports relayer failover: `RelayerClient` accepts a list of endpoints and rotates on failure.                                                |
| **Fee fairness**          | A relayer charges a fee taken from the shielded amount.                                                    | Fee is encoded in the proof's public inputs and verified on-chain. The relayer cannot inflate it.                                                 |

#### Threat: Malicious / Colluding Relayer

- **Selective dropping**: A relayer may silently drop transactions. Users
  detect this via confirmation timeouts and resubmit through another relayer.
- **Timing correlation**: A relayer that logs timestamps can attempt to
  correlate submissions with on-chain inclusion. Relay jitter mitigates this
  but does not eliminate it against a relayer + sequencer collusion.
- **Proof resubmission**: A relayer cannot replay a spent proof because
  nullifiers are marked on-chain. Resubmission of the same proof is harmless.
- **Cross-chain root relay**: `sync_epoch_root` on the MadaraAdapter and
  BridgeRouter is callable by any address, but the root is cryptographically
  committed by the source chain's pool contract. A malicious relayer cannot
  forge a root — only delay or withhold its relay. Honest-1-of-N suffices.

#### Current Limitations (Pre-Mainnet)

- **No relayer bond or slashing.** A misbehaving relayer faces no economic
  penalty. Production deployments should introduce a staked relayer registry
  with slashing for provably-dropped transactions.
- **No multi-relayer rotation** in the SDK yet — `RelayerClient` connects
  to one endpoint at a time with manual failover.
- **No liveness proof.** The protocol does not verify that a relayer is
  actively serving requests. A future heartbeat or challenge mechanism is
  recommended.

### 9.2 Cross-Chain Message Ordering

StarkPrivacy operates across three settlement layers: Starknet L2, Madara L3 appchains, and L1 Ethereum (via the L1 bridge adapter). Each layer has different message ordering guarantees.

#### Layer-Specific Ordering

| Path                          | Mechanism                                   | Ordering Guarantee                                                                                                              |
| ----------------------------- | ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| **L2→L1** (Starknet→Ethereum) | `send_message_to_l1_syscall`                | Messages arrive in the order they are included in proven batches. No per-transaction ordering within a batch.                   |
| **L1→L2** (Ethereum→Starknet) | L1→L2 message consumption                   | The Starknet sequencer delivers messages; the consumer calls `handle_l1_message`. Order depends on sequencer scheduling.        |
| **L2↔L3** (Starknet↔Madara)   | `sync_epoch_root` + `receive_from_appchain` | Epoch-based: the owner relays epoch roots. Ordering is per-epoch (not per-transaction). Intra-epoch ordering is not guaranteed. |
| **EVM↔Cairo** (Kakarot)       | Direct contract call                        | Synchronous — same transaction, same block. No ordering concerns.                                                               |

#### Safety Properties

1. **No double-spend across layers.** Domain-separated nullifiers (`chain_id`, `app_id`) ensure a nullifier spent on Starknet L2 cannot be replayed on a Madara appchain or vice versa.

2. **No commitment replay.** Both `BridgeRouter.unlocked_commitments` and `MadaraAdapter.processed_commitments` track processed commitments. A commitment bridged once cannot be bridged again.

3. **Epoch root integrity.** `receive_from_appchain` verifies the source epoch root matches a previously synced root. If the root was never synced (or was synced incorrectly), the inbound transfer is rejected.

#### Known Limitations

- **No guaranteed delivery.** If the relayer / operator fails to relay an epoch root, inbound transfers for that epoch are blocked until the root is synced. Liveness depends on the operator.
- **No total ordering across layers.** Two deposits on different layers in the same wall-clock second may appear in any order in the Merkle tree. This does not affect correctness (the ZK proof references a specific root) but may surprise indexers.
- **Epoch finality lag.** Outbound locks are committed immediately, but the destination cannot accept them until the source epoch is finalized and its root is relayed. This introduces a latency proportional to the epoch duration.
- **L1→L2 censorship.** The Starknet sequencer controls which L1→L2 messages are consumed and when. A censoring sequencer could delay bridged deposits.

### 9.3 Privacy Analysis

#### 9.3.1 Nullifier Leakage (Information-Theoretic)

Each spend publishes two nullifiers on-chain: `nf = Poseidon(Poseidon(sk, cm), Poseidon(chain_id, app_id))`. We analyze what an observer can infer.

**What nullifiers reveal:**

| Observable                     | Inference                                                                                                 | Severity        |
| ------------------------------ | --------------------------------------------------------------------------------------------------------- | --------------- |
| Nullifier value                | Nothing — Poseidon is a PRF; the nullifier is computationally indistinguishable from random without `sk`. | None            |
| Nullifier count per block      | Number of spends (not deposits) in that block.                                                            | Low             |
| Two nullifiers per transaction | Each tx spends exactly two notes (fixed fan-in). An observer knows each tx consumes two UTXOs.            | Low (by design) |
| Nullifier timing               | When a note was spent (block timestamp). Combined with deposit timestamps, narrows the anonymity set.     | Medium          |
| Nullifier absence              | If a known commitment has no corresponding nullifier, the note is unspent.                                | Low             |

**Anonymity set analysis:**

The anonymity set for a withdrawal is the set of all unspent commitments that share the same root.
With a Merkle tree of $N$ leaves and $S$ spent nullifiers, the anonymity set size is $N - S$.
The **minimum anonymity set** equals the number of deposits since the last root the verifier accepts (ring buffer of 100 roots).

**Mitigations already in place:**

- Domain separation (`chain_id`, `app_id`) prevents cross-chain nullifier correlation
- Fixed 2-in-2-out fan-in/fan-out hides whether a tx is a self-transfer, split, or merge
- Dummy envelope batching (see §9.3.2) hides the true transaction rate

**Residual risk:**

- A passive observer with deposit timing data can narrow the anonymity set by intersecting deposit-time windows with spend-time windows. Standard countermeasure: users should wait for at least $k$ additional deposits before spending (configurable in SDK via `minAnonymitySet`).

#### 9.3.2 Traffic Analysis Resistance

The SDK implements four layers of metadata resistance:

| Layer                | Mechanism                                     | Parameters               | Protection                                        |
| -------------------- | --------------------------------------------- | ------------------------ | ------------------------------------------------- |
| **Envelope padding** | All proof types padded to 64 felt252 elements | `ENVELOPE_SIZE = 64`     | Transfer/withdraw/dummy indistinguishable by size |
| **Batch padding**    | Real proofs mixed with dummy proofs           | `DEFAULT_BATCH_SIZE = 8` | Hides number of real txs per batch                |
| **Batch shuffling**  | Fisher-Yates shuffle with rejection sampling  | Unbiased                 | Hides real/dummy positions within batch           |
| **Relay jitter**     | Uniform random delay before submission        | 100ms – 2000ms           | Decorrelates user action time from on-chain time  |

**Adversary model:**

A network-level adversary who can:

1. Observe all on-chain transactions (public by definition)
2. Observe the relayer's submission timing
3. Correlate user IP→relayer connection with on-chain events

**What the adversary learns:**

- **Batch granularity:** The adversary sees 8-envelope batches. With $r$ real txs and $8-r$ dummies per batch, the adversary cannot distinguish which envelopes are real (all are 64 felts, all have valid structure).
- **Timing:** With 100–2000ms jitter, the adversary's timing window is ≥2 seconds per batch. If multiple users submit within this window, they are indistinguishable.
- **IP correlation:** If a single user connects to the relayer and a batch is submitted shortly after, the adversary can link with probability inversely proportional to the number of concurrent users.

**Known limitations:**

- **Single-user batches.** If only one user is active, $r=1$ and the adversary knows one of the 8 envelopes is real (12.5% chance per guess). This is a fundamental limitation of low-traffic pools.
- **No mix network.** The relayer is a single hop, not a multi-hop mix network. IP-level anonymity requires external tools (Tor, VPN).
- **No cover traffic from the protocol.** Dummy envelopes are generated by the client, not by the relayer. If the relayer has zero clients, it submits zero batches — revealing inactivity.

**Recommendation:** For production, deploy multiple relayers with independent batching + a protocol-level cover traffic generator that submits dummy batches during quiet periods.

#### 9.3.3 Key Leakage Impact Analysis

StarkPrivacy uses a two-key model: spending key (`sk`) and viewing key (`vk = Poseidon(sk, 1)`).

| Compromised Key      | What Attacker Gains                                                                                          | What Attacker Cannot Do                                                                                      |
| -------------------- | ------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------ |
| **Viewing key only** | Scan all incoming notes (via `tryScanNote`); learn which notes belong to the user; compute total balance     | Spend any note (cannot derive nullifiers without `sk`); forge new commitments; impersonate the user on-chain |
| **Spending key**     | Everything the viewing key provides, PLUS: derive nullifiers to spend all notes; forge transfers/withdrawals | N/A — full compromise of all current and past notes                                                          |
| **Ephemeral key**    | Recover the shared secret for one specific stealth note; learn the recipient of that single payment          | Scan other notes; spend any note; compromise the viewing key or spending key                                 |

**Forward secrecy:** Compromising the viewing key does **not** reveal past ephemeral keys or shared secrets (Poseidon is one-way). However, it does reveal all future and past note ownership (since the viewing key is static). True forward secrecy would require ratcheted viewing keys (not currently implemented).

**Viewing key sharing (auditor model):** The `exportViewingKeys()` function enables users to share read-only access with auditors or compliance officers. The auditor can verify balances and transaction involvement but cannot spend. This is the basis for the selective disclosure model (see §8 Compliance).

**Post-compromise recovery:** If a spending key is suspected compromised:

1. Generate a new `KeyManager` with fresh keys
2. Transfer all notes from old key → new key (self-transfer)
3. Old nullifiers will be spent; new commitments belong to new key
4. Old spending key can no longer spend the transferred notes

**Recommendation:** Store spending keys on hardware wallets or air-gapped devices. Share viewing keys only with trusted auditors under NDA/legal agreement. Implement key rotation reminders in the CLI.

### 9.4 STARK Soundness Parameters

StarkPrivacy delegates STARK proof generation to an external prover backend (stone-prover or S-Two). The application layer defines envelope structure and validates proof format but does not control low-level STARK parameters. This section documents the minimum requirements the prover backend must satisfy.

#### Target Security Level

**128-bit computational security** — an adversary must perform at least $2^{128}$ operations to forge a valid proof.

#### Parameter Requirements

| Parameter             | Minimum Value                                           | Rationale                                                                                                        |
| --------------------- | ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| **Field**             | Starknet felt252 ($p = 2^{251} + 17 \cdot 2^{192} + 1$) | Native field; fixed by Starknet                                                                                  |
| **FRI blowup factor** | ≥ 4 (recommended: 16)                                   | Higher blowup increases proof size but improves soundness. Factor of 4 gives $\log_2(4) = 2$ bits per FRI query. |
| **FRI query count**   | ≥ 30 (for blowup 16) or ≥ 64 (for blowup 4)             | Each query contributes $\log_2(\text{blowup})$ bits. Need $\geq 128$ total bits.                                 |
| **Hash function**     | Poseidon (Starknet-native)                              | Must match the commitment/nullifier hash used in circuits.                                                       |
| **Constraint degree** | ≤ 4                                                     | Transfer circuit: degree ~2 (Poseidon rounds + linear constraints). Within standard bounds.                      |
| **Trace length**      | Power of 2, ≥ $2^{10}$                                  | Depends on circuit size. Estimated ~$2^{14}$ for transfer, ~$2^{14}$ for withdraw.                               |
| **Grinding factor**   | ≥ 20 bits                                               | Proof-of-work on proof commitment; raises forging cost by $2^{20}$.                                              |

#### What the Application Layer Validates

The on-chain `MockVerifier` (current) and `StarkVerifier` (production) validate:

1. **Envelope structure** — proof type field, minimum size (7 for transfer, 8 for withdraw)
2. **Public input consistency** — Merkle root, nullifiers, commitments match declared values
3. **STARK proof** — (StarkVerifier only) verifies the STARK proof using Starknet's built-in verifier

The application layer does **not** validate FRI parameters directly — it trusts that a valid STARK proof implies the prover used parameters that satisfy the verifier's acceptance criteria.

#### Pre-Mainnet Checklist

- [ ] Confirm stone-prover / S-Two FRI blowup ≥ 4 _(requires prover config review)_
- [ ] Confirm FRI query count yields ≥ 128-bit security _(requires prover config review)_
- [ ] Confirm grinding factor ≥ 20 bits _(requires prover config review)_
- [ ] Run proof verification against StarkVerifier (not MockVerifier) on Sepolia _(Sepolia deployment runbook: `docs/sepolia-deployment-runbook.md`)_
- [ ] Measure proof generation time and size across representative circuits _(SDK `prover.ts` `generateTransferProofAsync`/`generateWithdrawProofAsync` wired and tested)_
- [ ] Verify Poseidon instantiation matches Starknet reference (same round constants, MDS matrix) _(contracts use `poseidon_hash_span` from core lib — matches by construction)_

---

## 10. Gas Costs

Measured values from `snforge test` on Cairo 2.16.0 / snforge 0.57.0.
See `docs/gas-benchmarks.md` for full breakdown including L1 data gas.

| Operation             | L2 Gas      |
| --------------------- | ----------- |
| Deposit               | ~2,755,512  |
| Transfer (2-in-2-out) | ~6,825,036  |
| Withdraw              | ~5,837,148  |
| Stealth register+pub  | ~842,450    |
| Epoch advance         | ~1,376,924  |
| Cross-chain lock      | ~459,860    |
| Full governance flow  | ~3,245,945  |

---

## Appendix A: Felt252 Encoding

All values in the protocol are field elements. Amounts are represented as
raw felt252 values (no fixed-point scaling). Asset IDs are protocol-assigned
felt252 constants. Addresses are Starknet contract addresses (also felt252).
