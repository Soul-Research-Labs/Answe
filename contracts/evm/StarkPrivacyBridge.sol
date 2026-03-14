// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IStarknetMessaging
 * @notice Minimal interface for Starknet's core L1↔L2 messaging contract.
 *         See: https://github.com/starkware-libs/cairo-lang/blob/master/src/starkware/starknet/eth/IStarknetMessaging.sol
 */
interface IStarknetMessaging {
    /**
     * @notice Send a message to an L2 contract.
     * @param toAddress  The L2 contract address (felt252).
     * @param selector   The L2 function selector (felt252).
     * @param payload    Array of felt252 values.
     * @return The message hash and nonce.
     */
    function sendMessageToL2(
        uint256 toAddress,
        uint256 selector,
        uint256[] calldata payload
    ) external payable returns (bytes32, uint256);

    /**
     * @notice Consume a message from L2.
     * @param fromAddress The L2 contract that sent the message.
     * @param payload     The expected payload.
     * @return The message hash.
     */
    function consumeMessageFromL2(
        uint256 fromAddress,
        uint256[] calldata payload
    ) external returns (bytes32);
}

/**
 * @title StarkPrivacyBridge
 * @notice L1 Ethereum contract for StarkPrivacy L1↔L2 bridging.
 *
 * Handles:
 * - L1→L2 deposits: Users deposit ETH on L1, sends a message to L2 L1BridgeAdapter
 *   which inserts the commitment into the privacy pool's Merkle tree.
 * - L2→L1 withdrawals: Consumes L2-originated messages to release ETH to recipients.
 *
 * Security:
 * - Deposits require non-zero commitment and amount.
 * - Withdrawals require valid L2→L1 message consumption (verified by Starknet core).
 * - Owner can pause in emergencies.
 * - Replay protection via Starknet's message consumption (each message consumed once).
 */
contract StarkPrivacyBridge {
    // ─── State ───────────────────────────────────────────────────

    /// @notice Starknet core messaging contract on L1.
    IStarknetMessaging public immutable starknetCore;

    /// @notice The L2 L1BridgeAdapter contract address (felt252).
    uint256 public immutable l2BridgeAdapter;

    /// @notice Owner (admin) — can pause/unpause.
    address public owner;

    /// @notice Emergency pause flag.
    bool public paused;

    /// @notice Total deposits initiated from L1.
    uint256 public depositCount;

    /// @notice Total withdrawals completed on L1.
    uint256 public withdrawCount;

    /// @notice L2 function selector for handle_l1_message.
    /// @dev    sn_keccak("handle_l1_message") truncated to 251 bits.
    uint256 public constant HANDLE_L1_MESSAGE_SELECTOR =
        0x02d757788a8d8d6f21d1cd40bce38a8222d70654214e96ff95d8086e684fbee5;

    // ─── Events ──────────────────────────────────────────────────

    event Deposit(
        uint256 indexed commitment,
        uint256 amount,
        uint256 assetId,
        uint256 depositIndex
    );

    event Withdrawal(
        uint256 indexed commitment,
        address indexed recipient,
        uint256 amount,
        uint256 assetId,
        uint256 withdrawIndex
    );

    event Paused(address indexed caller);
    event Unpaused(address indexed caller);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ─── Errors ──────────────────────────────────────────────────

    error BridgePaused();
    error InvalidCommitment();
    error InvalidAmount();
    error MsgValueMismatch();
    error NotOwner();
    error AlreadyPaused();
    error NotPaused();
    error TransferFailed();
    error ZeroAddress();

    // ─── Modifiers ───────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert BridgePaused();
        _;
    }

    // ─── Constructor ─────────────────────────────────────────────

    /**
     * @param _starknetCore    Address of the Starknet core contract on L1.
     * @param _l2BridgeAdapter The L2 L1BridgeAdapter contract address (felt252).
     * @param _owner           Initial owner/admin.
     */
    constructor(
        address _starknetCore,
        uint256 _l2BridgeAdapter,
        address _owner
    ) {
        if (_starknetCore == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();
        if (_l2BridgeAdapter == 0) revert InvalidCommitment();

        starknetCore = IStarknetMessaging(_starknetCore);
        l2BridgeAdapter = _l2BridgeAdapter;
        owner = _owner;
        paused = false;
    }

    // ─── L1 → L2 Deposit ────────────────────────────────────────

    /**
     * @notice Deposit ETH into the StarkPrivacy pool via L1→L2 message.
     * @param commitment The note commitment (Poseidon hash of note fields).
     * @param assetId    Asset identifier (0 = native ETH).
     *
     * The msg.value is sent as the deposit amount. The Starknet core contract
     * will deliver the message to the L2 L1BridgeAdapter, which calls
     * pool.deposit(commitment, amount, assetId).
     */
    function deposit(
        uint256 commitment,
        uint256 assetId
    ) external payable whenNotPaused {
        if (commitment == 0) revert InvalidCommitment();
        if (msg.value == 0) revert InvalidAmount();

        // Build the L2 message payload:
        // [commitment, amount_low, amount_high, asset_id]
        uint256[] memory payload = new uint256[](4);
        payload[0] = commitment;
        payload[1] = msg.value & ((1 << 128) - 1);  // low 128 bits
        payload[2] = msg.value >> 128;                // high 128 bits
        payload[3] = assetId;

        // Send message to L2 via Starknet core.
        // msg.value is forwarded to cover L2 gas fees.
        starknetCore.sendMessageToL2{value: 0}(
            l2BridgeAdapter,
            HANDLE_L1_MESSAGE_SELECTOR,
            payload
        );

        uint256 idx = depositCount;
        depositCount = idx + 1;

        emit Deposit(commitment, msg.value, assetId, idx);
    }

    // ─── L2 → L1 Withdrawal ─────────────────────────────────────

    /**
     * @notice Complete a withdrawal initiated from L2.
     * @param commitment The note commitment that was spent on L2.
     * @param recipient  L1 address to receive the ETH.
     * @param amount     Amount to withdraw (must match L2 message).
     * @param assetId    Asset identifier (must match L2 message).
     *
     * Consumes the L2→L1 message. Starknet core verifies the message
     * was actually sent by the L2 L1BridgeAdapter. This provides replay
     * protection — each message can only be consumed once.
     */
    function withdraw(
        uint256 commitment,
        address recipient,
        uint256 amount,
        uint256 assetId
    ) external whenNotPaused {
        if (commitment == 0) revert InvalidCommitment();
        if (recipient == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();

        // Build the expected L2→L1 message payload.
        // Must match exactly what L2 L1BridgeAdapter sent via send_message_to_l1_syscall.
        uint256[] memory payload = new uint256[](5);
        payload[0] = commitment;
        payload[1] = amount & ((1 << 128) - 1);       // amount_low
        payload[2] = amount >> 128;                     // amount_high
        payload[3] = assetId;
        payload[4] = uint256(uint160(recipient));       // L1 recipient as felt252

        // Consume the message from L2. Reverts if the message doesn't exist.
        starknetCore.consumeMessageFromL2(l2BridgeAdapter, payload);

        uint256 idx = withdrawCount;
        withdrawCount = idx + 1;

        // Transfer ETH to recipient.
        (bool success, ) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();

        emit Withdrawal(commitment, recipient, amount, assetId, idx);
    }

    // ─── Admin ───────────────────────────────────────────────────

    /**
     * @notice Pause the bridge (emergency stop).
     */
    function pause() external onlyOwner {
        if (paused) revert AlreadyPaused();
        paused = true;
        emit Paused(msg.sender);
    }

    /**
     * @notice Unpause the bridge.
     */
    function unpause() external onlyOwner {
        if (!paused) revert NotPaused();
        paused = false;
        emit Unpaused(msg.sender);
    }

    /**
     * @notice Transfer ownership to a new address.
     * @param newOwner The new owner address.
     */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    // ─── Receive ─────────────────────────────────────────────────

    /// @notice Accept ETH deposits (for funding withdrawals).
    receive() external payable {}
}
