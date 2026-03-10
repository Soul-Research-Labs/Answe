# StarkPrivacy Protocol Specification

> Revision 1.0 — June 2025

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
5. Cross-chain epoch roots are synced by an honest relayer set.

---

## 10. Gas Costs (Estimated)

| Operation             | L2 Gas   |
| --------------------- | -------- |
| Deposit               | ~300 000 |
| Transfer (2-in-2-out) | ~800 000 |
| Withdraw              | ~750 000 |
| Stealth scan tag      | ~25 000  |
| Epoch advance         | ~150 000 |
| Cross-chain lock      | ~200 000 |

---

## Appendix A: Felt252 Encoding

All values in the protocol are field elements. Amounts are represented as
raw felt252 values (no fixed-point scaling). Asset IDs are protocol-assigned
felt252 constants. Addresses are Starknet contract addresses (also felt252).
