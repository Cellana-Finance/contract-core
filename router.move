module cellana::router {
    use std::vector;
    use aptos_std::math64;
    use aptos_framework::aptos_account;
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::fungible_asset::{Self, FungibleAsset, Metadata};
    use aptos_framework::object;
    use aptos_framework::object::Object;
    use aptos_framework::primary_fungible_store;
    use cellana::coin_wrapper::is_wrapper;

    use cellana::coin_wrapper;
    use cellana::gauge;
    use cellana::liquidity_pool::{Self, LiquidityPool};
    use cellana::vote_manager;

    /// Output is less than the desired minimum amount.
    const EINSUFFICIENT_OUTPUT_AMOUNT: u64 = 1;
    /// The liquidity pool is misconfigured and has 0 amount of one asset but non-zero amount of the other.
    const EINFINITY_POOL: u64 = 2;
    /// One or both tokens passed are not valid native fungible assets.
    const ENOT_NATIVE_FUNGIBLE_ASSETS: u64 = 3;
    /// Invalid input data.
    const EINVALID_INPUT_DATA: u64 = 4;
    /// Tokens that charge a transfer fee are not supported.
    const UNSUPPORTED_TAX: u64 = 6;

    public entry fun create_pool(token_1: Object<Metadata>, token_2: Object<Metadata>, is_stable: bool) {
        let pool = liquidity_pool::create(token_1, token_2, is_stable);
        vote_manager::whitelist_default_reward_pool(pool);
        vote_manager::create_gauge_internal(pool);
    }

    public entry fun create_pool_coin<CoinType>(token_2: Object<Metadata>, is_stable: bool) {
        let token_1 = coin_wrapper::create_fungible_asset<CoinType>();
        let pool = liquidity_pool::create(token_1, token_2, is_stable);
        vote_manager::whitelist_default_reward_pool(pool);
        vote_manager::create_gauge_internal(pool);
    }

    public entry fun create_pool_both_coins<CoinType1, CoinType2>(is_stable: bool) {
        let token_1 = coin_wrapper::create_fungible_asset<CoinType1>();
        let token_2 = coin_wrapper::create_fungible_asset<CoinType2>();

        let pool = liquidity_pool::create(token_1, token_2, is_stable);
        vote_manager::whitelist_default_reward_pool(pool);
        vote_manager::create_gauge_internal(pool);
    }

    /////////////////////////////////////////////////// USERS /////////////////////////////////////////////////////////

    #[view]
    public fun get_trade_diff(
        amount_in: u64,
        from_token: Object<Metadata>,
        to_token: Object<Metadata>,
        is_stable: bool
    ): (u64, u64) {
        let pool = liquidity_pool::liquidity_pool(from_token, to_token, is_stable);
        liquidity_pool::get_trade_diff(pool, from_token, amount_in)
    }

    #[view]
    public fun get_amount_out(
        amount_in: u64,
        from_token: Object<Metadata>,
        to_token: Object<Metadata>,
        is_stable: bool,
    ): (u64, u64) {
        let pool = liquidity_pool::liquidity_pool(from_token, to_token, is_stable);
        liquidity_pool::get_amount_out(pool, from_token, amount_in)
    }

    #[view]
    public fun get_amounts_out(
        amount_in: u64,
        from_token: Object<Metadata>,
        to_tokens: vector<address>,
        is_stable: vector<bool>,
    ): u64 {
        assert!(vector::length(&to_tokens) == vector::length(&is_stable), EINVALID_INPUT_DATA);

        let curr_amount_in = amount_in;
        let from_token = from_token;
        vector::zip(to_tokens, is_stable, |to_token, is_stable| {
            let to_token = object::address_to_object(to_token);
            let (amount_out, _) = get_amount_out(curr_amount_in, from_token, to_token, is_stable);
            from_token = to_token;
            curr_amount_in = amount_out;
        });
        curr_amount_in
    }

    public entry fun swap_entry(
        user: &signer,
        amount_in: u64,
        amount_out_min: u64,
        from_token: Object<Metadata>,
        to_token: Object<Metadata>,
        is_stable: bool,
        recipient: address,
    ) {
        assert!(!is_wrapper( to_token ), ENOT_NATIVE_FUNGIBLE_ASSETS);
        let in = exact_withdraw(user, from_token, amount_in);
        let out = swap(in, amount_out_min, to_token, is_stable);
        exact_deposit(recipient, out);
    }

    public entry fun swap_route_entry(
        user: &signer,
        amount_in: u64,
        amount_out_min: u64,
        from_token: Object<Metadata>,
        to_tokens: vector<Object<Metadata>>,
        is_stables: vector<bool>,
        recipient: address,
    ) {
        assert!(!is_wrapper( *vector::borrow(&to_tokens,vector::length(&to_tokens)-1) ), ENOT_NATIVE_FUNGIBLE_ASSETS);

        let in = exact_withdraw(user, from_token, amount_in);
        let out = swap_router(in, amount_out_min, to_tokens, is_stables);
        exact_deposit(recipient, out);
    }

    public entry fun swap_route_entry_from_coin<FromCoin>(
        user: &signer,
        amount_in: u64,
        amount_out_min: u64,
        to_tokens: vector<Object<Metadata>>,
        is_stables: vector<bool>,
        recipient: address,
    ) {
        assert!(!is_wrapper( *vector::borrow(&to_tokens,vector::length(&to_tokens)-1) ), ENOT_NATIVE_FUNGIBLE_ASSETS);
        let in = coin_wrapper::wrap(coin::withdraw<FromCoin>(user, amount_in));
        exact_deposit(recipient, swap_router(in, amount_out_min, to_tokens, is_stables));
    }

    public entry fun swap_route_entry_to_coin<ToCoin>(
        user: &signer,
        amount_in: u64,
        amount_out_min: u64,
        from_token: Object<Metadata>,
        to_tokens: vector<Object<Metadata>>,
        is_stables: vector<bool>,
        recipient: address,
    ) {
        let in = exact_withdraw(user, from_token, amount_in);
        let out = swap_router(in, amount_out_min, to_tokens, is_stables);
        coin::register<ToCoin>(user);
        coin::deposit(recipient, coin_wrapper::unwrap<ToCoin>(out));
    }

    public entry fun swap_route_entry_both_coins<FromCoin, ToCoin>(
        user: &signer,
        amount_in: u64,
        amount_out_min: u64,
        to_tokens: vector<Object<Metadata>>,
        is_stables: vector<bool>,
        recipient: address,
    ) {
        let in = coin_wrapper::wrap(coin::withdraw<FromCoin>(user, amount_in));
        let out = swap_router(in, amount_out_min, to_tokens, is_stables);
        coin::register<ToCoin>(user);
        coin::deposit(recipient, coin_wrapper::unwrap<ToCoin>(out));
    }

    public fun swap_router(
        in: FungibleAsset,
        amount_out_min: u64,
        to_tokens: vector<Object<Metadata>>,
        is_stables: vector<bool>,
    ): FungibleAsset {
        let out = in;
        vector::zip(to_tokens, is_stables, |to_token, is_stable| {
            out = swap(out, 0, to_token, is_stable);
        });
        assert!(fungible_asset::amount(&out) >= amount_out_min, EINSUFFICIENT_OUTPUT_AMOUNT);
        out
    }

    public fun swap(
        in: FungibleAsset,
        amount_out_min: u64,
        to_token: Object<Metadata>,
        is_stable: bool,
    ): FungibleAsset {
        let from_token = fungible_asset::asset_metadata(&in);
        let pool = liquidity_pool::liquidity_pool(from_token, to_token, is_stable);
        let out = liquidity_pool::swap(pool, in);
        assert!(fungible_asset::amount(&out) >= amount_out_min, EINSUFFICIENT_OUTPUT_AMOUNT);
        out
    }

    public entry fun swap_coin_for_asset_entry<FromCoin>(
        user: &signer,
        amount_in: u64,
        amount_out_min: u64,
        to_token: Object<Metadata>,
        is_stable: bool,
        recipient: address,
    ) {


        let in = coin::withdraw<FromCoin>(user, amount_in);
        let out = swap_coin_for_asset<FromCoin>(in, amount_out_min, to_token, is_stable);
        exact_deposit(recipient, out);
    }

    public fun swap_coin_for_asset<FromCoin>(
        in: Coin<FromCoin>,
        amount_out_min: u64,
        to_token: Object<Metadata>,
        is_stable: bool,
    ): FungibleAsset {
        swap(coin_wrapper::wrap(in), amount_out_min, to_token, is_stable)
    }

    public entry fun swap_asset_for_coin_entry<ToCoin>(
        user: &signer,
        amount_in: u64,
        amount_out_min: u64,
        from_token: Object<Metadata>,
        is_stable: bool,
        recipient: address,
    ) {
        let in = exact_withdraw(user, from_token, amount_in);
        let out = swap_asset_for_coin<ToCoin>(in, amount_out_min, is_stable);
        coin::register<ToCoin>(user);
        aptos_account::deposit_coins(recipient, out);
    }

    public fun swap_asset_for_coin<ToCoin>(
        in: FungibleAsset,
        amount_out_min: u64,
        is_stable: bool,
    ): Coin<ToCoin> {
        let to_token = coin_wrapper::get_wrapper<ToCoin>();
        let out = swap(in, amount_out_min, to_token, is_stable);
        coin_wrapper::unwrap<ToCoin>(out)
    }

    public entry fun swap_coin_for_coin_entry<FromCoin, ToCoin>(
        user: &signer,
        amount_in: u64,
        amount_out_min: u64,
        is_stable: bool,
        recipient: address,
    ) {
        let in = coin::withdraw<FromCoin>(user, amount_in);
        let out = swap_coin_for_coin<FromCoin, ToCoin>(in, amount_out_min, is_stable);
        coin::register<ToCoin>(user);
        coin::deposit(recipient, out);
    }

    public fun swap_coin_for_coin<FromCoin, ToCoin>(
        in: Coin<FromCoin>,
        amount_out_min: u64,
        is_stable: bool,
    ): Coin<ToCoin> {
        let in = coin_wrapper::wrap(in);
        swap_asset_for_coin<ToCoin>(in, amount_out_min, is_stable)
    }

    /////////////////////////////////////////////////// LPs ///////////////////////////////////////////////////////////

    #[view]
    public fun quote_liquidity(
        token_1: Object<Metadata>,
        token_2: Object<Metadata>,
        is_stable: bool,
        amount_1: u64,
    ): u64 {
        let pool = liquidity_pool::liquidity_pool(token_1, token_2, is_stable);
        let (reserves_1, reserves_2) = liquidity_pool::pool_reserves(pool);
        // Reverse the reserve numbers if token 1 and token 2 don't match the pool's token order.
        if (!liquidity_pool::is_sorted(token_1, token_2)) {
            (reserves_1, reserves_2) = (reserves_2, reserves_1);
        };
        if (reserves_1 == 0 || reserves_2 == 0) {
            0
        }else {
            math64::mul_div(amount_1, reserves_2, reserves_1)
        }
    }

    #[view]
    public fun liquidity_amount_out(
        token_1: Object<Metadata>,
        token_2: Object<Metadata>,
        is_stable: bool,
        amount_1: u64,
        amount_2: u64
    ): u64 {
        liquidity_pool::liquidity_out(token_1, token_2, is_stable, amount_1, amount_2)
    }

    #[view]
    public fun redeemable_liquidity(pool: Object<LiquidityPool>, amount: u64): (u64, u64) {
        liquidity_pool::liquidity_amounts(pool, amount)
    }

    public entry fun add_liquidity_and_stake_entry(
        lp: &signer,
        token_1: Object<Metadata>,
        token_2: Object<Metadata>,
        is_stable: bool,
        amount_1: u64,
        amount_2: u64,
    ) {
        let pool = liquidity_pool::liquidity_pool(token_1, token_2, is_stable);

        // add liquidity
        let (amount_1, amount_2) = get_optimal_amounts(token_1, token_2, is_stable, amount_1, amount_2);
        let tokens_1 = exact_withdraw(lp, token_1, amount_1);
        assert!(amount_1 == fungible_asset::amount(&tokens_1), EINVALID_INPUT_DATA);
        let tokens_2 = exact_withdraw(lp, token_2, amount_2);
        assert!(amount_2 == fungible_asset::amount(&tokens_2), EINVALID_INPUT_DATA);
        let lp_token_amount = liquidity_pool::mint_lp(lp, tokens_1, tokens_2, is_stable);

        // stake lp to the gauge
        let gauge = vote_manager::get_gauge(pool);
        gauge::stake(lp, gauge, lp_token_amount);
    }

    public entry fun add_liquidity_and_stake_coin_entry<CoinType>(
        lp: &signer,
        token_2: Object<Metadata>,
        is_stable: bool,
        amount_1: u64,
        amount_2: u64,
    ) {
        let pool = liquidity_pool::liquidity_pool(coin_wrapper::get_wrapper<CoinType>(), token_2, is_stable);

        // add liquidity
        let (amount_1, amount_2) = get_optimal_amounts(
            coin_wrapper::get_wrapper<CoinType>(),
            token_2,
            is_stable,
            amount_1,
            amount_2
        );
        let token_1 = coin::withdraw<CoinType>(lp, amount_1);
        let token_2 = exact_withdraw(lp, token_2, amount_2);
        assert!(amount_2 == fungible_asset::amount(&token_2), EINVALID_INPUT_DATA);
        let lp_token_amount = liquidity_pool::mint_lp(lp, coin_wrapper::wrap(token_1), token_2, is_stable);

        // stake lp to the gauge
        let gauge = vote_manager::get_gauge(pool);
        gauge::stake(lp, gauge, lp_token_amount);
    }

    public entry fun add_liquidity_and_stake_both_coins_entry<CoinType1, CoinType2>(
        lp: &signer,
        is_stable: bool,
        amount_1: u64,
        amount_2: u64,
    ) {
        let pool = liquidity_pool::liquidity_pool(
            coin_wrapper::get_wrapper<CoinType1>(),
            coin_wrapper::get_wrapper<CoinType2>(),
            is_stable,
        );

        // add liquidity
        let (amount_1, amount_2) = get_optimal_amounts(
            coin_wrapper::get_wrapper<CoinType1>(),
            coin_wrapper::get_wrapper<CoinType2>(),
            is_stable,
            amount_1,
            amount_2);
        let token_1 = coin::withdraw<CoinType1>(lp, amount_1);
        let token_2 = coin::withdraw<CoinType2>(lp, amount_2);
        let lp_token_amount = liquidity_pool::mint_lp(
            lp,
            coin_wrapper::wrap(token_1),
            coin_wrapper::wrap(token_2),
            is_stable
        );

        // stake lp to the gauge
        let gauge = vote_manager::get_gauge(pool);
        gauge::stake(lp, gauge, lp_token_amount);
    }

    public entry fun unstake_and_remove_liquidity_entry(
        lp: &signer,
        token_1: Object<Metadata>,
        token_2: Object<Metadata>,
        is_stable: bool,
        liquidity: u64,
        amount_1_min: u64,
        amount_2_min: u64,
        recipient: address,
    ) {
        let pool = liquidity_pool::liquidity_pool(token_1, token_2, is_stable);
        gauge::unstake_lp(lp, vote_manager::get_gauge(pool), liquidity);

        assert!(!coin_wrapper::is_wrapper(token_1) && !coin_wrapper::is_wrapper(token_2), ENOT_NATIVE_FUNGIBLE_ASSETS);
        let (amount_1, amount_2) = remove_liquidity_internal(
            lp,
            token_1,
            token_2,
            is_stable,
            liquidity,
            amount_1_min,
            amount_2_min
        );
        primary_fungible_store::deposit(recipient, amount_1);
        primary_fungible_store::deposit(recipient, amount_2);
    }


    public entry fun unstake_and_remove_liquidity_coin_entry<CoinType>(
        lp: &signer,
        token_2: Object<Metadata>,
        is_stable: bool,
        liquidity: u64,
        amount_1_min: u64,
        amount_2_min: u64,
        recipient: address,
    ) {
        let token_1 = coin_wrapper::get_wrapper<CoinType>();
        let pool = liquidity_pool::liquidity_pool(token_1, token_2, is_stable);
        gauge::unstake_lp(lp, vote_manager::get_gauge(pool), liquidity);

        assert!(!coin_wrapper::is_wrapper(token_2), ENOT_NATIVE_FUNGIBLE_ASSETS);
        let (amount_1, amount_2) =
            remove_liquidity_internal(lp, token_1, token_2, is_stable, liquidity, amount_1_min, amount_2_min);

        aptos_account::deposit_coins<CoinType>(recipient, coin_wrapper::unwrap(amount_1));
        primary_fungible_store::deposit(recipient, amount_2);
    }

    public entry fun unstake_and_remove_liquidity_both_coins_entry<CoinType1, CoinType2>(
        lp: &signer,
        is_stable: bool,
        liquidity: u64,
        amount_1_min: u64,
        amount_2_min: u64,
        recipient: address,
    ) {
        let token_1 = coin_wrapper::get_wrapper<CoinType1>();
        let token_2 = coin_wrapper::get_wrapper<CoinType2>();
        let pool = liquidity_pool::liquidity_pool(token_1, token_2, is_stable);
        gauge::unstake_lp(lp, vote_manager::get_gauge(pool), liquidity);

        let (amount_1, amount_2) =
            remove_liquidity_internal(lp, token_1, token_2, is_stable, liquidity, amount_1_min, amount_2_min);
        aptos_account::deposit_coins<CoinType1>(recipient, coin_wrapper::unwrap(amount_1));
        aptos_account::deposit_coins<CoinType2>(recipient, coin_wrapper::unwrap(amount_2));
    }

    fun get_optimal_amounts(
        token_1: Object<Metadata>,
        token_2: Object<Metadata>,
        is_stable: bool,
        amount_1: u64,
        amount_2: u64
    ): (u64, u64) {
        assert!(amount_1 > 0 && amount_2 > 0, EINVALID_INPUT_DATA);
        let optimal_amount_2 = quote_liquidity(token_1, token_2, is_stable, amount_1);
        // Initial liquidity. There's no optimal amount. Return original amounts.
        if (optimal_amount_2 == 0) {
            (amount_1, amount_2)
        } else if (optimal_amount_2 <= amount_2) {
            // User's passing in more of token 2 than necessary.
            (amount_1, optimal_amount_2)
        }else {
            // User's passing in more of token 1 than necessary.
            let optimal_amount_1 = quote_liquidity(token_2, token_1, is_stable, amount_2);
            (optimal_amount_1, amount_2)
        }
    }

    fun remove_liquidity_internal(
        lp: &signer,
        token_1: Object<Metadata>,
        token_2: Object<Metadata>,
        is_stable: bool,
        liquidity: u64,
        amount_1_min: u64,
        amount_2_min: u64,
    ): (FungibleAsset, FungibleAsset) {
        let (redeemed_1, redeemed_2) = liquidity_pool::burn(lp, token_1, token_2, is_stable, liquidity);
        let amount_1 = fungible_asset::amount(&redeemed_1);
        let amount_2 = fungible_asset::amount(&redeemed_2);
        assert!(amount_1 >= amount_1_min && amount_2 >= amount_2_min, EINSUFFICIENT_OUTPUT_AMOUNT);
        (redeemed_1, redeemed_2)
    }

    // Deposit fungible asset use primary fungible store without tax
    public(friend) fun exact_deposit(owner: address, fa: FungibleAsset) {
        let fa_balance = fungible_asset::amount(&fa);
        let token_metadata = fungible_asset::asset_metadata(&fa);
        let before_balance = primary_fungible_store::balance(owner, token_metadata);
        primary_fungible_store::deposit(owner, fa);
        let after_balance = primary_fungible_store::balance(owner, token_metadata);
        assert!(fa_balance == after_balance - before_balance, UNSUPPORTED_TAX);
    }

    // Withdraw fungible asset use primary fungible store without tax
    public(friend) fun exact_withdraw<T: key>(
        owner: &signer,
        metadata: Object<T>,
        amount: u64
    ): FungibleAsset {
        let fa = primary_fungible_store::withdraw(owner, metadata, amount);
        assert!(fungible_asset::amount(&fa) == amount, UNSUPPORTED_TAX);
        fa
    }

    #[deprecated]
    public entry fun add_liquidity_entry(
        _lp: &signer,
        _token_1: Object<Metadata>,
        _token_2: Object<Metadata>,
        _is_stable: bool,
        _amount_1: u64,
        _amount_2: u64,
    ) {
        abort 0
    }

    #[deprecated]
    public fun add_liquidity(
        _lp: &signer,
        _token_1: FungibleAsset,
        _token_2: FungibleAsset,
        _is_stable: bool,
    ) {
        abort 0
    }

    #[deprecated]
    public entry fun add_liquidity_coin_entry<CoinType>(
        _lp: &signer,
        _token_2: Object<Metadata>,
        _is_stable: bool,
        _amount_1: u64,
        _amount_2: u64,
    ) {
        abort 0
    }

    #[deprecated]
    public fun add_liquidity_coin<CoinType>(
        _lp: &signer,
        _token_1: Coin<CoinType>,
        _token_2: FungibleAsset,
        _is_stable: bool,
    ) {
        abort 0
    }

    #[deprecated]
    public entry fun add_liquidity_both_coins_entry<CoinType1, CoinType2>(
        _lp: &signer,
        _is_stable: bool,
        _amount_1: u64,
        _amount_2: u64,
    ) {
        abort 0
    }

    #[deprecated]
    public fun add_liquidity_both_coins<CoinType1, CoinType2>(
        _lp: &signer,
        _token_1: Coin<CoinType1>,
        _token_2: Coin<CoinType2>,
        _is_stable: bool,
    ) {
        abort 0
    }

    #[deprecated]
    public entry fun remove_liquidity_entry(
        _lp: &signer,
        _token_1: Object<Metadata>,
        _token_2: Object<Metadata>,
        _is_stable: bool,
        _liquidity: u64,
        _amount_1_min: u64,
        _amount_2_min: u64,
        _recipient: address,
    ) {
        abort 0
    }

    #[deprecated]
    public fun remove_liquidity(
        _lp: &signer,
        _token_1: Object<Metadata>,
        _token_2: Object<Metadata>,
        _is_stable: bool,
        _liquidity: u64,
        _amount_1_min: u64,
        _amount_2_min: u64,
    ): (FungibleAsset, FungibleAsset) {
        abort 0
    }

    #[deprecated]
    public entry fun remove_liquidity_coin_entry<CoinType>(
        _lp: &signer,
        _token_2: Object<Metadata>,
        _is_stable: bool,
        _liquidity: u64,
        _amount_1_min: u64,
        _amount_2_min: u64,
        _recipient: address,
    ) {
        abort 0
    }

    #[deprecated]
    public fun remove_liquidity_coin<CoinType>(
        _lp: &signer,
        _token_2: Object<Metadata>,
        _is_stable: bool,
        _liquidity: u64,
        _amount_1_min: u64,
        _amount_2_min: u64,
    ): (Coin<CoinType>, FungibleAsset) {
        abort 0
    }

    #[deprecated]
    public entry fun remove_liquidity_both_coins_entry<CoinType1, CoinType2>(
        _lp: &signer,
        _is_stable: bool,
        _liquidity: u64,
        _amount_1_min: u64,
        _amount_2_min: u64,
        _recipient: address,
    ) {
        abort 0
    }

    #[deprecated]
    public fun remove_liquidity_both_coins<CoinType1, CoinType2>(
        _lp: &signer,
        _is_stable: bool,
        _liquidity: u64,
        _amount_1_min: u64,
        _amount_2_min: u64,
    ): (Coin<CoinType1>, Coin<CoinType2>) {
        abort 0
    }
}
