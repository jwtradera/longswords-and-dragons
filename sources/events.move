module overmind::breeder_events {
    use std::string::String;

    struct CreateDragonCollectionEvent has store, drop {
        name: String,
        description: String,
        uri: String,
        breeding_time: u64,
        starting_properties: vector<vector<u8>>,
        timestamp: u64
    }

    struct CreateSwordCollectionEvent has store, drop {
        name: String,
        description: String,
        uri: String,
        combine_amount: u64,
        starting_properties: vector<vector<u8>>,
        timestamp: u64
    }

    struct CreateDragonEvent has store, drop {
        owner: address,
        collection_name: String,
        dragon_name: String,
        dragon_description: String,
        dragon_uri: String,
        creation_number: u64,
        timestamp: u64
    }

    struct CreateSwordEvent has store, drop {
        onwer: address,
        collection_name: String,
        sword_name: String,
        sword_description: String,
        sword_uri: String,
        amount: u64,
        creation_numbers: vector<u64>,
        timestamp: u64
    }

    struct BreedDragonsEvent has store, drop {
        onwer: address,
        collection_name: String,
        first_dragon_creation_number: u64,
        second_dragon_creation_number: u64,
        finish_timestamp: u64,
        timestamp: u64
    }

    struct HatchDragonEvent has store, drop {
        owner: address,
        first_dragon_creation_number: u64,
        second_dragon_creation_number: u64,
        new_dragon_creation_number: u64,
        new_dragon_name: String,
        new_dragon_description: String,
        new_dragon_uri: String,
        new_dragon_property_values: vector<vector<u8>>,
        timestamp: u64
    }

    struct CombineSwordsEvent has store, drop {
        owner: address,
        collection_name: String,
        swords_creation_numbers: vector<u64>,
        new_sword_creation_number: u64,
        new_sword_name: String,
        new_sword_description: String,
        new_sword_uri: String,
        new_sword_property_values: vector<vector<u8>>,
        timestamp: u64
    }

    public fun new_create_dragon_collection_event(
        name: String,
        description: String,
        uri: String,
        breeding_time: u64,
        starting_properties: vector<vector<u8>>,
        timestamp: u64
    ): CreateDragonCollectionEvent {
        CreateDragonCollectionEvent { name, description, uri, breeding_time, starting_properties, timestamp}
    }

    public fun new_create_sword_collection_event(
        name: String,
        description: String,
        uri: String,
        combine_amount: u64,
        starting_properties: vector<vector<u8>>,
        timestamp: u64
    ): CreateSwordCollectionEvent {
        CreateSwordCollectionEvent { name, description, uri, combine_amount, starting_properties, timestamp }
    }

    public fun new_create_dragon_event(
        owner: address,
        collection_name: String,
        dragon_name: String,
        dragon_description: String,
        dragon_uri: String,
        creation_number: u64,
        timestamp: u64
    ): CreateDragonEvent {
        CreateDragonEvent {
            owner,
            collection_name,
            dragon_name,
            dragon_description,
            dragon_uri,
            creation_number,
            timestamp
        }
    }

    public fun new_create_sword_event(
        onwer: address,
        collection_name: String,
        sword_name: String,
        sword_description: String,
        sword_uri: String,
        amount: u64,
        creation_numbers: vector<u64>,
        timestamp: u64
    ): CreateSwordEvent {
        CreateSwordEvent {
            onwer,
            collection_name,
            sword_name,
            sword_description,
            sword_uri,
            amount,
            creation_numbers,
            timestamp
        }
    }

    public fun new_breed_dragons_event(
        onwer: address,
        collection_name: String,
        first_dragon_creation_number: u64,
        second_dragon_creation_number: u64,
        finish_timestamp: u64,
        timestamp: u64
    ): BreedDragonsEvent {
        BreedDragonsEvent {
            onwer,
            collection_name,
            first_dragon_creation_number,
            second_dragon_creation_number,
            finish_timestamp,
            timestamp
        }
    }

    public fun new_hatch_dragon_event(
        owner: address,
        first_dragon_creation_number: u64,
        second_dragon_creation_number: u64,
        new_dragon_creation_number: u64,
        new_dragon_name: String,
        new_dragon_description: String,
        new_dragon_uri: String,
        new_dragon_property_values: vector<vector<u8>>,
        timestamp: u64
    ): HatchDragonEvent {
        HatchDragonEvent {
            owner,
            first_dragon_creation_number,
            second_dragon_creation_number,
            new_dragon_creation_number,
            new_dragon_name,
            new_dragon_description,
            new_dragon_uri,
            new_dragon_property_values,
            timestamp
        }
    }

    public fun new_combine_swords_event(
        owner: address,
        collection_name: String,
        swords_creation_numbers: vector<u64>,
        new_sword_creation_number: u64,
        new_sword_name: String,
        new_sword_description: String,
        new_sword_uri: String,
        new_sword_property_values: vector<vector<u8>>,
        timestamp: u64
    ): CombineSwordsEvent {
        CombineSwordsEvent {
            owner,
            collection_name,
            swords_creation_numbers,
            new_sword_creation_number,
            new_sword_name,
            new_sword_description,
            new_sword_uri,
            new_sword_property_values,
            timestamp
        }
    }
}