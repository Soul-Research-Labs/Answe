/// ReentrancyGuard — prevents reentrancy attacks on privacy pool operations.
///
/// Simple lock mechanism: set a flag before external calls, check it at entry.
/// Based on OpenZeppelin's reentrancy guard pattern.

#[starknet::component]
pub mod ReentrancyGuard {
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};

    #[storage]
    pub struct Storage {
        /// Lock flag: true when inside a protected function.
        locked: bool,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {}

    #[generate_trait]
    pub impl ReentrancyGuardImpl<
        TContractState, +HasComponent<TContractState>,
    > of ReentrancyGuardTrait<TContractState> {
        /// Enter a protected section. Panics if already locked.
        fn start(ref self: ComponentState<TContractState>) {
            assert!(!self.locked.read(), "reentrancy detected");
            self.locked.write(true);
        }

        /// Exit a protected section.
        fn end(ref self: ComponentState<TContractState>) {
            self.locked.write(false);
        }
    }
}
