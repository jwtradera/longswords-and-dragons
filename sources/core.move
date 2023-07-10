/*
    This quest involves the new standard of NFTs and requires knowledge of aptos-token-objects smart contract.
    The quest has two main features: breeding NFTs and combining NFTs.
    Breeding requires to have two monster NFTs from the same collection. It freezes transfer of those NFTs for time
    specified while creating a monster collection. After the time passed, owner of the two NFTs can call `hatch_monster`
    function, which unlocks the NFTs and transfers a new one with combine properties to the owner.
    Combining requires to have from 2 to 10 NFTs from the same collection (amount specified while creating equipment
    collection). Owner of the NFTs can call `combine_equipment` function to burn their NFTs and receive a new one with
    combined properties.
*/

module overmind::breeder_core {
    use std::bcs;
    use std::option;
    use std::signer;
    use std::string::{Self, String};
    use std::vector;
    use aptos_std::aptos_hash;
    use aptos_std::from_bcs;
    use aptos_std::math64;
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::object::{Self, Object};
    use aptos_framework::timestamp;
    use aptos_token_objects::aptos_token;
    use aptos_token_objects::token::{Self, Token};
    use aptos_token_objects::property_map::{Self, PropertyMap};
    use overmind::breeder_events::{
        Self,
        CreateDragonCollectionEvent,
        CreateDragonEvent,
        BreedDragonsEvent,
        HatchDragonEvent,
        CreateSwordCollectionEvent,
        CreateSwordEvent,
        CombineSwordsEvent
    };
    #[test_only]
    use aptos_token_objects::royalty;
    #[test_only]
    use aptos_token_objects::collection;
    #[test_only]
    use aptos_token_objects::collection::Collection;
    #[test_only]
    use std::features;

    ////////////
    // ERRORS //
    ////////////

    const ERROR_SIGNER_NOT_ADMIN: u64 = 0;
    const ERROR_STATE_NOT_INITIALIZED: u64 = 1;
    const ERROR_INVALID_BREEDING_TIME: u64 = 2;
    const ERROR_INVALID_COMBINE_AMOUNT: u64 = 3;
    const ERROR_INVALID_SWORDS_PROPERTY_VALUES_SUM: u64 = 4;
    const ERROR_COLLECTION_ALREADY_EXISTS: u64 = 5;
    const ERROR_COLLECTION_DOES_NOT_EXIST: u64 = 6;
    const ERROR_SIGNER_IS_NOT_THE_OWNER: u64 = 7;
    const ERROR_DRAGON_DURING_BREEDING: u64 = 8;
    const ERROR_DRAGONS_NOT_BREEDING: u64 = 9;
    const ERROR_BREEDING_HAS_NOT_ENDED: u64 = 10;
    const ERROR_INCORRECT_AMOUNT_OF_SWORDS: u64 = 11;
    const ERROR_PROPERTY_LENGTH_MISMATCH: u64 = 12;
    const ERROR_TOKEN_FROM_WRONG_COLLECTION: u64 = 13;

    //////////////
    // PDA Seed //
    //////////////

    const BREEDER_SEED: vector<u8> = b"BREEDER";

    //////////////////////////
    // COLLECTIONS SETTINGS //
    //////////////////////////

    const DRAGON_COLLECTION_MAX_SUPPLY: u64 = 10000;
    const SWORD_COLLECTION_MAX_SUPPLY: u64 = 1000;
    const ROYALTY_NUMERATOR: u64 = 1;
    const ROYALTY_DENOMINATOR: u64 = 10;

    ////////////////////////////
    // BREEDING TIME SETTINGS //
    ////////////////////////////

    const MINIMAL_BREEDING_TIME: u64 = 60 * 60 * 24;
    const MAXIMAL_BREEDING_TIME: u64 = 60 * 60 * 24 * 365 / 12;

    ////////////////////////
    // MONSTER PROPERTIES //
    ////////////////////////

    const DRAGON_PROPERTY_KEYS: vector<vector<u8>> = vector[b"Health", b"Defence", b"Strength", b"Ability"];
    const DRAGON_PROPERTY_TYPES: vector<vector<u8>> = vector[b"u64", b"u64", b"u64", b"0x1::string::String"];
    const DRAGON_MINIMAL_START_PROPERTY_VALUES: vector<u64> = vector[10, 0, 1];
    const DRAGON_MAXIMAL_START_PROPERTY_VALUES: vector<u64> = vector[100, 10, 20];

    /////////////////////////////
    // COMBINE AMOUNT SETTINGS //
    /////////////////////////////

    const MINIMAL_AMOUNT_TO_COMBINE: u64 = 2;
    const MAXIMAL_AMOUNT_TO_COMBINE: u64 = 10;

    //////////////////////////
    // EQUIPMENT PROPERTIES //
    //////////////////////////

    const SWORD_PROPERTY_KEYS: vector<vector<u8>> = vector[b"Attack", b"Durability", b"Ability"];
    const SWORD_PROPERTY_TYPES: vector<vector<u8>> = vector[b"u64", b"u64", b"0x1::string::String"];
    const SWORD_MINIMAL_START_PROPERTY_VALUES_SUM: u64 = 10;
    const SWORD_MAXIMAL_START_PROPERTY_VALUES_SUM: u64 = 100;

    /*
        Resource kept under admin address. Stores data about available collections.
    */
    struct State has key {
        // Breeder instance
        breeder: Breeder,
        // Combiner instance
        combiner: Combiner,
        // PDA's SingerCapability
        cap: SignerCapability
    }

    /*
        Holds data about dragon colections and ongoing breedings.
    */
    struct Breeder has store {
        // Available dragon collections and their corresponding names
        collections: SimpleMap<String, DragonRace>,
        // List of ongoing breedings and timestamps of when they going to finish
        ongoing_breedings: SimpleMap<vector<u8>, u64>,
        // Events
        create_dragon_collection_events: EventHandle<CreateDragonCollectionEvent>,
        create_dragon_events: EventHandle<CreateDragonEvent>,
        breed_dragons_events: EventHandle<BreedDragonsEvent>,
        hatch_dragon_events: EventHandle<HatchDragonEvent>
    }

    /*
        Holds data about a single monster collection
    */
    struct DragonRace has store, copy, drop {
        // Amount of time required for two dragons to hatch a new one
        breeding_time: u64,
        // Starting properties of a dragon created via create_dragon function
        starting_properties: vector<vector<u8>>,
    }

    /*
        Holds data about equipment collections
    */
    struct Combiner has store {
        // Available sword collections with their corresponding names
        collections: SimpleMap<String, SwordType>,
        // Events
        create_sword_collection_events: EventHandle<CreateSwordCollectionEvent>,
        create_sword_events: EventHandle<CreateSwordEvent>,
        combine_swords_events: EventHandle<CombineSwordsEvent>
    }

    /*
        Holds data about a single sword collection
    */
    struct SwordType has store, copy, drop {
        // Amount of sword tokens required to combine them into one
        combine_amount: u64,
        // Starting properties of sword created via create_sword function
        starting_properties: vector<vector<u8>>
    }

    /*
        Creates a PDA and initializes State resource
        @param admin - signer of the admin account
    */
    public entry fun init(admin: &signer) {
        // TODO: Assert the signer is the admin
        assert_signer_is_admin(admin);
        
        // TODO: Create resource account
        let (resource_acc, signer_cap) = account::create_resource_account(admin, BREEDER_SEED);

        // TODO: Create State instance and move it to the admin
        move_to(
            admin,
            State {
                breeder: Breeder {
                    collections: simple_map::create(),
                    ongoing_breedings: simple_map::create(),
                    create_dragon_collection_events: account::new_event_handle<CreateDragonCollectionEvent>(&resource_acc),
                    create_dragon_events: account::new_event_handle<CreateDragonEvent>(&resource_acc),
                    breed_dragons_events: account::new_event_handle<BreedDragonsEvent>(&resource_acc),
                    hatch_dragon_events: account::new_event_handle<HatchDragonEvent>(&resource_acc),
                },
                combiner: Combiner {
                    collections: simple_map::create(),
                    create_sword_collection_events: account::new_event_handle<CreateSwordCollectionEvent>(&resource_acc),
                    create_sword_events: account::new_event_handle<CreateSwordEvent>(&resource_acc),
                    combine_swords_events: account::new_event_handle<CombineSwordsEvent>(&resource_acc),
                },
                cap: signer_cap
            }
        );
    }

    /*
        Creates a new dragpm collection and adds it to Breeder's collections.
        @param account - an account signing the transaction
        @param name - name of the new collection
        @param description - description of the new collection
        @param uri - image's URI of the new collection
        @param breeding_time - amount of time NFTs will be frozen for while breeding
        @param ability_property - special ability of every NFT in the collection
    */
    public entry fun create_dragon_collection(
        _account: &signer,
        name: String,
        description: String,
        uri: String,
        breeding_time: u64,
        ability_property: String
    ) acquires State {
        // TODO: Assert that the state is initialized
        assert_state_initialized();
        let state = borrow_global_mut<State>(@admin);

        // TODO: Assert that breeding time is correct
        assert_breeding_time_is_correct(breeding_time);

        // TODO: Assert that a collection with provided name does not exist
        assert_collection_does_not_exist(&simple_map::keys(&state.breeder.collections), &name);

        // TODO: Create a collection
        let resource_account = account::create_signer_with_capability(&state.cap);
        create_collection_internal(&resource_account, name, description, uri, DRAGON_COLLECTION_MAX_SUPPLY, false, true);

        // TODO: Calculate monster starting properties
        let starting_properties = vector::empty();
        let calculated_properties = calculate_dragons_starting_properties(breeding_time);
        vector::for_each_ref(&calculated_properties, |property| {
            vector::push_back(&mut starting_properties, bcs::to_bytes(property));
        });

        // TODO: Push ability property to the starting properties
        vector::push_back(&mut starting_properties, bcs::to_bytes(&ability_property));

        // TODO: Add a new MonsterRace to Breeder's collections
        simple_map::add(&mut state.breeder.collections, name, DragonRace {
            breeding_time,
            starting_properties
        });

        // TODO: Emit CreateMonsterCollectionEvent event
        let new_collection_event = breeder_events::new_create_dragon_collection_event(
            name, description, uri, breeding_time, starting_properties, timestamp::now_seconds()
        );
        event::emit_event<CreateDragonCollectionEvent>(
            &mut state.breeder.create_dragon_collection_events, new_collection_event
        );
    }

    /*
        Creates a new sword collection and adds it to Combiner's collections.
        @param account - signer of the transaction
        @param name - name of the new collection
        @param description - description of the new collection
        @param uri - image's URI of the new collection
        @param combine_amount - amount of NFT from this collection required to combined them into one
        @param ability_property - special ability of NFTs from this collection
    */
    public entry fun create_sword_collection(
        _account: &signer,
        name: String,
        description: String,
        uri: String,
        combine_amount: u64,
        property_values: vector<u64>,
        ability_property: String
    ) acquires State {
        // TODO: Assert that combine amount is correct
        assert_combine_amount_is_correct(combine_amount);

        // TODO: Calculate equipment starting properties sum
        let starting_properties_sum = calculate_swords_starting_properties_sum(combine_amount);

        // TODO: Assert that sum of provided property_values is correct
        assert_sword_property_values_sum_is_correct(&property_values, starting_properties_sum);

        // TODO: Assert that state is initialized
        assert_state_initialized();
        let state = borrow_global_mut<State>(@admin);

        // TODO: Assert that collection with provided name does not exist
        assert_collection_does_not_exist(&simple_map::keys(&state.combiner.collections), &name);

        // TODO: Create a collection
        let resource_account = account::create_signer_with_capability(&state.cap);
        create_collection_internal(&resource_account, name, description, uri, SWORD_COLLECTION_MAX_SUPPLY, true, false);

        // TODO: Create a new Equipment and add it to Combiner's collections
        let starting_properties = vector::map_ref(&property_values, |value| {
            bcs::to_bytes(value)
        });
        vector::push_back(&mut starting_properties, bcs::to_bytes(&ability_property));

        simple_map::add(&mut state.combiner.collections, name, SwordType {
            combine_amount,
            starting_properties
        });

        // TODO: Emit CreateEquipmentCollectionEvent event
        let new_collection_event = breeder_events::new_create_sword_collection_event(
            name, description, uri, combine_amount, starting_properties, timestamp::now_seconds()
        );
        event::emit_event<CreateSwordCollectionEvent>(
            &mut state.combiner.create_sword_collection_events, new_collection_event
        );
    }

    /*
        Creates a new dragon NFT from provided collection.
        @param account - account, which the newly created token is transfered to
        @param collection_name - name of the collection
        @param dragon_name - name of the created dragon token
        @param dragon_description - description of the created dragon token
        @param dragon_uri - image's UTI of the created dragon token
    */
    public entry fun create_dragon(
        account: &signer,
        collection_name: String,
        dragon_name: String,
        dragon_description: String,
        dragon_uri: String
    ) acquires State {
        // TODO: Assert that state is initialized
        assert_state_initialized();
        let state = borrow_global_mut<State>(@admin);

        // TODO: Assert that collection with provided name exists
        assert_collection_exists(&simple_map::keys(&state.breeder.collections), &collection_name);

        // TODO: Create a variable holding PDA's GUID next creation number
        let resource_account = account::create_signer_with_capability(&state.cap);
        let resource_acc_addr = signer::address_of(&resource_account);
        let creation_number = account::get_guid_next_creation_num(resource_acc_addr);
        let token_address = object::create_guid_object_address(resource_acc_addr, creation_number);

        // TODO: Mint a new NFT
        aptos_token::mint(
            &resource_account,
            collection_name,
            dragon_description,
            dragon_name,
            dragon_uri,
            vector::empty(),
            vector::empty(),
            vector::empty(),
        );

        // TODO: Transfer the NFT to the signer of the transaction
        let account_addr = signer::address_of(account);
        object::transfer_raw(&resource_account, token_address, account_addr);

        // TODO: Emit CreateMonsterEvent event
        let new_dragon_event = breeder_events::new_create_dragon_event(
            account_addr, collection_name, dragon_name, dragon_description, dragon_uri, creation_number, timestamp::now_seconds()
        );
        event::emit_event<CreateDragonEvent>(
            &mut state.breeder.create_dragon_events, new_dragon_event
        );
    }


    /*
        Creates a new sword token from provided collection
        @param account - account, which the newly created token is transfered to
        @param collection_name - name of the collection
        @param sword_name - name of the created sword token
        @param sword_description - description of the created sword token
        @param sword_uri - image's UTI of the created sword token
        @param amount - amount of tokens to be created
    */
    public entry fun create_sword(
        account: &signer,
        collection_name: String,
        sword_name: String,
        sword_description: String,
        sword_uri: String,
        amount: u64
    ) acquires State {
        // TODO: Assert that state is initialized
        assert_state_initialized();
        let state = borrow_global_mut<State>(@admin);

        // TODO: Assert that collection with provided name exists
        assert_collection_exists(&simple_map::keys(&state.combiner.collections), &collection_name);

        // TODO: For every token to be created:
        //      1. Create a variable holding PDA's GUID next creation number
        //      2. Mint a new NFT
        //      3. Transfer the NFT to the signer of the transaction
        let account_addr = signer::address_of(account);
        let resource_account = account::create_signer_with_capability(&state.cap);
        let resource_acc_addr = signer::address_of(&resource_account);

        let i = 0;
        let creation_numbers = vector::empty();
        while (i < amount) {
            let creation_number = account::get_guid_next_creation_num(resource_acc_addr);
            let token_address = object::create_guid_object_address(resource_acc_addr, creation_number);

            // TODO: Mint a new NFT
            aptos_token::mint(
                &resource_account,
                collection_name,
                sword_description,
                sword_name,
                sword_uri,
                vector::empty(),
                vector::empty(),
                vector::empty(),
            );

            object::transfer_raw(&resource_account, token_address, account_addr);
            vector::push_back(&mut creation_numbers, creation_number);

            i = i + 1;
        };

        // TODO: Emit CreateEquipmentEvent event
        let new_sword_event = breeder_events::new_create_sword_event(
            account_addr, collection_name, sword_name, sword_description, sword_uri, amount, creation_numbers, timestamp::now_seconds()
        );
        event::emit_event<CreateSwordEvent>(
            &mut state.combiner.create_sword_events, new_sword_event
        );
    }

    /*
        Freezes both provided dragon tokens and adds a record to Breeder's ongoing_breedings
        @param owner - owner of the provided monster tokens
        @param collection_name - name of the collection, which the tokens are from
        @param first_dragon_creation_number - creation number of the first dragon token
        @param second_dragon_creation_number - creation number of the second dragon token
    */
    public entry fun breed_dragons(
        owner: &signer,
        collection_name: String,
        first_dragon_creation_number: u64,
        second_dragon_creation_number: u64
    ) acquires State {
        // TODO: Assert that state is initialized
        assert_state_initialized();
        let state = borrow_global_mut<State>(@admin);
        let owner_addr = signer::address_of(owner);
        let resource_account = account::create_signer_with_capability(&state.cap);
        let resource_acc_addr = signer::address_of(&resource_account);

        // TODO: Assert that collection with provided name exists
        assert_collection_exists(&simple_map::keys(&state.breeder.collections), &collection_name);

        // TODO: Assert that the signer owns the first monster token
        let first_dragon_address = object::create_guid_object_address(resource_acc_addr, first_dragon_creation_number);
        let first_dragon = object::address_to_object(first_dragon_address);
        assert_signer_owns_token(owner, first_dragon);
        
        // TODO: Assert that the first monster token is from the provided collection
        assert_token_is_from_correct_collection(collection_name, first_dragon);

        // TODO: Assert that the first monster is not breeding
        assert_dragon_not_breeding(first_dragon);

        // TODO: Assert that the signer owns the second monster token
        let second_dragon_address = object::create_guid_object_address(resource_acc_addr, second_dragon_creation_number);
        let second_dragon = object::address_to_object(second_dragon_address);
        assert_signer_owns_token(owner, second_dragon);

        // TODO: Assert that the second monster token is from the provided collection
        assert_token_is_from_correct_collection(collection_name, second_dragon);

        // TODO: Assert that the second monster is not breeding
        assert_dragon_not_breeding(second_dragon);

        // TODO: Create a hash from both of monster addresses
        let breeding_key_bytes = bcs::to_bytes(&first_dragon_address);
        vector::append(&mut breeding_key_bytes, bcs::to_bytes(&second_dragon_address));
        let breeding_key = aptos_hash::sha3_512(breeding_key_bytes);

        let current_timestamp = timestamp::now_seconds();
        let breeding_time = simple_map::borrow(&state.breeder.collections, &collection_name).breeding_time;
        let finish_timestamp = current_timestamp + breeding_time;

        // TODO: Add new record to Breeder's ongoing_breedings
        simple_map::add(&mut state.breeder.ongoing_breedings, breeding_key, finish_timestamp);

        // TODO: Freeze transfer of both tokens
        aptos_token::freeze_transfer(&resource_account, first_dragon);
        aptos_token::freeze_transfer(&resource_account, second_dragon);

        // TODO: Emit BreedMonsterEvent event
        let breed_dragon_event = breeder_events::new_breed_dragons_event(
            owner_addr, collection_name, first_dragon_creation_number, second_dragon_creation_number, finish_timestamp, current_timestamp
        );
        event::emit_event<BreedDragonsEvent>(
            &mut state.breeder.breed_dragons_events, breed_dragon_event
        );
    }

    /*
        Unfreezes provided dragon tokens, creates new one with combined properties and transfers it to the owner.
        @param owner - owner of the two breeding dragon tokens
        @param first_dragon_creation_number - creation number of the first dragon token
        @param second_dragon_creation_number - creation number of the second dragon token
        @param new_dragon_name - name of the new dragon token
        @param new_dragon_description - description of the new dragon token
        @param new_dragon_uri - image's URI of the new dragon token
    */
    public entry fun hatch_dragon(
        owner: &signer,
        first_dragon_creation_number: u64,
        second_dragon_creation_number: u64,
        new_dragon_name: String,
        new_dragon_description: String,
        new_dragon_uri: String
    ) acquires State {
        // TODO: Assert that state is initialized
        assert_state_initialized();
        let state = borrow_global_mut<State>(@admin);
        let owner_addr = signer::address_of(owner);
        let resource_account = account::create_signer_with_capability(&state.cap);
        let resource_acc_addr = signer::address_of(&resource_account);

        // TODO: Assert that the signer owns the first monster token
        let first_dragon_address = object::create_guid_object_address(resource_acc_addr, first_dragon_creation_number);
        let first_dragon = object::address_to_object(first_dragon_address);
        assert_signer_owns_token(owner, first_dragon);

        // TODO: Assert that the signer owns the second monster token
        let second_dragon_address = object::create_guid_object_address(resource_acc_addr, second_dragon_creation_number);
        let second_dragon = object::address_to_object(second_dragon_address);
        assert_signer_owns_token(owner, second_dragon);

        // TODO: Assert that the monsters are breeding
        let breeding_key_bytes = bcs::to_bytes(&first_dragon_address);
        vector::append(&mut breeding_key_bytes, bcs::to_bytes(&second_dragon_address));
        let breeding_key = aptos_hash::sha3_512(breeding_key_bytes);

        assert_dragons_are_breeding(&state.breeder.ongoing_breedings, &breeding_key);

        // TODO: Assert that the breeding has finished
        assert_breeding_finished(&state.breeder.ongoing_breedings, &breeding_key);

        // TODO: Remove breeding record from Breeder's ongoing_breedings
        simple_map::remove(&mut state.breeder.ongoing_breedings, &breeding_key);

        // TODO: Unfreeze transfer of both monster tokens
        aptos_token::unfreeze_transfer(&resource_account, first_dragon);
        aptos_token::unfreeze_transfer(&resource_account, second_dragon);

        // TODO: Create a variable and save PDA's GUID next creation number
        let creation_number = account::get_guid_next_creation_num(resource_acc_addr);
        let token_address = object::create_guid_object_address(resource_acc_addr, creation_number);

        // TODO: Combine properties of the monster tokens
        let first_col_name = token::collection_name(first_dragon);
        let first_collection = simple_map::borrow(&state.breeder.collections, &first_col_name);

        let second_col_name = token::collection_name(second_dragon);
        let second_collection = simple_map::borrow(&state.breeder.collections, &second_col_name);

        let property_keys = vector::map_ref(&DRAGON_PROPERTY_KEYS, |key| string::utf8(*key));
        let property_types = vector::map_ref(&DRAGON_PROPERTY_TYPES, |type| string::utf8(*type));

        let property_maps = vector[
            property_map::prepare_input(
                property_keys,
                property_types,
                vector[
                    *vector::borrow(&first_collection.starting_properties, 0),
                    *vector::borrow(&first_collection.starting_properties, 1),
                    *vector::borrow(&first_collection.starting_properties, 2),
                    *vector::borrow(&first_collection.starting_properties, 3),
                ]
            ),
            property_map::prepare_input(
                property_keys,
                property_types,
                vector[
                    *vector::borrow(&second_collection.starting_properties, 0),
                    *vector::borrow(&second_collection.starting_properties, 1),
                    *vector::borrow(&second_collection.starting_properties, 2),
                    *vector::borrow(&second_collection.starting_properties, 3),
                ]
            )
        ];

        let property_map_objects = vector::map(property_maps, |property_map| {
            let constructor_ref = object::create_object_from_account(owner);
            property_map::init(&constructor_ref, property_map);

            object::object_from_constructor_ref<PropertyMap>(&constructor_ref)
        });

        let property_values = combine_properties(property_keys, property_map_objects);

        // TODO: Mint a new monster token
        aptos_token::mint(
            &resource_account,
            first_col_name,
            new_dragon_description,
            new_dragon_name,
            new_dragon_uri,
            property_keys,
            property_types,
            property_values,
        );

        // TODO: Transfer the new monster token to the owner
        object::transfer_raw(&resource_account, token_address, owner_addr);

        // TODO: Emit HatchMonsterEvent event
        let current_timestamp = timestamp::now_seconds();        
        let hatch_dragon_event = breeder_events::new_hatch_dragon_event(
            owner_addr, first_dragon_creation_number, second_dragon_creation_number,
            creation_number, new_dragon_name, new_dragon_description, new_dragon_uri, property_values,
            current_timestamp
        );
        event::emit_event<HatchDragonEvent>(
            &mut state.breeder.hatch_dragon_events, hatch_dragon_event
        );
    }

    /*
        Burns provided sword tokens, creates new one with combined properties and transfers it to the owner
        @param owner - owner of the provided sword tokens
        @param collection_name - name of the collection, which the tokens are from
        @param swords_creation_numbers - list of sword tokens to be burned
        @param new_sword_name - name of the new sword token
        @param new_sword_description - description of the new sword token
        @param new_sword_uri - image's URI of the new sword token
    */
    public entry fun combine_swords(
        owner: &signer,
        collection_name: String,
        swords_creation_numbers: vector<u64>,
        new_sword_name: String,
        new_sword_description: String,
        new_sword_uri: String
    ) acquires State {
        // TODO: Assert that state is initialized
        assert_state_initialized();
        let state = borrow_global_mut<State>(@admin);
        let owner_addr = signer::address_of(owner);
        let resource_account = account::create_signer_with_capability(&state.cap);
        let resource_acc_addr = signer::address_of(&resource_account);

        // TODO: Assert that amount of equipment to burn is correct
        let amount = vector::length(&swords_creation_numbers);
        assert!(amount >= MINIMAL_AMOUNT_TO_COMBINE && amount <= MAXIMAL_AMOUNT_TO_COMBINE, ERROR_INCORRECT_AMOUNT_OF_SWORDS);

        // TODO: Create a vector and for each of equipment's creation numbers:
        //      1. Create Object<PropertyMap>
        //      2. Push it to the vector
        let collection = simple_map::borrow(&state.combiner.collections, &collection_name);
        let property_keys = vector::map_ref(&SWORD_PROPERTY_KEYS, |key| string::utf8(*key));
        let property_types = vector::map_ref(&SWORD_PROPERTY_TYPES, |type| string::utf8(*type));

        let property_map_objects = vector::empty();
        vector::for_each_ref(&swords_creation_numbers, |_swords_creation_number| {
            let property_map = property_map::prepare_input(
                property_keys,
                property_types,
                vector[
                    *vector::borrow(&collection.starting_properties, 0),
                    *vector::borrow(&collection.starting_properties, 1),
                    *vector::borrow(&collection.starting_properties, 2),
                ]
            );

            let constructor_ref = object::create_object_from_account(owner);
            property_map::init(&constructor_ref, property_map);

            let property_map_object = object::object_from_constructor_ref<PropertyMap>(&constructor_ref);
            vector::push_back(&mut property_map_objects, property_map_object);
        });


        // TODO: Combine properties of the equipment
        let property_values = combine_properties(property_keys, property_map_objects);

        // TODO: For each of equipement's creation numbers
        //      1. Assert that the signer owns the token
        //      2. Assert that the token is from the provided collection
        //      3. Burn the token
        vector::for_each_ref(&swords_creation_numbers, |swords_creation_number| {
            let sword_address = object::create_guid_object_address(resource_acc_addr, *swords_creation_number);
            let token = object::address_to_object(sword_address);

            assert_signer_owns_token(owner, token);
            assert_token_is_from_correct_collection(collection_name, token);
            aptos_token::burn(&resource_account, token);
        });

        // TODO: Save PDA's GUID next creation number
        let creation_number = account::get_guid_next_creation_num(resource_acc_addr);
        let token_address = object::create_guid_object_address(resource_acc_addr, creation_number);

        // TODO: Mint a new equipment NFT with combined properties
        aptos_token::mint(
            &resource_account,
            collection_name,
            new_sword_description,
            new_sword_name,
            new_sword_uri,
            property_keys,
            property_types,
            property_values,
        );

        // TODO: Transfer the new equipment NFT to the owner
        object::transfer_raw(&resource_account, token_address, owner_addr);

        // TODO: Emit CombineEquipmentEvent event
        let combine_swords_event = breeder_events::new_combine_swords_event(
            owner_addr, 
            collection_name,
            swords_creation_numbers,
            creation_number,
            new_sword_name,
            new_sword_description,
            new_sword_uri,
            property_values,
            timestamp::now_seconds()
        );
        event::emit_event<CombineSwordsEvent>(
            &mut state.combiner.combine_swords_events, combine_swords_event
        );
    }

    /*
        Returns sum of starting properties for provieded combine amount
        @param combine_amount - amount of sword tokens that would be combined
        @returns - sum of the starting properties
    */
    #[view]
    public fun get_equipment_starting_properties_sum(combine_amount: u64): u64 {
        // TODO: Assert that provided combine amount is correct
        assert_combine_amount_is_correct(combine_amount);

        // TODO: Calcualte and return equipment starting properties sum
        let starting_properties_sum = calculate_swords_starting_properties_sum(combine_amount);
        starting_properties_sum
    }

    /*
        Wrapper for creating a new collection
        @param creator - creator of the collection
        @param name - name of the collection
        @param description - description of the new collection
        @param uri - image's URI of the new collection
        @param supply - supply of the new collection
        @param burnable - states if tokens from the collection are burnable
        @param freezable - states if tokens from the collection are freezable
    */
    inline fun create_collection_internal(
        creator: &signer,
        name: String,
        description: String,
        uri: String,
        supply: u64,
        burnable: bool,
        freezable: bool
    ) {
        // TODO: Call aptos_token::creation_collection function with appropriate parameters
        aptos_token::create_collection(
            creator,
            description,
            supply,
            name,
            uri,
            false,
            false,
            false,
            false,
            false,
            false,
            false,
            burnable,
            freezable,
            ROYALTY_NUMERATOR,
            ROYALTY_DENOMINATOR
        );
    }

    /*
        Converts byte representation of provided property parameters (keys, types, values) into string representation
        @param property_params - parameters of properties
        @returns - string representation of properties' parameters
    */
    inline fun get_property_params_as_strings(property_params: &vector<vector<u8>>): vector<String> {
        // TODO: Convert vector of byte representations into vector of string representations
        vector::map_ref(property_params, |param| string::utf8(*param))
    }

    /*
        Calculates starting properties of dragons basing on provided breeding time
        @param breeding_time - time required for monsters to hatch a new one
        @returns - list of starting properties
    */
    inline fun calculate_dragons_starting_properties(breeding_time: u64): vector<u64> {
        // TODO: Calculate monster starting properties accordingly to the formula:
        //        (b_t - MIN_B_T)^3
        //      --------------------- * P_Diff + P_Min
        //      (MAX_B_T - MIN_B_T)^3
        // Where:
        //      b_t - breeding_time
        //      MIN_B_T - MINIMAL_BREEDING_TIME
        //      MAX_B_T - MAXIMAL_BREEDING_TIME
        //      P_Diff - Difference between minimal and maximal of one of monster start property values
        //      P_Min - Minimal value of one of monster start property values

        let starting_properties = vector::empty();

        let i = 0;
        while (i < 3) {
            let min_start_pv = *(vector::borrow(&DRAGON_MINIMAL_START_PROPERTY_VALUES, i));
            let max_start_pv = *(vector::borrow(&DRAGON_MAXIMAL_START_PROPERTY_VALUES, i));
            let b_diff = math64::mul_div(math64::pow((breeding_time - MINIMAL_BREEDING_TIME), 3), max_start_pv - min_start_pv, math64::pow((MAXIMAL_BREEDING_TIME - MINIMAL_BREEDING_TIME), 3));
            let starting_property = b_diff + min_start_pv;
            vector::push_back(&mut starting_properties, starting_property);

            i = i + 1;
        };

        starting_properties
    }

    /*
        Calculates sum of starting properties of swords basing on provided combine amount
        @param combine_amount - amount of equipment tokens required to combine them into one
        @returns - sum of starting properties
    */
    inline fun calculate_swords_starting_properties_sum(combine_amount: u64): u64 {
        // TODO: Calculate sum of equipment starting properties accordingly to the formula:
        //          (c_a - MIN_AMOUNT)^2
        //      --------------------------- * P_Diff + P_MIN
        //      (MAX_AMOUNT - MIN_AMOUNT)^2
        // Where:
        //      c_a - combine_amount
        //      MIN_AMOUNT - MINIMAL_AMOUNT_OF_PIECES_TO_COMBINE
        //      MAX_AMOUNT - MAXIMAL_AMOUNT_OF_PIECES_TO_COMBINE
        //      P_Diff - Difference between EQUIPMENT_MAXIMAL_START_PROPERTY_VALUES_SUM and
        //          EQUIPMENT_MINIMAL_START_PROPERTY_VALUES_SUM
        //      P_MIN - EQUIPMENT_MINIMAL_START_PROPERTY_VALUES_SUM

        math64::mul_div(math64::pow((combine_amount - MINIMAL_AMOUNT_TO_COMBINE), 2), SWORD_MAXIMAL_START_PROPERTY_VALUES_SUM - SWORD_MINIMAL_START_PROPERTY_VALUES_SUM, math64::pow((MAXIMAL_AMOUNT_TO_COMBINE - MINIMAL_AMOUNT_TO_COMBINE), 2)) + SWORD_MINIMAL_START_PROPERTY_VALUES_SUM
    }

    /*
        Calculates combined properties for provided PropertyMap instances
        @param property_keys - property keys of a collection
        @param property_maps - PropertyMap instances of tokens
        @returns - combined property values
    */
    inline fun combine_properties(
        property_keys: vector<String>,
        property_maps: vector<Object<PropertyMap>>
    ): vector<vector<u8>> {
        // TODO: Assert that both vectors have the same length
        assert_property_vectors_lengths(&property_keys, &property_maps);

        // TODO: Create a vector for combined properties
        let properties: vector<vector<u8>> = vector::empty();

        // TODO: For each of property keys:
        //      1. Read property's type and value from each of property maps
        //          a. If the type is u64, then add it to an accumulator
        //          b. If the type is not u64, then push it to the vector and break looping through property maps
        //      2. If the accumulator does not have any value, then continue to the next iteration
        //      3. Otherwise, push the accumulator's value to the vector
        let maps_length = vector::length(&property_maps);
        vector::for_each_ref(&property_keys, |p_key| {
            let accumulator: u64 = 0;
            
            let i = 0;
            while (i < maps_length) {
                let p_obj = vector::borrow(&property_maps, i);
                let (p_type, p_value) = property_map::read(p_obj, p_key);

                if (p_type == string::utf8(b"u64")) {
                    let val = property_map::read_u64(p_obj, p_key);
                    accumulator = accumulator + val;
                }
                else {
                    vector::push_back(&mut properties, p_value);
                    break
                };

                i = i + 1;
            };

            if(accumulator > 0) {
                vector::push_back(&mut properties, bcs::to_bytes(&accumulator));
            };
        });

        properties
    }

    /////////////
    // ASSERTS //
    /////////////

    inline fun assert_signer_is_admin(admin: &signer) {
        // TODO: Assert that address of the parameter is the same as admin in Move.toml
        let admin_addr = signer::address_of(admin);
        assert!(admin_addr == @admin, ERROR_SIGNER_NOT_ADMIN);
    }

    inline fun assert_state_initialized() {
        // TODO: Assert that State resource exists at the admin address
        assert!(exists<State>(@admin), ERROR_STATE_NOT_INITIALIZED);
    }

    inline fun assert_breeding_time_is_correct(breeding_time: u64) {
        // TODO: Assert that breeding_time is greater or equals to MINIMAL_BREEDING_TIME and is smaller or equals to
        //      MAXIMAL_BREEDING_TIME
        assert!(breeding_time >= MINIMAL_BREEDING_TIME && breeding_time <= MAXIMAL_BREEDING_TIME, ERROR_INVALID_BREEDING_TIME);
    }

    inline fun assert_combine_amount_is_correct(combine_amount: u64) {
        // TODO: Assert that combine_amount is greater or equals to MINIMAL_TO_COMBINE and is smaller
        //      or equals to MAXIMAL_AMOUNT_TO_COMBINE
        assert!(combine_amount >= MINIMAL_AMOUNT_TO_COMBINE && combine_amount <= MAXIMAL_AMOUNT_TO_COMBINE, ERROR_INVALID_COMBINE_AMOUNT);

    }

    inline fun assert_sword_property_values_sum_is_correct(property_values: &vector<u64>, expected_sum: u64) {
        // TODO: Assert that sum of property_values' values is smaller or equals expected_sum
        let sum_property_values = 0;
        vector::for_each_ref(property_values, |value| {
            sum_property_values = sum_property_values + *value;
        });
        assert!(sum_property_values <= expected_sum, ERROR_INVALID_SWORDS_PROPERTY_VALUES_SUM);
    }

    inline fun assert_collection_does_not_exist(collections: &vector<String>, collection_name: &String) {
        // TODO: Assert that the vector does not contain the collection's name
        assert!(!vector::contains(collections, collection_name), ERROR_COLLECTION_ALREADY_EXISTS);
    }

    inline fun assert_collection_exists(collections: &vector<String>, collection_name: &String) {
        // TODO: Assert that the vector contains the collection's name
        assert!(vector::contains(collections, collection_name), ERROR_COLLECTION_DOES_NOT_EXIST);
    }

    inline fun assert_signer_owns_token(owner: &signer, token: Object<Token>) {
        // TODO: Assert that address of the owner is the same as the owner of the object
        let address = signer::address_of(owner);
        assert!(object::is_owner<Token>(token, address), ERROR_SIGNER_IS_NOT_THE_OWNER);
    }

    inline fun assert_dragon_not_breeding(monster: Object<Token>) {
        // TODO: Assert that transfer of the object is allowed
        assert!(object::ungated_transfer_allowed(monster), ERROR_DRAGON_DURING_BREEDING);
    }

    inline fun assert_dragons_are_breeding(
        ongoing_breedings: &SimpleMap<vector<u8>, u64>,
        dragons_pair_hash: &vector<u8>
    ) {
        // TODO: Assert that the map contains the provided key
        assert!(simple_map::contains_key(ongoing_breedings, dragons_pair_hash), ERROR_DRAGONS_NOT_BREEDING);
    }

    inline fun assert_breeding_finished(
        ongoing_breedings: &SimpleMap<vector<u8>, u64>,
        dragons_pair_hash: &vector<u8>
    ) {
        // TODO: Assert that timestamp related to the provided monster_pair_hash is smaller or equals current timestamp
        let finish_timestamp = *simple_map::borrow(ongoing_breedings, dragons_pair_hash);
        let current_timestamp = timestamp::now_seconds();
        assert!(finish_timestamp <= current_timestamp, ERROR_BREEDING_HAS_NOT_ENDED);
    }

    inline fun assert_amount_of_swords_is_correct(swords: &vector<u64>, combine_amount: u64) {
        // TODO: Assert that the vector's length equals to combine_amount
        assert!(vector::length(swords) == combine_amount, ERROR_INVALID_COMBINE_AMOUNT);
    }

    inline fun assert_property_vectors_lengths(
        property_keys: &vector<String>,
        properties: &vector<Object<PropertyMap>>
    ) {
        // TODO: Assert that each of the property maps length equals to number of keys in property_keys
        let property_length = vector::length(property_keys);
        vector::for_each_ref<Object<PropertyMap>>(properties, |property| {
            let map_length = property_map::length(property);
            assert!(map_length == property_length, ERROR_PROPERTY_LENGTH_MISMATCH);
        });
    }

    inline fun assert_token_is_from_correct_collection(collection_name: String, token: Object<Token>) {
        // TODO: Assert that collection of the token is the same as collection_name
        assert!(token::collection_name(token) == collection_name, ERROR_TOKEN_FROM_WRONG_COLLECTION);
    }

    ///////////
    // TESTS //
    ///////////

    #[test]
    fun test_create_collection_internal() {
        let creator = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"My new collection");
        let description = string::utf8(b"This is my first collection");
        let uri = string::utf8(b"https://i1.sndcdn.com/artworks-000032011179-v3cdjs-t500x500.jpg");

        create_collection_internal(&creator, name, description, uri, 50, false, false);

        let collection_address = collection::create_collection_address(&@0xCAFE, &name);
        let collection_object = object::address_to_object<Collection>(collection_address);
        assert!(option::is_some(&collection::count(collection_object)), 0);
        assert!(*option::borrow(&collection::count(collection_object)) == 0, 1);
        assert!(collection::creator(collection_object) == @0xCAFE, 2);
        assert!(collection::description(collection_object) == description, 3);
        assert!(collection::name(collection_object) == name, 4);
        assert!(collection::uri(collection_object) == uri, 5);
        assert!(royalty::exists_at(collection_address), 6);

        let maybe_royalty = royalty::get(collection_object);
        assert!(option::is_some(&maybe_royalty), 7);

        let royalty = option::extract(&mut maybe_royalty);
        assert!(royalty::denominator(&royalty) == 10, 8);
        assert!(royalty::numerator(&royalty) == 1, 9);

        assert!(!aptos_token::is_mutable_collection_description(collection_object), 10);
        assert!(!aptos_token::is_mutable_collection_royalty(collection_object), 11);
        assert!(!aptos_token::is_mutable_collection_uri(collection_object), 12);
        assert!(!aptos_token::is_mutable_collection_description(collection_object), 13);
        assert!(!aptos_token::is_mutable_collection_token_name(collection_object), 14);
        assert!(!aptos_token::is_mutable_collection_token_properties(collection_object), 15);
        assert!(!aptos_token::are_collection_tokens_burnable(collection_object), 16);
        assert!(!aptos_token::are_collection_tokens_freezable(collection_object), 17);
    }

    #[test]
    fun test_get_property_params_as_strings() {
        let property_keys = vector[b"First key", b"Second key", b"Third key"];
        let property_keys_strings = get_property_params_as_strings(&property_keys);
        assert!(
            property_keys_strings ==
                vector[
                    string::utf8(b"First key"),
                    string::utf8(b"Second key"),
                    string::utf8(b"Third key")
                ],
            0
        );
    }

    #[test]
    fun test_calculate_dragons_starting_properties() {
        let breeding_time = MINIMAL_BREEDING_TIME;
        let starting_properties = calculate_dragons_starting_properties(breeding_time);
        assert!(starting_properties == DRAGON_MINIMAL_START_PROPERTY_VALUES, 0);

        let breeding_time = MAXIMAL_BREEDING_TIME;
        let starting_properties = calculate_dragons_starting_properties(breeding_time);
        assert!(starting_properties == DRAGON_MAXIMAL_START_PROPERTY_VALUES, 1);

        let breeding_time = 60 * 60 * 24 * 16;
        let starting_properties = calculate_dragons_starting_properties(breeding_time);
        assert!(*vector::borrow(&starting_properties, 0) == 21, 2);
        assert!(*vector::borrow(&starting_properties, 1) == 1, 3);
        assert!(*vector::borrow(&starting_properties, 2) == 3, 4);
    }

    #[test]
    fun test_calculate_swords_starting_properties_sum() {
        let combine_amount = 2;
        let starting_properties_sum = calculate_swords_starting_properties_sum(combine_amount);
        assert!(starting_properties_sum == SWORD_MINIMAL_START_PROPERTY_VALUES_SUM, 0);

        let combine_amount = 10;
        let starting_properties_sum = calculate_swords_starting_properties_sum(combine_amount);
        assert!(starting_properties_sum == SWORD_MAXIMAL_START_PROPERTY_VALUES_SUM, 1);

        let combine_amount = 6;
        let starting_properties_sum = calculate_swords_starting_properties_sum(combine_amount);
        assert!(starting_properties_sum == 32, 2);
    }

    #[test]
    fun test_combine_properties() {
        let property_keys = vector[
            string::utf8(b"First key"),
            string::utf8(b"Second key"),
            string::utf8(b"Third key"),
            string::utf8(b"Fourth key"),
            string::utf8(b"Fifth key")
        ];
        let property_types = vector[
            string::utf8(b"u64"),
            string::utf8(b"u64"),
            string::utf8(b"0x1::string::String"),
            string::utf8(b"address"),
            string::utf8(b"u64")
        ];
        let property_maps = vector[
            property_map::prepare_input(
                property_keys,
                property_types,
                vector[
                    bcs::to_bytes(&150),
                    bcs::to_bytes(&46),
                    bcs::to_bytes(&string::utf8(b"Random ability")),
                    bcs::to_bytes(&@0xACE),
                    bcs::to_bytes(&111)
                ]
            ),
            property_map::prepare_input(
                property_keys,
                property_types,
                vector[
                    bcs::to_bytes(&45),
                    bcs::to_bytes(&11),
                    bcs::to_bytes(&string::utf8(b"Random ability")),
                    bcs::to_bytes(&@0xACE),
                    bcs::to_bytes(&111)
                ]
            ),
            property_map::prepare_input(
                property_keys,
                property_types,
                vector[
                    bcs::to_bytes(&846),
                    bcs::to_bytes(&5),
                    bcs::to_bytes(&string::utf8(b"Random ability")),
                    bcs::to_bytes(&@0xACE),
                    bcs::to_bytes(&111)
                ]
            ),
        ];
        let creator = account::create_account_for_test(@0xCAFE);
        let property_map_objects = vector::map(property_maps, |property_map| {
            let creation_number = account::get_guid_next_creation_num(@0xCAFE);
            let constructor_ref = object::create_object_from_account(&creator);
            property_map::init(&constructor_ref, property_map);

            let property_map_address = object::create_guid_object_address(@0xCAFE, creation_number);
            object::address_to_object<PropertyMap>(property_map_address)
        });

        let combined_properties = combine_properties(property_keys, property_map_objects);
        assert!(vector::length(&combined_properties) == vector::length(&property_keys), 0);
        assert!(from_bcs::to_u64(*vector::borrow(&combined_properties, 0)) == 1041, 1);
        assert!(from_bcs::to_u64(*vector::borrow(&combined_properties, 1)) == 62, 2);
        assert!(
            from_bcs::to_string(*vector::borrow(&combined_properties, 2)) ==
                string::utf8(b"Random ability"),
            3
        );
        assert!(from_bcs::to_address(*vector::borrow(&combined_properties, 3)) == @0xACE, 4);
        assert!(from_bcs::to_u64(*vector::borrow(&combined_properties, 4)) == 333, 5);
    }

    #[test]
    fun test_init() acquires State {
        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let state = borrow_global<State>(@admin);
        assert!(simple_map::length(&state.breeder.collections) == 0, 0);
        assert!(simple_map::length(&state.breeder.ongoing_breedings) == 0, 1);
        assert!(simple_map::length(&state.combiner.collections) == 0, 2);
        assert!(event::counter(&state.breeder.create_dragon_collection_events) == 0, 3);
        assert!(event::counter(&state.breeder.create_dragon_events) == 0, 4);
        assert!(event::counter(&state.breeder.breed_dragons_events) == 0, 5);
        assert!(event::counter(&state.breeder.hatch_dragon_events) == 0, 6);
        assert!(event::counter(&state.combiner.create_sword_collection_events) == 0, 7);
        assert!(event::counter(&state.combiner.create_sword_events) == 0, 8);
        assert!(event::counter(&state.combiner.combine_swords_events) == 0, 9);

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);
        assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 10);
    }

    #[test]
    #[expected_failure(abort_code = 0, location = Self)]
    fun test_init_signer_not_admin() {
        let account = account::create_account_for_test(@0xACE);
        init(&account);
    }

    #[test]
    #[expected_failure(abort_code = 524303, location = aptos_framework::account)]
    fun test_init_resource_account_already_exists() {
        let admin = account::create_account_for_test(@admin);
        init(&admin);
        init(&admin);
    }

    #[test]
    fun test_create_dragon_collection() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Dragon collection");
        let description = string::utf8(b"This is a dragon collection");
        let uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(&account, name, description, uri, breeding_time, ability_property);

        let state = borrow_global<State>(@admin);
        assert!(simple_map::length(&state.breeder.collections) == 1, 0);
        assert!(simple_map::contains_key(&state.breeder.collections, &name), 1);
        assert!(simple_map::length(&state.breeder.ongoing_breedings) == 0, 2);
        assert!(event::counter(&state.breeder.create_dragon_collection_events) == 1, 3);
        assert!(event::counter(&state.breeder.create_dragon_events) == 0, 4);
        assert!(event::counter(&state.breeder.breed_dragons_events) == 0, 5);
        assert!(event::counter(&state.breeder.hatch_dragon_events) == 0, 6);
        assert!(simple_map::length(&state.combiner.collections) == 0, 7);
        assert!(event::counter(&state.combiner.create_sword_collection_events) == 0, 8);
        assert!(event::counter(&state.combiner.create_sword_events) == 0, 9);
        assert!(event::counter(&state.combiner.combine_swords_events) == 0, 10);

        let dragon_race = simple_map::borrow(&state.breeder.collections, &name);
        assert!(dragon_race.breeding_time == breeding_time, 11);

        let expected_starting_properties = vector[
            bcs::to_bytes(&40),
            bcs::to_bytes(&3),
            bcs::to_bytes(&7),
            bcs::to_bytes(&ability_property)
        ];
        assert!(dragon_race.starting_properties == expected_starting_properties, 12);
    }

    #[test]
    #[expected_failure(abort_code = 1, location = Self)]
    fun test_create_dragon_collection_state_not_initialized() acquires State {
        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Dragon collection");
        let description = string::utf8(b"This is a dragon collection");
        let uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(&account, name, description, uri, breeding_time, ability_property);
    }

    #[test]
    #[expected_failure(abort_code = 2, location = Self)]
    fun test_create_dragon_collection_incorrect_breeding_time_too_small() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Dragon collection");
        let description = string::utf8(b"This is a dragon collection");
        let uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 11;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(&account, name, description, uri, breeding_time, ability_property);
    }

    #[test]
    #[expected_failure(abort_code = 2, location = Self)]
    fun test_create_dragon_collection_incorrect_breeding_time_too_big() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Dragon collection");
        let description = string::utf8(b"This is a dragon collection");
        let uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 5646851151;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(&account, name, description, uri, breeding_time, ability_property);
    }

    #[test]
    #[expected_failure(abort_code = 5, location = Self)]
    fun test_create_dragon_collection_already_exists() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Dragon collection");
        let description = string::utf8(b"This is a dragon collection");
        let uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 60 * 60 * 24 * 13;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(&account, name, description, uri, breeding_time, ability_property);
        create_dragon_collection(&account, name, description, uri, breeding_time, ability_property);
    }

    #[test]
    fun test_create_sword_collection() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Sword collection");
        let description = string::utf8(b"This is a sword collection");
        let uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let combine_amount = 4;
        let property_values = vector[10, 5];
        let ability_property = string::utf8(b"Fire imbued");
        create_sword_collection(
            &account,
            name,
            description,
            uri,
            combine_amount,
            property_values,
            ability_property
        );

        let state = borrow_global<State>(@admin);
        assert!(simple_map::length(&state.breeder.collections) == 0, 0);
        assert!(simple_map::length(&state.breeder.ongoing_breedings) == 0, 1);
        assert!(event::counter(&state.breeder.create_dragon_collection_events) == 0, 2);
        assert!(event::counter(&state.breeder.create_dragon_events) == 0, 3);
        assert!(event::counter(&state.breeder.breed_dragons_events) == 0, 4);
        assert!(event::counter(&state.breeder.hatch_dragon_events) == 0, 5);
        assert!(simple_map::length(&state.combiner.collections) == 1, 6);
        assert!(simple_map::contains_key(&state.combiner.collections, &name), 7);
        assert!(event::counter(&state.combiner.create_sword_collection_events) == 1, 8);
        assert!(event::counter(&state.combiner.create_sword_events) == 0, 9);
        assert!(event::counter(&state.combiner.combine_swords_events) == 0, 10);

        let sword_type = simple_map::borrow(&state.combiner.collections, &name);
        assert!(sword_type.combine_amount == combine_amount, 11);

        let expected_starting_properties = vector::map_ref(&property_values, |value| {
            bcs::to_bytes(value)
        });
        vector::push_back(&mut expected_starting_properties, bcs::to_bytes(&ability_property));
        assert!(sword_type.starting_properties == expected_starting_properties, 12);
    }

    #[test]
    #[expected_failure(abort_code = 3, location = Self)]
    fun test_create_sword_collection_incorrect_combine_amount_too_small() acquires State {
        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Sword collection");
        let description = string::utf8(b"This is a sword collection");
        let uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let combine_amount = 1;
        let property_values = vector[10, 5];
        let ability_property = string::utf8(b"Fire imbued");
        create_sword_collection(
            &account,
            name,
            description,
            uri,
            combine_amount,
            property_values,
            ability_property
        );
    }

    #[test]
    #[expected_failure(abort_code = 3, location = Self)]
    fun test_create_sword_collection_incorrect_combine_amount_too_big() acquires State {
        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Sword collection");
        let description = string::utf8(b"This is a sword collection");
        let uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let combine_amount = 2222;
        let property_values = vector[10, 5];
        let ability_property = string::utf8(b"Fire imbued");
        create_sword_collection(
            &account,
            name,
            description,
            uri,
            combine_amount,
            property_values,
            ability_property
        );
    }

    #[test]
    #[expected_failure(abort_code = 4, location = Self)]
    fun test_create_sword_collection_incorrect_property_values_sum() acquires State {
        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Sword collection");
        let description = string::utf8(b"This is a sword collection");
        let uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let combine_amount = 4;
        let property_values = vector[10, 55, 5];
        let ability_property = string::utf8(b"Fire imbued");
        create_sword_collection(
            &account,
            name,
            description,
            uri,
            combine_amount,
            property_values,
            ability_property
        );
    }

    #[test]
    #[expected_failure(abort_code = 1, location = Self)]
    fun test_create_sword_collection_state_not_initialized() acquires State {
        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Sword collection");
        let description = string::utf8(b"This is a sword collection");
        let uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let combine_amount = 4;
        let property_values = vector[10, 0, 3];
        let ability_property = string::utf8(b"Fire imbued");
        create_sword_collection(
            &account,
            name,
            description,
            uri,
            combine_amount,
            property_values,
            ability_property
        );
    }

    #[test]
    #[expected_failure(abort_code = 5, location = Self)]
    fun test_create_sword_collection_already_exists() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let name = string::utf8(b"Sword collection");
        let description = string::utf8(b"This is a sword collection");
        let uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let combine_amount = 4;
        let property_values = vector[10, 0, 3];
        let ability_property = string::utf8(b"Fire imbued");
        create_sword_collection(
            &account,
            name,
            description,
            uri,
            combine_amount,
            property_values,
            ability_property
        );
        create_sword_collection(
            &account,
            name,
            description,
            uri,
            combine_amount,
            property_values,
            ability_property
        );
    }

    #[test]
    fun test_create_dragon() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        let collection_description = string::utf8(b"This is a dragon collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);
        let creation_number = account::get_guid_next_creation_num(resource_account_address);

        let dragon_name = string::utf8(b"The first dragon");
        let dragon_description = string::utf8(b"This is the very first dragon in this collection");
        let dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, dragon_name, dragon_description, dragon_uri);

        let state = borrow_global<State>(@admin);
        assert!(simple_map::length(&state.breeder.collections) == 1, 0);
        assert!(simple_map::contains_key(&state.breeder.collections, &collection_name), 1);
        assert!(simple_map::length(&state.breeder.ongoing_breedings) == 0, 2);
        assert!(event::counter(&state.breeder.create_dragon_collection_events) == 1, 3);
        assert!(event::counter(&state.breeder.create_dragon_events) == 1, 4);
        assert!(event::counter(&state.breeder.breed_dragons_events) == 0, 5);
        assert!(event::counter(&state.breeder.hatch_dragon_events) == 0, 6);
        assert!(simple_map::length(&state.combiner.collections) == 0, 7);
        assert!(event::counter(&state.combiner.create_sword_collection_events) == 0, 8);
        assert!(event::counter(&state.combiner.create_sword_events) == 0, 9);
        assert!(event::counter(&state.combiner.combine_swords_events) == 0, 10);

        let dragon_race = simple_map::borrow(&state.breeder.collections, &collection_name);
        assert!(dragon_race.breeding_time == breeding_time, 11);

        let expected_starting_properties = vector[
            bcs::to_bytes(&40),
            bcs::to_bytes(&3),
            bcs::to_bytes(&7),
            bcs::to_bytes(&ability_property)
        ];
        assert!(dragon_race.starting_properties == expected_starting_properties, 12);

        let token_address = object::create_guid_object_address(resource_account_address, creation_number);
        let token_object = object::address_to_object<Token>(token_address);
        assert!(!aptos_token::are_properties_mutable(token_object), 13);
        assert!(!aptos_token::is_burnable(token_object), 14);
        assert!(aptos_token::is_freezable_by_creator(token_object), 15);
        assert!(!aptos_token::is_mutable_description(token_object), 16);
        assert!(!aptos_token::is_mutable_name(token_object), 17);
        assert!(!aptos_token::is_mutable_uri(token_object), 18);
        assert!(token::creator(token_object) == resource_account_address, 19);
        assert!(token::collection_name(token_object) == collection_name, 20);
        assert!(token::description(token_object) == dragon_description, 21);
        assert!(token::name(token_object) == dragon_name, 22);
        assert!(token::uri(token_object) == dragon_uri, 23);

        let maybe_token_royalty = token::royalty(token_object);
        assert!(option::is_some(&maybe_token_royalty), 24);

        let token_royalty = option::extract(&mut maybe_token_royalty);
        assert!(royalty::denominator(&token_royalty) == 10, 25);
        assert!(royalty::numerator(&token_royalty) == 1, 26);
        assert!(royalty::payee_address(&token_royalty) == resource_account_address, 27);
    }

    #[test]
    #[expected_failure(abort_code = 1, location = Self)]
    fun test_create_dragon_state_not_initalized() acquires State {
        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        let dragon_name = string::utf8(b"The first dragon");
        let dragon_description = string::utf8(b"This is the very first dragon in this collection");
        let dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, dragon_name, dragon_description, dragon_uri);
    }

    #[test]
    #[expected_failure(abort_code = 6, location = Self)]
    fun test_create_dragon_collection_does_not_exist() acquires State {
        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        let dragon_name = string::utf8(b"The first dragon");
        let dragon_description = string::utf8(b"This is the very first dragon in this collection");
        let dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, dragon_name, dragon_description, dragon_uri);
    }

    #[test]
    fun test_create_sword() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Sword collection");
        let collection_description = string::utf8(b"This is a sword collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let combine_amount = 4;
        let property_values = vector[10, 5];
        let ability_property = string::utf8(b"Fire imbued");
        create_sword_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            combine_amount,
            property_values,
            ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);
        let creation_number = account::get_guid_next_creation_num(resource_account_address);

        let sword_name = string::utf8(b"Eggscalibur");
        let sword_description = string::utf8(b"For a true chef");
        let sword_uri = string::utf8(b"https://cdnb.artstation.com/p/assets/covers/images/032/429/081/large/james-jones-james-jones-th3.jpg?1684926233");
        create_sword(&account, collection_name, sword_name, sword_description, sword_uri, 2);

        let state = borrow_global<State>(@admin);
        assert!(simple_map::length(&state.breeder.collections) == 0, 0);
        assert!(simple_map::length(&state.breeder.ongoing_breedings) == 0, 1);
        assert!(event::counter(&state.breeder.create_dragon_collection_events) == 0, 2);
        assert!(event::counter(&state.breeder.create_dragon_events) == 0, 3);
        assert!(event::counter(&state.breeder.breed_dragons_events) == 0, 4);
        assert!(event::counter(&state.breeder.hatch_dragon_events) == 0, 5);
        assert!(simple_map::length(&state.combiner.collections) == 1, 6);
        assert!(simple_map::contains_key(&state.combiner.collections, &collection_name), 7);
        assert!(event::counter(&state.combiner.create_sword_collection_events) == 1, 8);
        assert!(event::counter(&state.combiner.create_sword_events) == 1, 9);
        assert!(event::counter(&state.combiner.combine_swords_events) == 0, 10);

        let equipment = simple_map::borrow(&state.combiner.collections, &collection_name);
        assert!(equipment.combine_amount == combine_amount, 11);

        let expected_starting_properties = vector::map_ref(&property_values, |value| {
            bcs::to_bytes(value)
        });
        vector::push_back(&mut expected_starting_properties, bcs::to_bytes(&ability_property));
        assert!(equipment.starting_properties == expected_starting_properties, 12);

        let counter = 0;
        while (counter <= 1) {
            let token_address =
                object::create_guid_object_address(resource_account_address, creation_number + counter);
            let token_object = object::address_to_object<Token>(token_address);
            assert!(!aptos_token::are_properties_mutable(token_object), 13 + 15 * counter);
            assert!(aptos_token::is_burnable(token_object), 14 + 15 * counter);
            assert!(!aptos_token::is_freezable_by_creator(token_object), 15 + 15 * counter);
            assert!(!aptos_token::is_mutable_description(token_object), 16 + 15 * counter);
            assert!(!aptos_token::is_mutable_name(token_object), 17 + 15 * counter);
            assert!(!aptos_token::is_mutable_uri(token_object), 18 + 15 * counter);
            assert!(token::creator(token_object) == resource_account_address, 19 + 15 * counter);
            assert!(token::collection_name(token_object) == collection_name, 20 + 15 * counter);
            assert!(token::description(token_object) == sword_description, 21 + 15 * counter);
            assert!(token::name(token_object) == sword_name, 22 + 15 * counter);
            assert!(token::uri(token_object) == sword_uri, 23 + 15 * counter);

            let maybe_token_royalty = token::royalty(token_object);
            assert!(option::is_some(&maybe_token_royalty), 24 + 15 * counter);

            let token_royalty = option::extract(&mut maybe_token_royalty);
            assert!(royalty::denominator(&token_royalty) == 10, 25 + 15 * counter);
            assert!(royalty::numerator(&token_royalty) == 1, 26 + 15 * counter);
            assert!(royalty::payee_address(&token_royalty) == resource_account_address, 27 + 15 * counter);

            counter = counter + 1;
        };
    }

    #[test]
    #[expected_failure(abort_code = 1, location = Self)]
    fun test_create_sword_state_not_initialized() acquires State {
        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Sword collection");
        let sword_name = string::utf8(b"Eggscalibur");
        let sword_description = string::utf8(b"For a true chef");
        let sword_uri = string::utf8(b"https://cdnb.artstation.com/p/assets/covers/images/032/429/081/large/james-jones-james-jones-th3.jpg?1684926233");
        create_sword(&account, collection_name, sword_name, sword_description, sword_uri, 2);
    }

    #[test]
    #[expected_failure(abort_code = 6, location = Self)]
    fun test_create_sword_collection_does_not_exist() acquires State {
        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Sword collection");
        let sword_name = string::utf8(b"Eggscalibur");
        let sword_description = string::utf8(b"For a true chef");
        let sword_uri = string::utf8(b"https://cdnb.artstation.com/p/assets/covers/images/032/429/081/large/james-jones-james-jones-th3.jpg?1684926233");
        create_sword(&account, collection_name, sword_name, sword_description, sword_uri, 2);
    }

    #[test]
    fun test_breed_dragons() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        features::change_feature_flags(
            &aptos_framework,
            vector[features::get_sha_512_and_ripemd_160_feature()],
            vector[]
        );

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        let collection_description = string::utf8(b"This is a dragon collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_dragon_name = string::utf8(b"The first dragon");
        let first_dragon_description = string::utf8(b"This is the very first dragon in this collection");
        let first_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, first_dragon_name, first_dragon_description, first_dragon_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_dragon_name = string::utf8(b"The second dragon");
        let second_dragon_description = string::utf8(b"This is another dragon in this collection");
        let second_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, second_dragon_name, second_dragon_description, second_dragon_uri);

        let current_timestamp = timestamp::now_seconds();
        breed_dragons(&account, collection_name, first_creation_number, second_creation_number);

        let state = borrow_global<State>(@admin);
        assert!(simple_map::length(&state.breeder.collections) == 1, 0);
        assert!(simple_map::contains_key(&state.breeder.collections, &collection_name), 1);
        assert!(simple_map::length(&state.breeder.ongoing_breedings) == 1, 2);
        assert!(event::counter(&state.breeder.create_dragon_collection_events) == 1, 3);
        assert!(event::counter(&state.breeder.create_dragon_events) == 2, 4);
        assert!(event::counter(&state.breeder.breed_dragons_events) == 1, 5);
        assert!(event::counter(&state.breeder.hatch_dragon_events) == 0, 6);
        assert!(simple_map::length(&state.combiner.collections) == 0, 7);
        assert!(event::counter(&state.combiner.create_sword_collection_events) == 0, 8);
        assert!(event::counter(&state.combiner.create_sword_events) == 0, 9);
        assert!(event::counter(&state.combiner.combine_swords_events) == 0, 10);

        let first_dragon_address =
            object::create_guid_object_address(resource_account_address, first_creation_number);
        let second_dragon_address =
            object::create_guid_object_address(resource_account_address, second_creation_number);
        let breeding_key_bytes = bcs::to_bytes(&first_dragon_address);
        vector::append(&mut breeding_key_bytes, bcs::to_bytes(&second_dragon_address));

        let breeding_key = aptos_hash::sha3_512(breeding_key_bytes);
        assert!(simple_map::contains_key(&state.breeder.ongoing_breedings, &breeding_key), 11);

        let breeding_time =
            simple_map::borrow(&state.breeder.collections, &collection_name).breeding_time;
        let breeding_end = *simple_map::borrow(&state.breeder.ongoing_breedings, &breeding_key);
        let lower_limit = if (current_timestamp > 0) {
            current_timestamp + breeding_time - 1
        } else {
            current_timestamp + breeding_time
        };
        assert!(lower_limit <= breeding_end && breeding_end <= current_timestamp + breeding_time + 1, 12);

        let dragon_race = simple_map::borrow(&state.breeder.collections, &collection_name);
        assert!(dragon_race.breeding_time == breeding_time, 13);

        let expected_starting_properties = vector[
            bcs::to_bytes(&40),
            bcs::to_bytes(&3),
            bcs::to_bytes(&7),
            bcs::to_bytes(&ability_property)
        ];
        assert!(dragon_race.starting_properties == expected_starting_properties, 14);

        let first_dragon_token = object::address_to_object<Token>(first_dragon_address);
        assert!(!object::ungated_transfer_allowed(first_dragon_token), 15);

        let second_dragon_token = object::address_to_object<Token>(second_dragon_address);
        assert!(!object::ungated_transfer_allowed(second_dragon_token), 16);
    }

    #[test]
    #[expected_failure(abort_code = 1, location = Self)]
    fun test_breed_dragons_state_not_initialized() acquires State {
        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        breed_dragons(&account, collection_name, 156, 54);
    }

    #[test]
    #[expected_failure(abort_code = 6, location = Self)]
    fun test_breed_dragons_collection_does_not_exist() acquires State {
        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        breed_dragons(&account, collection_name, 156, 54);
    }

    #[test]
    #[expected_failure(abort_code = 7, location = Self)]
    fun test_breed_dragons_signer_does_not_own_the_first_token() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        features::change_feature_flags(
            &aptos_framework,
            vector[features::get_sha_512_and_ripemd_160_feature()],
            vector[]
        );

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        let collection_description = string::utf8(b"This is a dragon collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_dragon_name = string::utf8(b"The first dragon");
        let first_dragon_description = string::utf8(b"This is the very first dragon in this collection");
        let first_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, first_dragon_name, first_dragon_description, first_dragon_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_dragon_name = string::utf8(b"The second dragon");
        let second_dragon_description = string::utf8(b"This is another dragon in this collection");
        let second_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, second_dragon_name, second_dragon_description, second_dragon_uri);

        let first_dragon_address =
            object::create_guid_object_address(resource_account_address, first_creation_number);
        object::transfer_raw(&account, first_dragon_address, @0xBEEF);

        breed_dragons(&account, collection_name, first_creation_number, second_creation_number);
    }

    #[test]
    #[expected_failure(abort_code = 7, location = Self)]
    fun test_breed_dragons_signer_does_not_own_the_second_token() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        features::change_feature_flags(
            &aptos_framework,
            vector[features::get_sha_512_and_ripemd_160_feature()],
            vector[]
        );

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        let collection_description = string::utf8(b"This is a dragon collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_dragon_name = string::utf8(b"The first dragon");
        let first_dragon_description = string::utf8(b"This is the very first dragon in this collection");
        let first_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, first_dragon_name, first_dragon_description, first_dragon_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_dragon_name = string::utf8(b"The second dragon");
        let second_dragon_description = string::utf8(b"This is another dragon in this collection");
        let second_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, second_dragon_name, second_dragon_description, second_dragon_uri);

        let second_dragon_address =
            object::create_guid_object_address(resource_account_address, second_creation_number);
        object::transfer_raw(&account, second_dragon_address, @0xBEEF);

        breed_dragons(&account, collection_name, first_creation_number, second_creation_number);
    }

    #[test]
    #[expected_failure(abort_code = 13, location = Self)]
    fun test_breed_dragon_first_monster_from_incorrect_collection() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        features::change_feature_flags(
            &aptos_framework,
            vector[features::get_sha_512_and_ripemd_160_feature()],
            vector[]
        );

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        let collection_description = string::utf8(b"This is a dragon collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let another_collection_name = string::utf8(b"Dragon collection 2");
        let another_collection_description = string::utf8(b"This is another dragon collection");
        let another_collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let another_breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let another_ability_property = string::utf8(b"BEET");
        create_dragon_collection(
            &account,
            another_collection_name,
            another_collection_description,
            another_collection_uri,
            another_breeding_time,
            another_ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_dragon_name = string::utf8(b"The first dragon");
        let first_dragon_description = string::utf8(b"This is the very first dragon in this collection");
        let first_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, another_collection_name, first_dragon_name, first_dragon_description, first_dragon_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_dragon_name = string::utf8(b"The second dragon");
        let second_dragon_description = string::utf8(b"This is another dragon in this collection");
        let second_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, second_dragon_name, second_dragon_description, second_dragon_uri);

        breed_dragons(&account, collection_name, first_creation_number, second_creation_number);
    }

    #[test]
    #[expected_failure(abort_code = 13, location = Self)]
    fun test_breed_dragon_second_monster_from_incorrect_collection() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        features::change_feature_flags(
            &aptos_framework,
            vector[features::get_sha_512_and_ripemd_160_feature()],
            vector[]
        );

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        let collection_description = string::utf8(b"This is a dragon collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let another_collection_name = string::utf8(b"Dragon collection 2");
        let another_collection_description = string::utf8(b"This is another dragon collection");
        let another_collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let another_breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let another_ability_property = string::utf8(b"BEET");
        create_dragon_collection(
            &account,
            another_collection_name,
            another_collection_description,
            another_collection_uri,
            another_breeding_time,
            another_ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_dragon_name = string::utf8(b"The first dragon");
        let first_dragon_description = string::utf8(b"This is the very first dragon in this collection");
        let first_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, first_dragon_name, first_dragon_description, first_dragon_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_dragon_name = string::utf8(b"The second dragon");
        let second_dragon_description = string::utf8(b"This is another dragon in this collection");
        let second_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, another_collection_name, second_dragon_name, second_dragon_description, second_dragon_uri);

        breed_dragons(&account, collection_name, first_creation_number, second_creation_number);
    }

    #[test]
    #[expected_failure(abort_code = 8, location = Self)]
    fun test_breed_dragons_first_monster_already_breeding() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        features::change_feature_flags(
            &aptos_framework,
            vector[features::get_sha_512_and_ripemd_160_feature()],
            vector[]
        );

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        let collection_description = string::utf8(b"This is a dragon collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_dragon_name = string::utf8(b"The first dragon");
        let first_dragon_description = string::utf8(b"This is the very first dragon in this collection");
        let first_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, first_dragon_name, first_dragon_description, first_dragon_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_dragon_name = string::utf8(b"The second dragon");
        let second_dragon_description = string::utf8(b"This is another dragon in this collection");
        let second_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, second_dragon_name, second_dragon_description, second_dragon_uri);

        breed_dragons(&account, collection_name, first_creation_number, second_creation_number);

        let third_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let third_dragon_name = string::utf8(b"The third dragon");
        let third_dragon_description = string::utf8(b"This is another dragon in this collection");
        let third_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, third_dragon_name, third_dragon_description, third_dragon_uri);

        breed_dragons(&account, collection_name, first_creation_number, third_creation_number);
    }

    #[test]
    #[expected_failure(abort_code = 8, location = Self)]
    fun test_breed_dragons_second_monster_already_breeding() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        features::change_feature_flags(
            &aptos_framework,
            vector[features::get_sha_512_and_ripemd_160_feature()],
            vector[]
        );

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        let collection_description = string::utf8(b"This is a dragon collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_dragon_name = string::utf8(b"The first dragon");
        let first_dragon_description = string::utf8(b"This is the very first dragon in this collection");
        let first_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, first_dragon_name, first_dragon_description, first_dragon_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_dragon_name = string::utf8(b"The second dragon");
        let second_dragon_description = string::utf8(b"This is another dragon in this collection");
        let second_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, second_dragon_name, second_dragon_description, second_dragon_uri);

        breed_dragons(&account, collection_name, first_creation_number, second_creation_number);

        let third_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let third_dragon_name = string::utf8(b"The third dragon");
        let third_dragon_description = string::utf8(b"This is another dragon in this collection");
        let third_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, third_dragon_name, third_dragon_description, third_dragon_uri);

        breed_dragons(&account, collection_name, third_creation_number, second_creation_number);
    }

    #[test]
    fun test_hatch_dragon() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        features::change_feature_flags(
            &aptos_framework,
            vector[features::get_sha_512_and_ripemd_160_feature()],
            vector[]
        );

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        let collection_description = string::utf8(b"This is a dragon collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_dragon_name = string::utf8(b"The first dragon");
        let first_dragon_description = string::utf8(b"This is the very first dragon in this collection");
        let first_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, first_dragon_name, first_dragon_description, first_dragon_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_dragon_name = string::utf8(b"The second dragon");
        let second_dragon_description = string::utf8(b"This is another dragon in this collection");
        let second_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, second_dragon_name, second_dragon_description, second_dragon_uri);

        breed_dragons(&account, collection_name, first_creation_number, second_creation_number);
        timestamp::fast_forward_seconds(breeding_time);

        let new_dragon_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let new_dragon_name = string::utf8(b"Baby dragon");
        let new_dragon_description = string::utf8(b"This is a newly born baby dragon!");
        let new_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        hatch_dragon(
            &account,
            first_creation_number,
            second_creation_number,
            new_dragon_name,
            new_dragon_description,
            new_dragon_uri
        );

        let state = borrow_global<State>(@admin);
        assert!(simple_map::length(&state.breeder.collections) == 1, 0);
        assert!(simple_map::contains_key(&state.breeder.collections, &collection_name), 1);
        assert!(simple_map::length(&state.breeder.ongoing_breedings) == 0, 2);
        assert!(event::counter(&state.breeder.create_dragon_collection_events) == 1, 3);
        assert!(event::counter(&state.breeder.create_dragon_events) == 2, 4);
        assert!(event::counter(&state.breeder.breed_dragons_events) == 1, 5);
        assert!(event::counter(&state.breeder.hatch_dragon_events) == 1, 6);
        assert!(simple_map::length(&state.combiner.collections) == 0, 7);
        assert!(event::counter(&state.combiner.create_sword_collection_events) == 0, 8);
        assert!(event::counter(&state.combiner.create_sword_events) == 0, 9);
        assert!(event::counter(&state.combiner.combine_swords_events) == 0, 10);

        let dragon_race = simple_map::borrow(&state.breeder.collections, &collection_name);
        assert!(dragon_race.breeding_time == breeding_time, 11);

        let expected_starting_properties = vector[
            bcs::to_bytes(&40),
            bcs::to_bytes(&3),
            bcs::to_bytes(&7),
            bcs::to_bytes(&ability_property)
        ];
        assert!(dragon_race.starting_properties == expected_starting_properties, 12);

        let first_dragon_address =
            object::create_guid_object_address(resource_account_address, first_creation_number);
        let first_dragon_token = object::address_to_object<Token>(first_dragon_address);
        assert!(object::ungated_transfer_allowed(first_dragon_token), 13);

        let second_dragon_address =
            object::create_guid_object_address(resource_account_address, second_creation_number);
        let second_dragon_token = object::address_to_object<Token>(second_dragon_address);
        assert!(object::ungated_transfer_allowed(second_dragon_token), 14);

        let new_dragon_address =
            object::create_guid_object_address(resource_account_address, new_dragon_creation_number);
        let new_dragon_token = object::address_to_object<Token>(new_dragon_address);
        assert!(!aptos_token::are_properties_mutable(new_dragon_token), 15);
        assert!(!aptos_token::is_burnable(new_dragon_token), 16);
        assert!(aptos_token::is_freezable_by_creator(new_dragon_token), 17);
        assert!(!aptos_token::is_mutable_description(new_dragon_token), 18);
        assert!(!aptos_token::is_mutable_name(new_dragon_token), 19);
        assert!(!aptos_token::is_mutable_uri(new_dragon_token), 20);
        assert!(token::creator(new_dragon_token) == resource_account_address, 21);
        assert!(token::collection_name(new_dragon_token) == collection_name, 22);
        assert!(token::description(new_dragon_token) == new_dragon_description, 23);
        assert!(token::name(new_dragon_token) == new_dragon_name, 24);
        assert!(token::uri(new_dragon_token) == new_dragon_uri, 25);

        let maybe_token_royalty = token::royalty(new_dragon_token);
        assert!(option::is_some(&maybe_token_royalty), 26);

        let token_royalty = option::extract(&mut maybe_token_royalty);
        assert!(royalty::denominator(&token_royalty) == 10, 27);
        assert!(royalty::numerator(&token_royalty) == 1, 28);
        assert!(royalty::payee_address(&token_royalty) == resource_account_address, 29);

        let property_map = object::address_to_object<PropertyMap>(new_dragon_address);
        assert!(property_map::read_u64(&property_map, &string::utf8(b"Health")) == 80, 30);
        assert!(property_map::read_u64(&property_map, &string::utf8(b"Defence")) == 6, 31);
        assert!(property_map::read_u64(&property_map, &string::utf8(b"Strength")) == 14, 32);
        assert!(
            property_map::read_string(&property_map, &string::utf8(b"Ability")) == ability_property,
            33
        );
    }

    #[test]
    #[expected_failure(abort_code = 1, location = Self)]
    fun test_hatch_dragon_state_not_initialized() acquires State {
        let account = account::create_account_for_test(@0xCAFE);
        let new_dragon_name = string::utf8(b"Baby dragon");
        let new_dragon_description = string::utf8(b"This is a newly born baby dragon!");
        let new_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        hatch_dragon(
            &account,
            11,
            15,
            new_dragon_name,
            new_dragon_description,
            new_dragon_uri
        );
    }

    #[test]
    #[expected_failure(abort_code = 7, location = Self)]
    fun test_hatch_dragon_signer_not_owner_first_monster() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        let collection_description = string::utf8(b"This is a dragon collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_dragon_name = string::utf8(b"The first dragon");
        let first_dragon_description = string::utf8(b"This is the very first dragon in this collection");
        let first_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, first_dragon_name, first_dragon_description, first_dragon_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_dragon_name = string::utf8(b"The second dragon");
        let second_dragon_description = string::utf8(b"This is another dragon in this collection");
        let second_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, second_dragon_name, second_dragon_description, second_dragon_uri);

        let first_dragon_address =
            object::create_guid_object_address(resource_account_address, first_creation_number);
        object::transfer_raw(&account, first_dragon_address, @0xABC);

        let new_dragon_name = string::utf8(b"Baby dragon");
        let new_dragon_description = string::utf8(b"This is a newly born baby dragon!");
        let new_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        hatch_dragon(
            &account,
            first_creation_number,
            second_creation_number,
            new_dragon_name,
            new_dragon_description,
            new_dragon_uri
        );
    }

    #[test]
    #[expected_failure(abort_code = 7, location = Self)]
    fun test_hatch_dragon_signer_not_owner_second_monster() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        let collection_description = string::utf8(b"This is a dragon collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_dragon_name = string::utf8(b"The first dragon");
        let first_dragon_description = string::utf8(b"This is the very first dragon in this collection");
        let first_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, first_dragon_name, first_dragon_description, first_dragon_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_dragon_name = string::utf8(b"The second dragon");
        let second_dragon_description = string::utf8(b"This is another dragon in this collection");
        let second_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, second_dragon_name, second_dragon_description, second_dragon_uri);

        let second_dragon_address =
            object::create_guid_object_address(resource_account_address, second_creation_number);
        object::transfer_raw(&account, second_dragon_address, @0xABC);

        let new_dragon_name = string::utf8(b"Baby dragon");
        let new_dragon_description = string::utf8(b"This is a newly born baby dragon!");
        let new_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        hatch_dragon(
            &account,
            first_creation_number,
            second_creation_number,
            new_dragon_name,
            new_dragon_description,
            new_dragon_uri
        );
    }

    #[test]
    #[expected_failure(abort_code = 9, location = Self)]
    fun test_hatch_dragons_not_breeding() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        features::change_feature_flags(
            &aptos_framework,
            vector[features::get_sha_512_and_ripemd_160_feature()],
            vector[]
        );

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        let collection_description = string::utf8(b"This is a dragon collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_dragon_name = string::utf8(b"The first dragon");
        let first_dragon_description = string::utf8(b"This is the very first dragon in this collection");
        let first_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, first_dragon_name, first_dragon_description, first_dragon_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_dragon_name = string::utf8(b"The second dragon");
        let second_dragon_description = string::utf8(b"This is another dragon in this collection");
        let second_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, second_dragon_name, second_dragon_description, second_dragon_uri);

        let new_dragon_name = string::utf8(b"Baby dragon");
        let new_dragon_description = string::utf8(b"This is a newly born baby dragon!");
        let new_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        hatch_dragon(
            &account,
            first_creation_number,
            second_creation_number,
            new_dragon_name,
            new_dragon_description,
            new_dragon_uri
        );
    }

    #[test]
    #[expected_failure(abort_code = 10, location = Self)]
    fun test_hatch_dragon_breeding_not_finished() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        features::change_feature_flags(
            &aptos_framework,
            vector[features::get_sha_512_and_ripemd_160_feature()],
            vector[]
        );

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Dragon collection");
        let collection_description = string::utf8(b"This is a dragon collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let breeding_time = 60 * 60 * 24 * 21 + 60 * 60 * 11;
        let ability_property = string::utf8(b"YEET");
        create_dragon_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            breeding_time,
            ability_property
        );

        let first_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let first_dragon_name = string::utf8(b"The first dragon");
        let first_dragon_description = string::utf8(b"This is the very first dragon in this collection");
        let first_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, first_dragon_name, first_dragon_description, first_dragon_uri);

        let second_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let second_dragon_name = string::utf8(b"The second dragon");
        let second_dragon_description = string::utf8(b"This is another dragon in this collection");
        let second_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        create_dragon(&account, collection_name, second_dragon_name, second_dragon_description, second_dragon_uri);

        breed_dragons(&account, collection_name, first_creation_number, second_creation_number);

        let new_dragon_name = string::utf8(b"Baby dragon");
        let new_dragon_description = string::utf8(b"This is a newly born baby dragon!");
        let new_dragon_uri = string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        hatch_dragon(
            &account,
            first_creation_number,
            second_creation_number,
            new_dragon_name,
            new_dragon_description,
            new_dragon_uri
        );
    }

    #[test]
    fun test_combine_swords() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Sword collection");
        let collection_description = string::utf8(b"This is a sword collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let combine_amount = 4;
        let property_values = vector[10, 5];
        let ability_property = string::utf8(b"Fire imbued");
        create_sword_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            combine_amount,
            property_values,
            ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);
        let creation_number_brefore_first_creation = account::get_guid_next_creation_num(resource_account_address);

        let sword_name = string::utf8(b"Eggscalibur");
        let sword_description = string::utf8(b"For a true chef");
        let sword_uri = string::utf8(b"https://cdnb.artstation.com/p/assets/covers/images/032/429/081/large/james-jones-james-jones-th3.jpg?1684926233");
        create_sword(&account, collection_name, sword_name, sword_description, sword_uri, 2);

        let creation_number_brefore_second_creation =
            account::get_guid_next_creation_num(resource_account_address);
        let sword_name = string::utf8(b"The Great Spork");
        let sword_description = string::utf8(b"For a true taster");
        let sword_uri =
            string::utf8(b"https://www.watchuseek.com/attachments/spork-notes-1-jpg.532357/");
        create_sword(&account, collection_name, sword_name, sword_description, sword_uri, 2);

        let new_sword_creation_number = account::get_guid_next_creation_num(resource_account_address);
        let new_sword_name = string::utf8(b"Ultimate Cutlery");
        let new_sword_description = string::utf8(b"For a true Gourmet");
        let new_sword_uri = string::utf8(b"https://m.media-amazon.com/images/I/61QyLGqUVQL._AC_UF350,350_QL80_.jpg");
        combine_swords(
            &account,
            collection_name,
            vector[
                creation_number_brefore_first_creation,
                creation_number_brefore_first_creation + 1,
                creation_number_brefore_second_creation,
                creation_number_brefore_second_creation + 1
            ],
            new_sword_name,
            new_sword_description,
            new_sword_uri
        );

        let state = borrow_global<State>(@admin);
        assert!(simple_map::length(&state.breeder.collections) == 0, 0);
        assert!(simple_map::length(&state.breeder.ongoing_breedings) == 0, 1);
        assert!(event::counter(&state.breeder.create_dragon_collection_events) == 0, 2);
        assert!(event::counter(&state.breeder.create_dragon_events) == 0, 3);
        assert!(event::counter(&state.breeder.breed_dragons_events) == 0, 4);
        assert!(event::counter(&state.breeder.hatch_dragon_events) == 0, 5);
        assert!(simple_map::length(&state.combiner.collections) == 1, 6);
        assert!(simple_map::contains_key(&state.combiner.collections, &collection_name), 7);
        assert!(event::counter(&state.combiner.create_sword_collection_events) == 1, 8);
        assert!(event::counter(&state.combiner.create_sword_events) == 2, 9);
        assert!(event::counter(&state.combiner.combine_swords_events) == 1, 10);

        let sword_type = simple_map::borrow(&state.combiner.collections, &collection_name);
        assert!(sword_type.combine_amount == combine_amount, 11);

        let expected_starting_properties = vector::map_ref(&property_values, |value| {
            bcs::to_bytes(value)
        });
        vector::push_back(&mut expected_starting_properties, bcs::to_bytes(&ability_property));
        assert!(sword_type.starting_properties == expected_starting_properties, 12);

        let new_sword_address =
            object::create_guid_object_address(resource_account_address, new_sword_creation_number);
        let new_sword_token = object::address_to_object<Token>(new_sword_address);
        assert!(!aptos_token::are_properties_mutable(new_sword_token), 13);
        assert!(aptos_token::is_burnable(new_sword_token), 14);
        assert!(!aptos_token::is_freezable_by_creator(new_sword_token), 15);
        assert!(!aptos_token::is_mutable_description(new_sword_token), 16);
        assert!(!aptos_token::is_mutable_name(new_sword_token), 17);
        assert!(!aptos_token::is_mutable_uri(new_sword_token), 18);
        assert!(token::creator(new_sword_token) == resource_account_address, 19);
        assert!(token::collection_name(new_sword_token) == collection_name, 20);
        assert!(token::description(new_sword_token) == new_sword_description, 21);
        assert!(token::name(new_sword_token) == new_sword_name, 22);
        assert!(token::uri(new_sword_token) == new_sword_uri, 23);

        let maybe_token_royalty = token::royalty(new_sword_token);
        assert!(option::is_some(&maybe_token_royalty), 24);

        let token_royalty = option::extract(&mut maybe_token_royalty);
        assert!(royalty::denominator(&token_royalty) == 10, 25);
        assert!(royalty::numerator(&token_royalty) == 1, 26);
        assert!(royalty::payee_address(&token_royalty) == resource_account_address, 27);

        let property_map = object::address_to_object<PropertyMap>(new_sword_address);
        assert!(property_map::read_u64(&property_map, &string::utf8(b"Attack")) == 40, 28);
        assert!(property_map::read_u64(&property_map, &string::utf8(b"Durability")) == 20, 30);
        assert!(
            property_map::read_string(&property_map, &string::utf8(b"Ability")) ==
                string::utf8(b"Fire imbued"),
            31
        );
    }

    #[test]
    #[expected_failure(abort_code = 1, location = Self)]
    fun test_combine_swords_state_not_initialized() acquires State {
        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Sword collection");
        let new_sword_name = string::utf8(b"Ultimate Cutlery");
        let new_sword_description = string::utf8(b"For a true Gourmet");
        let new_sword_uri = string::utf8(b"https://m.media-amazon.com/images/I/61QyLGqUVQL._AC_UF350,350_QL80_.jpg");
        combine_swords(
            &account,
            collection_name,
            vector[15, 16, 55, 66],
            new_sword_name,
            new_sword_description,
            new_sword_uri
        );
    }

    #[test]
    #[expected_failure(abort_code = 11, location = Self)]
    fun test_combine_swords_incorrect_amount_of_equipment() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Sword collection");
        let collection_description = string::utf8(b"This is a sword collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let combine_amount = 4;
        let property_values = vector[10, 5];
        let ability_property = string::utf8(b"Fire imbued");
        create_sword_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            combine_amount,
            property_values,
            ability_property
        );

        let new_sword_name = string::utf8(b"Ultimate Cutlery");
        let new_sword_description = string::utf8(b"For a true Gourmet");
        let new_sword_uri = string::utf8(b"https://m.media-amazon.com/images/I/61QyLGqUVQL._AC_UF350,350_QL80_.jpg");
        combine_swords(
            &account,
            collection_name,
            vector[15],
            new_sword_name,
            new_sword_description,
            new_sword_uri
        );
    }

    #[test]
    #[expected_failure(abort_code = 7, location = Self)]
    fun test_combine_swords_signer_does_not_own_token() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Sword collection");
        let collection_description = string::utf8(b"This is a sword collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let combine_amount = 4;
        let property_values = vector[10, 5];
        let ability_property = string::utf8(b"Fire imbued");
        create_sword_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            combine_amount,
            property_values,
            ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let creation_number = account::get_guid_next_creation_num(resource_account_address);
        let sword_name = string::utf8(b"Eggscalibur");
        let sword_description = string::utf8(b"For a true chef");
        let sword_uri = string::utf8(b"https://cdnb.artstation.com/p/assets/covers/images/032/429/081/large/james-jones-james-jones-th3.jpg?1684926233");
        create_sword(&account, collection_name, sword_name, sword_description, sword_uri, 4);

        let equipment_address =
            object::create_guid_object_address(resource_account_address, creation_number + 1);
        object::transfer_raw(&account, equipment_address, @0xABCDEF);

        let new_sword_name = string::utf8(b"Ultimate Cutlery");
        let new_sword_description = string::utf8(b"For a true Gourmet");
        let new_sword_uri = string::utf8(b"https://m.media-amazon.com/images/I/61QyLGqUVQL._AC_UF350,350_QL80_.jpg");
        combine_swords(
            &account,
            collection_name,
            vector[
                creation_number,
                creation_number + 1,
                creation_number + 2,
                creation_number + 3
            ],
            new_sword_name,
            new_sword_description,
            new_sword_uri
        );
    }

    #[test]
    #[expected_failure(abort_code = 13, location = Self)]
    fun test_combine_swords_token_from_incorrect_collection() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);

        let admin = account::create_account_for_test(@admin);
        init(&admin);

        let account = account::create_account_for_test(@0xCAFE);
        let collection_name = string::utf8(b"Sword collection");
        let collection_description = string::utf8(b"This is a sword collection");
        let collection_uri =
            string::utf8(b"https://static.wikia.nocookie.net/dank_memer/images/c/c7/Dragon.png/revision/latest/thumbnail/width/360/height/360?cb=20221128103212");
        let combine_amount = 4;
        let property_values = vector[10, 5];
        let ability_property = string::utf8(b"Fire imbued");
        create_sword_collection(
            &account,
            collection_name,
            collection_description,
            collection_uri,
            combine_amount,
            property_values,
            ability_property
        );

        let another_collection_name = string::utf8(b"Sword collection 2");
        let another_collection_description = string::utf8(b"This is another sword collection");
        let another_collection_uri =
            string::utf8(b"https://i.pinimg.com/originals/07/6b/b1/076bb1fbef7d70f0a1a961ab8c136a22.jpg");
        let another_combine_amount = 4;
        let another_property_values = vector[10, 5];
        let another_ability_property = string::utf8(b"Ice imbued");
        create_sword_collection(
            &account,
            another_collection_name,
            another_collection_description,
            another_collection_uri,
            another_combine_amount,
            another_property_values,
            another_ability_property
        );

        let resource_account_address = account::create_resource_address(&@admin, BREEDER_SEED);

        let creation_number = account::get_guid_next_creation_num(resource_account_address);
        let sword_name = string::utf8(b"Eggscalibur");
        let sword_description = string::utf8(b"For a true chef");
        let sword_uri = string::utf8(b"https://cdnb.artstation.com/p/assets/covers/images/032/429/081/large/james-jones-james-jones-th3.jpg?1684926233");
        create_sword(&account, collection_name, sword_name, sword_description, sword_uri, 3);

        let sword_name = string::utf8(b"Eggscalibur");
        let sword_description = string::utf8(b"For a true chef");
        let sword_uri = string::utf8(b"https://cdnb.artstation.com/p/assets/covers/images/032/429/081/large/james-jones-james-jones-th3.jpg?1684926233");
        create_sword(&account, another_collection_name, sword_name, sword_description, sword_uri, 1);

        let new_sword_name = string::utf8(b"Ultimate Cutlery");
        let new_sword_description = string::utf8(b"For a true Gourmet");
        let new_sword_uri = string::utf8(b"https://m.media-amazon.com/images/I/61QyLGqUVQL._AC_UF350,350_QL80_.jpg");
        combine_swords(
            &account,
            collection_name,
            vector[
                creation_number,
                creation_number + 3,
                creation_number + 2,
                creation_number + 1
            ],
            new_sword_name,
            new_sword_description,
            new_sword_uri
        );
    }
}