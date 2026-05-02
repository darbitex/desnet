# DeSNet v0.3.2 — Chain Bytecode Bundle (PART 3 social verbs)

**Ground truth = on-chain bytecode fetched from mainnet @desnet on 2026-05-02.**

This is **3 of 3** parts. Each part covers a domain-grouped subset of modules.

## Package metadata (same across all parts)

```json
{
  "desnet_addr": "0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724",
  "pkg_name": "Desnet",
  "upgrade_number": "4",
  "source_digest": "404D8C42C1DFCFDD4FBB522936146642CCC0734618380B4B34DA582C368CC51E",
  "total_module_bytes": 71968,
  "pkg_concat_sha3_256": "6b5326ff446d35323332a879e152654dee2e7fbcc836be97a49516ffe1f73472"
}
```

## Modules in this part

| module | bytes | sha3_256 |
|---|---:|---|
| `assets` | 2,950 | `8de46f4e7e54e19b91eb0d4a627ace336be55ceb3caf2a76fd83c38041472e55` |
| `reference_gate` | 1,363 | `cd27eaf0bb619c6931ec111574ee42ec5311d8b80d016b71c0db0877162c6c67` |
| `history` | 2,934 | `19bf456b6b20991542b8ad6f953e260cdf2dfe32d5f0556acedec284bf5eaee0` |
| `link` | 1,981 | `ab14968a728d3a17f8e95677fbe3b905e5d9e589c7728077ab2de3b4b1df9133` |
| `mint` | 4,704 | `2c4f9f3e89d5070189eec6bbaeb42b5d5ed32324c7625480d271ba00c74b609a` |
| `giveaway` | 4,753 | `946ef6e50d56488a4cc5e60d666ab88febefd77e2eb3f82707c796002075c570` |
| `press` | 4,457 | `c3259a61676a4b59b067faf1eaec571e7a22e4812670e17e354e083a56c43893` |
| `pulse` | 2,490 | `42e1ceef93d19af5bbdfb91efb8e5ebcd6c06505bcec3c3846d37af015b11327` |

To verify each module's sha3 matches: `curl https://fullnode.mainnet.aptoslabs.com/v1/accounts/<@desnet>/module/<name>` → `.bytecode` field → strip `0x` → hex-decode → sha3_256.

---


## Module `assets` (2950 bytes)

`sha3_256: 8de46f4e7e54e19b91eb0d4a627ace336be55ceb3caf2a76fd83c38041472e55`

### ABI surface

**Structs** (7):

- `Node` `[key]` {children:vector<address>}
- `AssetChunkDeployed` `[drop+store]` {master_addr:address, chunk_addr:address, data_len:u64, timestamp_secs:u64}
- `AssetFinalized` `[drop+store]` {master_addr:address, root:address, depth:u8, timestamp_secs:u64}
- `AssetMasterCreated` `[drop+store]` {master_addr:address, creator_pid:address, mime:u8, total_size:u64, timestamp_secs:u64}
- `AssetNodeDeployed` `[drop+store]` {master_addr:address, node_addr:address, children_count:u64, timestamp_secs:u64}
- `Chunk` `[key]` {data:vector<u8>}
- `Master` `[key]` {root:address, depth:u8, total_size:u64, mime:u8, creator_pid:address, creator_addr:address, sealed:bool, created_at_secs:u64}

**Public fns** (21):

- [view] `chunk_size(address) → u64`
- [view] `chunk_size_max() → u64`
- [view] `creator_pid_of(address) → address`
- [entry] `deploy_chunk(&signer,address,vector<u8>)`
- [entry] `deploy_node(&signer,address,vector<address>)`
- [view] `depth_of(address) → u8`
- [entry] `finalize(&signer,address,address,u8)`
- [view] `is_sealed(address) → bool`
- [view] `master_exists(address) → bool`
- [view] `max_total_size() → u64`
- [view] `mime_gif() → u8`
- [view] `mime_jpeg() → u8`
- [view] `mime_of(address) → u8`
- [view] `mime_png() → u8`
- [view] `mime_svg() → u8`
- [view] `mime_webp() → u8`
- [view] `read_chunk(address) → vector<u8>`
- [view] `read_node(address) → vector<address>`
- [view] `root_of(address) → address`
- [entry] `start_upload(&signer,u8,u64,address)`
- [view] `total_size_of(address) → u64`

### MASM (disassembled bytecode)

```move
// Bytecode version v9
module 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::assets
use 0x1::signer
use 0x1::object
use 0x1::timestamp
use 0x1::event
struct Node has key
  children: vector<address>

struct AssetChunkDeployed has drop + store
  master_addr: address
  chunk_addr: address
  data_len: u64
  timestamp_secs: u64

struct AssetFinalized has drop + store
  master_addr: address
  root: address
  depth: u8
  timestamp_secs: u64

struct AssetMasterCreated has drop + store
  master_addr: address
  creator_pid: address
  mime: u8
  total_size: u64
  timestamp_secs: u64

struct AssetNodeDeployed has drop + store
  master_addr: address
  node_addr: address
  children_count: u64
  timestamp_secs: u64

struct Chunk has key
  data: vector<u8>

struct Master has key
  root: address
  depth: u8
  total_size: u64
  mime: u8
  creator_pid: address
  creator_addr: address
  sealed: bool
  created_at_secs: u64

// Function definition at index 0
fun assert_valid_mime(l0: u8)
    local l1: bool
    local l2: bool
    local l3: bool
    local l4: bool
    copy_loc l0
    ld_u8 1
    eq
    br_false l0
    ld_true
    // @5
    st_loc l1
l8: move_loc l1
    br_false l1
    ld_true
    st_loc l2
    // @10
l7: move_loc l2
    br_false l2
    ld_true
    st_loc l3
l6: move_loc l3
    // @15
    br_false l3
    ld_true
    st_loc l4
l5: move_loc l4
    br_false l4
    // @20
    ret
l4: ld_u64 1
    abort
l3: move_loc l0
    ld_u8 5
    // @25
    eq
    st_loc l4
    branch l5
l2: copy_loc l0
    ld_u8 4
    // @30
    eq
    st_loc l3
    branch l6
l1: copy_loc l0
    ld_u8 3
    // @35
    eq
    st_loc l2
    branch l7
l0: copy_loc l0
    ld_u8 2
    // @40
    eq
    st_loc l1
    branch l8

// Function definition at index 1
#[persistent] public fun chunk_size(l0: address): u64 acquires Chunk
    copy_loc l0
    exists Chunk
    br_true l0
    ld_u64 0
    ret
    // @5
l0: move_loc l0
    borrow_global Chunk
    borrow_field Chunk, data
    vec_len <u8>
    ret

// Function definition at index 2
#[persistent] public fun chunk_size_max(): u64
    ld_u64 30000
    ret

// Function definition at index 3
#[persistent] public fun creator_pid_of(l0: address): address acquires Master
    copy_loc l0
    exists Master
    br_false l0
    move_loc l0
    borrow_global Master
    // @5
    borrow_field Master, creator_pid
    read_ref
    ret
l0: ld_u64 7
    abort

// Function definition at index 4
#[persistent] entry public fun deploy_chunk(l0: &signer, l1: address, l2: vector<u8>) acquires Master
    local l3: &Master
    local l4: address
    local l5: u64
    local l6: object::ConstructorRef
    local l7: signer
    local l8: address
    copy_loc l1
    exists Master
    br_false l0
    copy_loc l1
    borrow_global Master
    // @5
    st_loc l3
    copy_loc l3
    borrow_field Master, sealed
    read_ref
    br_true l1
    // @10
    move_loc l0
    call signer::address_of
    st_loc l4
    move_loc l3
    borrow_field Master, creator_addr
    // @15
    read_ref
    copy_loc l4
    eq
    br_false l2
    borrow_loc l2
    // @20
    vec_len <u8>
    st_loc l5
    copy_loc l5
    ld_u64 0
    gt
    // @25
    br_false l3
    copy_loc l5
    ld_u64 30000
    le
    br_false l4
    // @30
    move_loc l4
    call object::create_object
    st_loc l6
    borrow_loc l6
    call object::generate_signer
    // @35
    st_loc l7
    borrow_loc l7
    call signer::address_of
    st_loc l8
    borrow_loc l7
    // @40
    move_loc l2
    pack Chunk
    move_to Chunk
    move_loc l1
    move_loc l8
    // @45
    move_loc l5
    call timestamp::now_seconds
    pack AssetChunkDeployed
    call event::emit<AssetChunkDeployed>
    ret
    // @50
l4: ld_u64 4
    abort
l3: ld_u64 5
    abort
l2: ld_u64 11
    // @55
    abort
l1: move_loc l0
    pop
    move_loc l3
    pop
    // @60
    ld_u64 6
    abort
l0: move_loc l0
    pop
    ld_u64 7
    // @65
    abort

// Function definition at index 5
#[persistent] entry public fun deploy_node(l0: &signer, l1: address, l2: vector<address>) acquires Master
    local l3: &Master
    local l4: address
    local l5: u64
    local l6: object::ConstructorRef
    local l7: signer
    local l8: address
    copy_loc l1
    exists Master
    br_false l0
    copy_loc l1
    borrow_global Master
    // @5
    st_loc l3
    copy_loc l3
    borrow_field Master, sealed
    read_ref
    br_true l1
    // @10
    move_loc l0
    call signer::address_of
    st_loc l4
    move_loc l3
    borrow_field Master, creator_addr
    // @15
    read_ref
    copy_loc l4
    eq
    br_false l2
    borrow_loc l2
    // @20
    vec_len <address>
    st_loc l5
    copy_loc l5
    ld_u64 0
    gt
    // @25
    br_false l3
    move_loc l4
    call object::create_object
    st_loc l6
    borrow_loc l6
    // @30
    call object::generate_signer
    st_loc l7
    borrow_loc l7
    call signer::address_of
    st_loc l8
    // @35
    borrow_loc l7
    move_loc l2
    pack Node
    move_to Node
    move_loc l1
    // @40
    move_loc l8
    move_loc l5
    call timestamp::now_seconds
    pack AssetNodeDeployed
    call event::emit<AssetNodeDeployed>
    // @45
    ret
l3: ld_u64 10
    abort
l2: ld_u64 11
    abort
    // @50
l1: move_loc l0
    pop
    move_loc l3
    pop
    ld_u64 6
    // @55
    abort
l0: move_loc l0
    pop
    ld_u64 7
    abort

// Function definition at index 6
#[persistent] public fun depth_of(l0: address): u8 acquires Master
    copy_loc l0
    exists Master
    br_false l0
    move_loc l0
    borrow_global Master
    // @5
    borrow_field Master, depth
    read_ref
    ret
l0: ld_u64 7
    abort

// Function definition at index 7
#[persistent] entry public fun finalize(l0: &signer, l1: address, l2: address, l3: u8) acquires Master
    local l4: &mut Master
    local l5: &mut address
    local l6: &mut u8
    copy_loc l1
    exists Master
    br_false l0
    copy_loc l1
    mut_borrow_global Master
    // @5
    st_loc l4
    copy_loc l4
    borrow_field Master, sealed
    read_ref
    br_true l1
    // @10
    copy_loc l4
    borrow_field Master, creator_addr
    read_ref
    move_loc l0
    call signer::address_of
    // @15
    eq
    br_false l2
    copy_loc l3
    ld_u8 0
    eq
    // @20
    br_false l3
    copy_loc l2
    exists Chunk
    br_false l4
    branch l5
    // @25
l5: copy_loc l4
    mut_borrow_field Master, root
    st_loc l5
    copy_loc l2
    move_loc l5
    // @30
    write_ref
    copy_loc l4
    mut_borrow_field Master, depth
    st_loc l6
    copy_loc l3
    // @35
    move_loc l6
    write_ref
    ld_true
    move_loc l4
    mut_borrow_field Master, sealed
    // @40
    write_ref
    move_loc l1
    move_loc l2
    move_loc l3
    call timestamp::now_seconds
    // @45
    pack AssetFinalized
    call event::emit<AssetFinalized>
    ret
l4: move_loc l4
    pop
    // @50
    ld_u64 8
    abort
l3: copy_loc l2
    exists Node
    br_false l6
    // @55
    branch l5
l6: move_loc l4
    pop
    ld_u64 9
    abort
    // @60
l2: move_loc l4
    pop
    ld_u64 11
    abort
l1: move_loc l0
    // @65
    pop
    move_loc l4
    pop
    ld_u64 6
    abort
    // @70
l0: move_loc l0
    pop
    ld_u64 7
    abort

// Function definition at index 8
#[persistent] public fun is_sealed(l0: address): bool acquires Master
    copy_loc l0
    exists Master
    br_true l0
    ld_false
    ret
    // @5
l0: move_loc l0
    borrow_global Master
    borrow_field Master, sealed
    read_ref
    ret

// Function definition at index 9
#[persistent] public fun master_exists(l0: address): bool
    move_loc l0
    exists Master
    ret

// Function definition at index 10
#[persistent] public fun max_total_size(): u64
    ld_u64 5000000
    ret

// Function definition at index 11
#[persistent] public fun mime_gif(): u8
    ld_u8 3
    ret

// Function definition at index 12
#[persistent] public fun mime_jpeg(): u8
    ld_u8 2
    ret

// Function definition at index 13
#[persistent] public fun mime_of(l0: address): u8 acquires Master
    copy_loc l0
    exists Master
    br_false l0
    move_loc l0
    borrow_global Master
    // @5
    borrow_field Master, mime
    read_ref
    ret
l0: ld_u64 7
    abort

// Function definition at index 14
#[persistent] public fun mime_png(): u8
    ld_u8 1
    ret

// Function definition at index 15
#[persistent] public fun mime_svg(): u8
    ld_u8 5
    ret

// Function definition at index 16
#[persistent] public fun mime_webp(): u8
    ld_u8 4
    ret

// Function definition at index 17
#[persistent] public fun read_chunk(l0: address): vector<u8> acquires Chunk
    copy_loc l0
    exists Chunk
    br_false l0
    move_loc l0
    borrow_global Chunk
    // @5
    borrow_field Chunk, data
    read_ref
    ret
l0: ld_u64 8
    abort

// Function definition at index 18
#[persistent] public fun read_node(l0: address): vector<address> acquires Node
    copy_loc l0
    exists Node
    br_false l0
    move_loc l0
    borrow_global Node
    // @5
    borrow_field Node, children
    read_ref
    ret
l0: ld_u64 9
    abort

// Function definition at index 19
#[persistent] public fun root_of(l0: address): address acquires Master
    copy_loc l0
    exists Master
    br_false l0
    move_loc l0
    borrow_global Master
    // @5
    borrow_field Master, root
    read_ref
    ret
l0: ld_u64 7
    abort

// Function definition at index 20
#[persistent] entry public fun start_upload(l0: &signer, l1: u8, l2: u64, l3: address)
    local l4: address
    local l5: object::ConstructorRef
    local l6: signer
    local l7: u64
    copy_loc l1
    call assert_valid_mime
    copy_loc l2
    ld_u64 0
    gt
    // @5
    br_false l0
    copy_loc l2
    ld_u64 5000000
    le
    br_false l1
    // @10
    move_loc l0
    call signer::address_of
    st_loc l4
    copy_loc l4
    call object::create_object
    // @15
    st_loc l5
    borrow_loc l5
    call object::generate_signer
    st_loc l6
    borrow_loc l6
    // @20
    call signer::address_of
    call timestamp::now_seconds
    st_loc l7
    borrow_loc l6
    ld_const<address> 0
    // @25
    ld_u8 0
    copy_loc l2
    copy_loc l1
    copy_loc l3
    move_loc l4
    // @30
    ld_false
    copy_loc l7
    pack Master
    move_to Master
    move_loc l3
    // @35
    move_loc l1
    move_loc l2
    move_loc l7
    pack AssetMasterCreated
    call event::emit<AssetMasterCreated>
    // @40
    ret
l1: move_loc l0
    pop
    ld_u64 2
    abort
    // @45
l0: move_loc l0
    pop
    ld_u64 3
    abort

// Function definition at index 21
#[persistent] public fun total_size_of(l0: address): u64 acquires Master
    copy_loc l0
    exists Master
    br_false l0
    move_loc l0
    borrow_global Master
    // @5
    borrow_field Master, total_size
    read_ref
    ret
l0: ld_u64 7
    abort
```

---

## Module `reference_gate` (1363 bytes)

`sha3_256: cd27eaf0bb619c6931ec111574ee42ec5311d8b80d016b71c0db0877162c6c67`

### ABI surface

**Structs** (1):

- `ReferenceGate` `[copy+drop+store]` {target_pid:address, min_token_balance:u64, max_token_balance:u64, min_lp_stake:u64}

**Public fns** (7):

-  `new(address,u64,u64,u64) → 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::reference_gate::ReferenceGate`
-  `check(&0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::reference_gate::ReferenceGate,address,bool,bool,address) → bool`
-  `is_open_for(&0x1::option::Option<0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::reference_gate::ReferenceGate>,address,bool,bool,address) → bool`
-  `max_token_balance(&0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::reference_gate::ReferenceGate) → u64`
-  `min_lp_stake(&0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::reference_gate::ReferenceGate) → u64`
-  `min_token_balance(&0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::reference_gate::ReferenceGate) → u64`
-  `target_pid(&0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::reference_gate::ReferenceGate) → address`

### MASM (disassembled bytecode)

```move
// Bytecode version v9
module 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::reference_gate
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::factory
use 0x1::fungible_asset
use 0x1::object
use 0x1::primary_fungible_store
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::lp_staking
use 0x1::option
struct ReferenceGate has copy + drop + store
  target_pid: address
  min_token_balance: u64
  max_token_balance: u64
  min_lp_stake: u64

// Function definition at index 0
#[persistent] public fun new(l0: address, l1: u64, l2: u64, l3: u64): ReferenceGate
    move_loc l0
    move_loc l1
    move_loc l2
    move_loc l3
    pack ReferenceGate
    // @5
    ret

// Function definition at index 1
#[persistent] public fun check(l0: &ReferenceGate, l1: address, l2: bool, l3: bool, l4: address): bool
    local l5: bool
    local l6: bool
    local l7: object::Object<fungible_asset::Metadata>
    local l8: u64
    local l9: address
    move_loc l3
    br_true l0
    move_loc l2
    not
    st_loc l3
    // @5
l20: move_loc l3
    br_false l1
    move_loc l0
    pop
    ld_false
    // @10
    ret
l1: copy_loc l0
    borrow_field ReferenceGate, min_token_balance
    read_ref
    ld_u64 0
    // @15
    eq
    copy_loc l0
    borrow_field ReferenceGate, max_token_balance
    read_ref
    ld_u64 18446744073709551615
    // @20
    eq
    st_loc l5
    br_false l2
    move_loc l5
    st_loc l6
    // @25
l19: move_loc l6
    br_false l3
    branch l4
l3: copy_loc l0
    borrow_field ReferenceGate, target_pid
    // @30
    read_ref
    call factory::owner_has_token
    br_true l5
    move_loc l0
    pop
    // @35
    ld_false
    ret
l5: copy_loc l0
    borrow_field ReferenceGate, target_pid
    read_ref
    // @40
    call factory::token_metadata_of_owner
    call object::address_to_object<fungible_asset::Metadata>
    st_loc l7
    copy_loc l1
    move_loc l7
    // @45
    call primary_fungible_store::balance<fungible_asset::Metadata>
    st_loc l8
    copy_loc l8
    copy_loc l0
    borrow_field ReferenceGate, min_token_balance
    // @50
    read_ref
    lt
    br_false l6
    move_loc l0
    pop
    // @55
    ld_false
    ret
l6: move_loc l8
    copy_loc l0
    borrow_field ReferenceGate, max_token_balance
    // @60
    read_ref
    gt
    br_true l7
    branch l4
l7: move_loc l0
    // @65
    pop
    ld_false
    ret
l4: copy_loc l0
    borrow_field ReferenceGate, min_lp_stake
    // @70
    read_ref
    ld_u64 0
    gt
    br_false l8
    copy_loc l4
    // @75
    ld_const<address> 0
    eq
    br_false l9
    move_loc l0
    pop
    // @80
    ld_false
    ret
l9: copy_loc l4
    call lp_staking::has_position
    br_true l10
    // @85
    move_loc l0
    pop
    ld_false
    ret
l10: copy_loc l0
    // @90
    borrow_field ReferenceGate, target_pid
    read_ref
    call factory::owner_has_token
    br_true l11
    move_loc l0
    // @95
    pop
    ld_false
    ret
l11: copy_loc l0
    borrow_field ReferenceGate, target_pid
    // @100
    read_ref
    call factory::lp_staking_pool_of_owner
    st_loc l9
    copy_loc l4
    call lp_staking::position_pool
    // @105
    move_loc l9
    neq
    br_false l12
    move_loc l0
    pop
    // @110
    ld_false
    ret
l12: copy_loc l4
    call lp_staking::position_recipient_pid
    st_loc l9
    // @115
    copy_loc l9
    ld_const<address> 0
    eq
    br_false l13
    copy_loc l4
    // @120
    call lp_staking::position_owner
    move_loc l1
    neq
    br_true l14
    branch l15
    // @125
l14: move_loc l0
    pop
    ld_false
    ret
l15: move_loc l4
    // @130
    call lp_staking::position_shares
    move_loc l0
    borrow_field ReferenceGate, min_lp_stake
    read_ref
    cast_u128
    // @135
    lt
    br_true l16
    branch l17
l16: ld_false
    ret
    // @140
l17: ld_true
    ret
l13: move_loc l9
    call object::address_to_object<object::ObjectCore>
    call object::owner<object::ObjectCore>
    // @145
    move_loc l1
    neq
    br_true l18
    branch l15
l18: move_loc l0
    // @150
    pop
    ld_false
    ret
l8: move_loc l0
    pop
    // @155
    branch l17
l2: ld_false
    st_loc l6
    branch l19
l0: ld_false
    // @160
    st_loc l3
    branch l20

// Function definition at index 2
#[persistent] public fun is_open_for(l0: &option::Option<ReferenceGate>, l1: address, l2: bool, l3: bool, l4: address): bool
    copy_loc l0
    call option::is_none<ReferenceGate>
    br_false l0
    move_loc l0
    pop
    // @5
    ld_true
    ret
l0: move_loc l0
    call option::borrow<ReferenceGate>
    move_loc l1
    // @10
    move_loc l2
    move_loc l3
    move_loc l4
    call check
    ret

// Function definition at index 3
#[persistent] public fun max_token_balance(l0: &ReferenceGate): u64
    move_loc l0
    borrow_field ReferenceGate, max_token_balance
    read_ref
    ret

// Function definition at index 4
#[persistent] public fun min_lp_stake(l0: &ReferenceGate): u64
    move_loc l0
    borrow_field ReferenceGate, min_lp_stake
    read_ref
    ret

// Function definition at index 5
#[persistent] public fun min_token_balance(l0: &ReferenceGate): u64
    move_loc l0
    borrow_field ReferenceGate, min_token_balance
    read_ref
    ret

// Function definition at index 6
#[persistent] public fun target_pid(l0: &ReferenceGate): address
    move_loc l0
    borrow_field ReferenceGate, target_pid
    read_ref
    ret
```

---

## Module `history` (2934 bytes)

`sha3_256: 19bf456b6b20991542b8ad6f953e260cdf2dfe32d5f0556acedec284bf5eaee0`

### ABI surface

**Structs** (3):

- `Entry` `[copy+drop+store]` {verb:u8, timestamp_secs:u64, target:0x1::option::Option<address>, payload:vector<u8>, asset:0x1::option::Option<address>}
- `HistoryChunk` `[key]` {entries:vector<0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::history::Entry>, sealed:bool}
- `HistoryLog` `[key]` {head_chunk:address, sealed_chunks:vector<address>, entry_count:u64, total_bytes:u64, head_chunk_bytes:u64, mint_count:u64, spark_count:u64, voice_count:u64, echo_count:u64, remix_count:u64, press_count:u64, sync_count:u64}

**Public fns** (18):

- [view] `history_exists(address) → bool`
- [view] `chunk_entries_count(address) → u64`
- [view] `chunk_entry_at(address,u64) → u8,u64,0x1::option::Option<address>,vector<u8>,0x1::option::Option<address>`
- [view] `chunk_is_sealed(address) → bool`
- [view] `chunk_rotate_threshold() → u64`
- [view] `count_verb(address,u8) → u64`
- [view] `head_chunk_addr(address) → address`
- [view] `max_payload_bytes() → u64`
- [view] `sealed_chunks_list(address) → vector<address>`
- [view] `total_bytes(address) → u64`
- [view] `total_entries(address) → u64`
- [view] `verb_echo() → u8`
- [view] `verb_mint() → u8`
- [view] `verb_press() → u8`
- [view] `verb_remix() → u8`
- [view] `verb_spark() → u8`
- [view] `verb_sync() → u8`
- [view] `verb_voice() → u8`

**Friend fns** (2):

- `append(address,0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::history::Entry)`
- `new_entry(u8,u64,0x1::option::Option<address>,vector<u8>,0x1::option::Option<address>) → 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::history::Entry`

### MASM (disassembled bytecode)

```move
// Bytecode version v9
module 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::history
use 0x1::option
use 0x1::object
use 0x1::signer
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::profile
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::link
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::mint
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::press
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::pulse
struct Entry has copy + drop + store
  verb: u8
  timestamp_secs: u64
  target: option::Option<address>
  payload: vector<u8>
  asset: option::Option<address>

struct HistoryChunk has key
  entries: vector<Entry>
  sealed: bool

struct HistoryLog has key
  head_chunk: address
  sealed_chunks: vector<address>
  entry_count: u64
  total_bytes: u64
  head_chunk_bytes: u64
  mint_count: u64
  spark_count: u64
  voice_count: u64
  echo_count: u64
  remix_count: u64
  press_count: u64
  sync_count: u64

// Function definition at index 0
friend fun append(l0: address, l1: Entry) acquires HistoryChunk, HistoryLog
    local l2: u64
    local l3: &mut HistoryLog
    local l4: address
    local l5: &mut HistoryChunk
    local l6: object::ConstructorRef
    local l7: signer
    local l8: u8
    copy_loc l0
    call ensure_history_log
    borrow_loc l1
    borrow_field Entry, payload
    vec_len <u8>
    // @5
    ld_u64 64
    add
    st_loc l2
    copy_loc l0
    mut_borrow_global HistoryLog
    // @10
    st_loc l3
    copy_loc l3
    borrow_field HistoryLog, head_chunk_bytes
    read_ref
    copy_loc l2
    // @15
    add
    ld_u64 30000
    gt
    br_true l0
    branch l1
    // @20
l0: copy_loc l3
    borrow_field HistoryLog, head_chunk
    read_ref
    st_loc l4
    copy_loc l4
    // @25
    mut_borrow_global HistoryChunk
    st_loc l5
    ld_true
    move_loc l5
    mut_borrow_field HistoryChunk, sealed
    // @30
    write_ref
    copy_loc l3
    mut_borrow_field HistoryLog, sealed_chunks
    move_loc l4
    vec_push_back <address>
    // @35
    move_loc l0
    call object::create_object
    st_loc l6
    borrow_loc l6
    call object::generate_signer
    // @40
    st_loc l7
    borrow_loc l7
    call signer::address_of
    borrow_loc l7
    vec_pack <Entry>, 0
    // @45
    ld_false
    pack HistoryChunk
    move_to HistoryChunk
    copy_loc l3
    mut_borrow_field HistoryLog, head_chunk
    // @50
    write_ref
    ld_u64 0
    copy_loc l3
    mut_borrow_field HistoryLog, head_chunk_bytes
    write_ref
    // @55
l1: borrow_loc l1
    borrow_field Entry, verb
    read_ref
    st_loc l8
    copy_loc l3
    // @60
    borrow_field HistoryLog, head_chunk
    read_ref
    mut_borrow_global HistoryChunk
    mut_borrow_field HistoryChunk, entries
    move_loc l1
    // @65
    vec_push_back <Entry>
    copy_loc l3
    borrow_field HistoryLog, entry_count
    read_ref
    ld_u64 1
    // @70
    add
    copy_loc l3
    mut_borrow_field HistoryLog, entry_count
    write_ref
    copy_loc l3
    // @75
    borrow_field HistoryLog, total_bytes
    read_ref
    copy_loc l2
    add
    copy_loc l3
    // @80
    mut_borrow_field HistoryLog, total_bytes
    write_ref
    copy_loc l3
    borrow_field HistoryLog, head_chunk_bytes
    read_ref
    // @85
    move_loc l2
    add
    copy_loc l3
    mut_borrow_field HistoryLog, head_chunk_bytes
    write_ref
    // @90
    copy_loc l8
    ld_u8 0
    eq
    br_false l2
    copy_loc l3
    // @95
    borrow_field HistoryLog, mint_count
    read_ref
    ld_u64 1
    add
    move_loc l3
    // @100
    mut_borrow_field HistoryLog, mint_count
    write_ref
    ret
l2: copy_loc l8
    ld_u8 1
    // @105
    eq
    br_false l3
    copy_loc l3
    borrow_field HistoryLog, spark_count
    read_ref
    // @110
    ld_u64 1
    add
    move_loc l3
    mut_borrow_field HistoryLog, spark_count
    write_ref
    // @115
    ret
l3: copy_loc l8
    ld_u8 2
    eq
    br_false l4
    // @120
    copy_loc l3
    borrow_field HistoryLog, voice_count
    read_ref
    ld_u64 1
    add
    // @125
    move_loc l3
    mut_borrow_field HistoryLog, voice_count
    write_ref
    ret
l4: copy_loc l8
    // @130
    ld_u8 3
    eq
    br_false l5
    copy_loc l3
    borrow_field HistoryLog, echo_count
    // @135
    read_ref
    ld_u64 1
    add
    move_loc l3
    mut_borrow_field HistoryLog, echo_count
    // @140
    write_ref
    ret
l5: copy_loc l8
    ld_u8 4
    eq
    // @145
    br_false l6
    copy_loc l3
    borrow_field HistoryLog, remix_count
    read_ref
    ld_u64 1
    // @150
    add
    move_loc l3
    mut_borrow_field HistoryLog, remix_count
    write_ref
    ret
    // @155
l6: copy_loc l8
    ld_u8 5
    eq
    br_false l7
    copy_loc l3
    // @160
    borrow_field HistoryLog, press_count
    read_ref
    ld_u64 1
    add
    move_loc l3
    // @165
    mut_borrow_field HistoryLog, press_count
    write_ref
    ret
l7: move_loc l8
    ld_u8 6
    // @170
    eq
    br_false l8
    copy_loc l3
    borrow_field HistoryLog, sync_count
    read_ref
    // @175
    ld_u64 1
    add
    move_loc l3
    mut_borrow_field HistoryLog, sync_count
    write_ref
    // @180
    ret
l8: move_loc l3
    pop
    ret

// Function definition at index 1
#[persistent] public fun history_exists(l0: address): bool
    move_loc l0
    exists HistoryLog
    ret

// Function definition at index 2
#[persistent] public fun chunk_entries_count(l0: address): u64 acquires HistoryChunk
    copy_loc l0
    exists HistoryChunk
    br_true l0
    ld_u64 0
    ret
    // @5
l0: move_loc l0
    borrow_global HistoryChunk
    borrow_field HistoryChunk, entries
    vec_len <Entry>
    ret

// Function definition at index 3
#[persistent] public fun chunk_entry_at(l0: address, l1: u64): (u8, u64, option::Option<address>, vector<u8>, option::Option<address>) acquires HistoryChunk
    local l2: &Entry
    copy_loc l0
    exists HistoryChunk
    br_false l0
    move_loc l0
    borrow_global HistoryChunk
    // @5
    borrow_field HistoryChunk, entries
    move_loc l1
    vec_borrow <Entry>
    st_loc l2
    copy_loc l2
    // @10
    borrow_field Entry, verb
    read_ref
    copy_loc l2
    borrow_field Entry, timestamp_secs
    read_ref
    // @15
    copy_loc l2
    borrow_field Entry, target
    read_ref
    copy_loc l2
    borrow_field Entry, payload
    // @20
    read_ref
    move_loc l2
    borrow_field Entry, asset
    read_ref
    ret
    // @25
l0: ld_u64 4
    abort

// Function definition at index 4
#[persistent] public fun chunk_is_sealed(l0: address): bool acquires HistoryChunk
    copy_loc l0
    exists HistoryChunk
    br_true l0
    ld_false
    ret
    // @5
l0: move_loc l0
    borrow_global HistoryChunk
    borrow_field HistoryChunk, sealed
    read_ref
    ret

// Function definition at index 5
#[persistent] public fun chunk_rotate_threshold(): u64
    ld_u64 30000
    ret

// Function definition at index 6
#[persistent] public fun count_verb(l0: address, l1: u8): u64 acquires HistoryLog
    local l2: &HistoryLog
    copy_loc l0
    exists HistoryLog
    br_true l0
    ld_u64 0
    ret
    // @5
l0: move_loc l0
    borrow_global HistoryLog
    st_loc l2
    copy_loc l1
    ld_u8 0
    // @10
    eq
    br_false l1
    move_loc l2
    borrow_field HistoryLog, mint_count
    read_ref
    // @15
    ret
l1: copy_loc l1
    ld_u8 1
    eq
    br_false l2
    // @20
    move_loc l2
    borrow_field HistoryLog, spark_count
    read_ref
    ret
l2: copy_loc l1
    // @25
    ld_u8 2
    eq
    br_false l3
    move_loc l2
    borrow_field HistoryLog, voice_count
    // @30
    read_ref
    ret
l3: copy_loc l1
    ld_u8 3
    eq
    // @35
    br_false l4
    move_loc l2
    borrow_field HistoryLog, echo_count
    read_ref
    ret
    // @40
l4: copy_loc l1
    ld_u8 4
    eq
    br_false l5
    move_loc l2
    // @45
    borrow_field HistoryLog, remix_count
    read_ref
    ret
l5: copy_loc l1
    ld_u8 5
    // @50
    eq
    br_false l6
    move_loc l2
    borrow_field HistoryLog, press_count
    read_ref
    // @55
    ret
l6: move_loc l1
    ld_u8 6
    eq
    br_false l7
    // @60
    move_loc l2
    borrow_field HistoryLog, sync_count
    read_ref
    ret
l7: move_loc l2
    // @65
    pop
    ld_u64 0
    ret

// Function definition at index 7
fun ensure_history_log(l0: address)
    local l1: signer
    local l2: object::ConstructorRef
    local l3: signer
    local l4: &signer
    local l5: HistoryLog
    copy_loc l0
    exists HistoryLog
    br_false l0
    ret
l0: copy_loc l0
    // @5
    call profile::derive_pid_signer
    st_loc l1
    move_loc l0
    call object::create_object
    st_loc l2
    // @10
    borrow_loc l2
    call object::generate_signer
    st_loc l3
    borrow_loc l3
    call signer::address_of
    // @15
    borrow_loc l3
    vec_pack <Entry>, 0
    ld_false
    pack HistoryChunk
    move_to HistoryChunk
    // @20
    borrow_loc l1
    st_loc l4
    vec_pack <address>, 0
    ld_u64 0
    ld_u64 0
    // @25
    ld_u64 0
    ld_u64 0
    ld_u64 0
    ld_u64 0
    ld_u64 0
    // @30
    ld_u64 0
    ld_u64 0
    ld_u64 0
    pack HistoryLog
    st_loc l5
    // @35
    move_loc l4
    move_loc l5
    move_to HistoryLog
    ret

// Function definition at index 8
#[persistent] public fun head_chunk_addr(l0: address): address acquires HistoryLog
    copy_loc l0
    exists HistoryLog
    br_false l0
    move_loc l0
    borrow_global HistoryLog
    // @5
    borrow_field HistoryLog, head_chunk
    read_ref
    ret
l0: ld_u64 3
    abort

// Function definition at index 9
#[persistent] public fun max_payload_bytes(): u64
    ld_u64 12000
    ret

// Function definition at index 10
friend fun new_entry(l0: u8, l1: u64, l2: option::Option<address>, l3: vector<u8>, l4: option::Option<address>): Entry
    copy_loc l0
    ld_u8 6
    le
    br_false l0
    borrow_loc l3
    // @5
    vec_len <u8>
    ld_u64 12000
    le
    br_false l1
    move_loc l0
    // @10
    move_loc l1
    move_loc l2
    move_loc l3
    move_loc l4
    pack Entry
    // @15
    ret
l1: ld_u64 1
    abort
l0: ld_u64 5
    abort

// Function definition at index 11
#[persistent] public fun sealed_chunks_list(l0: address): vector<address> acquires HistoryLog
    copy_loc l0
    exists HistoryLog
    br_true l0
    vec_pack <address>, 0
    ret
    // @5
l0: move_loc l0
    borrow_global HistoryLog
    borrow_field HistoryLog, sealed_chunks
    read_ref
    ret

// Function definition at index 12
#[persistent] public fun total_bytes(l0: address): u64 acquires HistoryLog
    copy_loc l0
    exists HistoryLog
    br_true l0
    ld_u64 0
    ret
    // @5
l0: move_loc l0
    borrow_global HistoryLog
    borrow_field HistoryLog, total_bytes
    read_ref
    ret

// Function definition at index 13
#[persistent] public fun total_entries(l0: address): u64 acquires HistoryLog
    copy_loc l0
    exists HistoryLog
    br_true l0
    ld_u64 0
    ret
    // @5
l0: move_loc l0
    borrow_global HistoryLog
    borrow_field HistoryLog, entry_count
    read_ref
    ret

// Function definition at index 14
#[persistent] public fun verb_echo(): u8
    ld_u8 3
    ret

// Function definition at index 15
#[persistent] public fun verb_mint(): u8
    ld_u8 0
    ret

// Function definition at index 16
#[persistent] public fun verb_press(): u8
    ld_u8 5
    ret

// Function definition at index 17
#[persistent] public fun verb_remix(): u8
    ld_u8 4
    ret

// Function definition at index 18
#[persistent] public fun verb_spark(): u8
    ld_u8 1
    ret

// Function definition at index 19
#[persistent] public fun verb_sync(): u8
    ld_u8 6
    ret

// Function definition at index 20
#[persistent] public fun verb_voice(): u8
    ld_u8 2
    ret
```

---

## Module `link` (1981 bytes)

`sha3_256: ab14968a728d3a17f8e95677fbe3b905e5d9e589c7728077ab2de3b4b1df9133`

### ABI surface

**Structs** (2):

- `LinkEvent` `[drop+store]` {actor_pid:address, target_pid:address, link_kind:u8, state:u8, timestamp_secs:u64}
- `PidSyncSet` `[key]` {syncs:0x1::smart_table::SmartTable<address, bool>, sync_count:u64, synced_by_count:u64}

**Public fns** (8):

- [view] `sync_count(address) → u64`
- [view] `is_synced(address,address) → bool`
- [view] `state_add() → u8`
- [view] `state_remove() → u8`
- [entry] `sync(&signer,address,address)`
- [view] `sync_kind() → u8`
- [view] `synced_by_count(address) → u64`
- [entry] `unsync(&signer,address)`

### MASM (disassembled bytecode)

```move
// Bytecode version v9
module 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::link
use 0x1::smart_table
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::profile
use 0x1::signer
use 0x1::option
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::reference_gate
use 0x1::timestamp
use 0x1::bcs
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::history
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::mint
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::giveaway
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::press
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::pulse
struct LinkEvent has drop + store
  actor_pid: address
  target_pid: address
  link_kind: u8
  state: u8
  timestamp_secs: u64

struct PidSyncSet has key
  syncs: smart_table::SmartTable<address, bool>
  sync_count: u64
  synced_by_count: u64

// Function definition at index 0
#[persistent] public fun sync_count(l0: address): u64 acquires PidSyncSet
    copy_loc l0
    exists PidSyncSet
    br_true l0
    ld_u64 0
    ret
    // @5
l0: move_loc l0
    borrow_global PidSyncSet
    borrow_field PidSyncSet, sync_count
    read_ref
    ret

// Function definition at index 1
fun ensure_sync_set(l0: address)
    local l1: signer
    copy_loc l0
    exists PidSyncSet
    br_true l0
    move_loc l0
    call profile::derive_pid_signer
    // @5
    st_loc l1
    borrow_loc l1
    call smart_table::new<address, bool>
    ld_u64 0
    ld_u64 0
    // @10
    pack PidSyncSet
    move_to PidSyncSet
    ret
l0: ret

// Function definition at index 2
#[persistent] public fun is_synced(l0: address, l1: address): bool acquires PidSyncSet
    copy_loc l0
    exists PidSyncSet
    br_true l0
    ld_false
    ret
    // @5
l0: move_loc l0
    borrow_global PidSyncSet
    borrow_field PidSyncSet, syncs
    move_loc l1
    call smart_table::contains<address, bool>
    // @10
    ret

// Function definition at index 3
#[persistent] public fun state_add(): u8
    ld_u8 1
    ret

// Function definition at index 4
#[persistent] public fun state_remove(): u8
    ld_u8 2
    ret

// Function definition at index 5
#[persistent] entry public fun sync(l0: &signer, l1: address, l2: address) acquires PidSyncSet
    local l3: address
    local l4: address
    local l5: option::Option<reference_gate::ReferenceGate>
    local l6: &mut PidSyncSet
    local l7: &mut PidSyncSet
    local l8: u64
    local l9: LinkEvent
    local l10: vector<u8>
    move_loc l0
    call signer::address_of
    st_loc l3
    copy_loc l3
    call profile::derive_pid_address
    // @5
    st_loc l4
    copy_loc l4
    call profile::assert_pid_exists
    copy_loc l1
    call profile::assert_pid_exists
    // @10
    copy_loc l4
    copy_loc l1
    neq
    br_false l0
    copy_loc l1
    // @15
    call profile::get_sync_gate
    st_loc l5
    borrow_loc l5
    move_loc l3
    ld_false
    // @20
    ld_true
    move_loc l2
    call reference_gate::is_open_for
    br_false l1
    copy_loc l4
    // @25
    call ensure_sync_set
    copy_loc l1
    call ensure_sync_set
    copy_loc l4
    mut_borrow_global PidSyncSet
    // @30
    st_loc l6
    copy_loc l6
    borrow_field PidSyncSet, syncs
    copy_loc l1
    call smart_table::contains<address, bool>
    // @35
    br_true l2
    copy_loc l6
    mut_borrow_field PidSyncSet, syncs
    copy_loc l1
    ld_true
    // @40
    call smart_table::add<address, bool>
    copy_loc l6
    borrow_field PidSyncSet, sync_count
    read_ref
    ld_u64 1
    // @45
    add
    move_loc l6
    mut_borrow_field PidSyncSet, sync_count
    write_ref
    copy_loc l1
    // @50
    mut_borrow_global PidSyncSet
    st_loc l7
    copy_loc l7
    borrow_field PidSyncSet, synced_by_count
    read_ref
    // @55
    ld_u64 1
    add
    move_loc l7
    mut_borrow_field PidSyncSet, synced_by_count
    write_ref
    // @60
    call timestamp::now_seconds
    st_loc l8
    copy_loc l4
    copy_loc l1
    ld_u8 1
    // @65
    ld_u8 1
    copy_loc l8
    pack LinkEvent
    st_loc l9
    borrow_loc l9
    // @70
    call bcs::to_bytes<LinkEvent>
    st_loc l10
    move_loc l4
    call history::verb_sync
    move_loc l8
    // @75
    move_loc l1
    call option::some<address>
    move_loc l10
    call option::none<address>
    call history::new_entry
    // @80
    call history::append
    ret
l2: move_loc l6
    pop
    ld_u64 4
    // @85
    abort
l1: ld_u64 3
    abort
l0: ld_u64 6
    abort

// Function definition at index 6
#[persistent] public fun sync_kind(): u8
    ld_u8 1
    ret

// Function definition at index 7
#[persistent] public fun synced_by_count(l0: address): u64 acquires PidSyncSet
    copy_loc l0
    exists PidSyncSet
    br_true l0
    ld_u64 0
    ret
    // @5
l0: move_loc l0
    borrow_global PidSyncSet
    borrow_field PidSyncSet, synced_by_count
    read_ref
    ret

// Function definition at index 8
#[persistent] entry public fun unsync(l0: &signer, l1: address) acquires PidSyncSet
    local l2: address
    local l3: &mut PidSyncSet
    local l4: &mut PidSyncSet
    local l5: u64
    local l6: LinkEvent
    local l7: vector<u8>
    move_loc l0
    call signer::address_of
    call profile::derive_pid_address
    st_loc l2
    copy_loc l2
    // @5
    exists PidSyncSet
    br_false l0
    copy_loc l2
    mut_borrow_global PidSyncSet
    st_loc l3
    // @10
    copy_loc l3
    borrow_field PidSyncSet, syncs
    copy_loc l1
    call smart_table::contains<address, bool>
    br_false l1
    // @15
    copy_loc l3
    mut_borrow_field PidSyncSet, syncs
    copy_loc l1
    call smart_table::remove<address, bool>
    pop
    // @20
    copy_loc l3
    borrow_field PidSyncSet, sync_count
    read_ref
    ld_u64 1
    sub
    // @25
    move_loc l3
    mut_borrow_field PidSyncSet, sync_count
    write_ref
    copy_loc l1
    exists PidSyncSet
    // @30
    br_true l2
    branch l3
l2: copy_loc l1
    mut_borrow_global PidSyncSet
    st_loc l4
    // @35
    copy_loc l4
    borrow_field PidSyncSet, synced_by_count
    read_ref
    ld_u64 0
    gt
    // @40
    br_false l4
    copy_loc l4
    borrow_field PidSyncSet, synced_by_count
    read_ref
    ld_u64 1
    // @45
    sub
    move_loc l4
    mut_borrow_field PidSyncSet, synced_by_count
    write_ref
l3: call timestamp::now_seconds
    // @50
    st_loc l5
    copy_loc l2
    copy_loc l1
    ld_u8 1
    ld_u8 2
    // @55
    copy_loc l5
    pack LinkEvent
    st_loc l6
    borrow_loc l6
    call bcs::to_bytes<LinkEvent>
    // @60
    st_loc l7
    move_loc l2
    call history::verb_sync
    move_loc l5
    move_loc l1
    // @65
    call option::some<address>
    move_loc l7
    call option::none<address>
    call history::new_entry
    call history::append
    // @70
    ret
l4: move_loc l4
    pop
    branch l3
l1: move_loc l3
    // @75
    pop
    ld_u64 5
    abort
l0: ld_u64 7
    abort
```

---

## Module `mint` (4704 bytes)

`sha3_256: 2c4f9f3e89d5070189eec6bbaeb42b5d5ed32324c7625480d271ba00c74b609a`

### ABI surface

**Structs** (8):

- `MintEvent` `[drop+store]` {author:address, seq:u64, timestamp_us:u64, content_kind:u8, content_text:vector<u8>, media:0x1::option::Option<0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::mint::MintMedia>, parent_mint_id:0x1::option::Option<0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::mint::MintId>, root_mint_id:0x1::option::Option<0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::mint::MintId>, quote_mint_id:0x1::option::Option<0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::mint::MintId>, mentions:vector<address>, tags:vector<vector<u8>>, tickers:vector<address>, tips:vector<0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::mint::Tip>}
- `MintExtras` `[store]` {gate:0x1::option::Option<0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::reference_gate::ReferenceGate>}
- `MintId` `[copy+drop+store]` {author:address, seq:u64}
- `MintMedia` `[copy+drop+store]` {kind:u8, mime:u8, inline_data:vector<u8>, ref_backend:u8, ref_blob_id:vector<u8>, ref_hash:vector<u8>}
- `PidMintExtras` `[key]` {extras:0x1::smart_table::SmartTable<u64, 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::mint::MintExtras>}
- `PidMintMeta` `[key]` {next_seq:u64, mint_count:u64}
- `Tip` `[copy+drop+store]` {recipient:address, token_metadata:address, amount:u64}
- `TipExecuted` `[drop+store]` {from_pid:address, to_addr:address, token_metadata:address, amount:u64, mint_seq:u64, timestamp_secs:u64}

**Public fns** (10):

- [view] `mint_count(address) → u64`
- [entry] `attach_mint_gate(&signer,u64,address,u64,u64,u64)`
- [view] `content_text_max_bytes() → u64`
- [entry] `create_mint(&signer,u8,vector<u8>,u8,u8,vector<u8>,u8,vector<u8>,vector<u8>,address,u64,bool,address,u64,bool,vector<address>,vector<vector<u8>>,vector<address>,vector<address>,vector<address>,vector<u64>,address,bool)`
- [view] `media_inline_max_bytes() → u64`
- [view] `mentions_max() → u64`
- [view] `next_seq(address) → u64`
- [view] `tags_max() → u64`
- [view] `tickers_max() → u64`
- [view] `tips_max() → u64`

**Friend fns** (1):

- `get_mint_gate(address,u64) → 0x1::option::Option<0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::reference_gate::ReferenceGate>`

### MASM (disassembled bytecode)

```move
// Bytecode version v9
module 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::mint
use 0x1::option
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::reference_gate
use 0x1::smart_table
use 0x1::signer
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::profile
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::assets
use 0x1::bcs
use 0x1::timestamp
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::history
use 0x1::fungible_asset
use 0x1::object
use 0x1::primary_fungible_store
use 0x1::event
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::factory
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::giveaway
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::press
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::pulse
struct MintEvent has drop + store
  author: address
  seq: u64
  timestamp_us: u64
  content_kind: u8
  content_text: vector<u8>
  media: option::Option<MintMedia>
  parent_mint_id: option::Option<MintId>
  root_mint_id: option::Option<MintId>
  quote_mint_id: option::Option<MintId>
  mentions: vector<address>
  tags: vector<vector<u8>>
  tickers: vector<address>
  tips: vector<Tip>

struct MintExtras has store
  gate: option::Option<reference_gate::ReferenceGate>

struct MintId has copy + drop + store
  author: address
  seq: u64

struct MintMedia has copy + drop + store
  kind: u8
  mime: u8
  inline_data: vector<u8>
  ref_backend: u8
  ref_blob_id: vector<u8>
  ref_hash: vector<u8>

struct PidMintExtras has key
  extras: smart_table::SmartTable<u64, MintExtras>

struct PidMintMeta has key
  next_seq: u64
  mint_count: u64

struct Tip has copy + drop + store
  recipient: address
  token_metadata: address
  amount: u64

struct TipExecuted has drop + store
  from_pid: address
  to_addr: address
  token_metadata: address
  amount: u64
  mint_seq: u64
  timestamp_secs: u64

// Function definition at index 0
fun assert_valid_mime(l0: u8)
    local l1: bool
    local l2: bool
    local l3: bool
    local l4: bool
    copy_loc l0
    ld_u8 1
    eq
    br_false l0
    ld_true
    // @5
    st_loc l1
l8: move_loc l1
    br_false l1
    ld_true
    st_loc l2
    // @10
l7: move_loc l2
    br_false l2
    ld_true
    st_loc l3
l6: move_loc l3
    // @15
    br_false l3
    ld_true
    st_loc l4
l5: move_loc l4
    br_false l4
    // @20
    ret
l4: ld_u64 13
    abort
l3: move_loc l0
    ld_u8 5
    // @25
    eq
    st_loc l4
    branch l5
l2: copy_loc l0
    ld_u8 4
    // @30
    eq
    st_loc l3
    branch l6
l1: copy_loc l0
    ld_u8 3
    // @35
    eq
    st_loc l2
    branch l7
l0: copy_loc l0
    ld_u8 2
    // @40
    eq
    st_loc l1
    branch l8

// Function definition at index 1
#[persistent] public fun mint_count(l0: address): u64 acquires PidMintMeta
    copy_loc l0
    exists PidMintMeta
    br_true l0
    ld_u64 0
    ret
    // @5
l0: move_loc l0
    borrow_global PidMintMeta
    borrow_field PidMintMeta, mint_count
    read_ref
    ret

// Function definition at index 2
fun assert_valid_backend(l0: u8)
    local l1: bool
    local l2: bool
    local l3: bool
    copy_loc l0
    ld_u8 0
    eq
    br_false l0
    ld_true
    // @5
    st_loc l1
l6: move_loc l1
    br_false l1
    ld_true
    st_loc l2
    // @10
l5: move_loc l2
    br_false l2
    ld_true
    st_loc l3
l4: move_loc l3
    // @15
    br_false l3
    ret
l3: ld_u64 14
    abort
l2: move_loc l0
    // @20
    ld_u8 3
    eq
    st_loc l3
    branch l4
l1: copy_loc l0
    // @25
    ld_u8 2
    eq
    st_loc l2
    branch l5
l0: copy_loc l0
    // @30
    ld_u8 1
    eq
    st_loc l1
    branch l6

// Function definition at index 3
#[persistent] entry public fun attach_mint_gate(l0: &signer, l1: u64, l2: address, l3: u64, l4: u64, l5: u64) acquires PidMintExtras, PidMintMeta
    local l6: address
    local l7: reference_gate::ReferenceGate
    local l8: &mut PidMintExtras
    local l9: &mut MintExtras
    move_loc l0
    call signer::address_of
    call profile::derive_pid_address
    st_loc l6
    copy_loc l6
    // @5
    call profile::assert_pid_exists
    copy_loc l6
    call ensure_mint_storage
    copy_loc l1
    copy_loc l6
    // @10
    call next_seq
    lt
    br_false l0
    move_loc l2
    move_loc l3
    // @15
    move_loc l4
    move_loc l5
    call reference_gate::new
    st_loc l7
    move_loc l6
    // @20
    mut_borrow_global PidMintExtras
    st_loc l8
    copy_loc l8
    borrow_field PidMintExtras, extras
    copy_loc l1
    // @25
    call smart_table::contains<u64, MintExtras>
    br_false l1
    move_loc l8
    mut_borrow_field PidMintExtras, extras
    move_loc l1
    // @30
    call smart_table::borrow_mut<u64, MintExtras>
    st_loc l9
    move_loc l7
    call option::some<reference_gate::ReferenceGate>
    move_loc l9
    // @35
    mut_borrow_field MintExtras, gate
    write_ref
    ret
l1: move_loc l8
    mut_borrow_field PidMintExtras, extras
    // @40
    move_loc l1
    move_loc l7
    call option::some<reference_gate::ReferenceGate>
    pack MintExtras
    call smart_table::add<u64, MintExtras>
    // @45
    ret
l0: ld_u64 20
    abort

// Function definition at index 4
#[persistent] public fun content_text_max_bytes(): u64
    ld_u64 333
    ret

// Function definition at index 5
#[persistent] entry public fun create_mint(l0: &signer, l1: u8, l2: vector<u8>, l3: u8, l4: u8, l5: vector<u8>, l6: u8, l7: vector<u8>, l8: vector<u8>, l9: address, l10: u64, l11: bool, l12: address, l13: u64, l14: bool, l15: vector<address>, l16: vector<vector<u8>>, l17: vector<address>, l18: vector<address>, l19: vector<address>, l20: vector<u64>, l21: address, l22: bool) acquires PidMintMeta
    local l23: address
    local l24: u8
    local l25: option::Option<MintMedia>
    local l26: bool
    local l27: option::Option<MintId>
    local l28: option::Option<MintId>
    local l29: option::Option<MintId>
    local l30: u64
    local l31: &mut PidMintMeta
    local l32: u64
    local l33: vector<Tip>
    local l34: u64
    local l35: MintEvent
    local l36: option::Option<address>
    local l37: option::Option<address>
    local l38: vector<u8>
    copy_loc l0
    call signer::address_of
    call profile::derive_pid_address
    st_loc l23
    copy_loc l23
    // @5
    call profile::assert_pid_exists
    copy_loc l23
    call ensure_mint_storage
    borrow_loc l2
    vec_len <u8>
    // @10
    ld_u64 333
    le
    br_false l0
    copy_loc l22
    br_false l1
    // @15
    copy_loc l21
    call assets::is_sealed
    br_false l2
    copy_loc l21
    call assets::mime_of
    // @20
    st_loc l24
    copy_loc l24
    call assert_valid_mime
    ld_u8 2
    move_loc l24
    // @25
    vec_pack <u8>, 0
    ld_u8 3
    borrow_loc l21
    call bcs::to_bytes<address>
    vec_pack <u8>, 0
    // @30
    pack MintMedia
    call option::some<MintMedia>
    st_loc l25
l23: copy_loc l11
    br_false l3
    // @35
    copy_loc l14
    st_loc l26
l21: move_loc l26
    br_true l4
    copy_loc l11
    // @40
    br_false l5
    copy_loc l9
    move_loc l10
    pack MintId
    call option::some<MintId>
    // @45
    st_loc l27
l20: copy_loc l14
    br_false l6
    copy_loc l12
    move_loc l13
    // @50
    pack MintId
    call option::some<MintId>
    st_loc l28
l19: call option::none<MintId>
    st_loc l29
    // @55
    borrow_loc l15
    vec_len <address>
    ld_u64 10
    le
    br_false l7
    // @60
    borrow_loc l16
    call validate_tags
    borrow_loc l17
    call validate_tickers
    borrow_loc l18
    // @65
    vec_len <address>
    st_loc l30
    copy_loc l30
    borrow_loc l19
    vec_len <address>
    // @70
    eq
    br_false l8
    copy_loc l30
    borrow_loc l20
    vec_len <u64>
    // @75
    eq
    br_false l9
    move_loc l30
    ld_u64 10
    le
    // @80
    br_false l10
    copy_loc l23
    mut_borrow_global PidMintMeta
    st_loc l31
    copy_loc l31
    // @85
    borrow_field PidMintMeta, next_seq
    read_ref
    st_loc l32
    copy_loc l32
    ld_u64 1
    // @90
    add
    copy_loc l31
    mut_borrow_field PidMintMeta, next_seq
    write_ref
    copy_loc l31
    // @95
    borrow_field PidMintMeta, mint_count
    read_ref
    ld_u64 1
    add
    move_loc l31
    // @100
    mut_borrow_field PidMintMeta, mint_count
    write_ref
    move_loc l0
    borrow_loc l18
    borrow_loc l19
    // @105
    borrow_loc l20
    copy_loc l32
    call execute_tips
    st_loc l33
    call timestamp::now_seconds
    // @110
    st_loc l34
    copy_loc l23
    move_loc l32
    copy_loc l34
    ld_u64 1000000
    // @115
    mul
    move_loc l1
    move_loc l2
    move_loc l25
    move_loc l27
    // @120
    move_loc l29
    move_loc l28
    move_loc l15
    move_loc l16
    move_loc l17
    // @125
    move_loc l33
    pack MintEvent
    st_loc l35
    copy_loc l11
    br_false l11
    // @130
    call history::verb_voice
    st_loc l24
l18: move_loc l11
    br_false l12
    move_loc l9
    // @135
    call option::some<address>
    st_loc l36
l16: move_loc l22
    br_false l13
    move_loc l21
    // @140
    call option::some<address>
    st_loc l37
l14: borrow_loc l35
    call bcs::to_bytes<MintEvent>
    st_loc l38
    // @145
    move_loc l23
    move_loc l24
    move_loc l34
    move_loc l36
    move_loc l38
    // @150
    move_loc l37
    call history::new_entry
    call history::append
    ret
l13: call option::none<address>
    // @155
    st_loc l37
    branch l14
l12: move_loc l14
    br_false l15
    move_loc l12
    // @160
    call option::some<address>
    st_loc l36
    branch l16
l15: call option::none<address>
    st_loc l36
    // @165
    branch l16
l11: copy_loc l14
    br_false l17
    call history::verb_remix
    st_loc l24
    // @170
    branch l18
l17: call history::verb_mint
    st_loc l24
    branch l18
l10: move_loc l0
    // @175
    pop
    ld_u64 12
    abort
l9: move_loc l0
    pop
    // @180
    ld_u64 12
    abort
l8: move_loc l0
    pop
    ld_u64 12
    // @185
    abort
l7: move_loc l0
    pop
    ld_u64 5
    abort
    // @190
l6: call option::none<MintId>
    st_loc l28
    branch l19
l5: call option::none<MintId>
    st_loc l27
    // @195
    branch l20
l4: move_loc l0
    pop
    ld_u64 2
    abort
    // @200
l3: ld_false
    st_loc l26
    branch l21
l2: move_loc l0
    pop
    // @205
    ld_u64 19
    abort
l1: copy_loc l3
    ld_u8 0
    eq
    // @210
    br_false l22
    call option::none<MintMedia>
    st_loc l25
    branch l23
l22: copy_loc l3
    // @215
    ld_u8 1
    eq
    br_false l24
    borrow_loc l5
    vec_len <u8>
    // @220
    ld_u64 8192
    le
    br_false l25
    copy_loc l4
    call assert_valid_mime
    // @225
    ld_u8 1
    move_loc l4
    move_loc l5
    ld_u8 0
    vec_pack <u8>, 0
    // @230
    vec_pack <u8>, 0
    pack MintMedia
    call option::some<MintMedia>
    st_loc l25
    branch l23
    // @235
l25: move_loc l0
    pop
    ld_u64 4
    abort
l24: move_loc l3
    // @240
    ld_u8 2
    eq
    br_false l26
    copy_loc l4
    call assert_valid_mime
    // @245
    copy_loc l6
    call assert_valid_backend
    ld_u8 2
    move_loc l4
    vec_pack <u8>, 0
    // @250
    move_loc l6
    move_loc l7
    move_loc l8
    pack MintMedia
    call option::some<MintMedia>
    // @255
    st_loc l25
    branch l23
l26: move_loc l0
    pop
    ld_u64 13
    // @260
    abort
l0: move_loc l0
    pop
    ld_u64 3
    abort

// Function definition at index 6
fun ensure_mint_storage(l0: address)
    local l1: signer
    local l2: signer
    copy_loc l0
    exists PidMintMeta
    br_false l0
    branch l1
l0: copy_loc l0
    // @5
    call profile::derive_pid_signer
    st_loc l1
    borrow_loc l1
    ld_u64 0
    ld_u64 0
    // @10
    pack PidMintMeta
    move_to PidMintMeta
l1: copy_loc l0
    exists PidMintExtras
    br_true l2
    // @15
    move_loc l0
    call profile::derive_pid_signer
    st_loc l2
    borrow_loc l2
    call smart_table::new<u64, MintExtras>
    // @20
    pack PidMintExtras
    move_to PidMintExtras
    ret
l2: ret

// Function definition at index 7
fun execute_tips(l0: &signer, l1: &vector<address>, l2: &vector<address>, l3: &vector<u64>, l4: u64): vector<Tip>
    local l5: vector<Tip>
    local l6: u64
    local l7: u64
    local l8: address
    local l9: address
    local l10: u64
    local l11: object::Object<fungible_asset::Metadata>
    local l12: fungible_asset::FungibleAsset
    vec_pack <Tip>, 0
    st_loc l5
    copy_loc l1
    vec_len <address>
    st_loc l6
    // @5
    ld_u64 0
    st_loc l7
l1: copy_loc l7
    copy_loc l6
    lt
    // @10
    br_false l0
    copy_loc l1
    copy_loc l7
    vec_borrow <address>
    read_ref
    // @15
    st_loc l8
    copy_loc l2
    copy_loc l7
    vec_borrow <address>
    read_ref
    // @20
    st_loc l9
    copy_loc l3
    copy_loc l7
    vec_borrow <u64>
    read_ref
    // @25
    st_loc l10
    copy_loc l9
    call object::address_to_object<fungible_asset::Metadata>
    st_loc l11
    copy_loc l0
    // @30
    move_loc l11
    copy_loc l10
    call primary_fungible_store::withdraw<fungible_asset::Metadata>
    st_loc l12
    copy_loc l8
    // @35
    move_loc l12
    call primary_fungible_store::deposit
    copy_loc l0
    call signer::address_of
    call profile::derive_pid_address
    // @40
    copy_loc l8
    copy_loc l9
    copy_loc l10
    copy_loc l4
    call timestamp::now_seconds
    // @45
    pack TipExecuted
    call event::emit<TipExecuted>
    mut_borrow_loc l5
    move_loc l8
    move_loc l9
    // @50
    move_loc l10
    pack Tip
    vec_push_back <Tip>
    move_loc l7
    ld_u64 1
    // @55
    add
    st_loc l7
    branch l1
l0: move_loc l0
    pop
    // @60
    move_loc l1
    pop
    move_loc l2
    pop
    move_loc l3
    // @65
    pop
    move_loc l5
    ret

// Function definition at index 8
friend fun get_mint_gate(l0: address, l1: u64): option::Option<reference_gate::ReferenceGate> acquires PidMintExtras
    local l2: &PidMintExtras
    copy_loc l0
    exists PidMintExtras
    br_true l0
    call option::none<reference_gate::ReferenceGate>
    ret
    // @5
l0: move_loc l0
    borrow_global PidMintExtras
    st_loc l2
    copy_loc l2
    borrow_field PidMintExtras, extras
    // @10
    copy_loc l1
    call smart_table::contains<u64, MintExtras>
    br_true l1
    move_loc l2
    pop
    // @15
    call option::none<reference_gate::ReferenceGate>
    ret
l1: move_loc l2
    borrow_field PidMintExtras, extras
    move_loc l1
    // @20
    call smart_table::borrow<u64, MintExtras>
    borrow_field MintExtras, gate
    read_ref
    ret

// Function definition at index 9
#[persistent] public fun media_inline_max_bytes(): u64
    ld_u64 8192
    ret

// Function definition at index 10
#[persistent] public fun mentions_max(): u64
    ld_u64 10
    ret

// Function definition at index 11
#[persistent] public fun next_seq(l0: address): u64 acquires PidMintMeta
    copy_loc l0
    exists PidMintMeta
    br_true l0
    ld_u64 0
    ret
    // @5
l0: move_loc l0
    borrow_global PidMintMeta
    borrow_field PidMintMeta, next_seq
    read_ref
    ret

// Function definition at index 12
#[persistent] public fun tags_max(): u64
    ld_u64 5
    ret

// Function definition at index 13
#[persistent] public fun tickers_max(): u64
    ld_u64 5
    ret

// Function definition at index 14
#[persistent] public fun tips_max(): u64
    ld_u64 10
    ret

// Function definition at index 15
fun validate_tags(l0: &vector<vector<u8>>)
    local l1: u64
    local l2: u64
    local l3: &vector<u8>
    local l4: u64
    local l5: u64
    local l6: u8
    local l7: bool
    local l8: bool
    local l9: bool
    copy_loc l0
    vec_len <vector<u8>>
    ld_u64 5
    le
    br_false l0
    // @5
    ld_u64 0
    st_loc l1
    copy_loc l0
    vec_len <vector<u8>>
    st_loc l2
    // @10
l14: copy_loc l1
    copy_loc l2
    lt
    br_false l1
    copy_loc l0
    // @15
    copy_loc l1
    vec_borrow <vector<u8>>
    st_loc l3
    copy_loc l3
    vec_len <u8>
    // @20
    st_loc l4
    copy_loc l4
    ld_u64 1
    ge
    br_false l2
    // @25
    copy_loc l4
    ld_u64 32
    le
    br_false l3
    ld_u64 0
    // @30
    st_loc l5
l9: copy_loc l5
    copy_loc l4
    lt
    br_false l4
    // @35
    copy_loc l3
    copy_loc l5
    vec_borrow <u8>
    read_ref
    st_loc l6
    // @40
    copy_loc l6
    ld_u8 97
    ge
    br_false l5
    copy_loc l6
    // @45
    ld_u8 122
    le
    st_loc l7
l13: move_loc l7
    br_false l6
    // @50
    ld_true
    st_loc l8
l12: move_loc l8
    br_false l7
    ld_true
    // @55
    st_loc l9
l10: move_loc l9
    br_false l8
    move_loc l5
    ld_u64 1
    // @60
    add
    st_loc l5
    branch l9
l8: move_loc l0
    pop
    // @65
    move_loc l3
    pop
    ld_u64 9
    abort
l7: move_loc l6
    // @70
    ld_u8 45
    eq
    st_loc l9
    branch l10
l6: copy_loc l6
    // @75
    ld_u8 48
    ge
    br_false l11
    copy_loc l6
    ld_u8 57
    // @80
    le
    st_loc l8
    branch l12
l11: ld_false
    st_loc l8
    // @85
    branch l12
l5: ld_false
    st_loc l7
    branch l13
l4: move_loc l3
    // @90
    pop
    move_loc l1
    ld_u64 1
    add
    st_loc l1
    // @95
    branch l14
l3: move_loc l0
    pop
    move_loc l3
    pop
    // @100
    ld_u64 8
    abort
l2: move_loc l0
    pop
    move_loc l3
    // @105
    pop
    ld_u64 7
    abort
l1: move_loc l0
    pop
    // @110
    ret
l0: move_loc l0
    pop
    ld_u64 6
    abort

// Function definition at index 16
fun validate_tickers(l0: &vector<address>)
    local l1: u64
    local l2: u64
    copy_loc l0
    vec_len <address>
    ld_u64 5
    le
    br_false l0
    // @5
    ld_u64 0
    st_loc l1
    copy_loc l0
    vec_len <address>
    st_loc l2
    // @10
l3: copy_loc l1
    copy_loc l2
    lt
    br_false l1
    copy_loc l0
    // @15
    copy_loc l1
    vec_borrow <address>
    read_ref
    call factory::is_factory_token
    br_false l2
    // @20
    move_loc l1
    ld_u64 1
    add
    st_loc l1
    branch l3
    // @25
l2: move_loc l0
    pop
    ld_u64 11
    abort
l1: move_loc l0
    // @30
    pop
    ret
l0: move_loc l0
    pop
    ld_u64 10
    // @35
    abort
```

---

## Module `giveaway` (4753 bytes)

`sha3_256: 946ef6e50d56488a4cc5e60d666ab88febefd77e2eb3f82707c796002075c570`

### ABI surface

**Structs** (5):

- `Giveaway` `[store+key]` {sponsor_pid:address, sponsor_wallet:address, kind:u8, deadline_secs:u64, fa_token_metadata:address, fa_amount_per_claim:u64, fa_total_budget:u64, nft_collection_addr:address, nft_addrs:vector<address>, claims_made:u64, follower_only:bool, nft_gate:0x1::option::Option<address>, lp_stake_gate:0x1::option::Option<address>, claimers:0x1::smart_table::SmartTable<address, bool>, extend_ref:0x1::object::ExtendRef}
- `GiveawayClaimed` `[drop+store]` {giveaway_addr:address, claimer_pid:address, claim_index:u64, timestamp_secs:u64}
- `GiveawayCreated` `[drop+store]` {sponsor_pid:address, mint_seq:u64, giveaway_addr:address, kind:u8, deadline_secs:u64, timestamp_secs:u64}
- `GiveawaySettled` `[drop+store]` {giveaway_addr:address, sponsor_pid:address, settler:address, refund_amount:u64, bounty_paid:u64, timestamp_secs:u64}
- `PidGiveawayStorage` `[key]` {giveaways:0x1::smart_table::SmartTable<u64, address>}

**Public fns** (11):

- [entry] `claim_giveaway(&signer,address,address,address)`
- [view] `claims_made(address) → u64`
- [entry] `create_fa_giveaway(&signer,u64,0x1::object::Object<0x1::fungible_asset::Metadata>,u64,u64,u64,bool,address,bool,address,bool)`
- [view] `deadline_secs(address) → u64`
- [entry] `create_nft_giveaway(&signer,u64,address,vector<address>,u64,bool,address,bool,address,bool)`
- [view] `giveaway_addr_for_mint(address,u64) → address`
- [view] `has_claimed(address,address) → bool`
- [view] `kind_fa() → u8`
- [view] `kind_nft() → u8`
- [view] `settle_bounty_bps() → u64`
- [entry] `settle_giveaway(&signer,address)`

### MASM (disassembled bytecode)

```move
// Bytecode version v9
module 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::giveaway
use 0x1::option
use 0x1::smart_table
use 0x1::object
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::link
use 0x4::token
use 0x4::collection
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::lp_staking
use 0x1::signer
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::profile
use 0x1::timestamp
use 0x1::fungible_asset
use 0x1::primary_fungible_store
use 0x1::event
use 0x1::vector
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::mint
struct Giveaway has store + key
  sponsor_pid: address
  sponsor_wallet: address
  kind: u8
  deadline_secs: u64
  fa_token_metadata: address
  fa_amount_per_claim: u64
  fa_total_budget: u64
  nft_collection_addr: address
  nft_addrs: vector<address>
  claims_made: u64
  follower_only: bool
  nft_gate: option::Option<address>
  lp_stake_gate: option::Option<address>
  claimers: smart_table::SmartTable<address, bool>
  extend_ref: object::ExtendRef

struct GiveawayClaimed has drop + store
  giveaway_addr: address
  claimer_pid: address
  claim_index: u64
  timestamp_secs: u64

struct GiveawayCreated has drop + store
  sponsor_pid: address
  mint_seq: u64
  giveaway_addr: address
  kind: u8
  deadline_secs: u64
  timestamp_secs: u64

struct GiveawaySettled has drop + store
  giveaway_addr: address
  sponsor_pid: address
  settler: address
  refund_amount: u64
  bounty_paid: u64
  timestamp_secs: u64

struct PidGiveawayStorage has key
  giveaways: smart_table::SmartTable<u64, address>

// Function definition at index 0
fun check_gates(l0: &Giveaway, l1: address, l2: address, l3: address, l4: address)
    local l5: object::Object<token::Token>
    local l6: object::Object<collection::Collection>
    local l7: address
    local l8: address
    copy_loc l0
    borrow_field Giveaway, follower_only
    read_ref
    br_true l0
    branch l1
    // @5
l0: move_loc l1
    copy_loc l0
    borrow_field Giveaway, sponsor_pid
    read_ref
    call link::is_synced
    // @10
    br_false l2
    branch l1
l1: copy_loc l0
    borrow_field Giveaway, nft_gate
    call option::is_some<address>
    // @15
    br_true l3
    branch l4
l3: copy_loc l0
    borrow_field Giveaway, nft_gate
    call option::borrow<address>
    // @20
    read_ref
    st_loc l1
    copy_loc l3
    ld_const<address> 0
    neq
    // @25
    br_false l5
    copy_loc l3
    call object::object_exists<token::Token>
    br_false l6
    move_loc l3
    // @30
    call object::address_to_object<token::Token>
    st_loc l5
    copy_loc l5
    call object::owner<token::Token>
    copy_loc l2
    // @35
    eq
    br_false l7
    move_loc l5
    call token::collection_object<token::Token>
    st_loc l6
    // @40
    borrow_loc l6
    call object::object_address<collection::Collection>
    move_loc l1
    eq
    br_false l8
    // @45
    branch l4
l4: copy_loc l0
    borrow_field Giveaway, lp_stake_gate
    call option::is_some<address>
    br_false l9
    // @50
    move_loc l0
    borrow_field Giveaway, lp_stake_gate
    call option::borrow<address>
    read_ref
    st_loc l7
    // @55
    copy_loc l4
    ld_const<address> 0
    neq
    br_false l10
    copy_loc l4
    // @60
    call lp_staking::has_position
    br_false l11
    copy_loc l4
    call lp_staking::position_pool
    move_loc l7
    // @65
    eq
    br_false l12
    copy_loc l4
    call lp_staking::position_recipient_pid
    st_loc l8
    // @70
    copy_loc l8
    ld_const<address> 0
    eq
    br_false l13
    copy_loc l4
    // @75
    call lp_staking::position_owner
    move_loc l2
    eq
    br_false l14
    branch l15
    // @80
l15: move_loc l4
    call lp_staking::position_shares
    ld_u128 0
    gt
    br_false l16
    // @85
    ret
l16: ld_u64 7
    abort
l14: ld_u64 7
    abort
    // @90
l13: move_loc l8
    call object::address_to_object<object::ObjectCore>
    call object::owner<object::ObjectCore>
    move_loc l2
    eq
    // @95
    br_false l17
    branch l15
l17: ld_u64 7
    abort
l12: ld_u64 7
    // @100
    abort
l11: ld_u64 7
    abort
l10: ld_u64 7
    abort
    // @105
l9: move_loc l0
    pop
    ret
l8: move_loc l0
    pop
    // @110
    ld_u64 6
    abort
l7: move_loc l0
    pop
    ld_u64 6
    // @115
    abort
l6: move_loc l0
    pop
    ld_u64 6
    abort
    // @120
l5: move_loc l0
    pop
    ld_u64 6
    abort
l2: move_loc l0
    // @125
    pop
    ld_u64 5
    abort

// Function definition at index 1
#[persistent] entry public fun claim_giveaway(l0: &signer, l1: address, l2: address, l3: address) acquires Giveaway
    local l4: address
    local l5: address
    local l6: &mut Giveaway
    local l7: u64
    local l8: signer
    local l9: object::Object<fungible_asset::Metadata>
    local l10: fungible_asset::FungibleAsset
    local l11: object::Object<object::ObjectCore>
    move_loc l0
    call signer::address_of
    st_loc l4
    copy_loc l4
    call profile::derive_pid_address
    // @5
    st_loc l5
    copy_loc l5
    call profile::assert_pid_exists
    copy_loc l1
    mut_borrow_global Giveaway
    // @10
    st_loc l6
    call timestamp::now_seconds
    st_loc l7
    copy_loc l7
    copy_loc l6
    // @15
    borrow_field Giveaway, deadline_secs
    read_ref
    lt
    br_false l0
    copy_loc l6
    // @20
    borrow_field Giveaway, claimers
    copy_loc l5
    call smart_table::contains<address, bool>
    br_true l1
    copy_loc l6
    // @25
    freeze_ref
    copy_loc l5
    copy_loc l4
    move_loc l2
    move_loc l3
    // @30
    call check_gates
    copy_loc l6
    borrow_field Giveaway, extend_ref
    call object::generate_signer_for_extending
    st_loc l8
    // @35
    copy_loc l6
    borrow_field Giveaway, kind
    read_ref
    ld_u8 1
    eq
    // @40
    br_false l2
    copy_loc l6
    borrow_field Giveaway, fa_token_metadata
    read_ref
    call object::address_to_object<fungible_asset::Metadata>
    // @45
    st_loc l9
    copy_loc l1
    copy_loc l9
    call primary_fungible_store::balance<fungible_asset::Metadata>
    copy_loc l6
    // @50
    borrow_field Giveaway, fa_amount_per_claim
    read_ref
    ge
    br_false l3
    borrow_loc l8
    // @55
    move_loc l9
    copy_loc l6
    borrow_field Giveaway, fa_amount_per_claim
    read_ref
    call primary_fungible_store::withdraw<fungible_asset::Metadata>
    // @60
    st_loc l10
    move_loc l4
    move_loc l10
    call primary_fungible_store::deposit
l6: copy_loc l6
    // @65
    mut_borrow_field Giveaway, claimers
    copy_loc l5
    ld_true
    call smart_table::add<address, bool>
    copy_loc l6
    // @70
    borrow_field Giveaway, claims_made
    read_ref
    ld_u64 1
    add
    copy_loc l6
    // @75
    mut_borrow_field Giveaway, claims_made
    write_ref
    move_loc l1
    move_loc l5
    move_loc l6
    // @80
    borrow_field Giveaway, claims_made
    read_ref
    move_loc l7
    pack GiveawayClaimed
    call event::emit<GiveawayClaimed>
    // @85
    ret
l3: move_loc l6
    pop
    ld_u64 3
    abort
    // @90
l2: copy_loc l6
    borrow_field Giveaway, kind
    read_ref
    ld_u8 2
    eq
    // @95
    br_false l4
    copy_loc l6
    borrow_field Giveaway, nft_addrs
    call vector::is_empty<address>
    br_true l5
    // @100
    copy_loc l6
    mut_borrow_field Giveaway, nft_addrs
    ld_u64 0
    call vector::remove<address>
    call object::address_to_object<object::ObjectCore>
    // @105
    st_loc l11
    borrow_loc l8
    move_loc l11
    move_loc l4
    call object::transfer<object::ObjectCore>
    // @110
    branch l6
l5: move_loc l6
    pop
    ld_u64 3
    abort
    // @115
l4: move_loc l6
    pop
    ld_u64 9
    abort
l1: move_loc l6
    // @120
    pop
    ld_u64 4
    abort
l0: move_loc l6
    pop
    // @125
    ld_u64 2
    abort

// Function definition at index 2
#[persistent] public fun claims_made(l0: address): u64 acquires Giveaway
    move_loc l0
    borrow_global Giveaway
    borrow_field Giveaway, claims_made
    read_ref
    ret

// Function definition at index 3
#[persistent] entry public fun create_fa_giveaway(l0: &signer, l1: u64, l2: object::Object<fungible_asset::Metadata>, l3: u64, l4: u64, l5: u64, l6: bool, l7: address, l8: bool, l9: address, l10: bool) acquires PidGiveawayStorage
    local l11: address
    local l12: address
    local l13: fungible_asset::FungibleAsset
    local l14: object::ConstructorRef
    local l15: address
    local l16: object::ExtendRef
    local l17: signer
    local l18: address
    local l19: address
    local l20: u8
    local l21: u64
    local l22: address
    local l23: u64
    local l24: u64
    local l25: address
    local l26: vector<address>
    local l27: u64
    local l28: bool
    local l29: option::Option<address>
    local l30: option::Option<address>
    local l31: smart_table::SmartTable<address, bool>
    local l32: Giveaway
    copy_loc l0
    call signer::address_of
    st_loc l11
    copy_loc l11
    call profile::derive_pid_address
    // @5
    st_loc l12
    copy_loc l12
    call profile::assert_pid_exists
    copy_loc l1
    copy_loc l12
    // @10
    call mint::next_seq
    lt
    br_false l0
    move_loc l0
    copy_loc l2
    // @15
    copy_loc l4
    call primary_fungible_store::withdraw<fungible_asset::Metadata>
    st_loc l13
    copy_loc l11
    call object::create_object
    // @20
    st_loc l14
    borrow_loc l14
    call object::address_from_constructor_ref
    st_loc l15
    borrow_loc l14
    // @25
    call object::generate_extend_ref
    st_loc l16
    borrow_loc l14
    call object::generate_signer
    st_loc l17
    // @30
    copy_loc l15
    move_loc l13
    call primary_fungible_store::deposit
    copy_loc l12
    st_loc l18
    // @35
    move_loc l11
    st_loc l19
    ld_u8 1
    st_loc l20
    copy_loc l5
    // @40
    st_loc l21
    borrow_loc l2
    call object::object_address<fungible_asset::Metadata>
    st_loc l22
    move_loc l3
    // @45
    st_loc l23
    move_loc l4
    st_loc l24
    ld_const<address> 0
    st_loc l25
    // @50
    vec_pack <address>, 0
    st_loc l26
    ld_u64 0
    st_loc l27
    move_loc l6
    // @55
    st_loc l28
    move_loc l8
    br_false l1
    move_loc l7
    call option::some<address>
    // @60
    st_loc l29
l4: move_loc l10
    br_false l2
    move_loc l9
    call option::some<address>
    // @65
    st_loc l30
l3: call smart_table::new<address, bool>
    st_loc l31
    move_loc l18
    move_loc l19
    // @70
    move_loc l20
    move_loc l21
    move_loc l22
    move_loc l23
    move_loc l24
    // @75
    move_loc l25
    move_loc l26
    move_loc l27
    move_loc l28
    move_loc l29
    // @80
    move_loc l30
    move_loc l31
    move_loc l16
    pack Giveaway
    st_loc l32
    // @85
    borrow_loc l17
    move_loc l32
    move_to Giveaway
    copy_loc l12
    call ensure_giveaway_storage
    // @90
    copy_loc l12
    mut_borrow_global PidGiveawayStorage
    mut_borrow_field PidGiveawayStorage, giveaways
    copy_loc l1
    copy_loc l15
    // @95
    call smart_table::add<u64, address>
    move_loc l12
    move_loc l1
    move_loc l15
    ld_u8 1
    // @100
    move_loc l5
    call timestamp::now_seconds
    pack GiveawayCreated
    call event::emit<GiveawayCreated>
    ret
    // @105
l2: call option::none<address>
    st_loc l30
    branch l3
l1: call option::none<address>
    st_loc l29
    // @110
    branch l4
l0: move_loc l0
    pop
    ld_u64 13
    abort

// Function definition at index 4
#[persistent] public fun deadline_secs(l0: address): u64 acquires Giveaway
    move_loc l0
    borrow_global Giveaway
    borrow_field Giveaway, deadline_secs
    read_ref
    ret

// Function definition at index 5
#[persistent] entry public fun create_nft_giveaway(l0: &signer, l1: u64, l2: address, l3: vector<address>, l4: u64, l5: bool, l6: address, l7: bool, l8: address, l9: bool) acquires PidGiveawayStorage
    local l10: address
    local l11: address
    local l12: object::ConstructorRef
    local l13: address
    local l14: object::ExtendRef
    local l15: signer
    local l16: u64
    local l17: u64
    local l18: object::Object<object::ObjectCore>
    local l19: address
    local l20: address
    local l21: u8
    local l22: address
    local l23: u64
    local l24: u64
    local l25: address
    local l26: vector<address>
    local l27: u64
    local l28: bool
    local l29: option::Option<address>
    local l30: option::Option<address>
    local l31: smart_table::SmartTable<address, bool>
    local l32: Giveaway
    copy_loc l0
    call signer::address_of
    st_loc l10
    copy_loc l10
    call profile::derive_pid_address
    // @5
    st_loc l11
    copy_loc l11
    call profile::assert_pid_exists
    copy_loc l1
    copy_loc l11
    // @10
    call mint::next_seq
    lt
    br_false l0
    copy_loc l10
    call object::create_object
    // @15
    st_loc l12
    borrow_loc l12
    call object::address_from_constructor_ref
    st_loc l13
    borrow_loc l12
    // @20
    call object::generate_extend_ref
    st_loc l14
    borrow_loc l12
    call object::generate_signer
    st_loc l15
    // @25
    borrow_loc l3
    vec_len <address>
    st_loc l16
    copy_loc l16
    ld_u64 0
    // @30
    gt
    br_false l1
    ld_u64 0
    st_loc l17
l4: copy_loc l17
    // @35
    copy_loc l16
    lt
    br_false l2
    borrow_loc l3
    copy_loc l17
    // @40
    vec_borrow <address>
    read_ref
    call object::address_to_object<object::ObjectCore>
    st_loc l18
    copy_loc l18
    // @45
    call object::owner<object::ObjectCore>
    copy_loc l10
    eq
    br_false l3
    copy_loc l0
    // @50
    move_loc l18
    copy_loc l13
    call object::transfer<object::ObjectCore>
    move_loc l17
    ld_u64 1
    // @55
    add
    st_loc l17
    branch l4
l3: move_loc l0
    pop
    // @60
    ld_u64 12
    abort
l2: move_loc l0
    pop
    copy_loc l11
    // @65
    st_loc l19
    move_loc l10
    st_loc l20
    ld_u8 2
    st_loc l21
    // @70
    copy_loc l4
    st_loc l17
    ld_const<address> 0
    st_loc l22
    ld_u64 0
    // @75
    st_loc l23
    ld_u64 0
    st_loc l24
    move_loc l2
    st_loc l25
    // @80
    move_loc l3
    st_loc l26
    ld_u64 0
    st_loc l27
    move_loc l5
    // @85
    st_loc l28
    move_loc l7
    br_false l5
    move_loc l6
    call option::some<address>
    // @90
    st_loc l29
l8: move_loc l9
    br_false l6
    move_loc l8
    call option::some<address>
    // @95
    st_loc l30
l7: call smart_table::new<address, bool>
    st_loc l31
    move_loc l19
    move_loc l20
    // @100
    move_loc l21
    move_loc l17
    move_loc l22
    move_loc l23
    move_loc l24
    // @105
    move_loc l25
    move_loc l26
    move_loc l27
    move_loc l28
    move_loc l29
    // @110
    move_loc l30
    move_loc l31
    move_loc l14
    pack Giveaway
    st_loc l32
    // @115
    borrow_loc l15
    move_loc l32
    move_to Giveaway
    copy_loc l11
    call ensure_giveaway_storage
    // @120
    copy_loc l11
    mut_borrow_global PidGiveawayStorage
    mut_borrow_field PidGiveawayStorage, giveaways
    copy_loc l1
    copy_loc l13
    // @125
    call smart_table::add<u64, address>
    move_loc l11
    move_loc l1
    move_loc l13
    ld_u8 2
    // @130
    move_loc l4
    call timestamp::now_seconds
    pack GiveawayCreated
    call event::emit<GiveawayCreated>
    ret
    // @135
l6: call option::none<address>
    st_loc l30
    branch l7
l5: call option::none<address>
    st_loc l29
    // @140
    branch l8
l1: move_loc l0
    pop
    ld_u64 3
    abort
    // @145
l0: move_loc l0
    pop
    ld_u64 13
    abort

// Function definition at index 6
fun ensure_giveaway_storage(l0: address)
    local l1: signer
    copy_loc l0
    exists PidGiveawayStorage
    br_true l0
    move_loc l0
    call profile::derive_pid_signer
    // @5
    st_loc l1
    borrow_loc l1
    call smart_table::new<u64, address>
    pack PidGiveawayStorage
    move_to PidGiveawayStorage
    // @10
    ret
l0: ret

// Function definition at index 7
#[persistent] public fun giveaway_addr_for_mint(l0: address, l1: u64): address acquires PidGiveawayStorage
    move_loc l0
    borrow_global PidGiveawayStorage
    borrow_field PidGiveawayStorage, giveaways
    move_loc l1
    call smart_table::borrow<u64, address>
    // @5
    read_ref
    ret

// Function definition at index 8
#[persistent] public fun has_claimed(l0: address, l1: address): bool acquires Giveaway
    move_loc l0
    borrow_global Giveaway
    borrow_field Giveaway, claimers
    move_loc l1
    call smart_table::contains<address, bool>
    // @5
    ret

// Function definition at index 9
#[persistent] public fun kind_fa(): u8
    ld_u8 1
    ret

// Function definition at index 10
#[persistent] public fun kind_nft(): u8
    ld_u8 2
    ret

// Function definition at index 11
#[persistent] public fun settle_bounty_bps(): u64
    ld_u64 5
    ret

// Function definition at index 12
#[persistent] entry public fun settle_giveaway(l0: &signer, l1: address) acquires Giveaway
    local l2: &mut Giveaway
    local l3: u64
    local l4: address
    local l5: address
    local l6: signer
    local l7: u64
    local l8: u64
    local l9: object::Object<fungible_asset::Metadata>
    local l10: u64
    local l11: fungible_asset::FungibleAsset
    local l12: object::Object<object::ObjectCore>
    copy_loc l1
    mut_borrow_global Giveaway
    st_loc l2
    call timestamp::now_seconds
    st_loc l3
    // @5
    copy_loc l3
    copy_loc l2
    borrow_field Giveaway, deadline_secs
    read_ref
    ge
    // @10
    br_false l0
    move_loc l0
    call signer::address_of
    st_loc l4
    copy_loc l2
    // @15
    borrow_field Giveaway, sponsor_wallet
    read_ref
    st_loc l5
    copy_loc l2
    borrow_field Giveaway, extend_ref
    // @20
    call object::generate_signer_for_extending
    st_loc l6
    ld_u64 0
    st_loc l7
    ld_u64 0
    // @25
    st_loc l8
    copy_loc l2
    borrow_field Giveaway, kind
    read_ref
    ld_u8 1
    // @30
    eq
    br_false l1
    copy_loc l2
    borrow_field Giveaway, fa_token_metadata
    read_ref
    // @35
    call object::address_to_object<fungible_asset::Metadata>
    st_loc l9
    copy_loc l1
    copy_loc l9
    call primary_fungible_store::balance<fungible_asset::Metadata>
    // @40
    st_loc l10
    copy_loc l10
    ld_u64 0
    gt
    br_true l2
    // @45
    branch l3
l2: copy_loc l10
    ld_u64 5
    mul
    ld_u64 10000
    // @50
    div
    st_loc l8
    move_loc l10
    copy_loc l8
    sub
    // @55
    st_loc l7
    copy_loc l8
    ld_u64 0
    gt
    br_true l4
    // @60
    branch l5
l4: borrow_loc l6
    copy_loc l9
    copy_loc l8
    call primary_fungible_store::withdraw<fungible_asset::Metadata>
    // @65
    st_loc l11
    copy_loc l4
    move_loc l11
    call primary_fungible_store::deposit
l5: copy_loc l7
    // @70
    ld_u64 0
    gt
    br_true l6
    branch l3
l6: borrow_loc l6
    // @75
    move_loc l9
    copy_loc l7
    call primary_fungible_store::withdraw<fungible_asset::Metadata>
    st_loc l11
    move_loc l5
    // @80
    move_loc l11
    call primary_fungible_store::deposit
l3: move_loc l1
    move_loc l2
    borrow_field Giveaway, sponsor_pid
    // @85
    read_ref
    move_loc l4
    move_loc l7
    move_loc l8
    move_loc l3
    // @90
    pack GiveawaySettled
    call event::emit<GiveawaySettled>
    ret
l1: copy_loc l2
    borrow_field Giveaway, kind
    // @95
    read_ref
    ld_u8 2
    eq
    br_true l7
    branch l3
    // @100
l7: copy_loc l2
    borrow_field Giveaway, nft_addrs
    vec_len <address>
    st_loc l7
l9: copy_loc l2
    // @105
    borrow_field Giveaway, nft_addrs
    call vector::is_empty<address>
    br_false l8
    branch l3
l8: copy_loc l2
    // @110
    mut_borrow_field Giveaway, nft_addrs
    vec_pop_back <address>
    call object::address_to_object<object::ObjectCore>
    st_loc l12
    borrow_loc l6
    // @115
    move_loc l12
    copy_loc l5
    call object::transfer<object::ObjectCore>
    branch l9
l0: move_loc l0
    // @120
    pop
    move_loc l2
    pop
    ld_u64 8
    abort
```

---

## Module `press` (4457 bytes)

`sha3_256: c3259a61676a4b59b067faf1eaec571e7a22e4812670e17e354e083a56c43893`

### ABI surface

**Structs** (6):

- `PidPressStorage` `[key]` {configs:0x1::smart_table::SmartTable<u64, 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::press::PressConfig>, registries:0x1::smart_table::SmartTable<u64, 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::press::PressedRegistry>}
- `PressCollection` `[key]` {collection_addr:address, extend_ref:0x1::object::ExtendRef, name:0x1::string::String}
- `PressConfig` `[copy+drop+store]` {supply_cap:u16, window_us:u64, pressed_count:u16, emission_consumed_total:u64, deadline_us:u64}
- `PressEnabled` `[drop+store]` {author_pid:address, mint_seq:u64, supply_cap:u16, window_us:u64, deadline_us:u64, timestamp_secs:u64}
- `PressMinted` `[drop+store]` {presser_pid:address, author_pid:address, mint_seq:u64, press_order:u16, emission_amount:u64, nft_object_addr:address, timestamp_secs:u64}
- `PressedRegistry` `[store]` {pressed_by:0x1::smart_table::SmartTable<address, bool>}

**Public fns** (8):

- [entry] `press(&signer,address,u64,address)`
- [view] `supply_cap(address,u64) → u16`
- [view] `deadline_us(address,u64) → u64`
- [entry] `enable_press(&signer,u64,u16,u8)`
- [view] `has_pressed(address,address,u64) → bool`
- [view] `is_press_enabled(address,u64) → bool`
- [view] `pressed_count(address,u64) → u16`
- [view] `royalty_bps() → u64`

### MASM (disassembled bytecode)

```move
// Bytecode version v9
module 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::press
use 0x1::smart_table
use 0x1::object
use 0x1::string
use 0x1::signer
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::profile
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::mint
use 0x1::option
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::reference_gate
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::link
use 0x1::timestamp
use 0x4::royalty
use 0x4::token
use 0x1::bcs
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::history
use 0x1::vector
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::factory
use 0x1::event
use 0x4::collection
struct PidPressStorage has key
  configs: smart_table::SmartTable<u64, PressConfig>
  registries: smart_table::SmartTable<u64, PressedRegistry>

struct PressCollection has key
  collection_addr: address
  extend_ref: object::ExtendRef
  name: string::String

struct PressConfig has copy + drop + store
  supply_cap: u16
  window_us: u64
  pressed_count: u16
  emission_consumed_total: u64
  deadline_us: u64

struct PressEnabled has drop + store
  author_pid: address
  mint_seq: u64
  supply_cap: u16
  window_us: u64
  deadline_us: u64
  timestamp_secs: u64

struct PressMinted has drop + store
  presser_pid: address
  author_pid: address
  mint_seq: u64
  press_order: u16
  emission_amount: u64
  nft_object_addr: address
  timestamp_secs: u64

struct PressedRegistry has store
  pressed_by: smart_table::SmartTable<address, bool>

// Function definition at index 0
#[persistent] entry public fun press(l0: &signer, l1: address, l2: u64, l3: address) acquires PidPressStorage, PressCollection
    local l4: address
    local l5: address
    local l6: option::Option<reference_gate::ReferenceGate>
    local l7: address
    local l8: bool
    local l9: reference_gate::ReferenceGate
    local l10: &mut PidPressStorage
    local l11: &mut PressConfig
    local l12: &mut PressedRegistry
    local l13: u16
    local l14: u16
    local l15: u64
    local l16: string::String
    local l17: string::String
    local l18: string::String
    local l19: string::String
    local l20: string::String
    local l21: signer
    local l22: object::ConstructorRef
    local l23: address
    local l24: object::Object<token::Token>
    local l25: u64
    local l26: PressMinted
    local l27: vector<u8>
    local l28: vector<u8>
    move_loc l0
    call signer::address_of
    st_loc l4
    copy_loc l4
    call profile::derive_pid_address
    // @5
    st_loc l5
    copy_loc l5
    call profile::assert_pid_exists
    copy_loc l1
    exists PidPressStorage
    // @10
    br_false l0
    copy_loc l5
    copy_loc l1
    neq
    br_true l1
    // @15
    branch l2
l1: copy_loc l1
    copy_loc l2
    call mint::get_mint_gate
    st_loc l6
    // @20
    borrow_loc l6
    call option::is_some<reference_gate::ReferenceGate>
    br_true l3
    branch l2
l3: borrow_loc l6
    // @25
    call option::borrow<reference_gate::ReferenceGate>
    call reference_gate::target_pid
    st_loc l7
    copy_loc l5
    move_loc l7
    // @30
    call link::is_synced
    st_loc l8
    mut_borrow_loc l6
    call option::extract<reference_gate::ReferenceGate>
    st_loc l9
    // @35
    borrow_loc l9
    copy_loc l4
    move_loc l8
    ld_false
    move_loc l3
    // @40
    call reference_gate::check
    br_false l4
    branch l2
l2: copy_loc l1
    mut_borrow_global PidPressStorage
    // @45
    st_loc l10
    copy_loc l10
    borrow_field PidPressStorage, configs
    copy_loc l2
    call smart_table::contains<u64, PressConfig>
    // @50
    br_false l5
    copy_loc l10
    mut_borrow_field PidPressStorage, configs
    copy_loc l2
    call smart_table::borrow_mut<u64, PressConfig>
    // @55
    st_loc l11
    call timestamp::now_seconds
    ld_u64 1000000
    mul
    copy_loc l11
    // @60
    borrow_field PressConfig, deadline_us
    read_ref
    lt
    br_false l6
    copy_loc l11
    // @65
    borrow_field PressConfig, pressed_count
    read_ref
    copy_loc l11
    borrow_field PressConfig, supply_cap
    read_ref
    // @70
    lt
    br_false l7
    move_loc l10
    mut_borrow_field PidPressStorage, registries
    copy_loc l2
    // @75
    call smart_table::borrow_mut<u64, PressedRegistry>
    st_loc l12
    copy_loc l12
    borrow_field PressedRegistry, pressed_by
    copy_loc l5
    // @80
    call smart_table::contains<address, bool>
    br_true l8
    move_loc l12
    mut_borrow_field PressedRegistry, pressed_by
    copy_loc l5
    // @85
    ld_true
    call smart_table::add<address, bool>
    copy_loc l11
    borrow_field PressConfig, pressed_count
    read_ref
    // @90
    ld_u16 1
    add
    copy_loc l11
    mut_borrow_field PressConfig, pressed_count
    write_ref
    // @95
    copy_loc l11
    borrow_field PressConfig, pressed_count
    read_ref
    st_loc l13
    copy_loc l11
    // @100
    borrow_field PressConfig, supply_cap
    read_ref
    st_loc l14
    copy_loc l13
    cast_u64
    // @105
    st_loc l15
    copy_loc l11
    borrow_field PressConfig, emission_consumed_total
    read_ref
    move_loc l15
    // @110
    add
    move_loc l11
    mut_borrow_field PressConfig, emission_consumed_total
    write_ref
    copy_loc l1
    // @115
    call ensure_press_collection
    pop
    copy_loc l1
    call profile::handle_of
    st_loc l16
    // @120
    borrow_loc l16
    copy_loc l2
    copy_loc l13
    call build_token_name
    st_loc l17
    // @125
    borrow_loc l16
    copy_loc l2
    call build_token_description
    st_loc l18
    borrow_loc l16
    // @130
    copy_loc l2
    call build_token_uri
    st_loc l19
    copy_loc l1
    borrow_global PressCollection
    // @135
    borrow_field PressCollection, name
    read_ref
    st_loc l20
    copy_loc l1
    call profile::derive_pid_signer
    // @140
    st_loc l21
    borrow_loc l21
    move_loc l20
    move_loc l18
    move_loc l17
    // @145
    call option::none<royalty::Royalty>
    move_loc l19
    call token::create
    st_loc l22
    borrow_loc l22
    // @150
    call object::address_from_constructor_ref
    st_loc l23
    borrow_loc l22
    call object::object_from_constructor_ref<token::Token>
    st_loc l24
    // @155
    borrow_loc l21
    move_loc l24
    copy_loc l4
    call object::transfer<token::Token>
    copy_loc l5
    // @160
    copy_loc l1
    eq
    br_false l9
    ld_u64 0
    st_loc l15
    // @165
l10: call timestamp::now_seconds
    st_loc l25
    copy_loc l5
    copy_loc l1
    move_loc l2
    // @170
    move_loc l13
    move_loc l15
    move_loc l23
    copy_loc l25
    pack PressMinted
    // @175
    st_loc l26
    borrow_loc l26
    call bcs::to_bytes<PressMinted>
    st_loc l27
    move_loc l5
    // @180
    call history::verb_press
    move_loc l25
    move_loc l1
    call option::some<address>
    move_loc l27
    // @185
    call option::none<address>
    call history::new_entry
    call history::append
    ret
l9: borrow_loc l1
    // @190
    call bcs::to_bytes<address>
    st_loc l28
    mut_borrow_loc l28
    borrow_loc l2
    call bcs::to_bytes<u64>
    // @195
    call vector::append<u8>
    borrow_loc l21
    move_loc l4
    move_loc l28
    copy_loc l13
    // @200
    cast_u64
    move_loc l14
    cast_u64
    call factory::emit_press_to_presser
    st_loc l15
    // @205
    branch l10
l8: move_loc l11
    pop
    move_loc l12
    pop
    // @210
    ld_u64 4
    abort
l7: move_loc l10
    pop
    move_loc l11
    // @215
    pop
    ld_u64 3
    abort
l6: move_loc l10
    pop
    // @220
    move_loc l11
    pop
    ld_u64 2
    abort
l5: move_loc l10
    // @225
    pop
    ld_u64 1
    abort
l4: ld_u64 5
    abort
    // @230
l0: ld_u64 1
    abort

// Function definition at index 1
#[persistent] public fun supply_cap(l0: address, l1: u64): u16 acquires PidPressStorage
    move_loc l0
    borrow_global PidPressStorage
    borrow_field PidPressStorage, configs
    move_loc l1
    call smart_table::borrow<u64, PressConfig>
    // @5
    borrow_field PressConfig, supply_cap
    read_ref
    ret

// Function definition at index 2
fun build_collection_description(l0: &string::String): string::String
    local l1: string::String
    ld_const<vector<u8>> [80, 114, 101, 115, 115, 32, 78, 70, 84, 115, 32, 99, 111, 108, 108, 101, 99, 116, 101, 100, 32, 102, 114, 111, 109, 32]
    call string::utf8
    st_loc l1
    mut_borrow_loc l1
    move_loc l0
    // @5
    read_ref
    call string::append
    mut_borrow_loc l1
    ld_const<vector<u8>> [39, 115, 32, 109, 105, 110, 116, 115, 32, 111, 110, 32, 68, 101, 83, 78, 101, 116, 46]
    call string::append_utf8
    // @10
    move_loc l1
    ret

// Function definition at index 3
fun build_collection_name(l0: &string::String): string::String
    local l1: string::String
    ld_const<vector<u8>> []
    call string::utf8
    st_loc l1
    mut_borrow_loc l1
    move_loc l0
    // @5
    read_ref
    call string::append
    mut_borrow_loc l1
    ld_const<vector<u8>> [39, 115, 32, 80, 114, 101, 115, 115, 101, 115]
    call string::append_utf8
    // @10
    move_loc l1
    ret

// Function definition at index 4
fun build_collection_uri(l0: &string::String): string::String
    ld_const<vector<u8>> []
    move_loc l0
    pop
    call string::utf8
    ret

// Function definition at index 5
fun build_token_description(l0: &string::String, l1: u64): string::String
    local l2: string::String
    ld_const<vector<u8>> [80, 114, 101, 115, 115, 101, 100, 32, 102, 114, 111, 109, 32]
    call string::utf8
    st_loc l2
    mut_borrow_loc l2
    move_loc l0
    // @5
    read_ref
    call string::append
    mut_borrow_loc l2
    ld_const<vector<u8>> [39, 115, 32, 109, 105, 110, 116, 32, 35]
    call string::append_utf8
    // @10
    mut_borrow_loc l2
    move_loc l1
    call u64_to_string
    call string::append
    mut_borrow_loc l2
    // @15
    ld_const<vector<u8>> [46]
    call string::append_utf8
    move_loc l2
    ret

// Function definition at index 6
fun build_token_name(l0: &string::String, l1: u64, l2: u16): string::String
    local l3: string::String
    ld_const<vector<u8>> []
    call string::utf8
    st_loc l3
    mut_borrow_loc l3
    move_loc l0
    // @5
    read_ref
    call string::append
    mut_borrow_loc l3
    ld_const<vector<u8>> [32, 35]
    call string::append_utf8
    // @10
    mut_borrow_loc l3
    move_loc l1
    call u64_to_string
    call string::append
    mut_borrow_loc l3
    // @15
    ld_const<vector<u8>> [32, 112, 114, 101, 115, 115, 32, 35]
    call string::append_utf8
    mut_borrow_loc l3
    move_loc l2
    cast_u64
    // @20
    call u64_to_string
    call string::append
    move_loc l3
    ret

// Function definition at index 7
fun build_token_uri(l0: &string::String, l1: u64): string::String
    ld_const<vector<u8>> []
    move_loc l0
    pop
    call string::utf8
    ret

// Function definition at index 8
#[persistent] public fun deadline_us(l0: address, l1: u64): u64 acquires PidPressStorage
    move_loc l0
    borrow_global PidPressStorage
    borrow_field PidPressStorage, configs
    move_loc l1
    call smart_table::borrow<u64, PressConfig>
    // @5
    borrow_field PressConfig, deadline_us
    read_ref
    ret

// Function definition at index 9
#[persistent] entry public fun enable_press(l0: &signer, l1: u64, l2: u16, l3: u8) acquires PidPressStorage
    local l4: bool
    local l5: bool
    local l6: address
    local l7: &mut PidPressStorage
    local l8: u64
    local l9: u64
    local l10: PressConfig
    copy_loc l2
    ld_u16 1
    ge
    br_false l0
    copy_loc l2
    // @5
    ld_u16 1000
    le
    st_loc l4
l7: move_loc l4
    br_false l1
    // @10
    copy_loc l3
    ld_u8 1
    ge
    br_false l2
    copy_loc l3
    // @15
    ld_u8 7
    le
    st_loc l5
l6: move_loc l5
    br_false l3
    // @20
    move_loc l0
    call signer::address_of
    call profile::derive_pid_address
    st_loc l6
    copy_loc l6
    // @25
    call profile::assert_pid_exists
    copy_loc l1
    copy_loc l6
    call mint::next_seq
    lt
    // @30
    br_false l4
    copy_loc l6
    call ensure_press_storage
    copy_loc l6
    mut_borrow_global PidPressStorage
    // @35
    st_loc l7
    copy_loc l7
    borrow_field PidPressStorage, configs
    copy_loc l1
    call smart_table::contains<u64, PressConfig>
    // @40
    br_true l5
    call timestamp::now_seconds
    ld_u64 1000000
    mul
    move_loc l3
    // @45
    cast_u64
    ld_u64 86400
    mul
    ld_u64 1000000
    mul
    // @50
    st_loc l8
    copy_loc l8
    add
    st_loc l9
    copy_loc l2
    // @55
    copy_loc l8
    ld_u16 0
    ld_u64 0
    copy_loc l9
    pack PressConfig
    // @60
    st_loc l10
    copy_loc l7
    mut_borrow_field PidPressStorage, configs
    copy_loc l1
    move_loc l10
    // @65
    call smart_table::add<u64, PressConfig>
    move_loc l7
    mut_borrow_field PidPressStorage, registries
    copy_loc l1
    call smart_table::new<address, bool>
    // @70
    pack PressedRegistry
    call smart_table::add<u64, PressedRegistry>
    move_loc l6
    move_loc l1
    move_loc l2
    // @75
    move_loc l8
    move_loc l9
    call timestamp::now_seconds
    pack PressEnabled
    call event::emit<PressEnabled>
    // @80
    ret
l5: move_loc l7
    pop
    ld_u64 10
    abort
    // @85
l4: ld_u64 11
    abort
l3: move_loc l0
    pop
    ld_u64 7
    // @90
    abort
l2: ld_false
    st_loc l5
    branch l6
l1: move_loc l0
    // @95
    pop
    ld_u64 6
    abort
l0: ld_false
    st_loc l4
    // @100
    branch l7

// Function definition at index 10
fun ensure_press_collection(l0: address): address acquires PressCollection
    local l1: signer
    local l2: string::String
    local l3: string::String
    local l4: royalty::Royalty
    local l5: object::ConstructorRef
    local l6: object::ExtendRef
    copy_loc l0
    exists PressCollection
    br_false l0
    move_loc l0
    borrow_global PressCollection
    // @5
    borrow_field PressCollection, collection_addr
    read_ref
    ret
l0: copy_loc l0
    call profile::derive_pid_signer
    // @10
    st_loc l1
    copy_loc l0
    call profile::handle_of
    st_loc l2
    borrow_loc l2
    // @15
    call build_collection_name
    st_loc l3
    move_loc l0
    call factory::vault_addr_of_pid
    st_loc l0
    // @20
    ld_u64 500
    ld_u64 10000
    move_loc l0
    call royalty::create
    st_loc l4
    // @25
    borrow_loc l1
    borrow_loc l2
    call build_collection_description
    copy_loc l3
    move_loc l4
    // @30
    call option::some<royalty::Royalty>
    borrow_loc l2
    call build_collection_uri
    call collection::create_unlimited_collection
    st_loc l5
    // @35
    borrow_loc l5
    call object::address_from_constructor_ref
    st_loc l0
    borrow_loc l5
    call object::generate_extend_ref
    // @40
    st_loc l6
    borrow_loc l1
    copy_loc l0
    move_loc l6
    move_loc l3
    // @45
    pack PressCollection
    move_to PressCollection
    move_loc l0
    ret

// Function definition at index 11
fun ensure_press_storage(l0: address)
    local l1: signer
    copy_loc l0
    exists PidPressStorage
    br_true l0
    move_loc l0
    call profile::derive_pid_signer
    // @5
    st_loc l1
    borrow_loc l1
    call smart_table::new<u64, PressConfig>
    call smart_table::new<u64, PressedRegistry>
    pack PidPressStorage
    // @10
    move_to PidPressStorage
    ret
l0: ret

// Function definition at index 12
#[persistent] public fun has_pressed(l0: address, l1: address, l2: u64): bool acquires PidPressStorage
    local l3: &PidPressStorage
    copy_loc l1
    exists PidPressStorage
    br_true l0
    ld_false
    ret
    // @5
l0: move_loc l1
    borrow_global PidPressStorage
    st_loc l3
    copy_loc l3
    borrow_field PidPressStorage, registries
    // @10
    copy_loc l2
    call smart_table::contains<u64, PressedRegistry>
    br_true l1
    move_loc l3
    pop
    // @15
    ld_false
    ret
l1: move_loc l3
    borrow_field PidPressStorage, registries
    move_loc l2
    // @20
    call smart_table::borrow<u64, PressedRegistry>
    borrow_field PressedRegistry, pressed_by
    move_loc l0
    call smart_table::contains<address, bool>
    ret

// Function definition at index 13
#[persistent] public fun is_press_enabled(l0: address, l1: u64): bool acquires PidPressStorage
    copy_loc l0
    exists PidPressStorage
    br_true l0
    ld_false
    ret
    // @5
l0: move_loc l0
    borrow_global PidPressStorage
    borrow_field PidPressStorage, configs
    move_loc l1
    call smart_table::contains<u64, PressConfig>
    // @10
    ret

// Function definition at index 14
#[persistent] public fun pressed_count(l0: address, l1: u64): u16 acquires PidPressStorage
    local l2: &PidPressStorage
    copy_loc l0
    exists PidPressStorage
    br_true l0
    ld_u16 0
    ret
    // @5
l0: move_loc l0
    borrow_global PidPressStorage
    st_loc l2
    copy_loc l2
    borrow_field PidPressStorage, configs
    // @10
    copy_loc l1
    call smart_table::contains<u64, PressConfig>
    br_true l1
    move_loc l2
    pop
    // @15
    ld_u16 0
    ret
l1: move_loc l2
    borrow_field PidPressStorage, configs
    move_loc l1
    // @20
    call smart_table::borrow<u64, PressConfig>
    borrow_field PressConfig, pressed_count
    read_ref
    ret

// Function definition at index 15
#[persistent] public fun royalty_bps(): u64
    ld_u64 500
    ret

// Function definition at index 16
fun u64_to_string(l0: u64): string::String
    local l1: vector<u8>
    local l2: u8
    copy_loc l0
    ld_u64 0
    eq
    br_false l0
    ld_const<vector<u8>> [48]
    // @5
    call string::utf8
    ret
l0: vec_pack <u8>, 0
    st_loc l1
l2: copy_loc l0
    // @10
    ld_u64 0
    gt
    br_false l1
    copy_loc l0
    ld_u64 10
    // @15
    mod
    cast_u8
    ld_u8 48
    add
    st_loc l2
    // @20
    mut_borrow_loc l1
    move_loc l2
    vec_push_back <u8>
    move_loc l0
    ld_u64 10
    // @25
    div
    st_loc l0
    branch l2
l1: mut_borrow_loc l1
    call vector::reverse<u8>
    // @30
    move_loc l1
    call string::utf8
    ret
```

---

## Module `pulse` (2490 bytes)

`sha3_256: 42e1ceef93d19af5bbdfb91efb8e5ebcd6c06505bcec3c3846d37af015b11327`

### ABI surface

**Structs** (2):

- `PidReactionRegistry` `[key]` {active:0x1::smart_table::SmartTable<vector<u8>, bool>, spark_count_given:u64, echo_count_given:u64}
- `PulseEvent` `[drop+store]` {actor_pid:address, target_author:address, target_seq:u64, reaction_kind:u8, state:u8, timestamp_secs:u64}

**Public fns** (9):

- [view] `state_add() → u8`
- [view] `state_remove() → u8`
- [entry] `echo(&signer,address,u64,address)`
- [view] `echo_kind() → u8`
- [view] `has_reacted(address,address,u64,u8) → bool`
- [entry] `spark(&signer,address,u64,address)`
- [view] `spark_kind() → u8`
- [entry] `unecho(&signer,address,u64)`
- [entry] `unspark(&signer,address,u64)`

### MASM (disassembled bytecode)

```move
// Bytecode version v9
module 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::pulse
use 0x1::smart_table
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::mint
use 0x1::option
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::reference_gate
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::link
use 0x1::signer
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::profile
use 0x1::bcs
use 0x1::vector
use 0x1::timestamp
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::history
struct PidReactionRegistry has key
  active: smart_table::SmartTable<vector<u8>, bool>
  spark_count_given: u64
  echo_count_given: u64

struct PulseEvent has drop + store
  actor_pid: address
  target_author: address
  target_seq: u64
  reaction_kind: u8
  state: u8
  timestamp_secs: u64

// Function definition at index 0
#[persistent] public fun state_add(): u8
    ld_u8 1
    ret

// Function definition at index 1
#[persistent] public fun state_remove(): u8
    ld_u8 2
    ret

// Function definition at index 2
fun check_mint_gate_or_self_exempt(l0: address, l1: address, l2: address, l3: u64, l4: address)
    local l5: option::Option<reference_gate::ReferenceGate>
    local l6: bool
    local l7: reference_gate::ReferenceGate
    copy_loc l1
    copy_loc l2
    eq
    br_false l0
    ret
    // @5
l0: move_loc l2
    move_loc l3
    call mint::get_mint_gate
    st_loc l5
    borrow_loc l5
    // @10
    call option::is_none<reference_gate::ReferenceGate>
    br_false l1
    ret
l1: borrow_loc l5
    call option::borrow<reference_gate::ReferenceGate>
    // @15
    call reference_gate::target_pid
    st_loc l2
    move_loc l1
    move_loc l2
    call link::is_synced
    // @20
    st_loc l6
    mut_borrow_loc l5
    call option::extract<reference_gate::ReferenceGate>
    st_loc l7
    borrow_loc l7
    // @25
    move_loc l0
    move_loc l6
    ld_false
    move_loc l4
    call reference_gate::check
    // @30
    br_false l2
    ret
l2: ld_u64 3
    abort

// Function definition at index 3
#[persistent] entry public fun echo(l0: &signer, l1: address, l2: u64, l3: address) acquires PidReactionRegistry
    local l4: address
    local l5: address
    local l6: vector<u8>
    move_loc l0
    call signer::address_of
    st_loc l4
    copy_loc l4
    call profile::derive_pid_address
    // @5
    st_loc l5
    copy_loc l5
    call profile::assert_pid_exists
    move_loc l4
    copy_loc l5
    // @10
    copy_loc l1
    copy_loc l2
    move_loc l3
    call check_mint_gate_or_self_exempt
    copy_loc l5
    // @15
    call ensure_reaction_registry
    copy_loc l1
    copy_loc l2
    ld_u8 2
    call make_key
    // @20
    st_loc l6
    move_loc l5
    borrow_loc l6
    ld_u8 2
    move_loc l1
    // @25
    move_loc l2
    ld_true
    call toggle_reaction
    ret

// Function definition at index 4
#[persistent] public fun echo_kind(): u8
    ld_u8 2
    ret

// Function definition at index 5
fun ensure_reaction_registry(l0: address)
    local l1: signer
    copy_loc l0
    exists PidReactionRegistry
    br_true l0
    move_loc l0
    call profile::derive_pid_signer
    // @5
    st_loc l1
    borrow_loc l1
    call smart_table::new<vector<u8>, bool>
    ld_u64 0
    ld_u64 0
    // @10
    pack PidReactionRegistry
    move_to PidReactionRegistry
    ret
l0: ret

// Function definition at index 6
#[persistent] public fun has_reacted(l0: address, l1: address, l2: u64, l3: u8): bool acquires PidReactionRegistry
    local l4: vector<u8>
    copy_loc l0
    exists PidReactionRegistry
    br_true l0
    ld_false
    ret
    // @5
l0: move_loc l1
    move_loc l2
    move_loc l3
    call make_key
    st_loc l4
    // @10
    move_loc l0
    borrow_global PidReactionRegistry
    borrow_field PidReactionRegistry, active
    move_loc l4
    call smart_table::contains<vector<u8>, bool>
    // @15
    ret

// Function definition at index 7
fun make_key(l0: address, l1: u64, l2: u8): vector<u8>
    local l3: vector<u8>
    borrow_loc l0
    call bcs::to_bytes<address>
    st_loc l3
    mut_borrow_loc l3
    borrow_loc l1
    // @5
    call bcs::to_bytes<u64>
    call vector::append<u8>
    mut_borrow_loc l3
    move_loc l2
    vec_push_back <u8>
    // @10
    move_loc l3
    ret

// Function definition at index 8
#[persistent] entry public fun spark(l0: &signer, l1: address, l2: u64, l3: address) acquires PidReactionRegistry
    local l4: address
    local l5: address
    local l6: vector<u8>
    move_loc l0
    call signer::address_of
    st_loc l4
    copy_loc l4
    call profile::derive_pid_address
    // @5
    st_loc l5
    copy_loc l5
    call profile::assert_pid_exists
    move_loc l4
    copy_loc l5
    // @10
    copy_loc l1
    copy_loc l2
    move_loc l3
    call check_mint_gate_or_self_exempt
    copy_loc l5
    // @15
    call ensure_reaction_registry
    copy_loc l1
    copy_loc l2
    ld_u8 1
    call make_key
    // @20
    st_loc l6
    move_loc l5
    borrow_loc l6
    ld_u8 1
    move_loc l1
    // @25
    move_loc l2
    ld_true
    call toggle_reaction
    ret

// Function definition at index 9
#[persistent] public fun spark_kind(): u8
    ld_u8 1
    ret

// Function definition at index 10
fun toggle_reaction(l0: address, l1: &vector<u8>, l2: u8, l3: address, l4: u64, l5: bool) acquires PidReactionRegistry
    local l6: &mut PidReactionRegistry
    local l7: u64
    local l8: address
    local l9: address
    local l10: u64
    local l11: u8
    local l12: u8
    local l13: PulseEvent
    local l14: u8
    local l15: vector<u8>
    copy_loc l0
    exists PidReactionRegistry
    br_false l0
    copy_loc l0
    mut_borrow_global PidReactionRegistry
    // @5
    st_loc l6
    copy_loc l5
    br_false l1
    copy_loc l6
    borrow_field PidReactionRegistry, active
    // @10
    copy_loc l1
    read_ref
    call smart_table::contains<vector<u8>, bool>
    br_true l2
    copy_loc l6
    // @15
    mut_borrow_field PidReactionRegistry, active
    move_loc l1
    read_ref
    ld_true
    call smart_table::add<vector<u8>, bool>
    // @20
    copy_loc l2
    ld_u8 1
    eq
    br_false l3
    copy_loc l6
    // @25
    borrow_field PidReactionRegistry, spark_count_given
    read_ref
    ld_u64 1
    add
    move_loc l6
    // @30
    mut_borrow_field PidReactionRegistry, spark_count_given
    write_ref
l8: call timestamp::now_seconds
    st_loc l7
    copy_loc l0
    // @35
    st_loc l8
    copy_loc l3
    st_loc l9
    move_loc l4
    st_loc l10
    // @40
    copy_loc l2
    st_loc l11
    move_loc l5
    br_false l4
    ld_u8 1
    // @45
    st_loc l12
l7: move_loc l8
    move_loc l9
    move_loc l10
    move_loc l11
    // @50
    move_loc l12
    copy_loc l7
    pack PulseEvent
    st_loc l13
    move_loc l2
    // @55
    ld_u8 1
    eq
    br_false l5
    call history::verb_spark
    st_loc l14
    // @60
l6: borrow_loc l13
    call bcs::to_bytes<PulseEvent>
    st_loc l15
    move_loc l0
    move_loc l14
    // @65
    move_loc l7
    move_loc l3
    call option::some<address>
    move_loc l15
    call option::none<address>
    // @70
    call history::new_entry
    call history::append
    ret
l5: call history::verb_echo
    st_loc l14
    // @75
    branch l6
l4: ld_u8 2
    st_loc l12
    branch l7
l3: copy_loc l6
    // @80
    borrow_field PidReactionRegistry, echo_count_given
    read_ref
    ld_u64 1
    add
    move_loc l6
    // @85
    mut_borrow_field PidReactionRegistry, echo_count_given
    write_ref
    branch l8
l2: move_loc l1
    pop
    // @90
    move_loc l6
    pop
    ld_u64 4
    abort
l1: copy_loc l6
    // @95
    borrow_field PidReactionRegistry, active
    copy_loc l1
    read_ref
    call smart_table::contains<vector<u8>, bool>
    br_false l9
    // @100
    copy_loc l6
    mut_borrow_field PidReactionRegistry, active
    move_loc l1
    read_ref
    call smart_table::remove<vector<u8>, bool>
    // @105
    pop
    copy_loc l2
    ld_u8 1
    eq
    br_false l10
    // @110
    copy_loc l6
    borrow_field PidReactionRegistry, spark_count_given
    read_ref
    ld_u64 0
    gt
    // @115
    br_false l11
    copy_loc l6
    borrow_field PidReactionRegistry, spark_count_given
    read_ref
    ld_u64 1
    // @120
    sub
    move_loc l6
    mut_borrow_field PidReactionRegistry, spark_count_given
    write_ref
    branch l8
    // @125
l11: move_loc l6
    pop
    branch l8
l10: copy_loc l6
    borrow_field PidReactionRegistry, echo_count_given
    // @130
    read_ref
    ld_u64 0
    gt
    br_false l12
    copy_loc l6
    // @135
    borrow_field PidReactionRegistry, echo_count_given
    read_ref
    ld_u64 1
    sub
    move_loc l6
    // @140
    mut_borrow_field PidReactionRegistry, echo_count_given
    write_ref
    branch l8
l12: move_loc l6
    pop
    // @145
    branch l8
l9: move_loc l1
    pop
    move_loc l6
    pop
    // @150
    ld_u64 5
    abort
l0: move_loc l1
    pop
    ld_u64 6
    // @155
    abort

// Function definition at index 11
#[persistent] entry public fun unecho(l0: &signer, l1: address, l2: u64) acquires PidReactionRegistry
    local l3: vector<u8>
    move_loc l0
    call signer::address_of
    call profile::derive_pid_address
    copy_loc l1
    copy_loc l2
    // @5
    ld_u8 2
    call make_key
    st_loc l3
    borrow_loc l3
    ld_u8 2
    // @10
    move_loc l1
    move_loc l2
    ld_false
    call toggle_reaction
    ret

// Function definition at index 12
#[persistent] entry public fun unspark(l0: &signer, l1: address, l2: u64) acquires PidReactionRegistry
    local l3: vector<u8>
    move_loc l0
    call signer::address_of
    call profile::derive_pid_address
    copy_loc l1
    copy_loc l2
    // @5
    ld_u8 1
    call make_key
    st_loc l3
    borrow_loc l3
    ld_u8 1
    // @10
    move_loc l1
    move_loc l2
    ld_false
    call toggle_reaction
    ret
```

---
