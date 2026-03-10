/// IComplianceOracle — interface for optional compliance policy enforcement.
///
/// The privacy pool calls this oracle before processing deposits and withdrawals.
/// If no oracle is configured (zero address), compliance checks are skipped.
/// Deployers can plug in any compliance strategy: sanctions screening, zkKYC, etc.

#[starknet::interface]
pub trait IComplianceOracle<TContractState> {
    /// Check whether a deposit from `depositor` of `amount` for `asset_id` is allowed.
    /// Returns true if compliant, false if blocked.
    fn check_deposit(
        self: @TContractState,
        depositor: starknet::ContractAddress,
        amount: u256,
        asset_id: felt252,
    ) -> bool;

    /// Check whether a withdrawal to `recipient` of `amount` for `asset_id` is allowed.
    fn check_withdrawal(
        self: @TContractState,
        recipient: starknet::ContractAddress,
        amount: u256,
        asset_id: felt252,
    ) -> bool;

    /// Check whether a transfer proof with given nullifiers is allowed.
    /// This can be used for selective transparency / viewing key disclosure.
    fn check_transfer(
        self: @TContractState, nullifiers: Span<felt252>, output_commitments: Span<felt252>,
    ) -> bool;
}
