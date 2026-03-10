/// MultiSig — M-of-N multisignature governance for critical operations.
///
/// Requires M out of N registered signers to approve an operation before
/// it can be executed. Designed to serve as the proposer for the Timelock.

use starknet::ContractAddress;

#[starknet::interface]
pub trait IMultiSig<TContractState> {
    /// Propose a new operation (any signer).
    fn propose(
        ref self: TContractState,
        target: ContractAddress,
        selector: felt252,
        calldata_hash: felt252,
    ) -> u64;

    /// Approve a pending proposal (any signer who hasn't approved yet).
    fn approve(ref self: TContractState, proposal_id: u64);

    /// Revoke a previous approval (the signer who approved).
    fn revoke(ref self: TContractState, proposal_id: u64);

    /// Get number of signers.
    fn get_signer_count(self: @TContractState) -> u32;

    /// Get required threshold.
    fn get_threshold(self: @TContractState) -> u32;

    /// Get approval count for a proposal.
    fn get_approval_count(self: @TContractState, proposal_id: u64) -> u32;

    /// Check if a proposal has reached threshold.
    fn is_approved(self: @TContractState, proposal_id: u64) -> bool;

    /// Check if an address is a signer.
    fn is_signer(self: @TContractState, address: ContractAddress) -> bool;
}

#[starknet::contract]
pub mod MultiSig {
    use starknet::{ContractAddress, get_caller_address};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };

    const MAX_SIGNERS: u32 = 10;

    #[storage]
    struct Storage {
        threshold: u32,
        signer_count: u32,
        /// index -> signer address
        signers: Map<u32, ContractAddress>,
        /// address -> is_signer
        is_signer_map: Map<ContractAddress, bool>,
        /// proposal counter
        proposal_count: u64,
        /// proposal_id -> target
        proposal_targets: Map<u64, ContractAddress>,
        /// proposal_id -> selector
        proposal_selectors: Map<u64, felt252>,
        /// proposal_id -> calldata_hash
        proposal_calldata_hashes: Map<u64, felt252>,
        /// proposal_id -> approval count
        approval_counts: Map<u64, u32>,
        /// (proposal_id, signer) -> has_approved
        approvals: Map<(u64, ContractAddress), bool>,
        /// proposal_id -> executed
        executed: Map<u64, bool>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        ProposalCreated: ProposalCreated,
        ProposalApproved: ProposalApproved,
        ApprovalRevoked: ApprovalRevoked,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ProposalCreated {
        #[key]
        pub proposal_id: u64,
        pub proposer: ContractAddress,
        pub target: ContractAddress,
        pub selector: felt252,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ProposalApproved {
        #[key]
        pub proposal_id: u64,
        pub signer: ContractAddress,
        pub approval_count: u32,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ApprovalRevoked {
        #[key]
        pub proposal_id: u64,
        pub signer: ContractAddress,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        threshold: u32,
        signer_count: u32,
        signer_1: ContractAddress,
        signer_2: ContractAddress,
        signer_3: ContractAddress,
    ) {
        assert!(threshold > 0 && threshold <= signer_count, "invalid threshold");
        assert!(signer_count >= 1 && signer_count <= MAX_SIGNERS, "invalid signer count");

        self.threshold.write(threshold);
        self.signer_count.write(signer_count);
        self.proposal_count.write(0);

        // Register signers (up to 3 in constructor; add more via governance)
        if signer_count >= 1 {
            self.signers.write(0, signer_1);
            self.is_signer_map.write(signer_1, true);
        }
        if signer_count >= 2 {
            self.signers.write(1, signer_2);
            self.is_signer_map.write(signer_2, true);
        }
        if signer_count >= 3 {
            self.signers.write(2, signer_3);
            self.is_signer_map.write(signer_3, true);
        }
    }

    #[abi(embed_v0)]
    impl MultiSigImpl of super::IMultiSig<ContractState> {
        fn propose(
            ref self: ContractState,
            target: ContractAddress,
            selector: felt252,
            calldata_hash: felt252,
        ) -> u64 {
            let caller = get_caller_address();
            assert!(self.is_signer_map.read(caller), "not a signer");

            let id = self.proposal_count.read();
            self.proposal_count.write(id + 1);

            self.proposal_targets.write(id, target);
            self.proposal_selectors.write(id, selector);
            self.proposal_calldata_hashes.write(id, calldata_hash);
            self.approval_counts.write(id, 1);
            self.approvals.write((id, caller), true);

            self
                .emit(
                    ProposalCreated { proposal_id: id, proposer: caller, target, selector },
                );
            self
                .emit(
                    ProposalApproved { proposal_id: id, signer: caller, approval_count: 1 },
                );

            id
        }

        fn approve(ref self: ContractState, proposal_id: u64) {
            let caller = get_caller_address();
            assert!(self.is_signer_map.read(caller), "not a signer");
            assert!(proposal_id < self.proposal_count.read(), "invalid proposal");
            assert!(!self.executed.read(proposal_id), "already executed");
            assert!(!self.approvals.read((proposal_id, caller)), "already approved");

            self.approvals.write((proposal_id, caller), true);
            let count = self.approval_counts.read(proposal_id) + 1;
            self.approval_counts.write(proposal_id, count);

            self
                .emit(
                    ProposalApproved { proposal_id, signer: caller, approval_count: count },
                );
        }

        fn revoke(ref self: ContractState, proposal_id: u64) {
            let caller = get_caller_address();
            assert!(self.is_signer_map.read(caller), "not a signer");
            assert!(proposal_id < self.proposal_count.read(), "invalid proposal");
            assert!(!self.executed.read(proposal_id), "already executed");
            assert!(self.approvals.read((proposal_id, caller)), "not approved");

            self.approvals.write((proposal_id, caller), false);
            let count = self.approval_counts.read(proposal_id) - 1;
            self.approval_counts.write(proposal_id, count);

            self.emit(ApprovalRevoked { proposal_id, signer: caller });
        }

        fn get_signer_count(self: @ContractState) -> u32 {
            self.signer_count.read()
        }

        fn get_threshold(self: @ContractState) -> u32 {
            self.threshold.read()
        }

        fn get_approval_count(self: @ContractState, proposal_id: u64) -> u32 {
            self.approval_counts.read(proposal_id)
        }

        fn is_approved(self: @ContractState, proposal_id: u64) -> bool {
            self.approval_counts.read(proposal_id) >= self.threshold.read()
        }

        fn is_signer(self: @ContractState, address: ContractAddress) -> bool {
            self.is_signer_map.read(address)
        }
    }
}
