module cellana::cellana_token {
    use aptos_framework::fungible_asset::{Self, MintRef, TransferRef, BurnRef, FungibleAsset, FungibleStore};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::primary_fungible_store;

    use cellana::package_manager;

    use std::signer;
    use std::string;
    use std::option;

    // For minting emissions.
    friend cellana::minter;
    // For burning leftover emissions.
    friend cellana::vote_manager;
    // For locking/adding more $CELL into a voting escrow lock and for merging locks.
    friend cellana::voting_escrow;

    const TOKEN_NAME: vector<u8> = b"CELLANA";
    const TOKEN_SYMBOL: vector<u8> = b"CELL";
    const TOKEN_DECIMALS: u8 = 8;
    // TODO: Tweak
    const TOKEN_URI: vector<u8> = b"CELLANA";
    const PROJECT_URI: vector<u8> = b"https://cellana.finance/";

    #[resource_group_member(group = aptos_framework::object::ObjectGroup)]
    /// Fungible asset refs used to manage the $CELL token.
    struct CellanaToken has key {
        burn_ref: BurnRef,
        mint_ref: MintRef,
        transfer_ref: TransferRef,
    }

    /// Deploy the $CELL token.
    public entry fun initialize() {
        if (is_initialized()) {
            return
        };

        let cellana_token_metadata = &object::create_named_object(&package_manager::get_signer(), TOKEN_NAME);
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            cellana_token_metadata,
            option::none(),
            string::utf8(TOKEN_NAME),
            string::utf8(TOKEN_SYMBOL),
            TOKEN_DECIMALS,
            string::utf8(TOKEN_URI),
            string::utf8(PROJECT_URI),
        );
        let cellana_token = &object::generate_signer(cellana_token_metadata);
        move_to(cellana_token, CellanaToken {
            burn_ref: fungible_asset::generate_burn_ref(cellana_token_metadata),
            mint_ref: fungible_asset::generate_mint_ref(cellana_token_metadata),
            transfer_ref: fungible_asset::generate_transfer_ref(cellana_token_metadata),
        });
        package_manager::add_address(string::utf8(TOKEN_NAME), signer::address_of(cellana_token));
    }

    #[view]
    public fun is_initialized(): bool {
        package_manager::address_exists(string::utf8(TOKEN_NAME))
    }

    #[view]
    /// Return $CELL token address.
    public fun token_address(): address {
        package_manager::get_address(string::utf8(TOKEN_NAME))
    }

    #[view]
    /// Return the $CELL token metadata object.
    public fun token(): Object<CellanaToken> {
        object::address_to_object(token_address())
    }

    #[view]
    /// Return the total supply of $CELL tokens.
    public fun total_supply(): u128 {
        option::get_with_default(&fungible_asset::supply(token()), 0)
    }

    #[view]
    /// Return the total supply of $CELL tokens.
    public fun balance(user: address): u64 {
        primary_fungible_store::balance(user, token())
    }

    /// Called by the minter module to mint weekly emissions.
    public(friend) fun mint(amount: u64): FungibleAsset acquires CellanaToken {
        fungible_asset::mint(&unchecked_token_refs().mint_ref, amount)
    }

    public(friend) fun burn(cellana_tokens: FungibleAsset) acquires CellanaToken {
        fungible_asset::burn(&unchecked_token_refs().burn_ref, cellana_tokens);
    }

    /// For depositing $CELL into a fungible asset store. This can be the veCELL token, which cannot be deposited
    /// into normally as it's frozen (no owner transfers).
    public(friend) fun deposit<T: key>(store: Object<T>, cellana_tokens: FungibleAsset) acquires CellanaToken {
        fungible_asset::deposit_with_ref(&unchecked_token_refs().transfer_ref, store, cellana_tokens);
    }

    /// For withdrawing $CELL from a veNFT.
    public(friend) fun withdraw<T: key>(store: Object<T>, amount: u64): FungibleAsset acquires CellanaToken {
        fungible_asset::withdraw_with_ref(&unchecked_token_refs().transfer_ref, store, amount)
    }

    /// For extracting $CELL from the veCELL token when owner withdraws after the lockup has expired.
    public(friend) fun transfer<T: key>(
        from: Object<T>,
        to: Object<FungibleStore>,
        amount: u64,
    ) acquires CellanaToken {
        let from = object::convert(from);
        let transfer_ref = &unchecked_token_refs().transfer_ref;
        fungible_asset::transfer_with_ref(transfer_ref, from, to, amount);
    }

    /// Used to lock $CELL in when creating voting escrows.
    public(friend) fun disable_transfer<T: key>(cellana_store: Object<T>) acquires CellanaToken {
        let transfer_ref = &unchecked_token_refs().transfer_ref;
        fungible_asset::set_frozen_flag(transfer_ref, cellana_store, true);
    }

    inline fun unchecked_token_refs(): &CellanaToken {
        borrow_global<CellanaToken>(token_address())
    }

    #[test_only]
    friend cellana::cellana_token_tests;

    #[test_only]
    public fun test_mint(amount: u64): FungibleAsset acquires CellanaToken {
        mint(amount)
    }

    #[test_only]
    public fun test_burn(tokens: FungibleAsset) acquires CellanaToken {
        if (fungible_asset::amount(&tokens) == 0) {
            fungible_asset::destroy_zero(tokens);
        } else {
            burn(tokens);
        };
    }
}
