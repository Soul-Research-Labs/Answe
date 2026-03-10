/// RateLimiter — per-address rate limiting for privacy pool operations.
///
/// Prevents abuse by limiting the number of operations per address within a time window.
/// Uses a sliding window counter approach based on block timestamps.

use starknet::ContractAddress;

/// Rate limiter component. Embed in contracts that need rate limiting.
#[starknet::component]
pub mod RateLimiter {
    use starknet::{ContractAddress, get_block_timestamp};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };

    #[storage]
    pub struct Storage {
        /// Maximum operations per window per address.
        max_ops_per_window: u64,
        /// Window duration in seconds.
        window_duration: u64,
        /// Per-address tracking: address -> (window_start, ops_count).
        window_start: Map<ContractAddress, u64>,
        ops_count: Map<ContractAddress, u64>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        RateLimitExceeded: RateLimitExceeded,
    }

    #[derive(Drop, starknet::Event)]
    pub struct RateLimitExceeded {
        #[key]
        pub caller: ContractAddress,
        pub ops_count: u64,
    }

    #[generate_trait]
    pub impl RateLimiterImpl<
        TContractState, +HasComponent<TContractState>,
    > of RateLimiterTrait<TContractState> {
        /// Initialize the rate limiter with parameters.
        fn initialize(
            ref self: ComponentState<TContractState>,
            max_ops_per_window: u64,
            window_duration: u64,
        ) {
            assert!(max_ops_per_window > 0, "max ops must be positive");
            assert!(window_duration > 0, "window must be positive");
            self.max_ops_per_window.write(max_ops_per_window);
            self.window_duration.write(window_duration);
        }

        /// Check and increment the rate counter for a caller.
        /// Panics if the rate limit is exceeded.
        fn check_rate_limit(
            ref self: ComponentState<TContractState>, caller: ContractAddress,
        ) {
            let now = get_block_timestamp();
            let window = self.window_duration.read();
            let start = self.window_start.read(caller);
            let count = self.ops_count.read(caller);

            // If window has expired, reset
            if now >= start + window {
                self.window_start.write(caller, now);
                self.ops_count.write(caller, 1);
            } else {
                // Check limit
                assert!(
                    count < self.max_ops_per_window.read(),
                    "rate limit exceeded",
                );
                self.ops_count.write(caller, count + 1);
            }
        }

        /// Get remaining operations in the current window for an address.
        fn get_remaining_ops(
            self: @ComponentState<TContractState>, caller: ContractAddress,
        ) -> u64 {
            let now = get_block_timestamp();
            let window = self.window_duration.read();
            let start = self.window_start.read(caller);
            let count = self.ops_count.read(caller);
            let max_ops = self.max_ops_per_window.read();

            if now >= start + window {
                return max_ops;
            }

            if count >= max_ops {
                return 0;
            }

            max_ops - count
        }
    }
}
