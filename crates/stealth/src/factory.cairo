/// StealthAccountFactory — deploys one-time smart contract accounts for stealth payments.
///
/// Leverages Starknet's native Account Abstraction:
/// - Each stealth payment can deploy a unique AA account
/// - The stealth account is controlled by the derived stealth key
/// - Uses deploy_syscall for deterministic address derivation via salt
///
/// Flow:
/// 1. Sender derives stealth owner_hash = Poseidon(shared_secret, spending_pub)
/// 2. Sender deploys a stealth account via the factory (or funds existing one)
/// 3. Recipient scans, detects the note, and claims by proving stealth key ownership

use starknet::ContractAddress;

#[starknet::interface]
pub trait IStealthAccountFactory<TContractState> {
    /// Predict the stealth account address for a given salt (deterministic).
    fn get_stealth_account_address(
        self: @TContractState, salt: felt252,
    ) -> ContractAddress;

    /// Deploy a new stealth account. Returns the deployed address.
    /// The salt should be derived from the stealth derivation to ensure uniqueness.
    fn deploy_stealth_account(
        ref self: TContractState, salt: felt252, stealth_pub_key: felt252,
    ) -> ContractAddress;

    /// Deploy a stealth account with an optional recovery key.
    fn deploy_stealth_account_with_recovery(
        ref self: TContractState,
        salt: felt252,
        stealth_pub_key: felt252,
        recovery_pub_key: felt252,
    ) -> ContractAddress;

    /// Check if an address was deployed through this factory.
    fn is_deployed(self: @TContractState, address: ContractAddress) -> bool;

    /// Get number of deployed stealth accounts.
    fn get_deployment_count(self: @TContractState) -> u64;

    /// Get the account class hash used for deployments.
    fn get_account_class_hash(self: @TContractState) -> felt252;

    /// Get the recovery key for a deployed stealth account.
    fn get_recovery_key(self: @TContractState, account: ContractAddress) -> felt252;
}

#[starknet::contract]
pub mod StealthAccountFactory {
    use starknet::{
        ContractAddress, get_caller_address, SyscallResultTrait, syscalls::deploy_syscall,
        ClassHash,
    };
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };

    #[storage]
    struct Storage {
        /// Class hash of the account contract to deploy.
        account_class_hash: felt252,
        /// Owner / admin of the factory.
        owner: ContractAddress,
        /// Tracking deployed stealth accounts: address -> deployed flag.
        deployed: Map<ContractAddress, bool>,
        /// Recovery keys for stealth accounts: account -> recovery_pub_key
        recovery_keys: Map<ContractAddress, felt252>,
        /// Total deployments count.
        deployment_count: u64,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        StealthAccountDeployed: StealthAccountDeployed,
    }

    #[derive(Drop, starknet::Event)]
    struct StealthAccountDeployed {
        #[key]
        account_address: ContractAddress,
        salt: felt252,
        deployer: ContractAddress,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState, account_class_hash: felt252, owner: ContractAddress,
    ) {
        assert!(account_class_hash != 0, "invalid class hash");
        self.account_class_hash.write(account_class_hash);
        self.owner.write(owner);
        self.deployment_count.write(0);
    }

    #[abi(embed_v0)]
    impl StealthAccountFactoryImpl of super::IStealthAccountFactory<ContractState> {
        fn get_stealth_account_address(
            self: @ContractState, salt: felt252,
        ) -> ContractAddress {
            // Deterministic address via CREATE2-like mechanism in Starknet.
            let deployer: felt252 = starknet::get_contract_address().into();
            let addr_hash = core::poseidon::poseidon_hash_span(
                array![deployer, salt, self.account_class_hash.read()].span(),
            );
            let addr: ContractAddress = addr_hash.try_into().unwrap();
            addr
        }

        fn deploy_stealth_account(
            ref self: ContractState, salt: felt252, stealth_pub_key: felt252,
        ) -> ContractAddress {
            assert!(stealth_pub_key != 0, "invalid stealth pub key");

            let class_hash: ClassHash = self.account_class_hash.read().try_into().unwrap();

            // Constructor calldata: stealth public key as the account signer
            let mut constructor_calldata: Array<felt252> = array![stealth_pub_key];

            // Deploy via syscall (deterministic address from salt)
            let (deployed_address, _) = deploy_syscall(
                class_hash, salt, constructor_calldata.span(), false,
            )
                .unwrap_syscall();

            // Track deployment
            self.deployed.write(deployed_address, true);
            let count = self.deployment_count.read();
            self.deployment_count.write(count + 1);

            let caller = get_caller_address();
            self.emit(StealthAccountDeployed { account_address: deployed_address, salt, deployer: caller });

            deployed_address
        }

        fn deploy_stealth_account_with_recovery(
            ref self: ContractState,
            salt: felt252,
            stealth_pub_key: felt252,
            recovery_pub_key: felt252,
        ) -> ContractAddress {
            assert!(stealth_pub_key != 0, "invalid stealth pub key");
            assert!(recovery_pub_key != 0, "invalid recovery pub key");

            let class_hash: ClassHash = self.account_class_hash.read().try_into().unwrap();

            let mut constructor_calldata: Array<felt252> = array![stealth_pub_key];

            let (deployed_address, _) = deploy_syscall(
                class_hash, salt, constructor_calldata.span(), false,
            )
                .unwrap_syscall();

            self.deployed.write(deployed_address, true);
            self.recovery_keys.write(deployed_address, recovery_pub_key);
            let count = self.deployment_count.read();
            self.deployment_count.write(count + 1);

            let caller = get_caller_address();
            self.emit(StealthAccountDeployed { account_address: deployed_address, salt, deployer: caller });

            deployed_address
        }

        fn is_deployed(self: @ContractState, address: ContractAddress) -> bool {
            self.deployed.read(address)
        }

        fn get_deployment_count(self: @ContractState) -> u64 {
            self.deployment_count.read()
        }

        fn get_account_class_hash(self: @ContractState) -> felt252 {
            self.account_class_hash.read()
        }

        fn get_recovery_key(self: @ContractState, account: ContractAddress) -> felt252 {
            self.recovery_keys.read(account)
        }
    }
}
