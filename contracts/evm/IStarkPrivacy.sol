// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IStarkPrivacyPool
 * @notice Solidity interface for the StarkPrivacy pool on Kakarot zkEVM.
 *
 * Kakarot runs EVM bytecode on Starknet's CairoVM, so EVM dApps can call
 * this interface which maps to the underlying Cairo PrivacyPool contract.
 *
 * This enables existing Solidity protocols to integrate privacy features
 * without rewriting in Cairo.
 */
interface IStarkPrivacyPool {
    /// @notice Deposit tokens into the privacy pool.
    /// @param commitment The note commitment = Poseidon(owner, value, asset_id, blinding).
    /// @param amount     The amount of tokens to deposit.
    /// @param assetId    The asset identifier (0 = native token).
    function deposit(
        uint256 commitment,
        uint256 amount,
        uint256 assetId
    ) external payable;

    /// @notice Execute a private 2-in-2-out transfer.
    /// @param proof              STARK proof data.
    /// @param merkleRoot         Merkle root the proof is valid against.
    /// @param nullifiers         Two nullifiers being consumed.
    /// @param outputCommitments  Two new output commitments.
    function transfer(
        uint256[] calldata proof,
        uint256 merkleRoot,
        uint256[2] calldata nullifiers,
        uint256[2] calldata outputCommitments
    ) external;

    /// @notice Withdraw tokens from the privacy pool.
    /// @param proof            STARK proof data.
    /// @param merkleRoot       Merkle root the proof is valid against.
    /// @param nullifiers       Two nullifiers being consumed.
    /// @param changeCommitment Commitment for the change note.
    /// @param recipient        Address to receive the withdrawn tokens.
    /// @param amount           Amount to withdraw.
    /// @param assetId          Asset identifier.
    function withdraw(
        uint256[] calldata proof,
        uint256 merkleRoot,
        uint256[2] calldata nullifiers,
        uint256 changeCommitment,
        address recipient,
        uint256 amount,
        uint256 assetId
    ) external;

    /// @notice Get the current Merkle root.
    function getRoot() external view returns (uint256);

    /// @notice Get the number of leaves in the tree.
    function getLeafCount() external view returns (uint256);

    /// @notice Check if a nullifier has already been spent.
    function isNullifierSpent(uint256 nullifier) external view returns (bool);

    /// @notice Check if a root is in the known-root history.
    function isKnownRoot(uint256 root) external view returns (bool);

    /// @notice Get the pool balance for a specific asset.
    function getPoolBalance(uint256 assetId) external view returns (uint256);
}

/**
 * @title IStealthRegistry
 * @notice EVM interface to the StarkPrivacy stealth address registry.
 */
interface IStealthRegistry {
    /// @notice Register a stealth meta-address (spending + viewing public keys).
    function registerMetaAddress(
        uint256 spendingPubKey,
        uint256 viewingPubKey
    ) external;

    /// @notice Publish an ephemeral key for a stealth payment.
    /// @param ephemeralPubKey The one-time public key.
    /// @param encryptedNote   Encrypted note data for the recipient.
    /// @param noteCommitment  The commitment of the deposited note.
    function publishEphemeralKey(
        uint256 ephemeralPubKey,
        uint256[] calldata encryptedNote,
        uint256 noteCommitment
    ) external;

    /// @notice Get a registered meta-address.
    function getMetaAddress(
        address owner
    ) external view returns (uint256 spendingPubKey, uint256 viewingPubKey);

    /// @notice Get total number of published ephemeral keys.
    function getEphemeralCount() external view returns (uint256);
}

/**
 * @title IComplianceOracle
 * @notice EVM interface to the StarkPrivacy compliance oracle.
 */
interface IComplianceOracle {
    /// @notice Check if a deposit is allowed.
    function checkDeposit(address depositor) external view returns (bool);

    /// @notice Check if a withdrawal is allowed.
    function checkWithdrawal(address recipient) external view returns (bool);

    /// @notice Check if a transfer is allowed.
    function checkTransfer(uint256 nullifier) external view returns (bool);
}

/**
 * @title IEpochManager
 * @notice EVM interface to the cross-chain epoch manager.
 */
interface IEpochManager {
    /// @notice Get the current epoch number.
    function getCurrentEpoch() external view returns (uint64);

    /// @notice Get the finalized root for a given epoch.
    function getEpochRoot(uint64 epoch) external view returns (uint256);

    /// @notice Get the chain ID.
    function getChainId() external view returns (uint256);
}
