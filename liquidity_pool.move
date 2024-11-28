/// This module provides a common type of liquidity pool that supports both volatile and stable token pairs. It uses
/// fungible assets underneath and needs a separate router + coin_wrapper to support coins (different standard from
/// fungible assets). Swap fees are kept separately from the pool's reserves and thus don't compound.
///
/// For volatile pairs, the price and reserves can be computed using the constant product formula k = x * y.
/// For stable pairs, the price is computed using k = x^3 * y + x * y^3.
///
/// Note that all functions that return fungible assets such as swap, burn, claim_fees are friend-only since they might
/// return an internal wrapper fungible assets. The router or other modules should provide interface to call these based
/// on the underlying tokens of the pool - whether they're coins or fungible assets. See router.move for an example.
///
/// Another important thing to note is that all transfers of the LP tokens have to call via this module. This is
/// required so that fees are correctly updated for LPs. fungible_asset::transfer and primary_fungible_store::transfer
/// are not supported
module cellana::liquidity_pool {
    use std::bcs;
    use std::option;
    use std::signer;
    use std::string::{Self, String};
    use std::vector;
    use aptos_std::comparator;
    use aptos_std::math128;
    use aptos_std::math64;
    use aptos_std::math64::mul_div;
    use aptos_std::smart_table::{Self, SmartTable};
    use aptos_std::smart_vector::{Self, SmartVector};
    use aptos_framework::dispatchable_fungible_asset;
    use aptos_framework::event;
    use aptos_framework::fungible_asset::{
        Self, BurnRef, FungibleAsset, FungibleStore,
        Metadata, MintRef, TransferRef,
    };
    use aptos_framework::object::{Self, ConstructorRef, Object};
    use aptos_framework::primary_fungible_store;

    use cellana::coin_wrapper;
    use cellana::package_manager;

    friend cellana::gauge;
    friend cellana::router;
    friend cellana::rewards_pool;

    const FEE_SCALE: u64 = 10000;
    const LP_TOKEN_DECIMALS: u8 = 8;
    const MINIMUM_LIQUIDITY: u64 = 1000;

    /// We take 10^8 as we expect most of the coins to have 6-8 decimals.
    const SAMPLE_DECIMALS: u64 = 100000000;
    const MAX_SWAP_FEES_BPS: u64 = 30; // 0.3%

    /// Amount of tokens provided must be greater than zero.
    const EZERO_AMOUNT: u64 = 1;
    /// The amount of liquidity provided is so small that corresponding LP token amount is rounded to zero.
    const EINSUFFICIENT_LIQUIDITY_MINTED: u64 = 2;
    /// Amount of LP tokens redeemed is too small, so amounts of tokens received back are rounded to zero.
    const EINSUFFICIENT_LIQUIDITY_REDEEMED: u64 = 3;
    /// Claler is not authorized to perform the operation.
    const ENOT_AUTHORIZED: u64 = 4;
    /// All swaps are currently paused.
    const ESWAPS_ARE_PAUSED: u64 = 5;
    /// Swap leaves pool in a worse state than before.
    const EK_BEFORE_SWAP_GREATER_THAN_EK_AFTER_SWAP: u64 = 6;
    /// Can only create liquidity pools for whitelisted tokens.
    const ETOKEN_NOT_WHITELISTED: u64 = 7;
    /// Swap fee too high
    const ESWAP_FEE_TOO_HIGH: u64 = 8;
    /// Tokens must be different
    const ETOKENS_MUST_BE_DIFFERENT: u64 = 9;
    /// Token not in pool
    const ETOKEN_NOT_IN_POOL: u64 = 10;
    /// Tokens that charge a transfer fee are not supported.
    const UNSUPPORTED_TAX: u64 = 11;

    struct LPTokenRefs has store {
        burn_ref: BurnRef,
        mint_ref: MintRef,
        transfer_ref: TransferRef,
    }

    /// Stored in the protocol's account for configuring liquidity pools.
    struct LiquidityPoolConfigs has key {
        all_pools: SmartVector<Object<LiquidityPool>>,
        is_paused: bool,
        fee_manager: address,
        pauser: address,
        pending_fee_manager: address,
        pending_pauser: address,
        stable_fee_bps: u64,
        volatile_fee_bps: u64,
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct LiquidityPool has key {
        token_store_1: Object<FungibleStore>,
        token_store_2: Object<FungibleStore>,
        fees_store_1: Object<FungibleStore>,
        fees_store_2: Object<FungibleStore>,
        lp_token_refs: LPTokenRefs,
        swap_fee_bps: u64,
        is_stable: bool,
    }

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    struct FeesAccounting has key {
        total_fees_1: u128,
        total_fees_2: u128,
        total_fees_at_last_claim_1: SmartTable<address, u128>,
        total_fees_at_last_claim_2: SmartTable<address, u128>,
        claimable_1: SmartTable<address, u128>,
        claimable_2: SmartTable<address, u128>,
    }

    #[event]
    /// Event emitted when a pool is created.
    struct CreatePoolEvent has drop, store {
        pool: Object<LiquidityPool>,
        // Tokens are strings as they can be for coins or fungible assets.
        token_1: String,
        token_2: String,
        is_stable: bool,
    }

    #[event]
    /// Event emitted when a swap happens.
    struct SwapEvent has drop, store {
        pool: address,
        // Tokens are strings as they can be for coins or fungible assets.
        from_token: String,
        to_token: String,
        amount_in: u64,
        amount_out: u64,
    }

    #[event]
    /// Event emitted when reserves of a liquidity pool are updated.
    struct SyncEvent has drop, store {
        pool: address,
        reserves_1: u128,
        reserves_2: u128,
    }

    #[event]
    /// Event emitted when liquidity is added to a pool.
    struct AddLiquidityEvent has drop, store {
        lp: address,
        pool: address,
        amount_1: u64,
        amount_2: u64,
    }

    #[event]
    /// Event emitted when liquidity is removed from a pool.
    struct RemoveLiquidityEvent has drop, store {
        lp: address,
        pool: address,
        amount_lp: u64,
        amount_1: u64,
        amount_2: u64,
    }

    #[event]
    /// Event emitted when LP tokens are transferred.
    struct TransferEvent has drop, store {
        pool: address,
        amount: u64,
        from: address,
        to: address,
    }

    #[event]
    /// Event emitted when fees are claimed.
    struct ClaimFeesEvent has drop, store {
        pool: address,
        amount_1: u64,
        amount_2: u64,
    }

    public entry fun initialize() {
        if (is_initialized()) {
            return
        };

        coin_wrapper::initialize();
        let swap_signer = &package_manager::get_signer();
        move_to(swap_signer, LiquidityPoolConfigs {
            all_pools: smart_vector::new(),
            is_paused: false,
            fee_manager: @deployer,
            pauser: @deployer,
            pending_fee_manager: @0x0,
            pending_pauser: @0x0,
            stable_fee_bps: 4, // 0.04%
            volatile_fee_bps: 10, // 0.1%
        });
    }

    #[view]
    public fun is_initialized(): bool {
        exists<LiquidityPoolConfigs>(@cellana)
    }

    #[view]
    public fun liquidity_pool(
        token_1: Object<Metadata>,
        token_2: Object<Metadata>,
        is_stable: bool,
    ): Object<LiquidityPool> {
        object::address_to_object(liquidity_pool_address(token_1, token_2, is_stable))
    }

    #[view]
    public fun liquidity_pool_address(
        token_1: Object<Metadata>,
        token_2: Object<Metadata>,
        is_stable: bool,
    ): address {
        if (!is_sorted(token_1, token_2)) {
            return liquidity_pool_address(token_2, token_1, is_stable)
        };
        object::create_object_address(&@cellana, get_pool_seeds(token_1, token_2, is_stable))
    }

    #[view]
    public fun lp_token_supply<T: key>(pool: Object<T>): u128 {
        option::destroy_some(fungible_asset::supply(pool))
    }

    #[view]
    public fun pool_reserves<T: key>(pool: Object<T>): (u64, u64) acquires LiquidityPool {
        let pool_data = liquidity_pool_data(&pool);
        (
            fungible_asset::balance(pool_data.token_store_1),
            fungible_asset::balance(pool_data.token_store_2),
        )
    }

    #[view]
    public fun supported_token_strings(pool: Object<LiquidityPool>): vector<String> acquires LiquidityPool {
        vector::map(supported_inner_assets(pool), |a| coin_wrapper::get_original(a))
    }

    #[view]
    public fun supported_native_fungible_assets(
        pool: Object<LiquidityPool>,
    ): vector<Object<Metadata>> acquires LiquidityPool {
        vector::filter(supported_inner_assets(pool), |a| !coin_wrapper::is_wrapper(*a))
    }

    #[view]
    public fun supported_inner_assets(pool: Object<LiquidityPool>): vector<Object<Metadata>> acquires LiquidityPool {
        let pool_data = liquidity_pool_data(&pool);
        vector[
            fungible_asset::store_metadata(pool_data.token_store_1),
            fungible_asset::store_metadata(pool_data.token_store_2),
        ]
    }

    #[view]
    public fun is_sorted(token_1: Object<Metadata>, token_2: Object<Metadata>): bool {
        assert!(token_1 != token_2, ETOKENS_MUST_BE_DIFFERENT);
        let token_1_addr = object::object_address(&token_1);
        let token_2_addr = object::object_address(&token_2);
        comparator::is_smaller_than(&comparator::compare(&token_1_addr, &token_2_addr))
    }

    #[view]
    public fun is_stable(pool: Object<LiquidityPool>): bool acquires LiquidityPool {
        liquidity_pool_data(&pool).is_stable
    }

    #[view]
    public fun swap_fee_bps(pool: Object<LiquidityPool>): u64 acquires LiquidityPool {
        liquidity_pool_data(&pool).swap_fee_bps
    }

    #[view]
    public fun min_liquidity(): u64 {
        MINIMUM_LIQUIDITY
    }

    #[view]
    public fun liquidity_out(
        token_1: Object<Metadata>,
        token_2: Object<Metadata>,
        is_stable: bool,
        amount_1: u64,
        amount_2: u64
    ): u64 acquires LiquidityPool {
        if (!is_sorted(token_1, token_2)) {
            return liquidity_out(token_2, token_1, is_stable, amount_2, amount_1)
        };
        let pool = liquidity_pool(token_1, token_2, is_stable);
        let pool_data = liquidity_pool_data(&pool);
        let store_1 = pool_data.token_store_1;
        let store_2 = pool_data.token_store_2;
        let reserve_1 = fungible_asset::balance(store_1);
        let reserve_2 = fungible_asset::balance(store_2);

        let lp_token_supply = option::destroy_some(fungible_asset::supply(pool));
        let liquidity_token_amount = if (lp_token_supply == 0) {
            let total_liquidity = (math128::sqrt((amount_1 as u128) * (amount_2 as u128)) as u64);
            total_liquidity - MINIMUM_LIQUIDITY
        } else {
            // Only the smaller amount between the token 1 or token 2 is considered. Users should make sure to either
            // use the router module or calculate the optimal amounts to provide before calling this function.
            let token_1_liquidity = math64::mul_div(amount_1, (lp_token_supply as u64), reserve_1);
            let token_2_liquidity = math64::mul_div(amount_2, (lp_token_supply as u64), reserve_2);
            math64::min(token_1_liquidity, token_2_liquidity)
        };
        liquidity_token_amount
    }

    #[view]
    public fun liquidity_amounts(pool: Object<LiquidityPool>, lp_token_amount: u64): (u64, u64) acquires LiquidityPool {
        let lp_token_supply = option::destroy_some(fungible_asset::supply(pool));
        let pool_data = liquidity_pool_data(&pool);
        let store_1 = pool_data.token_store_1;
        let store_2 = pool_data.token_store_2;
        let reserve_1 = fungible_asset::balance(store_1);
        let reserve_2 = fungible_asset::balance(store_2);
        let amount_to_redeem_1 = (math128::mul_div(
            (lp_token_amount as u128),
            (reserve_1 as u128),
            lp_token_supply
        ) as u64);
        let amount_to_redeem_2 = (math128::mul_div(
            (lp_token_amount as u128),
            (reserve_2 as u128),
            lp_token_supply
        ) as u64);
        (amount_to_redeem_1, amount_to_redeem_2)
    }

    #[view]
    public fun gauge_claimable_fees(pool: Object<LiquidityPool>): (u64, u64) acquires LiquidityPool {
        let pool_data = liquidity_pool_data(&pool);
        let claimable_1 = fungible_asset::balance(pool_data.fees_store_1);
        let claimable_2 = fungible_asset::balance(pool_data.fees_store_2);
        (claimable_1, claimable_2)
    }

    #[view]
    public fun all_pool_addresses(): vector<Object<LiquidityPool>> acquires LiquidityPoolConfigs {
        smart_vector::to_vector(&safe_liquidity_pool_configs().all_pools)
    }

    /// Creates a new liquidity pool.
    public(friend) fun create(
        token_1: Object<Metadata>,
        token_2: Object<Metadata>,
        is_stable: bool,
    ): Object<LiquidityPool> acquires LiquidityPoolConfigs {
        if (!is_sorted(token_1, token_2)) {
            return create(token_2, token_1, is_stable)
        };
        let configs = unchecked_mut_liquidity_pool_configs();

        // The liquidity pool will serve 3 separate roles:
        // 1. Represent the liquidity pool that LPs and users interact with to add/remove liquidity and swap tokens.
        // 2. Represent the metadata of the LP token.
        // 3. Store the min liquidity that will be locked into the pool when initial liquidity is added.
        let pool_constructor_ref = create_lp_token(token_1, token_2, is_stable);
        let pool_signer = &object::generate_signer(pool_constructor_ref);
        let lp_token = object::object_from_constructor_ref<Metadata>(pool_constructor_ref);
        fungible_asset::create_store(pool_constructor_ref, lp_token);
        move_to(pool_signer, LiquidityPool {
            token_store_1: create_token_store(pool_signer, token_1),
            token_store_2: create_token_store(pool_signer, token_2),
            fees_store_1: create_token_store(pool_signer, token_1),
            fees_store_2: create_token_store(pool_signer, token_2),
            lp_token_refs: create_lp_token_refs(pool_constructor_ref),
            swap_fee_bps: if (is_stable) { configs.stable_fee_bps } else { configs.volatile_fee_bps },
            is_stable,
        });
        move_to(pool_signer, FeesAccounting {
            total_fees_1: 0,
            total_fees_2: 0,
            total_fees_at_last_claim_1: smart_table::new(),
            total_fees_at_last_claim_2: smart_table::new(),
            claimable_1: smart_table::new(),
            claimable_2: smart_table::new(),
        });
        let pool = object::convert(lp_token);
        smart_vector::push_back(&mut configs.all_pools, pool);

        event::emit(CreatePoolEvent {
            pool,
            token_1: coin_wrapper::get_original(token_1),
            token_2: coin_wrapper::get_original(token_2),
            is_stable,
        });
        pool
    }

    /////////////////////////////////////////////////// USERS /////////////////////////////////////////////////////////

    #[view]
    /// Return the amount of tokens received for a swap with the given amount in and the liquidity pool.
    public fun get_amount_out(
        pool: Object<LiquidityPool>,
        from: Object<Metadata>,
        amount_in: u64,
    ): (u64, u64) acquires LiquidityPool {
        let (token_1, token_2, reserve_1, reserve_2, decimals_1, decimals_2) = pool_metadata(pool);
        let pool_data = liquidity_pool_data(&pool);
        assert!(from == token_1 || from == token_2, ETOKEN_NOT_IN_POOL);

        let (reserve_1, reserve_2) = ((reserve_1 as u256), (reserve_2 as u256));
        let (reserve_in, reserve_out, decimals_in, decimals_out) = if (from == token_1) {
            (reserve_1, reserve_2, decimals_1, decimals_2)
        } else {
            (reserve_2, reserve_1, decimals_2, decimals_1)
        };
        let swap_amount = math64::mul_div(amount_in, (FEE_SCALE - pool_data.swap_fee_bps), FEE_SCALE);
        let fees_amount = amount_in - swap_amount;
        let swap_amount = (swap_amount as u256);
        let amount_out = if (pool_data.is_stable) {
            (reserve_in, reserve_out) = standardize_reserve(reserve_in, reserve_out, decimals_in, decimals_out);
            let token_in_scale = math128::pow(10, (decimals_in as u128));
            let token_out_scale = math128::pow(10, (decimals_out as u128));
            swap_amount = (math128::mul_div((swap_amount as u128), (SAMPLE_DECIMALS as u128), token_in_scale) as u256);

            let k = calculate_k(reserve_in, reserve_out, pool_data.is_stable);
            let out = reserve_out - get_y(swap_amount + reserve_in, k, reserve_out);
            (math128::mul_div((out as u128), token_out_scale, (SAMPLE_DECIMALS as u128)) as u256)
        } else {
            swap_amount * reserve_out / (reserve_in + swap_amount)
        };
        ((amount_out as u64), fees_amount)
    }

    fun standardize_reserve(reserve_in: u256, reserve_out: u256, decimals_in: u8, decimals_out: u8): (u256, u256) {
        let token_in_scale = math128::pow(10, (decimals_in as u128));
        let token_out_scale = math128::pow(10, (decimals_out as u128));
        reserve_in = (math128::mul_div((reserve_in as u128), (SAMPLE_DECIMALS as u128), token_in_scale) as u256);
        reserve_out = (math128::mul_div((reserve_out as u128), (SAMPLE_DECIMALS as u128), token_out_scale) as u256);
        (reserve_in, reserve_out)
    }

    public fun pool_metadata(
        pool: Object<LiquidityPool>
    ): (Object<Metadata>, Object<Metadata>, u64, u64, u8, u8) acquires LiquidityPool {
        let pool_data = liquidity_pool_data(&pool);
        let token_1 = fungible_asset::store_metadata(pool_data.token_store_1);
        let token_2 = fungible_asset::store_metadata(pool_data.token_store_2);
        let reserve_1 = fungible_asset::balance(pool_data.token_store_1);
        let reserve_2 = fungible_asset::balance(pool_data.token_store_2);
        let decimals_1 = fungible_asset::decimals(token_1);
        let decimals_2 = fungible_asset::decimals(token_2);
        (token_1, token_2, reserve_1, reserve_2, decimals_1, decimals_2)
    }

    public fun pool_reserve(pool: &LiquidityPool): (u64, u64, u8, u8) {
        let token_1 = fungible_asset::store_metadata(pool.token_store_1);
        let token_2 = fungible_asset::store_metadata(pool.token_store_2);
        let reserve_1 = fungible_asset::balance(pool.token_store_1);
        let reserve_2 = fungible_asset::balance(pool.token_store_2);
        let decimals_1 = fungible_asset::decimals(token_1);
        let decimals_2 = fungible_asset::decimals(token_2);
        (reserve_1, reserve_2, decimals_1, decimals_2)
    }

    #[view]
    /// Return current price and actual price after a swap with the given amount in and the liquidity pool.
    public fun get_trade_diff(
        pool: Object<LiquidityPool>,
        from: Object<Metadata>,
        amount_in: u64,
    ): (u64, u64) acquires LiquidityPool {
        let (token_1, _, reserve_1, reserve_2, decimal_1, decimal_2) = pool_metadata(pool);
        let decimal = if (from == token_1) { (decimal_1 as u64) }else { (decimal_2 as u64) };
        let sample = if (from == token_1) {
            math64::mul_div(reserve_1, math64::pow(10, (decimal_2 as u64)), reserve_2)
        } else {
            math64::mul_div(reserve_2, math64::pow(10, (decimal_1 as u64)), reserve_1)
        };
        let (amount_out_a, _) = get_amount_out(pool, from, sample);
        let a = mul_div(amount_out_a, math64::pow(10, decimal), sample);
        let (amount_out_b, _) = get_amount_out(pool, from, amount_in);
        let b = mul_div(amount_out_b, math64::pow(10, decimal), amount_in);

        (a, b)
    }

    /// Swaps `from` for the other token in the pool.
    /// This is friend-only as the returned fungible assets might be of an internal wrapper type. If this is not the
    /// case, this function can be made public.
    public(friend) fun swap(
        pool: Object<LiquidityPool>,
        from: FungibleAsset,
    ): FungibleAsset acquires FeesAccounting, LiquidityPool, LiquidityPoolConfigs {
        assert!(!safe_liquidity_pool_configs().is_paused, ESWAPS_ARE_PAUSED);
        // Calculate the amount of tokens to return to the user and the amount of fees to extract.
        let from_token = fungible_asset::metadata_from_asset(&from);
        let amount_in = fungible_asset::amount(&from);
        let (amount_out, fees_amount) = get_amount_out(pool, from_token, amount_in);
        let fees = fungible_asset::extract(&mut from, fees_amount);
        let pool_data = liquidity_pool_data(&pool);
        let store_1 = pool_data.token_store_1;
        let store_2 = pool_data.token_store_2;
        let decimals_1 = fungible_asset::decimals(fungible_asset::store_metadata(store_1));
        let decimals_2 = fungible_asset::decimals(fungible_asset::store_metadata(store_2));

        // Deposits and withdraws.
        let r1 = (fungible_asset::balance(store_1) as u256);
        let r2 = (fungible_asset::balance(store_2) as u256);
        let (reserve_in, reserve_out) = if (pool_data.is_stable) {
            standardize_reserve(r1, r2, decimals_1, decimals_2)
        }else {
            (r1, r2)
        };
        let k_before = calculate_k(reserve_in, reserve_out, pool_data.is_stable);
        let fees_accounting = unchecked_mut_fees_accounting(&pool);

        let swap_signer = &package_manager::get_signer();
        let fees_amount = (fees_amount as u128);
        let out = if (from_token == fungible_asset::store_metadata(pool_data.token_store_1)) {
            // User's swapping token 1 for token 2.
            dispatchable_exact_deposit(store_1, from);
            dispatchable_exact_deposit(pool_data.fees_store_1, fees);
            fees_accounting.total_fees_1 = fees_accounting.total_fees_1 + fees_amount;
            dispatchable_exact_withdraw(swap_signer, store_2, amount_out)
        } else {
            // User's swapping token 2 for token 1.
            dispatchable_exact_deposit(store_2, from);
            dispatchable_exact_deposit(pool_data.fees_store_2, fees);
            fees_accounting.total_fees_2 = fees_accounting.total_fees_2 + fees_amount;
            dispatchable_exact_withdraw(swap_signer, store_1, amount_out)
        };
        r1 = (fungible_asset::balance(store_1) as u256);
        r2 = (fungible_asset::balance(store_2) as u256);
        (reserve_in, reserve_out) = if (pool_data.is_stable) {
            standardize_reserve(r1, r2, decimals_1, decimals_2)
        }else {
            (r1, r2)
        };
        let k_after = calculate_k(reserve_in, reserve_out, pool_data.is_stable);
        assert!(k_before <= k_after, EK_BEFORE_SWAP_GREATER_THAN_EK_AFTER_SWAP);

        event::emit(
            SwapEvent {
                pool: object::object_address(&pool),
                from_token: coin_wrapper::get_original(from_token),
                to_token: coin_wrapper::get_original(fungible_asset::metadata_from_asset(&out)),
                amount_in,
                amount_out,
            },
        );
        event::emit(
            SyncEvent {
                pool: object::object_address(&pool),
                reserves_1: (fungible_asset::balance(pool_data.token_store_1) as u128),
                reserves_2: (fungible_asset::balance(pool_data.token_store_2) as u128),
            },
        );
        out
    }

    //////////////////////////////////////// Liquidity Providers (LPs) ///////////////////////////////////////////////

    /// Mint LP tokens for the given liquidity. Note that the LP would receive a smaller amount of LP tokens if the
    /// amounts of liquidity provided are not optimal (do not conform with the constant formula of the pool). Users
    /// should compute the optimal amounts before calling this function.
    public(friend) fun mint_lp(
        lp: &signer,
        fungible_asset_1: FungibleAsset,
        fungible_asset_2: FungibleAsset,
        is_stable: bool,
    ): u64 acquires FeesAccounting, LiquidityPool {
        let token_1 = fungible_asset::metadata_from_asset(&fungible_asset_1);
        let token_2 = fungible_asset::metadata_from_asset(&fungible_asset_2);
        if (!is_sorted(token_1, token_2)) {
            return mint_lp(lp, fungible_asset_2, fungible_asset_1, is_stable)
        };
        // The LP store needs to exist before we can mint LP tokens.
        let pool = liquidity_pool(token_1, token_2, is_stable);
        let lp_addr = signer::address_of(lp);
        let lp_store = ensure_lp_token_store(lp_addr, pool);
        let amount_1 = fungible_asset::amount(&fungible_asset_1);
        let amount_2 = fungible_asset::amount(&fungible_asset_2);
        assert!(amount_1 > 0 && amount_2 > 0, EZERO_AMOUNT);
        let pool_data = liquidity_pool_data(&pool);
        let store_1 = pool_data.token_store_1;
        let store_2 = pool_data.token_store_2;

        // Before depositing the added liquidity, compute the amount of LP tokens the LP will receive.
        let reserve_1 = fungible_asset::balance(store_1);
        let reserve_2 = fungible_asset::balance(store_2);
        let lp_token_supply = option::destroy_some(fungible_asset::supply(pool));
        let mint_ref = &pool_data.lp_token_refs.mint_ref;
        let liquidity_token_amount = if (lp_token_supply == 0) {
            let total_liquidity = (math128::sqrt((amount_1 as u128) * (amount_2 as u128)) as u64);
            // Permanently lock the first MINIMUM_LIQUIDITY tokens.
            fungible_asset::mint_to(mint_ref, pool, MINIMUM_LIQUIDITY);
            total_liquidity - MINIMUM_LIQUIDITY
        } else {
            // Only the smaller amount between the token 1 or token 2 is considered. Users should make sure to either
            // use the router module or calculate the optimal amounts to provide before calling this function.
            let token_1_liquidity = math64::mul_div(amount_1, (lp_token_supply as u64), reserve_1);
            let token_2_liquidity = math64::mul_div(amount_2, (lp_token_supply as u64), reserve_2);
            math64::min(token_1_liquidity, token_2_liquidity)
        };
        assert!(liquidity_token_amount > 0, EINSUFFICIENT_LIQUIDITY_MINTED);

        // Deposit the received liquidity into the pool.
        dispatchable_exact_deposit(store_1, fungible_asset_1);
        dispatchable_exact_deposit(store_2, fungible_asset_2);

        // Mint the corresponding amount of LP tokens to the LP.
        let lp_tokens = fungible_asset::mint(mint_ref, liquidity_token_amount);
        let lp_token_amount = fungible_asset::amount(&lp_tokens);
        fungible_asset::deposit_with_ref(&pool_data.lp_token_refs.transfer_ref, lp_store, lp_tokens);

        event::emit(
            AddLiquidityEvent {
                lp: lp_addr,
                pool: object::object_address(&pool),
                amount_1,
                amount_2,
            },
        );
        event::emit(
            SyncEvent {
                pool: object::object_address(&pool),
                reserves_1: (fungible_asset::balance(pool_data.token_store_1) as u128),
                reserves_2: (fungible_asset::balance(pool_data.token_store_2) as u128),
            },
        );

        lp_token_amount
    }

    /// Transfer a given amount of LP tokens from the sender to the receiver. This must be called for all transfers as
    /// fungible_asset::transfer or primary_fungible_store::transfer would not work for LP tokens.
    public entry fun transfer(
        from: &signer,
        lp_token: Object<LiquidityPool>,
        to: address,
        amount: u64,
    ) acquires LiquidityPool {
        assert!(amount > 0, EZERO_AMOUNT);
        let from_address = signer::address_of(from);
        let from_store = ensure_lp_token_store(from_address, lp_token);
        let to_store = ensure_lp_token_store(to, lp_token);

        let transfer_ref = &liquidity_pool_data(&lp_token).lp_token_refs.transfer_ref;
        fungible_asset::transfer_with_ref(transfer_ref, from_store, to_store, amount);

        event::emit(
            TransferEvent {
                pool: object::object_address(&lp_token),
                amount,
                from: from_address,
                to,
            },
        );
    }

    /// Burn the given amount of LP tokens and receive the underlying liquidity.
    /// This is friend-only as the returned fungible assets might be of an internal wrapper type. If this is not the
    /// case, this function can be made public.
    public(friend) fun burn(
        lp: &signer,
        token_1: Object<Metadata>,
        token_2: Object<Metadata>,
        is_stable: bool,
        amount: u64,
    ): (FungibleAsset, FungibleAsset) acquires LiquidityPool {
        assert!(amount > 0, EZERO_AMOUNT);
        let lp_address = signer::address_of(lp);
        let pool = liquidity_pool(token_1, token_2, is_stable);
        let store = ensure_lp_token_store(lp_address, pool);

        // Burn the provided LP tokens.
        let (amount_to_redeem_1, amount_to_redeem_2) = liquidity_amounts(pool, amount);
        assert!(amount_to_redeem_1 > 0 && amount_to_redeem_2 > 0, EINSUFFICIENT_LIQUIDITY_REDEEMED);
        let pool_data = liquidity_pool_data(&pool);
        fungible_asset::burn_from(&pool_data.lp_token_refs.burn_ref, store, amount);

        // Withdraw and return the redeemed tokens.
        let swap_signer = &package_manager::get_signer();
        let redeemed_1 =dispatchable_fungible_asset::withdraw(swap_signer, pool_data.token_store_1, amount_to_redeem_1);
        let redeemed_2 =dispatchable_fungible_asset::withdraw(swap_signer, pool_data.token_store_2, amount_to_redeem_2);
        if (!is_sorted(token_1, token_2)) {
            (redeemed_1, redeemed_2) = (redeemed_2, redeemed_1);
        };

        event::emit(
            RemoveLiquidityEvent {
                lp: lp_address,
                pool: object::object_address(&pool),
                amount_lp: amount,
                amount_1: amount_to_redeem_1,
                amount_2: amount_to_redeem_2,
            },
        );
        event::emit(
            SyncEvent {
                pool: object::object_address(&pool),
                reserves_1: (fungible_asset::balance(pool_data.token_store_1) as u128),
                reserves_2: (fungible_asset::balance(pool_data.token_store_2) as u128),
            },
        );

        (redeemed_1, redeemed_2)
    }

    /// This is friend-only as the returned fungible assets might be of an internal wrapper type. If this is not the
    /// case, this function can be made public.
    public(friend) fun claim_fees(
        _lp: &signer,
        pool: Object<LiquidityPool>,
    ): (FungibleAsset, FungibleAsset) acquires LiquidityPool {
        let (claimable_1, claimable_2) = gauge_claimable_fees(pool);

        let pool_data = liquidity_pool_data(&pool);

        let swap_signer = &package_manager::get_signer();
        let fees_1 = if (claimable_1 > 0) {
           dispatchable_fungible_asset::withdraw(swap_signer, pool_data.fees_store_1, claimable_1)
        } else {
            fungible_asset::zero(fungible_asset::store_metadata(pool_data.fees_store_1))
        };
        let fees_2 = if (claimable_2 > 0) {
           dispatchable_fungible_asset::withdraw(swap_signer, pool_data.fees_store_2, claimable_2)
        } else {
            fungible_asset::zero(fungible_asset::store_metadata(pool_data.fees_store_2))
        };

        event::emit(
            ClaimFeesEvent {
                pool: object::object_address(&pool),
                amount_1: (claimable_1 as u64),
                amount_2: (claimable_2 as u64),
            },
        );
        (fees_1, fees_2)
    }

    public(friend) fun deposit_fungible_asset<T: key>(store: Object<T>, fa: FungibleAsset): u64 {
        let current_balance = fungible_asset::balance(store);
        dispatchable_fungible_asset::deposit(store, fa);
        let new_balance = fungible_asset::balance(store);
        (new_balance - current_balance)
    }

    public(friend) fun dispatchable_exact_deposit<T: key>(store: Object<T>, fa: FungibleAsset) {
        let fa_balance = fungible_asset::amount(&fa);
        let extract_balance = deposit_fungible_asset<T>(store, fa);
        assert!(fa_balance == extract_balance, UNSUPPORTED_TAX);
    }

    public(friend) fun dispatchable_exact_withdraw<T: key>(user: &signer, store: Object<T>, amount: u64): FungibleAsset {
        let fa = dispatchable_fungible_asset::withdraw(user, store, amount);
        assert!(fungible_asset::amount(&fa) == amount, UNSUPPORTED_TAX);
        fa
    }

    /////////////////////////////////////////////////// OPERATIONS /////////////////////////////////////////////////////

    public entry fun set_pauser(pauser: &signer, new_pauser: address) acquires LiquidityPoolConfigs {
        let pool_configs = pauser_only_mut_liquidity_pool_configs(pauser);
        pool_configs.pending_pauser = new_pauser;
    }

    public entry fun accept_pauser(new_pauser: &signer) acquires LiquidityPoolConfigs {
        let pool_configs = unchecked_mut_liquidity_pool_configs();
        assert!(signer::address_of(new_pauser) == pool_configs.pending_pauser, ENOT_AUTHORIZED);
        pool_configs.pauser = pool_configs.pending_pauser;
        pool_configs.pending_pauser = @0x0;
    }

    public entry fun set_pause(pauser: &signer, is_paused: bool) acquires LiquidityPoolConfigs {
        let pool_configs = pauser_only_mut_liquidity_pool_configs(pauser);
        pool_configs.is_paused = is_paused;
    }

    public entry fun set_fee_manager(fee_manager: &signer, new_fee_manager: address) acquires LiquidityPoolConfigs {
        let pool_configs = fee_manager_only_mut_liquidity_pool_configs(fee_manager);
        pool_configs.pending_fee_manager = new_fee_manager;
    }

    public entry fun accept_fee_manager(new_fee_manager: &signer) acquires LiquidityPoolConfigs {
        let pool_configs = unchecked_mut_liquidity_pool_configs();
        assert!(signer::address_of(new_fee_manager) == pool_configs.pending_fee_manager, ENOT_AUTHORIZED);
        pool_configs.fee_manager = pool_configs.pending_fee_manager;
        pool_configs.pending_fee_manager = @0x0;
    }

    public entry fun set_stable_fee(fee_manager: &signer, new_fee_bps: u64) acquires LiquidityPoolConfigs {
        assert!(new_fee_bps <= MAX_SWAP_FEES_BPS, ESWAP_FEE_TOO_HIGH);
        let pool_configs = fee_manager_only_mut_liquidity_pool_configs(fee_manager);
        pool_configs.stable_fee_bps = new_fee_bps;
    }

    public entry fun set_volatile_fee(fee_manager: &signer, new_fee_bps: u64) acquires LiquidityPoolConfigs {
        assert!(new_fee_bps <= MAX_SWAP_FEES_BPS, ESWAP_FEE_TOO_HIGH);
        let pool_configs = fee_manager_only_mut_liquidity_pool_configs(fee_manager);
        pool_configs.volatile_fee_bps = new_fee_bps;
    }

    public entry fun set_pool_swap_fee(
        fee_manager: &signer,
        pool: Object<LiquidityPool>,
        new_fee_bps: u64,
    ) acquires LiquidityPool, LiquidityPoolConfigs {
        assert!(new_fee_bps <= MAX_SWAP_FEES_BPS, ESWAP_FEE_TOO_HIGH);
        fee_manager_only_mut_liquidity_pool_configs(fee_manager);
        unchecked_mut_liquidity_pool_data(&pool).swap_fee_bps = new_fee_bps;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    inline fun create_lp_token(
        token_1: Object<Metadata>,
        token_2: Object<Metadata>,
        is_stable: bool,
    ): &ConstructorRef {
        let token_name = lp_token_name(token_1, token_2);
        let seeds = get_pool_seeds(token_1, token_2, is_stable);
        let lp_token_constructor_ref = &object::create_named_object(&package_manager::get_signer(), seeds);
        // We don't enable automatic primary store creation because we need LPs to call into this module for transfers
        // so the fees accounting can be updated correctly.
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            lp_token_constructor_ref,
            option::none(),
            token_name,
            string::utf8(b"LP"),
            LP_TOKEN_DECIMALS,
            string::utf8(b""),
            string::utf8(b"")
        );
        lp_token_constructor_ref
    }

    inline fun create_lp_token_refs(constructor_ref: &ConstructorRef): LPTokenRefs {
        LPTokenRefs {
            burn_ref: fungible_asset::generate_burn_ref(constructor_ref),
            mint_ref: fungible_asset::generate_mint_ref(constructor_ref),
            transfer_ref: fungible_asset::generate_transfer_ref(constructor_ref),
        }
    }

    fun ensure_lp_token_store<T: key>(lp: address, pool: Object<T>): Object<FungibleStore> acquires LiquidityPool {
        primary_fungible_store::ensure_primary_store_exists(lp, pool);
        let store = primary_fungible_store::primary_store(lp, pool);
        if (!fungible_asset::is_frozen(store)) {
            // LPs must call transfer here to transfer the LP tokens so claimable fees can be updated correctly.
            let transfer_ref = &liquidity_pool_data(&pool).lp_token_refs.transfer_ref;
            fungible_asset::set_frozen_flag(transfer_ref, store, true);
        };
        store
    }

    inline fun get_pool_seeds(token_1: Object<Metadata>, token_2: Object<Metadata>, is_stable: bool): vector<u8> {
        let seeds = vector[];
        vector::append(&mut seeds, bcs::to_bytes(&object::object_address(&token_1)));
        vector::append(&mut seeds, bcs::to_bytes(&object::object_address(&token_2)));
        vector::append(&mut seeds, bcs::to_bytes(&is_stable));
        seeds
    }

    fun create_token_store(pool_signer: &signer, token: Object<Metadata>): Object<FungibleStore> {
        let constructor_ref = &object::create_object_from_object(pool_signer);
        fungible_asset::create_store(constructor_ref, token)
    }

    fun lp_token_name(token_1: Object<Metadata>, token_2: Object<Metadata>): String {
        let token_symbol = string::utf8(b"LP-");
        string::append(&mut token_symbol, fungible_asset::symbol(token_1));
        string::append_utf8(&mut token_symbol, b"-");
        string::append(&mut token_symbol, fungible_asset::symbol(token_2));
        token_symbol
    }

    fun calculate_k(r1: u256, r2: u256, is_stable: bool): u256 {
        if (is_stable) {
            // k = x^3 * y + y^3 * x. This is a modified constant for stable pairs.
            r1 * r1 * r1 * r2 + r2 * r2 * r2 * r1
        } else {
            // k = x * y. This is standard constant product for volatile asset pairs.
            r1 * r2
        }
    }

    fun calculate_constant_k(pool: &LiquidityPool): u256 {
        let r1 = (fungible_asset::balance(pool.token_store_1) as u256);
        let r2 = (fungible_asset::balance(pool.token_store_2) as u256);
        if (pool.is_stable) {
            // k = x^3 * y + y^3 * x. This is a modified constant for stable pairs.
            r1 * r1 * r1 * r2 + r2 * r2 * r2 * r1
        } else {
            // k = x * y. This is standard constant product for volatile asset pairs.
            r1 * r2
        }
    }

    inline fun safe_fees_accounting<T: key>(pool: &Object<T>): &FeesAccounting acquires FeesAccounting {
        borrow_global<FeesAccounting>(object::object_address(pool))
    }

    inline fun liquidity_pool_data<T: key>(pool: &Object<T>): &LiquidityPool acquires LiquidityPool {
        borrow_global<LiquidityPool>(object::object_address(pool))
    }

    inline fun safe_liquidity_pool_configs(): &LiquidityPoolConfigs acquires LiquidityPoolConfigs {
        borrow_global<LiquidityPoolConfigs>(@cellana)
    }

    inline fun pauser_only_mut_liquidity_pool_configs(
        pauser: &signer,
    ): &mut LiquidityPoolConfigs acquires LiquidityPoolConfigs {
        let pool_configs = unchecked_mut_liquidity_pool_configs();
        assert!(signer::address_of(pauser) == pool_configs.pauser, ENOT_AUTHORIZED);
        pool_configs
    }

    inline fun fee_manager_only_mut_liquidity_pool_configs(
        fee_manager: &signer,
    ): &mut LiquidityPoolConfigs acquires LiquidityPoolConfigs {
        let pool_configs = unchecked_mut_liquidity_pool_configs();
        assert!(signer::address_of(fee_manager) == pool_configs.fee_manager, ENOT_AUTHORIZED);
        pool_configs
    }

    inline fun unchecked_mut_liquidity_pool_data<T: key>(pool: &Object<T>): &mut LiquidityPool acquires LiquidityPool {
        borrow_global_mut<LiquidityPool>(object::object_address(pool))
    }

    inline fun unchecked_mut_fees_accounting<T: key>(pool: &Object<T>): &mut FeesAccounting acquires FeesAccounting {
        borrow_global_mut<FeesAccounting>(object::object_address(pool))
    }

    inline fun unchecked_mut_liquidity_pool_configs(): &mut LiquidityPoolConfigs acquires LiquidityPoolConfigs {
        borrow_global_mut<LiquidityPoolConfigs>(@cellana)
    }

    inline fun f(x0: u256, y: u256): u256 {
        x0 * (y * y * y) + (x0 * x0 * x0) * y
    }

    inline fun d(x0: u256, y: u256): u256 {
        3 * x0 * (y * y) + (x0 * x0 * x0)
    }

    fun get_y(x0: u256, xy: u256, y: u256): u256 {
        let i = 0;
        while (i < 255) {
            let y_prev = y;
            let k = f(x0, y);
            if (k < xy) {
                let dy = (xy - k) / d(x0, y);
                y = y + dy;
            } else {
                let dy = (k - xy) / d(x0, y);
                y = y - dy;
            };
            if (y > y_prev) {
                if (y - y_prev <= 1) {
                    return y
                }
            } else {
                if (y_prev - y <= 1) {
                    return y
                }
            };
            i = i + 1;
        };
        y
    }

    #[view]
    #[deprecated]
    public fun claimable_fees(_lp: address, _pool: Object<LiquidityPool>): (u128, u128) {
        abort 0
    }

    #[deprecated]
    public entry fun update_claimable_fees(_lp: address, _pool: Object<LiquidityPool>) {
        abort 0
    }

    #[deprecated]
    public fun mint(
        _lp: &signer,
        _fungible_asset_1: FungibleAsset,
        _fungible_asset_2: FungibleAsset,
        _is_stable: bool, ) {
        abort 0
    }

    #[test_only]
    friend cellana::liquidity_pool_tests;

    #[test_only]
    friend cellana::router_tests;

    #[test_only]
    friend cellana::vote_manager_tests;
}
