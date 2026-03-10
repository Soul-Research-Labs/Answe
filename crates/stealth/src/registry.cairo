/// StealthRegistry — on-chain registry for stealth address metadata.
///
/// Stealth address protocol (adapted from Lumora):
/// 1. Recipient publishes a "stealth meta-address" (spending_pub, viewing_pub)
/// 2. Sender generates ephemeral keypair, computes shared secret via Poseidon
/// 3. Sender derives one-time stealth address and publishes ephemeral_pub on-chain
/// 4. Recipient scans ephemeral_pubs with viewing key to detect incoming payments
///
/// On Starknet, stealth addresses can deploy one-time AA smart accounts,
/// giving the recipient full programmable control.
use starknet::ContractAddress;

#[starknet::interface]
pub trait IStealthRegistry<TContractState> {
    /// Register a stealth meta-address. Anyone can look this up to send privately.
    fn register_meta_address(
        ref self: TContractState, spending_pub_x: felt252, viewing_pub_x: felt252,
    );

    /// Publish an ephemeral public key used to derive a stealth address.
    /// Called by senders after creating a stealth payment.
    /// `scan_tag` enables recipients to quickly filter without full decryption.
    fn publish_ephemeral_key(
        ref self: TContractState,
        ephemeral_pub_x: felt252,
        encrypted_note: Span<felt252>,
        commitment: felt252,
        scan_tag: felt252,
    );

    /// Get the stealth meta-address for a user.
    fn get_meta_address(
        self: @TContractState, user: ContractAddress,
    ) -> (felt252, felt252);

    /// Get the total number of published ephemeral keys (for scanning).
    fn get_ephemeral_count(self: @TContractState) -> u64;

    /// Get ephemeral key data at a given index (for scanning).
    fn get_ephemeral_at(
        self: @TContractState, index: u64,
    ) -> (felt252, felt252);

    /// Get the encrypted note data at a given index.
    fn get_encrypted_note_at(
        self: @TContractState, index: u64,
    ) -> Array<felt252>;

    /// Get the scan tag at a given index (for fast filtering).
    fn get_scan_tag_at(self: @TContractState, index: u64) -> felt252;
}

#[starknet::contract]
pub mod StealthRegistry {
    use starknet::{ContractAddress, get_caller_address};
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess, StoragePointerWriteAccess, StoragePathEntry};
    use starkprivacy_stealth::encrypted_note::NOTE_PADDED_SIZE;

    #[storage]
    struct Storage {
        /// Meta-address: user -> (spending_pub_x, viewing_pub_x)
        meta_spending_pub: Map<ContractAddress, felt252>,
        meta_viewing_pub: Map<ContractAddress, felt252>,
        /// Ephemeral keys published by senders (append-only log)
        ephemeral_pub_x: Map<u64, felt252>,
        ephemeral_commitment: Map<u64, felt252>,
        /// Encrypted note data: index -> element_index -> felt252
        encrypted_note_data: Map<u64, Map<u32, felt252>>,
        encrypted_note_len: Map<u64, u32>,
        /// Scan tags for fast recipient filtering
        ephemeral_scan_tag: Map<u64, felt252>,
        ephemeral_count: u64,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        MetaAddressRegistered: MetaAddressRegistered,
        EphemeralKeyPublished: EphemeralKeyPublished,
    }

    #[derive(Drop, starknet::Event)]
    struct MetaAddressRegistered {
        #[key]
        user: ContractAddress,
        spending_pub_x: felt252,
        viewing_pub_x: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct EphemeralKeyPublished {
        #[key]
        index: u64,
        ephemeral_pub_x: felt252,
        commitment: felt252,
        scan_tag: felt252,
        encrypted_note_len: u32,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {}

    #[abi(embed_v0)]
    impl StealthRegistryImpl of super::IStealthRegistry<ContractState> {
        fn register_meta_address(
            ref self: ContractState, spending_pub_x: felt252, viewing_pub_x: felt252,
        ) {
            assert!(spending_pub_x != 0, "invalid spending pub");
            assert!(viewing_pub_x != 0, "invalid viewing pub");

            let caller = get_caller_address();
            self.meta_spending_pub.write(caller, spending_pub_x);
            self.meta_viewing_pub.write(caller, viewing_pub_x);

            self.emit(MetaAddressRegistered { user: caller, spending_pub_x, viewing_pub_x });
        }

        fn publish_ephemeral_key(
            ref self: ContractState,
            ephemeral_pub_x: felt252,
            encrypted_note: Span<felt252>,
            commitment: felt252,
            scan_tag: felt252,
        ) {
            assert!(ephemeral_pub_x != 0, "invalid ephemeral pub");
            assert!(commitment != 0, "invalid commitment");
            assert!(encrypted_note.len() <= NOTE_PADDED_SIZE, "encrypted note too large");

            let index = self.ephemeral_count.read();
            self.ephemeral_pub_x.write(index, ephemeral_pub_x);
            self.ephemeral_commitment.write(index, commitment);
            self.ephemeral_scan_tag.write(index, scan_tag);

            // Store encrypted note data on-chain
            let note_len = encrypted_note.len();
            self.encrypted_note_len.write(index, note_len);
            let mut i: u32 = 0;
            while i < note_len {
                self.encrypted_note_data.entry(index).entry(i).write(*encrypted_note.at(i));
                i += 1;
            };

            self.ephemeral_count.write(index + 1);

            self
                .emit(
                    EphemeralKeyPublished {
                        index,
                        ephemeral_pub_x,
                        commitment,
                        scan_tag,
                        encrypted_note_len: note_len,
                    },
                );
        }

        fn get_meta_address(
            self: @ContractState, user: ContractAddress,
        ) -> (felt252, felt252) {
            (self.meta_spending_pub.read(user), self.meta_viewing_pub.read(user))
        }

        fn get_ephemeral_count(self: @ContractState) -> u64 {
            self.ephemeral_count.read()
        }

        fn get_ephemeral_at(
            self: @ContractState, index: u64,
        ) -> (felt252, felt252) {
            assert!(index < self.ephemeral_count.read(), "index out of bounds");
            (self.ephemeral_pub_x.read(index), self.ephemeral_commitment.read(index))
        }

        fn get_encrypted_note_at(
            self: @ContractState, index: u64,
        ) -> Array<felt252> {
            assert!(index < self.ephemeral_count.read(), "index out of bounds");
            let note_len = self.encrypted_note_len.read(index);
            let mut result: Array<felt252> = array![];
            let mut i: u32 = 0;
            while i < note_len {
                result.append(self.encrypted_note_data.entry(index).entry(i).read());
                i += 1;
            };
            result
        }

        fn get_scan_tag_at(self: @ContractState, index: u64) -> felt252 {
            assert!(index < self.ephemeral_count.read(), "index out of bounds");
            self.ephemeral_scan_tag.read(index)
        }
    }
}
