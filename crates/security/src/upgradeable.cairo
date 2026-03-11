/// UpgradeableProxy — UUPS-style upgrade pattern for StarkPrivacy contracts.
///
/// Uses Starknet's native `replace_class_syscall` to swap the contract's
/// class hash in-place, preserving storage. Upgrade authority flows through
/// the governance pipeline: MultiSig → Timelock → UpgradeableProxy.upgrade().
///
/// Security:
/// - Only the designated `governor` (typically a Timelock contract) can trigger upgrades.
/// - Upgrade includes a `new_class_hash` validation (non-zero).
/// - Emits UpgradeExecuted event for off-chain monitoring.
/// - Supports emergency upgrade with reduced delay via `emergency_governor`.

use starknet::ContractAddress;
use starknet::ClassHash;

#[starknet::interface]
pub trait IUpgradeableProxy<TContractState> {
    /// Upgrade the contract to a new class hash.
    /// Can only be called by the governor (Timelock).
    fn upgrade(ref self: TContractState, new_class_hash: ClassHash);

    /// Get the current implementation class hash.
    fn get_implementation(self: @TContractState) -> ClassHash;

    /// Get the governor address (Timelock).
    fn get_governor(self: @TContractState) -> ContractAddress;

    /// Get the emergency governor address (for critical patches).
    fn get_emergency_governor(self: @TContractState) -> ContractAddress;

    /// Set a new governor (only current governor).
    fn set_governor(ref self: TContractState, new_governor: ContractAddress);

    /// Set a new emergency governor (only governor).
    fn set_emergency_governor(ref self: TContractState, new_emergency: ContractAddress);

    /// Get the total number of upgrades performed.
    fn get_upgrade_count(self: @TContractState) -> u64;
}

#[starknet::contract]
pub mod UpgradeableProxy {
    use starknet::{ContractAddress, ClassHash, get_caller_address, SyscallResultTrait};
    use starknet::syscalls::replace_class_syscall;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};

    #[storage]
    struct Storage {
        /// Current implementation class hash.
        implementation: ClassHash,
        /// Governor address (typically a Timelock contract).
        governor: ContractAddress,
        /// Emergency governor for critical patches (typically a MultiSig).
        emergency_governor: ContractAddress,
        /// Total upgrades performed.
        upgrade_count: u64,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        UpgradeExecuted: UpgradeExecuted,
        GovernorUpdated: GovernorUpdated,
        EmergencyGovernorUpdated: EmergencyGovernorUpdated,
    }

    #[derive(Drop, starknet::Event)]
    struct UpgradeExecuted {
        #[key]
        old_class_hash: ClassHash,
        new_class_hash: ClassHash,
        upgrade_number: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct GovernorUpdated {
        old_governor: ContractAddress,
        new_governor: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct EmergencyGovernorUpdated {
        old_emergency: ContractAddress,
        new_emergency: ContractAddress,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        initial_class_hash: ClassHash,
        governor: ContractAddress,
        emergency_governor: ContractAddress,
    ) {
        assert!(governor != 0.try_into().unwrap(), "governor cannot be zero");
        self.implementation.write(initial_class_hash);
        self.governor.write(governor);
        self.emergency_governor.write(emergency_governor);
        self.upgrade_count.write(0);
    }

    #[abi(embed_v0)]
    impl UpgradeableProxyImpl of super::IUpgradeableProxy<ContractState> {
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            self._assert_authorized();

            let zero_hash: ClassHash = 0.try_into().unwrap();
            assert!(new_class_hash != zero_hash, "class hash cannot be zero");

            let old_hash = self.implementation.read();
            assert!(new_class_hash != old_hash, "already at this version");

            // Execute the upgrade via Starknet syscall
            replace_class_syscall(new_class_hash).unwrap_syscall();

            let count = self.upgrade_count.read() + 1;
            self.implementation.write(new_class_hash);
            self.upgrade_count.write(count);

            self.emit(UpgradeExecuted {
                old_class_hash: old_hash,
                new_class_hash,
                upgrade_number: count,
            });
        }

        fn get_implementation(self: @ContractState) -> ClassHash {
            self.implementation.read()
        }

        fn get_governor(self: @ContractState) -> ContractAddress {
            self.governor.read()
        }

        fn get_emergency_governor(self: @ContractState) -> ContractAddress {
            self.emergency_governor.read()
        }

        fn set_governor(ref self: ContractState, new_governor: ContractAddress) {
            self._assert_governor();
            assert!(new_governor != 0.try_into().unwrap(), "governor cannot be zero");

            let old = self.governor.read();
            self.governor.write(new_governor);
            self.emit(GovernorUpdated { old_governor: old, new_governor });
        }

        fn set_emergency_governor(ref self: ContractState, new_emergency: ContractAddress) {
            self._assert_governor();

            let old = self.emergency_governor.read();
            self.emergency_governor.write(new_emergency);
            self.emit(EmergencyGovernorUpdated { old_emergency: old, new_emergency: new_emergency });
        }

        fn get_upgrade_count(self: @ContractState) -> u64 {
            self.upgrade_count.read()
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        /// Check that caller is either governor or emergency governor.
        fn _assert_authorized(self: @ContractState) {
            let caller = get_caller_address();
            let gov = self.governor.read();
            let emerg = self.emergency_governor.read();
            assert!(
                caller == gov || caller == emerg,
                "caller is not authorized to upgrade"
            );
        }

        /// Check that caller is the governor (not emergency).
        fn _assert_governor(self: @ContractState) {
            assert!(
                get_caller_address() == self.governor.read(),
                "caller is not governor"
            );
        }
    }
}
