# DeSNet v0.3.2 — Chain Bytecode Bundle (PART 2 financial)

**Ground truth = on-chain bytecode fetched from mainnet @desnet on 2026-05-02.**

This is **2 of 3** parts. Each part covers a domain-grouped subset of modules.

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
| `amm` | 8,165 | `e0a984d031ae2884c914f5d990cad6597bece26507e33c6bb34bbbddcd302618` |
| `apt_vault` | 3,004 | `764df5444ec37a19ea0d12621de7f411a0a973dd61fe3066f7958d13ae6fb04f` |
| `lp_staking` | 6,047 | `754a12aa6558170945b1985e35a6829736d35ad43b7eea4491f79940ede01c27` |
| `lp_emission` | 1,929 | `015edb5016286d4b96621f7b971867f7560b63636abc370ceeab2c3d39026745` |
| `reaction_emission` | 2,195 | `f6c103a82678c2b08d3d4988e19f0464d11148e5a608d901920c25154bab79f0` |
| `handle_fee_vault` | 2,115 | `c6caf6b4f5ad59d932dee42a4000d3b94e3a7c5b6fbdb422c42623faecf15430` |

To verify each module's sha3 matches: `curl https://fullnode.mainnet.aptoslabs.com/v1/accounts/<@desnet>/module/<name>` → `.bytecode` field → strip `0x` → hex-decode → sha3_256.

---


## Module `amm` (8165 bytes)

`sha3_256: e0a984d031ae2884c914f5d990cad6597bece26507e33c6bb34bbbddcd302618`

### ABI surface

**Structs** (9):

- `Pool` `[key]` {handle:vector<u8>, apt_reserve:0x1::object::Object<0x1::fungible_asset::FungibleStore>, token_reserve:0x1::object::Object<0x1::fungible_asset::FungibleStore>, apt_fees:0x1::object::Object<0x1::fungible_asset::FungibleStore>, token_fees:0x1::object::Object<0x1::fungible_asset::FungibleStore>, token_metadata_addr:address, lp_supply:u128, fee_per_lp_apt:u128, fee_per_lp_token:u128, creator_pid:address, locked:bool, extend_ref:0x1::object::ExtendRef}
- `FeesExtractedForClaim` `[drop+store]` {handle:vector<u8>, pool_addr:address, apt_extracted:u64, token_extracted:u64}
- `FlashBorrowed` `[drop+store]` {pool_addr:address, metadata_addr:address, amount:u64, fee:u64}
- `FlashReceipt` `[]` {pool_addr:address, metadata_addr:address, amount:u64, fee:u64}
- `FlashRepaid` `[drop+store]` {pool_addr:address, metadata_addr:address, repaid:u64}
- `LiquidityAdded` `[drop+store]` {handle:vector<u8>, pool_addr:address, apt_in:u64, token_in:u64, lp_minted:u128, new_apt_reserve:u64, new_token_reserve:u64, new_lp_supply:u128}
- `LiquidityRemoved` `[drop+store]` {handle:vector<u8>, pool_addr:address, lp_burned:u128, apt_out:u64, token_out:u64, new_apt_reserve:u64, new_token_reserve:u64, new_lp_supply:u128}
- `PoolCreated` `[drop+store]` {handle:vector<u8>, pool_addr:address, token_metadata_addr:address, apt_in:u64, token_in:u64, lp_minted:u128, creator_pid:address}
- `Swapped` `[drop+store]` {handle:vector<u8>, pool_addr:address, actor:address, apt_to_token:bool, amount_in:u64, amount_out:u64, fee_amount:u64, new_apt_reserve:u64, new_token_reserve:u64}

**Public fns** (35):

-  `swap(address,address,0x1::fungible_asset::FungibleAsset,u64) → 0x1::fungible_asset::FungibleAsset`
- [view] `compute_amount_out(u64,u64,u64) → u64`
-  `compute_flash_fee(u64) → u64`
- [view] `creator_pid(vector<u8>) → address`
- [view] `creator_pid_at(address) → address`
- [view] `fee_acc_scale() → u128`
- [view] `fee_bps(vector<u8>) → u64`
- [view] `fee_buckets(vector<u8>) → u64,u64`
- [view] `fee_buckets_at(address) → u64,u64`
- [view] `fee_per_lp(vector<u8>) → u128,u128`
-  `flash_borrow(address,0x1::object::Object<0x1::fungible_asset::Metadata>,u64) → 0x1::fungible_asset::FungibleAsset,0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::amm::FlashReceipt`
- [view] `flash_fee_bps() → u64`
-  `flash_repay(address,0x1::fungible_asset::FungibleAsset,0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::amm::FlashReceipt)`
- [view] `lp_fee_per_share(address) → u128,u128`
- [view] `lp_fee_per_share_by_handle(vector<u8>) → u128,u128`
- [view] `lp_supply(vector<u8>) → u128`
- [view] `lp_supply_at(address) → u128`
-  `pool_address_of_handle(vector<u8>) → address`
-  `pool_exists(vector<u8>) → bool`
-  `pool_exists_at(address) → bool`
- [view] `pool_locked(address) → bool`
- [view] `pool_locked_by_handle(vector<u8>) → bool`
- [view] `pool_tokens(address) → 0x1::object::Object<0x1::fungible_asset::Metadata>,0x1::object::Object<0x1::fungible_asset::Metadata>`
- [view] `quote_swap_exact_in(vector<u8>,u64,bool) → u64`
- [view] `quote_swap_exact_in_at(address,u64,bool) → u64`
- [view] `read_warning() → vector<u8>`
- [view] `reserves(vector<u8>) → u64,u64`
- [view] `reserves_at(address) → u64,u64`
- [entry] `swap_apt_for_token(&signer,vector<u8>,u64,u64)`
-  `swap_exact_apt_in(vector<u8>,0x1::fungible_asset::FungibleAsset,u64) → 0x1::fungible_asset::FungibleAsset`
-  `swap_exact_apt_in_actor(vector<u8>,0x1::fungible_asset::FungibleAsset,u64,address) → 0x1::fungible_asset::FungibleAsset`
-  `swap_exact_token_in(vector<u8>,0x1::fungible_asset::FungibleAsset,u64) → 0x1::fungible_asset::FungibleAsset`
-  `swap_exact_token_in_actor(vector<u8>,0x1::fungible_asset::FungibleAsset,u64,address) → 0x1::fungible_asset::FungibleAsset`
- [entry] `swap_token_for_apt(&signer,vector<u8>,u64,u64)`
- [view] `token_metadata_addr(vector<u8>) → address`

**Friend fns** (4):

- `add_liquidity_internal(vector<u8>,0x1::fungible_asset::FungibleAsset,0x1::fungible_asset::FungibleAsset,u64) → u128,0x1::fungible_asset::FungibleAsset,0x1::fungible_asset::FungibleAsset`
- `create_pool_atomic(vector<u8>,0x1::fungible_asset::FungibleAsset,0x1::fungible_asset::FungibleAsset,address) → u128`
- `extract_fees_for_claim(vector<u8>,u64,u64) → 0x1::fungible_asset::FungibleAsset,0x1::fungible_asset::FungibleAsset`
- `remove_liquidity_internal(vector<u8>,u128,u64,u64) → 0x1::fungible_asset::FungibleAsset,0x1::fungible_asset::FungibleAsset`

### MASM (disassembled bytecode)

```move
// Bytecode version v9
module 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::amm
use 0x1::object
use 0x1::fungible_asset
use 0x1::event
use 0x1::vector
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::governance
use 0x1::math128
use 0x1::signer
use 0x1::aptos_coin
use 0x1::coin
use 0x1::primary_fungible_store
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::apt_vault
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::lp_staking
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::factory
struct Pool has key
  handle: vector<u8>
  apt_reserve: object::Object<fungible_asset::FungibleStore>
  token_reserve: object::Object<fungible_asset::FungibleStore>
  apt_fees: object::Object<fungible_asset::FungibleStore>
  token_fees: object::Object<fungible_asset::FungibleStore>
  token_metadata_addr: address
  lp_supply: u128
  fee_per_lp_apt: u128
  fee_per_lp_token: u128
  creator_pid: address
  locked: bool
  extend_ref: object::ExtendRef

struct FeesExtractedForClaim has drop + store
  handle: vector<u8>
  pool_addr: address
  apt_extracted: u64
  token_extracted: u64

struct FlashBorrowed has drop + store
  pool_addr: address
  metadata_addr: address
  amount: u64
  fee: u64

struct FlashReceipt
  pool_addr: address
  metadata_addr: address
  amount: u64
  fee: u64

struct FlashRepaid has drop + store
  pool_addr: address
  metadata_addr: address
  repaid: u64

struct LiquidityAdded has drop + store
  handle: vector<u8>
  pool_addr: address
  apt_in: u64
  token_in: u64
  lp_minted: u128
  new_apt_reserve: u64
  new_token_reserve: u64
  new_lp_supply: u128

struct LiquidityRemoved has drop + store
  handle: vector<u8>
  pool_addr: address
  lp_burned: u128
  apt_out: u64
  token_out: u64
  new_apt_reserve: u64
  new_token_reserve: u64
  new_lp_supply: u128

struct PoolCreated has drop + store
  handle: vector<u8>
  pool_addr: address
  token_metadata_addr: address
  apt_in: u64
  token_in: u64
  lp_minted: u128
  creator_pid: address

struct Swapped has drop + store
  handle: vector<u8>
  pool_addr: address
  actor: address
  apt_to_token: bool
  amount_in: u64
  amount_out: u64
  fee_amount: u64
  new_apt_reserve: u64
  new_token_reserve: u64

// Function definition at index 0
#[persistent] public fun swap(l0: address, l1: address, l2: fungible_asset::FungibleAsset, l3: u64): fungible_asset::FungibleAsset acquires Pool
    local l4: vector<u8>
    local l5: object::Object<fungible_asset::Metadata>
    copy_loc l0
    exists Pool
    br_false l0
    move_loc l0
    borrow_global Pool
    // @5
    borrow_field Pool, handle
    read_ref
    st_loc l4
    borrow_loc l2
    call fungible_asset::metadata_from_asset
    // @10
    st_loc l5
    borrow_loc l5
    call object::object_address<fungible_asset::Metadata>
    ld_const<address> 10
    eq
    // @15
    br_false l1
    move_loc l4
    move_loc l2
    move_loc l3
    call swap_exact_apt_in
    // @20
    ret
l1: move_loc l4
    move_loc l2
    move_loc l3
    call swap_exact_token_in
    // @25
    ret
l0: ld_u64 1
    abort

// Function definition at index 1
friend fun add_liquidity_internal(l0: vector<u8>, l1: fungible_asset::FungibleAsset, l2: fungible_asset::FungibleAsset, l3: u64): (u128, fungible_asset::FungibleAsset, fungible_asset::FungibleAsset) acquires Pool
    local l4: address
    local l5: u64
    local l6: u64
    local l7: bool
    local l8: object::Object<fungible_asset::Metadata>
    local l9: &mut Pool
    local l10: object::Object<fungible_asset::Metadata>
    local l11: u64
    local l12: u64
    local l13: bool
    local l14: u128
    local l15: u128
    local l16: u128
    local l17: u128
    local l18: u128
    local l19: fungible_asset::FungibleAsset
    local l20: fungible_asset::FungibleAsset
    move_loc l0
    call pool_address_of_handle
    st_loc l4
    copy_loc l4
    exists Pool
    // @5
    br_false l0
    borrow_loc l1
    call fungible_asset::amount
    st_loc l5
    borrow_loc l2
    // @10
    call fungible_asset::amount
    st_loc l6
    copy_loc l5
    ld_u64 0
    gt
    // @15
    br_false l1
    copy_loc l6
    ld_u64 0
    gt
    st_loc l7
    // @20
l17: move_loc l7
    br_false l2
    borrow_loc l1
    call fungible_asset::metadata_from_asset
    st_loc l8
    // @25
    borrow_loc l8
    call object::object_address<fungible_asset::Metadata>
    ld_const<address> 10
    eq
    br_false l3
    // @30
    copy_loc l4
    mut_borrow_global Pool
    st_loc l9
    copy_loc l9
    borrow_field Pool, locked
    // @35
    read_ref
    br_true l4
    borrow_loc l2
    call fungible_asset::metadata_from_asset
    st_loc l10
    // @40
    borrow_loc l10
    call object::object_address<fungible_asset::Metadata>
    copy_loc l9
    borrow_field Pool, token_metadata_addr
    read_ref
    // @45
    eq
    br_false l5
    copy_loc l9
    borrow_field Pool, apt_reserve
    read_ref
    // @50
    call fungible_asset::balance<fungible_asset::FungibleStore>
    st_loc l11
    copy_loc l9
    borrow_field Pool, token_reserve
    read_ref
    // @55
    call fungible_asset::balance<fungible_asset::FungibleStore>
    st_loc l12
    copy_loc l11
    ld_u64 0
    gt
    // @60
    br_false l6
    copy_loc l12
    ld_u64 0
    gt
    st_loc l13
    // @65
l16: move_loc l13
    br_false l7
    copy_loc l5
    cast_u128
    copy_loc l9
    // @70
    borrow_field Pool, lp_supply
    read_ref
    mul
    copy_loc l11
    cast_u128
    // @75
    div
    st_loc l14
    copy_loc l6
    cast_u128
    copy_loc l9
    // @80
    borrow_field Pool, lp_supply
    read_ref
    mul
    copy_loc l12
    cast_u128
    // @85
    div
    st_loc l15
    copy_loc l14
    copy_loc l15
    lt
    // @90
    br_false l8
    move_loc l14
    st_loc l16
l15: copy_loc l16
    ld_u128 0
    // @95
    gt
    br_false l9
    copy_loc l16
    move_loc l3
    cast_u128
    // @100
    ge
    br_false l10
    copy_loc l16
    move_loc l11
    cast_u128
    // @105
    mul
    copy_loc l9
    borrow_field Pool, lp_supply
    read_ref
    div
    // @110
    st_loc l17
    copy_loc l16
    move_loc l12
    cast_u128
    mul
    // @115
    copy_loc l9
    borrow_field Pool, lp_supply
    read_ref
    div
    st_loc l18
    // @120
    copy_loc l5
    cast_u128
    move_loc l17
    sub
    st_loc l17
    // @125
    copy_loc l6
    cast_u128
    move_loc l18
    sub
    st_loc l18
    // @130
    copy_loc l17
    ld_u128 0
    gt
    br_false l11
    mut_borrow_loc l1
    // @135
    copy_loc l17
    cast_u64
    call fungible_asset::extract
    st_loc l19
l14: copy_loc l18
    // @140
    ld_u128 0
    gt
    br_false l12
    mut_borrow_loc l2
    copy_loc l18
    // @145
    cast_u64
    call fungible_asset::extract
    st_loc l20
l13: copy_loc l9
    borrow_field Pool, apt_reserve
    // @150
    read_ref
    move_loc l1
    call fungible_asset::deposit<fungible_asset::FungibleStore>
    copy_loc l9
    borrow_field Pool, token_reserve
    // @155
    read_ref
    move_loc l2
    call fungible_asset::deposit<fungible_asset::FungibleStore>
    copy_loc l9
    borrow_field Pool, lp_supply
    // @160
    read_ref
    copy_loc l16
    add
    copy_loc l9
    mut_borrow_field Pool, lp_supply
    // @165
    write_ref
    copy_loc l9
    borrow_field Pool, handle
    read_ref
    move_loc l4
    // @170
    move_loc l5
    move_loc l17
    cast_u64
    sub
    move_loc l6
    // @175
    move_loc l18
    cast_u64
    sub
    copy_loc l16
    copy_loc l9
    // @180
    borrow_field Pool, apt_reserve
    read_ref
    call fungible_asset::balance<fungible_asset::FungibleStore>
    copy_loc l9
    borrow_field Pool, token_reserve
    // @185
    read_ref
    call fungible_asset::balance<fungible_asset::FungibleStore>
    move_loc l9
    borrow_field Pool, lp_supply
    read_ref
    // @190
    pack LiquidityAdded
    call event::emit<LiquidityAdded>
    move_loc l16
    move_loc l19
    move_loc l20
    // @195
    ret
l12: move_loc l10
    call fungible_asset::zero<fungible_asset::Metadata>
    st_loc l20
    branch l13
    // @200
l11: move_loc l8
    call fungible_asset::zero<fungible_asset::Metadata>
    st_loc l19
    branch l14
l10: move_loc l9
    // @205
    pop
    ld_u64 4
    abort
l9: move_loc l9
    pop
    // @210
    ld_u64 3
    abort
l8: move_loc l15
    st_loc l16
    branch l15
    // @215
l7: move_loc l9
    pop
    ld_u64 3
    abort
l6: ld_false
    // @220
    st_loc l13
    branch l16
l5: move_loc l9
    pop
    ld_u64 6
    // @225
    abort
l4: move_loc l9
    pop
    ld_u64 12
    abort
    // @230
l3: ld_u64 6
    abort
l2: ld_u64 5
    abort
l1: ld_false
    // @235
    st_loc l7
    branch l17
l0: ld_u64 1
    abort

// Function definition at index 2
#[persistent] public fun compute_amount_out(l0: u64, l1: u64, l2: u64): u64
    local l3: u128
    local l4: u128
    move_loc l2
    cast_u128
    ld_u128 9990
    mul
    st_loc l3
    // @5
    copy_loc l3
    move_loc l1
    cast_u128
    mul
    move_loc l0
    // @10
    cast_u128
    ld_u128 10000
    mul
    move_loc l3
    add
    // @15
    div
    cast_u64
    ret

// Function definition at index 3
#[persistent] public fun compute_flash_fee(l0: u64): u64
    move_loc l0
    ld_u64 10
    mul
    ld_u64 10000
    div
    // @5
    ret

// Function definition at index 4
friend fun create_pool_atomic(l0: vector<u8>, l1: fungible_asset::FungibleAsset, l2: fungible_asset::FungibleAsset, l3: address): u128
    local l4: address
    local l5: u64
    local l6: u64
    local l7: bool
    local l8: object::Object<fungible_asset::Metadata>
    local l9: object::Object<fungible_asset::Metadata>
    local l10: address
    local l11: signer
    local l12: object::ConstructorRef
    local l13: signer
    local l14: object::ExtendRef
    local l15: object::TransferRef
    local l16: object::Object<fungible_asset::FungibleStore>
    local l17: object::Object<fungible_asset::FungibleStore>
    local l18: object::Object<fungible_asset::FungibleStore>
    local l19: object::Object<fungible_asset::FungibleStore>
    local l20: u128
    borrow_loc l0
    call vector::is_empty<u8>
    br_true l0
    copy_loc l0
    call pool_address_of_handle
    // @5
    st_loc l4
    copy_loc l4
    exists Pool
    br_true l1
    borrow_loc l1
    // @10
    call fungible_asset::amount
    st_loc l5
    borrow_loc l2
    call fungible_asset::amount
    st_loc l6
    // @15
    copy_loc l5
    ld_u64 0
    gt
    br_false l2
    copy_loc l6
    // @20
    ld_u64 0
    gt
    st_loc l7
l6: move_loc l7
    br_false l3
    // @25
    borrow_loc l1
    call fungible_asset::metadata_from_asset
    st_loc l8
    borrow_loc l8
    call object::object_address<fungible_asset::Metadata>
    // @30
    ld_const<address> 10
    eq
    br_false l4
    borrow_loc l2
    call fungible_asset::metadata_from_asset
    // @35
    st_loc l9
    borrow_loc l9
    call object::object_address<fungible_asset::Metadata>
    st_loc l10
    call governance::derive_pkg_signer
    // @40
    st_loc l11
    borrow_loc l11
    borrow_loc l0
    call pool_seed
    call object::create_named_object
    // @45
    st_loc l12
    borrow_loc l12
    call object::generate_signer
    st_loc l13
    borrow_loc l12
    // @50
    call object::generate_extend_ref
    st_loc l14
    borrow_loc l12
    call object::generate_transfer_ref
    st_loc l15
    // @55
    borrow_loc l15
    call object::disable_ungated_transfer
    copy_loc l4
    copy_loc l8
    call create_store_at_pool
    // @60
    st_loc l16
    copy_loc l4
    copy_loc l9
    call create_store_at_pool
    st_loc l17
    // @65
    copy_loc l4
    move_loc l8
    call create_store_at_pool
    st_loc l18
    copy_loc l4
    // @70
    move_loc l9
    call create_store_at_pool
    st_loc l19
    copy_loc l5
    copy_loc l6
    // @75
    call mint_lp_initial
    st_loc l20
    copy_loc l20
    ld_u128 1000
    ge
    // @80
    br_false l5
    copy_loc l16
    move_loc l1
    call fungible_asset::deposit<fungible_asset::FungibleStore>
    copy_loc l17
    // @85
    move_loc l2
    call fungible_asset::deposit<fungible_asset::FungibleStore>
    borrow_loc l13
    copy_loc l0
    move_loc l16
    // @90
    move_loc l17
    move_loc l18
    move_loc l19
    copy_loc l10
    copy_loc l20
    // @95
    ld_u128 0
    ld_u128 0
    copy_loc l3
    ld_false
    move_loc l14
    // @100
    pack Pool
    move_to Pool
    move_loc l0
    move_loc l4
    move_loc l10
    // @105
    move_loc l5
    move_loc l6
    copy_loc l20
    move_loc l3
    pack PoolCreated
    // @110
    call event::emit<PoolCreated>
    move_loc l20
    ret
l5: ld_u64 9
    abort
    // @115
l4: ld_u64 6
    abort
l3: ld_u64 5
    abort
l2: ld_false
    // @120
    st_loc l7
    branch l6
l1: ld_u64 2
    abort
l0: ld_u64 7
    // @125
    abort

// Function definition at index 5
#[persistent] public fun creator_pid(l0: vector<u8>): address acquires Pool
    local l1: address
    move_loc l0
    call pool_address_of_handle
    st_loc l1
    copy_loc l1
    exists Pool
    // @5
    br_false l0
    move_loc l1
    borrow_global Pool
    borrow_field Pool, creator_pid
    read_ref
    // @10
    ret
l0: ld_u64 1
    abort

// Function definition at index 6
fun create_store_at_pool(l0: address, l1: object::Object<fungible_asset::Metadata>): object::Object<fungible_asset::FungibleStore>
    local l2: object::ConstructorRef
    move_loc l0
    call object::create_object
    st_loc l2
    borrow_loc l2
    move_loc l1
    // @5
    call fungible_asset::create_store<fungible_asset::Metadata>
    ret

// Function definition at index 7
#[persistent] public fun creator_pid_at(l0: address): address acquires Pool
    copy_loc l0
    exists Pool
    br_false l0
    move_loc l0
    borrow_global Pool
    // @5
    borrow_field Pool, creator_pid
    read_ref
    ret
l0: ld_u64 1
    abort

// Function definition at index 8
friend fun extract_fees_for_claim(l0: vector<u8>, l1: u64, l2: u64): (fungible_asset::FungibleAsset, fungible_asset::FungibleAsset) acquires Pool
    local l3: address
    local l4: &Pool
    local l5: signer
    local l6: fungible_asset::FungibleAsset
    local l7: fungible_asset::FungibleAsset
    move_loc l0
    call pool_address_of_handle
    st_loc l3
    copy_loc l3
    exists Pool
    // @5
    br_false l0
    copy_loc l3
    borrow_global Pool
    st_loc l4
    copy_loc l4
    // @10
    borrow_field Pool, locked
    read_ref
    br_true l1
    copy_loc l4
    borrow_field Pool, apt_fees
    // @15
    read_ref
    call fungible_asset::balance<fungible_asset::FungibleStore>
    copy_loc l1
    ge
    br_false l2
    // @20
    copy_loc l4
    borrow_field Pool, token_fees
    read_ref
    call fungible_asset::balance<fungible_asset::FungibleStore>
    copy_loc l2
    // @25
    ge
    br_false l3
    copy_loc l4
    borrow_field Pool, extend_ref
    call object::generate_signer_for_extending
    // @30
    st_loc l5
    borrow_loc l5
    copy_loc l4
    borrow_field Pool, apt_fees
    read_ref
    // @35
    copy_loc l1
    call fungible_asset::withdraw<fungible_asset::FungibleStore>
    borrow_loc l5
    copy_loc l4
    borrow_field Pool, token_fees
    // @40
    read_ref
    copy_loc l2
    call fungible_asset::withdraw<fungible_asset::FungibleStore>
    move_loc l4
    borrow_field Pool, handle
    // @45
    read_ref
    move_loc l3
    move_loc l1
    move_loc l2
    pack FeesExtractedForClaim
    // @50
    call event::emit<FeesExtractedForClaim>
    ret
l3: move_loc l4
    pop
    ld_u64 11
    // @55
    abort
l2: move_loc l4
    pop
    ld_u64 11
    abort
    // @60
l1: move_loc l4
    pop
    ld_u64 12
    abort
l0: ld_u64 1
    // @65
    abort

// Function definition at index 9
#[persistent] public fun fee_acc_scale(): u128
    ld_u128 1000000000000000000
    ret

// Function definition at index 10
#[persistent] public fun fee_bps(l0: vector<u8>): u64
    ld_u64 10
    ret

// Function definition at index 11
#[persistent] public fun fee_buckets(l0: vector<u8>): (u64, u64) acquires Pool
    local l1: address
    local l2: &Pool
    move_loc l0
    call pool_address_of_handle
    st_loc l1
    copy_loc l1
    exists Pool
    // @5
    br_false l0
    move_loc l1
    borrow_global Pool
    st_loc l2
    copy_loc l2
    // @10
    borrow_field Pool, apt_fees
    read_ref
    call fungible_asset::balance<fungible_asset::FungibleStore>
    move_loc l2
    borrow_field Pool, token_fees
    // @15
    read_ref
    call fungible_asset::balance<fungible_asset::FungibleStore>
    ret
l0: ld_u64 1
    abort

// Function definition at index 12
#[persistent] public fun fee_buckets_at(l0: address): (u64, u64) acquires Pool
    local l1: &Pool
    copy_loc l0
    exists Pool
    br_false l0
    move_loc l0
    borrow_global Pool
    // @5
    st_loc l1
    copy_loc l1
    borrow_field Pool, apt_fees
    read_ref
    call fungible_asset::balance<fungible_asset::FungibleStore>
    // @10
    move_loc l1
    borrow_field Pool, token_fees
    read_ref
    call fungible_asset::balance<fungible_asset::FungibleStore>
    ret
    // @15
l0: ld_u64 1
    abort

// Function definition at index 13
#[persistent] public fun fee_per_lp(l0: vector<u8>): (u128, u128) acquires Pool
    local l1: address
    local l2: &Pool
    move_loc l0
    call pool_address_of_handle
    st_loc l1
    copy_loc l1
    exists Pool
    // @5
    br_false l0
    move_loc l1
    borrow_global Pool
    st_loc l2
    copy_loc l2
    // @10
    borrow_field Pool, fee_per_lp_apt
    read_ref
    move_loc l2
    borrow_field Pool, fee_per_lp_token
    read_ref
    // @15
    ret
l0: ld_u64 1
    abort

// Function definition at index 14
#[persistent] public fun flash_borrow(l0: address, l1: object::Object<fungible_asset::Metadata>, l2: u64): (fungible_asset::FungibleAsset, FlashReceipt) acquires Pool
    local l3: &mut Pool
    local l4: address
    local l5: object::Object<fungible_asset::FungibleStore>
    local l6: u64
    local l7: signer
    local l8: FlashReceipt
    local l9: fungible_asset::FungibleAsset
    copy_loc l0
    exists Pool
    br_false l0
    copy_loc l2
    ld_u64 0
    // @5
    gt
    br_false l1
    copy_loc l0
    mut_borrow_global Pool
    st_loc l3
    // @10
    copy_loc l3
    borrow_field Pool, locked
    read_ref
    br_true l2
    ld_true
    // @15
    copy_loc l3
    mut_borrow_field Pool, locked
    write_ref
    borrow_loc l1
    call object::object_address<fungible_asset::Metadata>
    // @20
    st_loc l4
    copy_loc l4
    ld_const<address> 10
    eq
    br_false l3
    // @25
    copy_loc l3
    borrow_field Pool, apt_reserve
    read_ref
    st_loc l5
l6: copy_loc l5
    // @30
    call fungible_asset::balance<fungible_asset::FungibleStore>
    copy_loc l2
    ge
    br_false l4
    copy_loc l2
    // @35
    ld_u64 10
    mul
    ld_u64 10000
    div
    st_loc l6
    // @40
    move_loc l3
    borrow_field Pool, extend_ref
    call object::generate_signer_for_extending
    st_loc l7
    borrow_loc l7
    // @45
    move_loc l5
    copy_loc l2
    call fungible_asset::withdraw<fungible_asset::FungibleStore>
    copy_loc l0
    copy_loc l4
    // @50
    copy_loc l2
    copy_loc l6
    pack FlashReceipt
    move_loc l0
    move_loc l4
    // @55
    move_loc l2
    move_loc l6
    pack FlashBorrowed
    call event::emit<FlashBorrowed>
    ret
    // @60
l4: move_loc l3
    pop
    ld_u64 3
    abort
l3: copy_loc l4
    // @65
    copy_loc l3
    borrow_field Pool, token_metadata_addr
    read_ref
    eq
    br_false l5
    // @70
    copy_loc l3
    borrow_field Pool, token_reserve
    read_ref
    st_loc l5
    branch l6
    // @75
l5: move_loc l3
    pop
    ld_u64 15
    abort
l2: move_loc l3
    // @80
    pop
    ld_u64 12
    abort
l1: ld_u64 5
    abort
    // @85
l0: ld_u64 1
    abort

// Function definition at index 15
#[persistent] public fun flash_fee_bps(): u64
    ld_u64 10
    ret

// Function definition at index 16
#[persistent] public fun flash_repay(l0: address, l1: fungible_asset::FungibleAsset, l2: FlashReceipt) acquires Pool
    local l3: u64
    local l4: u64
    local l5: address
    local l6: address
    local l7: u64
    local l8: object::Object<fungible_asset::Metadata>
    local l9: &mut Pool
    local l10: object::Object<fungible_asset::FungibleStore>
    local l11: object::Object<fungible_asset::FungibleStore>
    local l12: bool
    local l13: fungible_asset::FungibleAsset
    local l14: u128
    move_loc l2
    unpack FlashReceipt
    st_loc l3
    st_loc l4
    st_loc l5
    // @5
    st_loc l6
    copy_loc l0
    move_loc l6
    eq
    br_false l0
    // @10
    borrow_loc l1
    call fungible_asset::amount
    st_loc l7
    copy_loc l7
    move_loc l4
    // @15
    copy_loc l3
    add
    eq
    br_false l1
    borrow_loc l1
    // @20
    call fungible_asset::metadata_from_asset
    st_loc l8
    borrow_loc l8
    call object::object_address<fungible_asset::Metadata>
    copy_loc l5
    // @25
    eq
    br_false l2
    copy_loc l0
    mut_borrow_global Pool
    st_loc l9
    // @30
    copy_loc l5
    ld_const<address> 10
    eq
    br_false l3
    copy_loc l9
    // @35
    borrow_field Pool, apt_reserve
    read_ref
    st_loc l10
    copy_loc l9
    borrow_field Pool, apt_fees
    // @40
    read_ref
    st_loc l11
    ld_true
    st_loc l12
l7: mut_borrow_loc l1
    // @45
    copy_loc l3
    call fungible_asset::extract
    st_loc l13
    move_loc l11
    move_loc l13
    // @50
    call fungible_asset::deposit<fungible_asset::FungibleStore>
    move_loc l10
    move_loc l1
    call fungible_asset::deposit<fungible_asset::FungibleStore>
    copy_loc l9
    // @55
    borrow_field Pool, lp_supply
    read_ref
    ld_u128 0
    gt
    br_true l4
    // @60
    branch l5
l4: move_loc l3
    cast_u128
    ld_u128 1000000000000000000
    mul
    // @65
    copy_loc l9
    borrow_field Pool, lp_supply
    read_ref
    div
    st_loc l14
    // @70
    move_loc l12
    br_false l6
    copy_loc l9
    borrow_field Pool, fee_per_lp_apt
    read_ref
    // @75
    move_loc l14
    add
    copy_loc l9
    mut_borrow_field Pool, fee_per_lp_apt
    write_ref
    // @80
l5: ld_false
    move_loc l9
    mut_borrow_field Pool, locked
    write_ref
    move_loc l0
    // @85
    move_loc l5
    move_loc l7
    pack FlashRepaid
    call event::emit<FlashRepaid>
    ret
    // @90
l6: copy_loc l9
    borrow_field Pool, fee_per_lp_token
    read_ref
    move_loc l14
    add
    // @95
    copy_loc l9
    mut_borrow_field Pool, fee_per_lp_token
    write_ref
    branch l5
l3: copy_loc l9
    // @100
    borrow_field Pool, token_reserve
    read_ref
    st_loc l10
    copy_loc l9
    borrow_field Pool, token_fees
    // @105
    read_ref
    st_loc l11
    ld_false
    st_loc l12
    branch l7
    // @110
l2: ld_u64 15
    abort
l1: ld_u64 14
    abort
l0: ld_u64 13
    // @115
    abort

// Function definition at index 17
#[persistent] public fun lp_fee_per_share(l0: address): (u128, u128) acquires Pool
    local l1: &Pool
    copy_loc l0
    exists Pool
    br_false l0
    move_loc l0
    borrow_global Pool
    // @5
    st_loc l1
    copy_loc l1
    borrow_field Pool, fee_per_lp_apt
    read_ref
    move_loc l1
    // @10
    borrow_field Pool, fee_per_lp_token
    read_ref
    ret
l0: ld_u64 1
    abort

// Function definition at index 18
#[persistent] public fun lp_fee_per_share_by_handle(l0: vector<u8>): (u128, u128) acquires Pool
    move_loc l0
    call pool_address_of_handle
    call lp_fee_per_share
    ret

// Function definition at index 19
#[persistent] public fun lp_supply(l0: vector<u8>): u128 acquires Pool
    local l1: address
    move_loc l0
    call pool_address_of_handle
    st_loc l1
    copy_loc l1
    exists Pool
    // @5
    br_false l0
    move_loc l1
    borrow_global Pool
    borrow_field Pool, lp_supply
    read_ref
    // @10
    ret
l0: ld_u64 1
    abort

// Function definition at index 20
#[persistent] public fun lp_supply_at(l0: address): u128 acquires Pool
    copy_loc l0
    exists Pool
    br_false l0
    move_loc l0
    borrow_global Pool
    // @5
    borrow_field Pool, lp_supply
    read_ref
    ret
l0: ld_u64 1
    abort

// Function definition at index 21
fun mint_lp_initial(l0: u64, l1: u64): u128
    move_loc l0
    cast_u128
    move_loc l1
    cast_u128
    mul
    // @5
    call math128::sqrt
    ret

// Function definition at index 22
#[persistent] public fun pool_address_of_handle(l0: vector<u8>): address
    local l1: vector<u8>
    local l2: address
    borrow_loc l0
    call pool_seed
    st_loc l1
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    st_loc l2
    // @5
    borrow_loc l2
    move_loc l1
    call object::create_object_address
    ret

// Function definition at index 23
#[persistent] public fun pool_exists(l0: vector<u8>): bool
    move_loc l0
    call pool_address_of_handle
    exists Pool
    ret

// Function definition at index 24
#[persistent] public fun pool_exists_at(l0: address): bool
    move_loc l0
    exists Pool
    ret

// Function definition at index 25
#[persistent] public fun pool_locked(l0: address): bool acquires Pool
    copy_loc l0
    exists Pool
    br_false l0
    move_loc l0
    borrow_global Pool
    // @5
    borrow_field Pool, locked
    read_ref
    ret
l0: ld_u64 1
    abort

// Function definition at index 26
#[persistent] public fun pool_locked_by_handle(l0: vector<u8>): bool acquires Pool
    move_loc l0
    call pool_address_of_handle
    call pool_locked
    ret

// Function definition at index 27
fun pool_seed(l0: &vector<u8>): vector<u8>
    local l1: vector<u8>
    ld_const<vector<u8>> [100, 101, 115, 110, 101, 116, 58, 58, 97, 109, 109, 58, 58, 112, 111, 111, 108, 58, 58]
    st_loc l1
    mut_borrow_loc l1
    move_loc l0
    read_ref
    // @5
    call vector::append<u8>
    move_loc l1
    ret

// Function definition at index 28
#[persistent] public fun pool_tokens(l0: address): (object::Object<fungible_asset::Metadata>, object::Object<fungible_asset::Metadata>) acquires Pool
    local l1: &Pool
    local l2: object::Object<fungible_asset::Metadata>
    local l3: object::Object<fungible_asset::Metadata>
    copy_loc l0
    exists Pool
    br_false l0
    move_loc l0
    borrow_global Pool
    // @5
    st_loc l1
    ld_const<address> 10
    call object::address_to_object<fungible_asset::Metadata>
    move_loc l1
    borrow_field Pool, token_metadata_addr
    // @10
    read_ref
    call object::address_to_object<fungible_asset::Metadata>
    ret
l0: ld_u64 1
    abort

// Function definition at index 29
#[persistent] public fun quote_swap_exact_in(l0: vector<u8>, l1: u64, l2: bool): u64 acquires Pool
    local l3: address
    local l4: &Pool
    local l5: u64
    local l6: u64
    move_loc l0
    call pool_address_of_handle
    st_loc l3
    copy_loc l3
    exists Pool
    // @5
    br_false l0
    move_loc l3
    borrow_global Pool
    st_loc l4
    copy_loc l4
    // @10
    borrow_field Pool, apt_reserve
    read_ref
    call fungible_asset::balance<fungible_asset::FungibleStore>
    st_loc l5
    move_loc l4
    // @15
    borrow_field Pool, token_reserve
    read_ref
    call fungible_asset::balance<fungible_asset::FungibleStore>
    st_loc l6
    move_loc l2
    // @20
    br_false l1
    move_loc l5
    move_loc l6
    move_loc l1
    call compute_amount_out
    // @25
    ret
l1: move_loc l6
    move_loc l5
    move_loc l1
    call compute_amount_out
    // @30
    ret
l0: ld_u64 1
    abort

// Function definition at index 30
#[persistent] public fun quote_swap_exact_in_at(l0: address, l1: u64, l2: bool): u64 acquires Pool
    local l3: &Pool
    local l4: u64
    local l5: u64
    copy_loc l0
    exists Pool
    br_false l0
    move_loc l0
    borrow_global Pool
    // @5
    st_loc l3
    copy_loc l3
    borrow_field Pool, apt_reserve
    read_ref
    call fungible_asset::balance<fungible_asset::FungibleStore>
    // @10
    st_loc l4
    move_loc l3
    borrow_field Pool, token_reserve
    read_ref
    call fungible_asset::balance<fungible_asset::FungibleStore>
    // @15
    st_loc l5
    move_loc l2
    br_false l1
    move_loc l4
    move_loc l5
    // @20
    move_loc l1
    call compute_amount_out
    ret
l1: move_loc l5
    move_loc l4
    // @25
    move_loc l1
    call compute_amount_out
    ret
l0: ld_u64 1
    abort

// Function definition at index 31
#[persistent] public fun read_warning(): vector<u8>
    ld_const<vector<u8>> [68, 69, 83, 78, 69, 84, 32, 65, 77, 77, 32, 120, 42, 121, 61, 107, 46, 32, 65, 73, 45, 97, 117, 100, 105, 116, 101, 100, 32, 111, 110, 108, 121, 46, 32, 85, 115, 101, 32, 97, 116, 32, 111, 119, 110, 32, 114, 105, 115, 107, 46]
    ret

// Function definition at index 32
friend fun remove_liquidity_internal(l0: vector<u8>, l1: u128, l2: u64, l3: u64): (fungible_asset::FungibleAsset, fungible_asset::FungibleAsset) acquires Pool
    local l4: address
    local l5: &mut Pool
    local l6: u64
    local l7: u128
    local l8: u64
    local l9: bool
    local l10: signer
    local l11: fungible_asset::FungibleAsset
    local l12: fungible_asset::FungibleAsset
    move_loc l0
    call pool_address_of_handle
    st_loc l4
    copy_loc l4
    exists Pool
    // @5
    br_false l0
    copy_loc l1
    ld_u128 0
    gt
    br_false l1
    // @10
    copy_loc l4
    mut_borrow_global Pool
    st_loc l5
    copy_loc l5
    borrow_field Pool, locked
    // @15
    read_ref
    br_true l2
    copy_loc l5
    borrow_field Pool, lp_supply
    read_ref
    // @20
    copy_loc l1
    ge
    br_false l3
    copy_loc l5
    borrow_field Pool, apt_reserve
    // @25
    read_ref
    call fungible_asset::balance<fungible_asset::FungibleStore>
    copy_loc l5
    borrow_field Pool, token_reserve
    read_ref
    // @30
    call fungible_asset::balance<fungible_asset::FungibleStore>
    st_loc l6
    cast_u128
    copy_loc l1
    mul
    // @35
    copy_loc l5
    borrow_field Pool, lp_supply
    read_ref
    div
    move_loc l6
    // @40
    cast_u128
    copy_loc l1
    mul
    copy_loc l5
    borrow_field Pool, lp_supply
    // @45
    read_ref
    div
    st_loc l7
    cast_u64
    st_loc l8
    // @50
    move_loc l7
    cast_u64
    st_loc l6
    copy_loc l8
    move_loc l2
    // @55
    ge
    br_false l4
    copy_loc l6
    move_loc l3
    ge
    // @60
    br_false l5
    copy_loc l8
    ld_u64 0
    gt
    br_false l6
    // @65
    copy_loc l6
    ld_u64 0
    gt
    st_loc l9
l8: move_loc l9
    // @70
    br_false l7
    copy_loc l5
    borrow_field Pool, lp_supply
    read_ref
    copy_loc l1
    // @75
    sub
    copy_loc l5
    mut_borrow_field Pool, lp_supply
    write_ref
    copy_loc l5
    // @80
    borrow_field Pool, extend_ref
    call object::generate_signer_for_extending
    st_loc l10
    borrow_loc l10
    copy_loc l5
    // @85
    borrow_field Pool, apt_reserve
    read_ref
    copy_loc l8
    call fungible_asset::withdraw<fungible_asset::FungibleStore>
    borrow_loc l10
    // @90
    copy_loc l5
    borrow_field Pool, token_reserve
    read_ref
    copy_loc l6
    call fungible_asset::withdraw<fungible_asset::FungibleStore>
    // @95
    copy_loc l5
    borrow_field Pool, handle
    read_ref
    move_loc l4
    move_loc l1
    // @100
    move_loc l8
    move_loc l6
    copy_loc l5
    borrow_field Pool, apt_reserve
    read_ref
    // @105
    call fungible_asset::balance<fungible_asset::FungibleStore>
    copy_loc l5
    borrow_field Pool, token_reserve
    read_ref
    call fungible_asset::balance<fungible_asset::FungibleStore>
    // @110
    move_loc l5
    borrow_field Pool, lp_supply
    read_ref
    pack LiquidityRemoved
    call event::emit<LiquidityRemoved>
    // @115
    ret
l7: move_loc l5
    pop
    ld_u64 3
    abort
    // @120
l6: ld_false
    st_loc l9
    branch l8
l5: move_loc l5
    pop
    // @125
    ld_u64 4
    abort
l4: move_loc l5
    pop
    ld_u64 4
    // @130
    abort
l3: move_loc l5
    pop
    ld_u64 8
    abort
    // @135
l2: move_loc l5
    pop
    ld_u64 12
    abort
l1: ld_u64 5
    // @140
    abort
l0: ld_u64 1
    abort

// Function definition at index 33
#[persistent] public fun reserves(l0: vector<u8>): (u64, u64) acquires Pool
    local l1: address
    local l2: &Pool
    move_loc l0
    call pool_address_of_handle
    st_loc l1
    copy_loc l1
    exists Pool
    // @5
    br_false l0
    move_loc l1
    borrow_global Pool
    st_loc l2
    copy_loc l2
    // @10
    borrow_field Pool, apt_reserve
    read_ref
    call fungible_asset::balance<fungible_asset::FungibleStore>
    move_loc l2
    borrow_field Pool, token_reserve
    // @15
    read_ref
    call fungible_asset::balance<fungible_asset::FungibleStore>
    ret
l0: ld_u64 1
    abort

// Function definition at index 34
#[persistent] public fun reserves_at(l0: address): (u64, u64) acquires Pool
    local l1: &Pool
    copy_loc l0
    exists Pool
    br_false l0
    move_loc l0
    borrow_global Pool
    // @5
    st_loc l1
    copy_loc l1
    borrow_field Pool, apt_reserve
    read_ref
    call fungible_asset::balance<fungible_asset::FungibleStore>
    // @10
    move_loc l1
    borrow_field Pool, token_reserve
    read_ref
    call fungible_asset::balance<fungible_asset::FungibleStore>
    ret
    // @15
l0: ld_u64 1
    abort

// Function definition at index 35
#[persistent] entry public fun swap_apt_for_token(l0: &signer, l1: vector<u8>, l2: u64, l3: u64) acquires Pool
    local l4: address
    local l5: fungible_asset::FungibleAsset
    copy_loc l0
    call signer::address_of
    st_loc l4
    move_loc l0
    move_loc l2
    // @5
    call coin::withdraw<aptos_coin::AptosCoin>
    call coin::coin_to_fungible_asset<aptos_coin::AptosCoin>
    st_loc l5
    move_loc l1
    move_loc l5
    // @10
    move_loc l3
    copy_loc l4
    call swap_exact_apt_in_actor
    st_loc l5
    move_loc l4
    // @15
    move_loc l5
    call primary_fungible_store::deposit
    ret

// Function definition at index 36
#[persistent] public fun swap_exact_apt_in(l0: vector<u8>, l1: fungible_asset::FungibleAsset, l2: u64): fungible_asset::FungibleAsset acquires Pool
    move_loc l0
    move_loc l1
    move_loc l2
    ld_const<address> 0
    call swap_exact_apt_in_actor
    // @5
    ret

// Function definition at index 37
#[persistent] public fun swap_exact_apt_in_actor(l0: vector<u8>, l1: fungible_asset::FungibleAsset, l2: u64, l3: address): fungible_asset::FungibleAsset acquires Pool
    local l4: address
    local l5: u64
    local l6: object::Object<fungible_asset::Metadata>
    local l7: &mut Pool
    local l8: u64
    local l9: u64
    local l10: u64
    local l11: fungible_asset::FungibleAsset
    local l12: u128
    local l13: signer
    move_loc l0
    call pool_address_of_handle
    st_loc l4
    copy_loc l4
    exists Pool
    // @5
    br_false l0
    borrow_loc l1
    call fungible_asset::amount
    st_loc l5
    copy_loc l5
    // @10
    ld_u64 0
    gt
    br_false l1
    borrow_loc l1
    call fungible_asset::metadata_from_asset
    // @15
    st_loc l6
    borrow_loc l6
    call object::object_address<fungible_asset::Metadata>
    ld_const<address> 10
    eq
    // @20
    br_false l2
    copy_loc l4
    mut_borrow_global Pool
    st_loc l7
    copy_loc l7
    // @25
    borrow_field Pool, locked
    read_ref
    br_true l3
    copy_loc l7
    borrow_field Pool, apt_reserve
    // @30
    read_ref
    call fungible_asset::balance<fungible_asset::FungibleStore>
    copy_loc l7
    borrow_field Pool, token_reserve
    read_ref
    // @35
    call fungible_asset::balance<fungible_asset::FungibleStore>
    copy_loc l5
    ld_u64 10
    mul
    ld_u64 10000
    // @40
    div
    st_loc l8
    copy_loc l5
    call compute_amount_out
    st_loc l10
    // @45
    copy_loc l10
    move_loc l2
    ge
    br_false l4
    copy_loc l10
    // @50
    ld_u64 0
    gt
    br_false l5
    mut_borrow_loc l1
    copy_loc l8
    // @55
    call fungible_asset::extract
    st_loc l11
    copy_loc l7
    borrow_field Pool, apt_fees
    read_ref
    // @60
    move_loc l11
    call fungible_asset::deposit<fungible_asset::FungibleStore>
    copy_loc l7
    borrow_field Pool, lp_supply
    read_ref
    // @65
    ld_u128 0
    gt
    br_true l6
    branch l7
l6: copy_loc l8
    // @70
    cast_u128
    ld_u128 1000000000000000000
    mul
    copy_loc l7
    borrow_field Pool, lp_supply
    // @75
    read_ref
    div
    st_loc l12
    copy_loc l7
    borrow_field Pool, fee_per_lp_apt
    // @80
    read_ref
    move_loc l12
    add
    copy_loc l7
    mut_borrow_field Pool, fee_per_lp_apt
    // @85
    write_ref
l7: copy_loc l7
    borrow_field Pool, apt_reserve
    read_ref
    move_loc l1
    // @90
    call fungible_asset::deposit<fungible_asset::FungibleStore>
    copy_loc l7
    borrow_field Pool, extend_ref
    call object::generate_signer_for_extending
    st_loc l13
    // @95
    borrow_loc l13
    copy_loc l7
    borrow_field Pool, token_reserve
    read_ref
    copy_loc l10
    // @100
    call fungible_asset::withdraw<fungible_asset::FungibleStore>
    copy_loc l7
    borrow_field Pool, handle
    read_ref
    move_loc l4
    // @105
    move_loc l3
    ld_true
    move_loc l5
    move_loc l10
    move_loc l8
    // @110
    copy_loc l7
    borrow_field Pool, apt_reserve
    read_ref
    call fungible_asset::balance<fungible_asset::FungibleStore>
    move_loc l7
    // @115
    borrow_field Pool, token_reserve
    read_ref
    call fungible_asset::balance<fungible_asset::FungibleStore>
    pack Swapped
    call event::emit<Swapped>
    // @120
    ret
l5: move_loc l7
    pop
    ld_u64 3
    abort
    // @125
l4: move_loc l7
    pop
    ld_u64 4
    abort
l3: move_loc l7
    // @130
    pop
    ld_u64 12
    abort
l2: ld_u64 6
    abort
    // @135
l1: ld_u64 5
    abort
l0: ld_u64 1
    abort

// Function definition at index 38
#[persistent] public fun swap_exact_token_in(l0: vector<u8>, l1: fungible_asset::FungibleAsset, l2: u64): fungible_asset::FungibleAsset acquires Pool
    move_loc l0
    move_loc l1
    move_loc l2
    ld_const<address> 0
    call swap_exact_token_in_actor
    // @5
    ret

// Function definition at index 39
#[persistent] public fun swap_exact_token_in_actor(l0: vector<u8>, l1: fungible_asset::FungibleAsset, l2: u64, l3: address): fungible_asset::FungibleAsset acquires Pool
    local l4: address
    local l5: u64
    local l6: &mut Pool
    local l7: object::Object<fungible_asset::Metadata>
    local l8: u64
    local l9: u64
    local l10: fungible_asset::FungibleAsset
    local l11: u128
    local l12: signer
    move_loc l0
    call pool_address_of_handle
    st_loc l4
    copy_loc l4
    exists Pool
    // @5
    br_false l0
    borrow_loc l1
    call fungible_asset::amount
    st_loc l5
    copy_loc l5
    // @10
    ld_u64 0
    gt
    br_false l1
    copy_loc l4
    mut_borrow_global Pool
    // @15
    st_loc l6
    copy_loc l6
    borrow_field Pool, locked
    read_ref
    br_true l2
    // @20
    borrow_loc l1
    call fungible_asset::metadata_from_asset
    st_loc l7
    borrow_loc l7
    call object::object_address<fungible_asset::Metadata>
    // @25
    copy_loc l6
    borrow_field Pool, token_metadata_addr
    read_ref
    eq
    br_false l3
    // @30
    copy_loc l6
    borrow_field Pool, apt_reserve
    read_ref
    call fungible_asset::balance<fungible_asset::FungibleStore>
    st_loc l8
    // @35
    copy_loc l6
    borrow_field Pool, token_reserve
    read_ref
    call fungible_asset::balance<fungible_asset::FungibleStore>
    copy_loc l5
    // @40
    ld_u64 10
    mul
    ld_u64 10000
    div
    st_loc l9
    // @45
    move_loc l8
    copy_loc l5
    call compute_amount_out
    st_loc l8
    copy_loc l8
    // @50
    move_loc l2
    ge
    br_false l4
    copy_loc l8
    ld_u64 0
    // @55
    gt
    br_false l5
    mut_borrow_loc l1
    copy_loc l9
    call fungible_asset::extract
    // @60
    st_loc l10
    copy_loc l6
    borrow_field Pool, token_fees
    read_ref
    move_loc l10
    // @65
    call fungible_asset::deposit<fungible_asset::FungibleStore>
    copy_loc l6
    borrow_field Pool, lp_supply
    read_ref
    ld_u128 0
    // @70
    gt
    br_true l6
    branch l7
l6: copy_loc l9
    cast_u128
    // @75
    ld_u128 1000000000000000000
    mul
    copy_loc l6
    borrow_field Pool, lp_supply
    read_ref
    // @80
    div
    st_loc l11
    copy_loc l6
    borrow_field Pool, fee_per_lp_token
    read_ref
    // @85
    move_loc l11
    add
    copy_loc l6
    mut_borrow_field Pool, fee_per_lp_token
    write_ref
    // @90
l7: copy_loc l6
    borrow_field Pool, token_reserve
    read_ref
    move_loc l1
    call fungible_asset::deposit<fungible_asset::FungibleStore>
    // @95
    copy_loc l6
    borrow_field Pool, extend_ref
    call object::generate_signer_for_extending
    st_loc l12
    borrow_loc l12
    // @100
    copy_loc l6
    borrow_field Pool, apt_reserve
    read_ref
    copy_loc l8
    call fungible_asset::withdraw<fungible_asset::FungibleStore>
    // @105
    copy_loc l6
    borrow_field Pool, handle
    read_ref
    move_loc l4
    move_loc l3
    // @110
    ld_false
    move_loc l5
    move_loc l8
    move_loc l9
    copy_loc l6
    // @115
    borrow_field Pool, apt_reserve
    read_ref
    call fungible_asset::balance<fungible_asset::FungibleStore>
    move_loc l6
    borrow_field Pool, token_reserve
    // @120
    read_ref
    call fungible_asset::balance<fungible_asset::FungibleStore>
    pack Swapped
    call event::emit<Swapped>
    ret
    // @125
l5: move_loc l6
    pop
    ld_u64 3
    abort
l4: move_loc l6
    // @130
    pop
    ld_u64 4
    abort
l3: move_loc l6
    pop
    // @135
    ld_u64 6
    abort
l2: move_loc l6
    pop
    ld_u64 12
    // @140
    abort
l1: ld_u64 5
    abort
l0: ld_u64 1
    abort

// Function definition at index 40
#[persistent] entry public fun swap_token_for_apt(l0: &signer, l1: vector<u8>, l2: u64, l3: u64) acquires Pool
    local l4: address
    local l5: address
    local l6: object::Object<fungible_asset::Metadata>
    local l7: fungible_asset::FungibleAsset
    copy_loc l0
    call signer::address_of
    st_loc l4
    copy_loc l1
    call pool_address_of_handle
    // @5
    st_loc l5
    copy_loc l5
    exists Pool
    br_false l0
    move_loc l5
    // @10
    borrow_global Pool
    borrow_field Pool, token_metadata_addr
    read_ref
    call object::address_to_object<fungible_asset::Metadata>
    st_loc l6
    // @15
    move_loc l0
    move_loc l6
    move_loc l2
    call primary_fungible_store::withdraw<fungible_asset::Metadata>
    st_loc l7
    // @20
    move_loc l1
    move_loc l7
    move_loc l3
    copy_loc l4
    call swap_exact_token_in_actor
    // @25
    st_loc l7
    move_loc l4
    move_loc l7
    call primary_fungible_store::deposit
    ret
    // @30
l0: move_loc l0
    pop
    ld_u64 1
    abort

// Function definition at index 41
#[persistent] public fun token_metadata_addr(l0: vector<u8>): address acquires Pool
    local l1: address
    move_loc l0
    call pool_address_of_handle
    st_loc l1
    copy_loc l1
    exists Pool
    // @5
    br_false l0
    move_loc l1
    borrow_global Pool
    borrow_field Pool, token_metadata_addr
    read_ref
    // @10
    ret
l0: ld_u64 1
    abort
```

---

## Module `apt_vault` (3004 bytes)

`sha3_256: 764df5444ec37a19ea0d12621de7f411a0a973dd61fe3066f7958d13ae6fb04f`

### ABI surface

**Structs** (4):

- `AptDeposited` `[drop+store]` {vault_addr:address, depositor:address, amount:u64}
- `AptSettled` `[drop+store]` {vault_addr:address, total_apt:u64, to_buyback:u64, to_owner:u64, owner_addr:address, token_burned:u64}
- `SettleRequested` `[drop+store]` {vault_addr:address, requested_at_secs:u64, executable_at_secs:u64}
- `Vault` `[key]` {apt_balance:0x1::coin::Coin<0x1::aptos_coin::AptosCoin>, burn_ref:0x1::fungible_asset::BurnRef, token_metadata_addr:address, handle:vector<u8>, amm_pool_addr:address, pid_object_addr:address, spec_version:u32, extend_ref:0x1::object::ExtendRef, pending_settle_at_secs:u64}

**Public fns** (10):

- [view] `handle(address) → vector<u8>`
- [view] `pool_addr(address) → address`
- [view] `apt_balance(address) → u64`
- [view] `current_owner(address) → address`
- [entry] `deposit_apt(&signer,address,u64)`
- [entry] `execute_settle(&signer,address)`
- [view] `pending_settle_at_secs(address) → u64`
- [entry] `request_settle(&signer,address)`
- [view] `settle_executable_at_secs(address) → u64`
- [view] `token_metadata(address) → address`

**Friend fns** (2):

- `burn_via_vault(address,0x1::fungible_asset::FungibleAsset)`
- `deploy(&signer,vector<u8>,address,address,address,0x1::fungible_asset::BurnRef) → address`

### MASM (disassembled bytecode)

```move
// Bytecode version v9
module 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::apt_vault
use 0x1::coin
use 0x1::aptos_coin
use 0x1::fungible_asset
use 0x1::object
use 0x1::signer
use 0x1::event
use 0x1::timestamp
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::amm
use 0x1::vector
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::factory
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::handle_fee_vault
struct AptDeposited has drop + store
  vault_addr: address
  depositor: address
  amount: u64

struct AptSettled has drop + store
  vault_addr: address
  total_apt: u64
  to_buyback: u64
  to_owner: u64
  owner_addr: address
  token_burned: u64

struct SettleRequested has drop + store
  vault_addr: address
  requested_at_secs: u64
  executable_at_secs: u64

struct Vault has key
  apt_balance: coin::Coin<aptos_coin::AptosCoin>
  burn_ref: fungible_asset::BurnRef
  token_metadata_addr: address
  handle: vector<u8>
  amm_pool_addr: address
  pid_object_addr: address
  spec_version: u32
  extend_ref: object::ExtendRef
  pending_settle_at_secs: u64

// Function definition at index 0
#[persistent] public fun handle(l0: address): vector<u8> acquires Vault
    move_loc l0
    borrow_global Vault
    borrow_field Vault, handle
    read_ref
    ret

// Function definition at index 1
#[persistent] public fun pool_addr(l0: address): address acquires Vault
    move_loc l0
    borrow_global Vault
    borrow_field Vault, amm_pool_addr
    read_ref
    ret

// Function definition at index 2
#[persistent] public fun apt_balance(l0: address): u64 acquires Vault
    move_loc l0
    borrow_global Vault
    borrow_field Vault, apt_balance
    call coin::value<aptos_coin::AptosCoin>
    ret

// Function definition at index 3
friend fun burn_via_vault(l0: address, l1: fungible_asset::FungibleAsset) acquires Vault
    move_loc l0
    borrow_global Vault
    borrow_field Vault, burn_ref
    move_loc l1
    call fungible_asset::burn
    // @5
    ret

// Function definition at index 4
#[persistent] public fun current_owner(l0: address): address acquires Vault
    move_loc l0
    borrow_global Vault
    borrow_field Vault, pid_object_addr
    read_ref
    call object::address_to_object<object::ObjectCore>
    // @5
    call object::owner<object::ObjectCore>
    ret

// Function definition at index 5
friend fun deploy(l0: &signer, l1: vector<u8>, l2: address, l3: address, l4: address, l5: fungible_asset::BurnRef): address
    local l6: vector<u8>
    local l7: object::ConstructorRef
    local l8: object::ExtendRef
    local l9: signer
    local l10: object::TransferRef
    borrow_loc l1
    call make_seed
    st_loc l6
    move_loc l0
    move_loc l6
    // @5
    call object::create_named_object
    st_loc l7
    borrow_loc l7
    call object::address_from_constructor_ref
    borrow_loc l7
    // @10
    call object::generate_extend_ref
    st_loc l8
    borrow_loc l7
    call object::generate_signer
    st_loc l9
    // @15
    borrow_loc l7
    call object::generate_transfer_ref
    st_loc l10
    borrow_loc l10
    call object::disable_ungated_transfer
    // @20
    borrow_loc l9
    call coin::zero<aptos_coin::AptosCoin>
    move_loc l5
    move_loc l2
    move_loc l1
    // @25
    move_loc l3
    move_loc l4
    ld_u32 4
    move_loc l8
    ld_u64 0
    // @30
    pack Vault
    move_to Vault
    ret

// Function definition at index 6
#[persistent] entry public fun deposit_apt(l0: &signer, l1: address, l2: u64) acquires Vault
    local l3: coin::Coin<aptos_coin::AptosCoin>
    copy_loc l1
    mut_borrow_global Vault
    copy_loc l0
    copy_loc l2
    call coin::withdraw<aptos_coin::AptosCoin>
    // @5
    st_loc l3
    mut_borrow_field Vault, apt_balance
    move_loc l3
    call coin::merge<aptos_coin::AptosCoin>
    move_loc l1
    // @10
    move_loc l0
    call signer::address_of
    move_loc l2
    pack AptDeposited
    call event::emit<AptDeposited>
    // @15
    ret

// Function definition at index 7
#[persistent] entry public fun execute_settle(l0: &signer, l1: address) acquires Vault
    local l2: &mut Vault
    local l3: u64
    local l4: address
    local l5: u64
    local l6: u64
    local l7: u64
    local l8: u64
    local l9: coin::Coin<aptos_coin::AptosCoin>
    local l10: fungible_asset::FungibleAsset
    local l11: fungible_asset::FungibleAsset
    local l12: u64
    copy_loc l1
    mut_borrow_global Vault
    st_loc l2
    move_loc l0
    pop
    // @5
    copy_loc l2
    borrow_field Vault, pending_settle_at_secs
    read_ref
    ld_u64 0
    gt
    // @10
    br_false l0
    call timestamp::now_seconds
    copy_loc l2
    borrow_field Vault, pending_settle_at_secs
    read_ref
    // @15
    ld_u64 60
    add
    ge
    br_false l1
    copy_loc l2
    // @20
    borrow_field Vault, handle
    read_ref
    call amm::pool_address_of_handle
    copy_loc l2
    borrow_field Vault, amm_pool_addr
    // @25
    read_ref
    eq
    br_false l2
    copy_loc l2
    borrow_field Vault, apt_balance
    // @30
    call coin::value<aptos_coin::AptosCoin>
    st_loc l3
    copy_loc l3
    ld_u64 10000000
    ge
    // @35
    br_false l3
    copy_loc l2
    borrow_field Vault, pid_object_addr
    read_ref
    call object::address_to_object<object::ObjectCore>
    // @40
    call object::owner<object::ObjectCore>
    st_loc l4
    copy_loc l3
    ld_u64 2
    div
    // @45
    st_loc l5
    copy_loc l2
    borrow_field Vault, handle
    read_ref
    call amm::reserves
    // @50
    pop
    ld_u64 100
    mul
    ld_u64 10000
    div
    // @55
    st_loc l6
    copy_loc l5
    copy_loc l6
    gt
    br_false l4
    // @60
    move_loc l6
    st_loc l7
l5: copy_loc l3
    copy_loc l7
    sub
    // @65
    st_loc l8
    copy_loc l2
    mut_borrow_field Vault, apt_balance
    copy_loc l7
    call coin::extract<aptos_coin::AptosCoin>
    // @70
    copy_loc l2
    mut_borrow_field Vault, apt_balance
    copy_loc l8
    call coin::extract<aptos_coin::AptosCoin>
    st_loc l9
    // @75
    call coin::coin_to_fungible_asset<aptos_coin::AptosCoin>
    st_loc l10
    copy_loc l2
    borrow_field Vault, handle
    read_ref
    // @80
    move_loc l10
    ld_u64 0
    call amm::swap_exact_apt_in
    st_loc l11
    borrow_loc l11
    // @85
    call fungible_asset::amount
    st_loc l12
    copy_loc l2
    borrow_field Vault, burn_ref
    move_loc l11
    // @90
    call fungible_asset::burn
    copy_loc l4
    move_loc l9
    call coin::deposit<aptos_coin::AptosCoin>
    ld_u64 0
    // @95
    move_loc l2
    mut_borrow_field Vault, pending_settle_at_secs
    write_ref
    move_loc l1
    move_loc l3
    // @100
    move_loc l7
    move_loc l8
    move_loc l4
    move_loc l12
    pack AptSettled
    // @105
    call event::emit<AptSettled>
    ret
l4: move_loc l5
    st_loc l7
    branch l5
    // @110
l3: move_loc l2
    pop
    ld_u64 1
    abort
l2: move_loc l2
    // @115
    pop
    ld_u64 5
    abort
l1: move_loc l2
    pop
    // @120
    ld_u64 7
    abort
l0: move_loc l2
    pop
    ld_u64 6
    // @125
    abort

// Function definition at index 8
fun make_seed(l0: &vector<u8>): vector<u8>
    local l1: vector<u8>
    vec_pack <u8>, 0
    st_loc l1
    mut_borrow_loc l1
    ld_const<vector<u8>> [118, 97, 117, 108, 116, 58, 58]
    call vector::append<u8>
    // @5
    mut_borrow_loc l1
    move_loc l0
    read_ref
    call vector::append<u8>
    move_loc l1
    // @10
    ret

// Function definition at index 9
#[persistent] public fun pending_settle_at_secs(l0: address): u64 acquires Vault
    move_loc l0
    borrow_global Vault
    borrow_field Vault, pending_settle_at_secs
    read_ref
    ret

// Function definition at index 10
#[persistent] entry public fun request_settle(l0: &signer, l1: address) acquires Vault
    local l2: &mut Vault
    local l3: u64
    local l4: bool
    local l5: &mut u64
    copy_loc l1
    mut_borrow_global Vault
    st_loc l2
    move_loc l0
    pop
    // @5
    copy_loc l2
    borrow_field Vault, apt_balance
    call coin::value<aptos_coin::AptosCoin>
    ld_u64 10000000
    ge
    // @10
    br_false l0
    call timestamp::now_seconds
    st_loc l3
    copy_loc l2
    borrow_field Vault, pending_settle_at_secs
    // @15
    read_ref
    ld_u64 0
    eq
    br_false l1
    ld_true
    // @20
    st_loc l4
l3: move_loc l4
    br_false l2
    move_loc l2
    mut_borrow_field Vault, pending_settle_at_secs
    // @25
    st_loc l5
    copy_loc l3
    move_loc l5
    write_ref
    move_loc l1
    // @30
    copy_loc l3
    move_loc l3
    ld_u64 60
    add
    pack SettleRequested
    // @35
    call event::emit<SettleRequested>
    ret
l2: move_loc l2
    pop
    ld_u64 8
    // @40
    abort
l1: copy_loc l3
    copy_loc l2
    borrow_field Vault, pending_settle_at_secs
    read_ref
    // @45
    ld_u64 60
    add
    ld_u64 3600
    add
    ge
    // @50
    st_loc l4
    branch l3
l0: move_loc l2
    pop
    ld_u64 1
    // @55
    abort

// Function definition at index 11
#[persistent] public fun settle_executable_at_secs(l0: address): u64 acquires Vault
    local l1: u64
    move_loc l0
    borrow_global Vault
    borrow_field Vault, pending_settle_at_secs
    read_ref
    st_loc l1
    // @5
    copy_loc l1
    ld_u64 0
    eq
    br_false l0
    ld_u64 0
    // @10
    ret
l0: move_loc l1
    ld_u64 60
    add
    ret

// Function definition at index 12
#[persistent] public fun token_metadata(l0: address): address acquires Vault
    move_loc l0
    borrow_global Vault
    borrow_field Vault, token_metadata_addr
    read_ref
    ret
```

---

## Module `lp_staking` (6047 bytes)

`sha3_256: 754a12aa6558170945b1985e35a6829736d35ad43b7eea4491f79940ede01c27`

### ABI surface

**Structs** (6):

- `Position` `[key]` {pool_addr:address, handle:vector<u8>, shares:u128, last_acc_per_share:u128, last_fee_per_lp_apt:u128, last_fee_per_lp_token:u128, unlock_at_secs:u64, recipient_pid:address}
- `Claimed` `[drop+store]` {handle:vector<u8>, position_addr:address, recipient:address, emission_amount:u64, apt_fee_amount:u64, token_fee_amount:u64}
- `PositionCreated` `[drop+store]` {handle:vector<u8>, position_addr:address, owner:address, shares:u128, unlock_at_secs:u64, recipient_pid:address, kind:u8}
- `PositionRemoved` `[drop+store]` {handle:vector<u8>, position_addr:address, owner:address, shares:u128, apt_returned:u64, token_returned:u64}
- `StakingPool` `[key]` {handle:vector<u8>, token_metadata_addr:address, rate_per_sec:u64, accumulated_per_share:u128, last_update_secs:u64, emission_reserve_addr:address, extend_ref:0x1::object::ExtendRef}
- `StakingPoolCreated` `[drop+store]` {handle:vector<u8>, pool_addr:address, token_metadata_addr:address, emission_reserve_addr:address, rate_per_sec:u64}

**Public fns** (22):

- [view] `acc_scale() → u128`
- [entry] `add_liquidity(&signer,vector<u8>,u64,u64,u64)`
- [entry] `add_liquidity_with_lock(&signer,vector<u8>,u64,u64,u64,u64)`
- [entry] `claim(&signer,address)`
- [view] `default_rate_per_sec() → u64`
- [view] `has_position(address) → bool`
- [view] `pool_acc_per_share(address) → u128`
- [view] `pool_rate_per_sec(address) → u64`
- [view] `position_fee_debt(0x1::object::Object<0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::lp_staking::Position>) → u128,u128`
- [view] `position_owner(address) → address`
- [view] `position_pending_all(address) → u64,u64,u64`
- [view] `position_pending_fees(0x1::object::Object<0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::lp_staking::Position>) → u64,u64`
- [view] `position_pool(address) → address`
- [view] `position_pool_addr(0x1::object::Object<0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::lp_staking::Position>) → address`
- [view] `position_recipient_pid(address) → address`
- [view] `position_shares(address) → u128`
- [view] `position_shares_obj(0x1::object::Object<0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::lp_staking::Position>) → u128`
- [view] `position_unlock_at(address) → u64`
- [entry] `remove_liquidity(&signer,address,u64,u64)`
-  `staking_pool_address_of_handle(vector<u8>) → address`
-  `staking_pool_exists(vector<u8>) → bool`
- [view] `unlock_forever_marker() → u64`

**Friend fns** (1):

- `create_pool_and_lock(vector<u8>,address,address,address,&signer,u128) → address`

### MASM (disassembled bytecode)

```move
// Bytecode version v9
module 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::lp_staking
use 0x1::object
use 0x1::vector
use 0x1::timestamp
use 0x1::signer
use 0x1::aptos_coin
use 0x1::coin
use 0x1::fungible_asset
use 0x1::primary_fungible_store
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::amm
use 0x1::event
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::lp_emission
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::governance
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::voter_history
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::factory
struct Position has key
  pool_addr: address
  handle: vector<u8>
  shares: u128
  last_acc_per_share: u128
  last_fee_per_lp_apt: u128
  last_fee_per_lp_token: u128
  unlock_at_secs: u64
  recipient_pid: address

struct Claimed has drop + store
  handle: vector<u8>
  position_addr: address
  recipient: address
  emission_amount: u64
  apt_fee_amount: u64
  token_fee_amount: u64

struct PositionCreated has drop + store
  handle: vector<u8>
  position_addr: address
  owner: address
  shares: u128
  unlock_at_secs: u64
  recipient_pid: address
  kind: u8

struct PositionRemoved has drop + store
  handle: vector<u8>
  position_addr: address
  owner: address
  shares: u128
  apt_returned: u64
  token_returned: u64

struct StakingPool has key
  handle: vector<u8>
  token_metadata_addr: address
  rate_per_sec: u64
  accumulated_per_share: u128
  last_update_secs: u64
  emission_reserve_addr: address
  extend_ref: object::ExtendRef

struct StakingPoolCreated has drop + store
  handle: vector<u8>
  pool_addr: address
  token_metadata_addr: address
  emission_reserve_addr: address
  rate_per_sec: u64

// Function definition at index 0
fun pool_seed(l0: &vector<u8>): vector<u8>
    local l1: vector<u8>
    ld_const<vector<u8>> [100, 101, 115, 110, 101, 116, 58, 58, 108, 112, 95, 115, 116, 97, 107, 105, 110, 103, 58, 58, 112, 111, 111, 108, 58, 58]
    st_loc l1
    mut_borrow_loc l1
    move_loc l0
    read_ref
    // @5
    call vector::append<u8>
    move_loc l1
    ret

// Function definition at index 1
#[persistent] public fun acc_scale(): u128
    ld_u128 1000000000000000000
    ret

// Function definition at index 2
#[persistent] entry public fun add_liquidity(l0: &signer, l1: vector<u8>, l2: u64, l3: u64, l4: u64) acquires StakingPool
    move_loc l0
    move_loc l1
    move_loc l2
    move_loc l3
    move_loc l4
    // @5
    ld_u64 0
    call add_liquidity_with_lock_internal
    ret

// Function definition at index 3
#[persistent] entry public fun add_liquidity_with_lock(l0: &signer, l1: vector<u8>, l2: u64, l3: u64, l4: u64, l5: u64) acquires StakingPool
    local l6: u64
    call timestamp::now_seconds
    st_loc l6
    copy_loc l5
    move_loc l6
    gt
    // @5
    br_false l0
    move_loc l0
    move_loc l1
    move_loc l2
    move_loc l3
    // @10
    move_loc l4
    move_loc l5
    call add_liquidity_with_lock_internal
    ret
l0: move_loc l0
    // @15
    pop
    ld_u64 8
    abort

// Function definition at index 4
fun add_liquidity_with_lock_internal(l0: &signer, l1: vector<u8>, l2: u64, l3: u64, l4: u64, l5: u64) acquires StakingPool
    local l6: address
    local l7: address
    local l8: fungible_asset::FungibleAsset
    local l9: object::Object<fungible_asset::Metadata>
    local l10: fungible_asset::FungibleAsset
    local l11: fungible_asset::FungibleAsset
    local l12: fungible_asset::FungibleAsset
    local l13: u128
    local l14: &StakingPool
    local l15: u128
    local l16: vector<u8>
    local l17: u128
    local l18: u128
    local l19: object::ConstructorRef
    local l20: signer
    local l21: address
    local l22: u8
    copy_loc l0
    call signer::address_of
    st_loc l6
    copy_loc l1
    call staking_pool_address_of_handle
    // @5
    st_loc l7
    copy_loc l7
    exists StakingPool
    br_false l0
    copy_loc l0
    // @10
    move_loc l2
    call coin::withdraw<aptos_coin::AptosCoin>
    call coin::coin_to_fungible_asset<aptos_coin::AptosCoin>
    st_loc l8
    copy_loc l7
    // @15
    borrow_global StakingPool
    borrow_field StakingPool, token_metadata_addr
    read_ref
    call object::address_to_object<fungible_asset::Metadata>
    st_loc l9
    // @20
    move_loc l0
    move_loc l9
    move_loc l3
    call primary_fungible_store::withdraw<fungible_asset::Metadata>
    st_loc l10
    // @25
    copy_loc l1
    move_loc l8
    move_loc l10
    move_loc l4
    call amm::add_liquidity_internal
    // @30
    st_loc l11
    st_loc l12
    st_loc l13
    copy_loc l13
    ld_u128 0
    // @35
    gt
    br_false l1
    borrow_loc l12
    call fungible_asset::amount
    ld_u64 0
    // @40
    gt
    br_false l2
    copy_loc l6
    move_loc l12
    call primary_fungible_store::deposit
    // @45
l7: borrow_loc l11
    call fungible_asset::amount
    ld_u64 0
    gt
    br_false l3
    // @50
    copy_loc l6
    move_loc l11
    call primary_fungible_store::deposit
l6: copy_loc l7
    call update_pool
    // @55
    copy_loc l7
    borrow_global StakingPool
    st_loc l14
    copy_loc l14
    borrow_field StakingPool, accumulated_per_share
    // @60
    read_ref
    st_loc l15
    move_loc l14
    borrow_field StakingPool, handle
    read_ref
    // @65
    st_loc l16
    copy_loc l1
    call amm::fee_per_lp
    st_loc l17
    st_loc l18
    // @70
    copy_loc l6
    call object::create_object
    st_loc l19
    borrow_loc l19
    call object::generate_signer
    // @75
    st_loc l20
    borrow_loc l20
    call signer::address_of
    st_loc l21
    borrow_loc l20
    // @80
    move_loc l7
    move_loc l1
    copy_loc l13
    move_loc l15
    move_loc l18
    // @85
    move_loc l17
    copy_loc l5
    ld_const<address> 0
    pack Position
    move_to Position
    // @90
    copy_loc l5
    ld_u64 0
    eq
    br_false l4
    ld_u8 2
    // @95
    st_loc l22
l5: move_loc l16
    move_loc l21
    move_loc l6
    move_loc l13
    // @100
    move_loc l5
    ld_const<address> 0
    move_loc l22
    pack PositionCreated
    call event::emit<PositionCreated>
    // @105
    ret
l4: ld_u8 3
    st_loc l22
    branch l5
l3: move_loc l11
    // @110
    call fungible_asset::destroy_zero
    branch l6
l2: move_loc l12
    call fungible_asset::destroy_zero
    branch l7
    // @115
l1: ld_u64 5
    abort
l0: move_loc l0
    pop
    ld_u64 1
    // @120
    abort

// Function definition at index 5
#[persistent] entry public fun claim(l0: &signer, l1: address) acquires Position, StakingPool
    copy_loc l1
    exists Position
    move_loc l0
    pop
    br_false l0
    // @5
    move_loc l1
    call claim_internal
    ret
l0: ld_u64 3
    abort

// Function definition at index 6
fun claim_internal(l0: address) acquires Position, StakingPool
    local l1: &mut Position
    local l2: address
    local l3: vector<u8>
    local l4: u128
    local l5: &StakingPool
    local l6: u128
    local l7: &mut u128
    local l8: u128
    local l9: u128
    local l10: u128
    local l11: u64
    local l12: u64
    local l13: u64
    local l14: object::Object<fungible_asset::Metadata>
    local l15: fungible_asset::FungibleAsset
    local l16: u64
    local l17: signer
    local l18: bool
    local l19: fungible_asset::FungibleAsset
    local l20: fungible_asset::FungibleAsset
    local l21: bool
    local l22: bool
    copy_loc l0
    mut_borrow_global Position
    st_loc l1
    copy_loc l1
    borrow_field Position, pool_addr
    // @5
    read_ref
    st_loc l2
    copy_loc l1
    borrow_field Position, handle
    read_ref
    // @10
    st_loc l3
    copy_loc l1
    borrow_field Position, shares
    read_ref
    st_loc l4
    // @15
    copy_loc l2
    call update_pool
    move_loc l2
    borrow_global StakingPool
    st_loc l5
    // @20
    copy_loc l5
    borrow_field StakingPool, accumulated_per_share
    read_ref
    st_loc l6
    copy_loc l6
    // @25
    copy_loc l1
    borrow_field Position, last_acc_per_share
    read_ref
    sub
    copy_loc l4
    // @30
    mul
    ld_u128 1000000000000000000
    div
    copy_loc l1
    mut_borrow_field Position, last_acc_per_share
    // @35
    st_loc l7
    move_loc l6
    move_loc l7
    write_ref
    copy_loc l3
    // @40
    call amm::fee_per_lp
    st_loc l8
    st_loc l6
    call amm::fee_acc_scale
    st_loc l9
    // @45
    copy_loc l6
    copy_loc l1
    borrow_field Position, last_fee_per_lp_apt
    read_ref
    sub
    // @50
    copy_loc l4
    mul
    copy_loc l9
    div
    st_loc l10
    // @55
    copy_loc l8
    copy_loc l1
    borrow_field Position, last_fee_per_lp_token
    read_ref
    sub
    // @60
    move_loc l4
    mul
    move_loc l9
    div
    st_loc l4
    // @65
    copy_loc l1
    mut_borrow_field Position, last_fee_per_lp_apt
    st_loc l7
    move_loc l6
    move_loc l7
    // @70
    write_ref
    copy_loc l1
    mut_borrow_field Position, last_fee_per_lp_token
    st_loc l7
    move_loc l8
    // @75
    move_loc l7
    write_ref
    cast_u64
    st_loc l11
    move_loc l10
    // @80
    cast_u64
    st_loc l12
    move_loc l4
    cast_u64
    st_loc l13
    // @85
    move_loc l1
    borrow_field Position, recipient_pid
    read_ref
    copy_loc l0
    call resolve_recipient
    // @90
    st_loc l2
    copy_loc l11
    ld_u64 0
    gt
    br_true l0
    // @95
    branch l1
l0: copy_loc l5
    borrow_field StakingPool, token_metadata_addr
    read_ref
    call object::address_to_object<fungible_asset::Metadata>
    // @100
    st_loc l14
    copy_loc l5
    borrow_field StakingPool, emission_reserve_addr
    read_ref
    move_loc l14
    // @105
    copy_loc l11
    call lp_emission::pull_for_claim
    st_loc l15
    borrow_loc l15
    call fungible_asset::amount
    // @110
    st_loc l16
    copy_loc l2
    move_loc l15
    call primary_fungible_store::deposit
    copy_loc l16
    // @115
    ld_u64 0
    gt
    br_true l2
    branch l1
l2: call governance::derive_pkg_signer
    // @120
    st_loc l17
    borrow_loc l17
    copy_loc l2
    copy_loc l5
    borrow_field StakingPool, token_metadata_addr
    // @125
    read_ref
    copy_loc l16
    call voter_history::record_reward_received_for_token
    move_loc l16
    call governance::record_emission_for_window
    // @130
l1: copy_loc l12
    ld_u64 0
    gt
    br_false l3
    ld_true
    // @135
    st_loc l18
l14: move_loc l18
    br_true l4
    branch l5
l4: move_loc l3
    // @140
    copy_loc l12
    copy_loc l13
    call amm::extract_fees_for_claim
    st_loc l19
    st_loc l20
    // @145
    borrow_loc l20
    call fungible_asset::amount
    ld_u64 0
    gt
    br_false l6
    // @150
    copy_loc l2
    move_loc l20
    call primary_fungible_store::deposit
l13: borrow_loc l19
    call fungible_asset::amount
    // @155
    ld_u64 0
    gt
    br_false l7
    copy_loc l2
    move_loc l19
    // @160
    call primary_fungible_store::deposit
l5: copy_loc l11
    ld_u64 0
    eq
    br_false l8
    // @165
    copy_loc l12
    ld_u64 0
    eq
    st_loc l21
l12: move_loc l21
    // @170
    br_false l9
    copy_loc l13
    ld_u64 0
    eq
    st_loc l22
    // @175
l11: move_loc l22
    br_false l10
    move_loc l5
    pop
    ret
    // @180
l10: move_loc l5
    borrow_field StakingPool, handle
    read_ref
    move_loc l0
    move_loc l2
    // @185
    move_loc l11
    move_loc l12
    move_loc l13
    pack Claimed
    call event::emit<Claimed>
    // @190
    ret
l9: ld_false
    st_loc l22
    branch l11
l8: ld_false
    // @195
    st_loc l21
    branch l12
l7: move_loc l19
    call fungible_asset::destroy_zero
    branch l5
    // @200
l6: move_loc l20
    call fungible_asset::destroy_zero
    branch l13
l3: copy_loc l13
    ld_u64 0
    // @205
    gt
    st_loc l18
    branch l14

// Function definition at index 7
friend fun create_pool_and_lock(l0: vector<u8>, l1: address, l2: address, l3: address, l4: &signer, l5: u128): address
    local l6: address
    local l7: signer
    local l8: object::ConstructorRef
    local l9: signer
    local l10: object::ExtendRef
    local l11: object::TransferRef
    local l12: u64
    local l13: u128
    local l14: u128
    copy_loc l0
    call staking_pool_address_of_handle
    st_loc l6
    copy_loc l6
    exists StakingPool
    // @5
    br_true l0
    copy_loc l5
    ld_u128 0
    gt
    br_false l1
    // @10
    copy_loc l4
    call signer::address_of
    copy_loc l3
    eq
    br_false l2
    // @15
    copy_loc l3
    exists Position
    br_true l3
    call governance::derive_pkg_signer
    st_loc l7
    // @20
    borrow_loc l7
    borrow_loc l0
    call pool_seed
    call object::create_named_object
    st_loc l8
    // @25
    borrow_loc l8
    call object::generate_signer
    st_loc l9
    borrow_loc l8
    call object::generate_extend_ref
    // @30
    st_loc l10
    borrow_loc l8
    call object::generate_transfer_ref
    st_loc l11
    borrow_loc l11
    // @35
    call object::disable_ungated_transfer
    call timestamp::now_seconds
    st_loc l12
    borrow_loc l9
    copy_loc l0
    // @40
    copy_loc l1
    ld_u64 1000000000
    ld_u128 0
    move_loc l12
    copy_loc l2
    // @45
    move_loc l10
    pack StakingPool
    move_to StakingPool
    copy_loc l0
    copy_loc l6
    // @50
    move_loc l1
    move_loc l2
    ld_u64 1000000000
    pack StakingPoolCreated
    call event::emit<StakingPoolCreated>
    // @55
    copy_loc l0
    call amm::fee_per_lp
    st_loc l13
    st_loc l14
    move_loc l4
    // @60
    copy_loc l6
    copy_loc l0
    copy_loc l5
    ld_u128 0
    move_loc l14
    // @65
    move_loc l13
    ld_u64 18446744073709551615
    copy_loc l3
    pack Position
    move_to Position
    // @70
    move_loc l0
    copy_loc l3
    copy_loc l3
    call object::address_to_object<object::ObjectCore>
    call object::owner<object::ObjectCore>
    // @75
    move_loc l5
    ld_u64 18446744073709551615
    move_loc l3
    ld_u8 1
    pack PositionCreated
    // @80
    call event::emit<PositionCreated>
    move_loc l6
    ret
l3: move_loc l4
    pop
    // @85
    ld_u64 9
    abort
l2: move_loc l4
    pop
    ld_u64 10
    // @90
    abort
l1: move_loc l4
    pop
    ld_u64 5
    abort
    // @95
l0: move_loc l4
    pop
    ld_u64 2
    abort

// Function definition at index 8
#[persistent] public fun default_rate_per_sec(): u64
    ld_u64 1000000000
    ret

// Function definition at index 9
#[persistent] public fun has_position(l0: address): bool
    move_loc l0
    exists Position
    ret

// Function definition at index 10
#[persistent] public fun pool_acc_per_share(l0: address): u128 acquires StakingPool
    copy_loc l0
    exists StakingPool
    br_false l0
    move_loc l0
    borrow_global StakingPool
    // @5
    borrow_field StakingPool, accumulated_per_share
    read_ref
    ret
l0: ld_u64 1
    abort

// Function definition at index 11
#[persistent] public fun pool_rate_per_sec(l0: address): u64 acquires StakingPool
    copy_loc l0
    exists StakingPool
    br_false l0
    move_loc l0
    borrow_global StakingPool
    // @5
    borrow_field StakingPool, rate_per_sec
    read_ref
    ret
l0: ld_u64 1
    abort

// Function definition at index 12
#[persistent] public fun position_fee_debt(l0: object::Object<Position>): (u128, u128) acquires Position
    local l1: address
    local l2: &Position
    borrow_loc l0
    call object::object_address<Position>
    st_loc l1
    copy_loc l1
    exists Position
    // @5
    br_false l0
    move_loc l1
    borrow_global Position
    st_loc l2
    copy_loc l2
    // @10
    borrow_field Position, last_fee_per_lp_apt
    read_ref
    move_loc l2
    borrow_field Position, last_fee_per_lp_token
    read_ref
    // @15
    ret
l0: ld_u64 3
    abort

// Function definition at index 13
#[persistent] public fun position_owner(l0: address): address
    move_loc l0
    call object::address_to_object<Position>
    call object::owner<Position>
    ret

// Function definition at index 14
#[persistent] public fun position_pending_all(l0: address): (u64, u64, u64) acquires Position, StakingPool
    local l1: &Position
    local l2: &StakingPool
    local l3: u128
    local l4: u64
    local l5: u128
    local l6: bool
    local l7: u128
    local l8: u128
    local l9: u128
    local l10: u64
    local l11: u64
    local l12: u64
    copy_loc l0
    exists Position
    br_true l0
    ld_u64 0
    ld_u64 0
    // @5
    ld_u64 0
    ret
l0: move_loc l0
    borrow_global Position
    st_loc l1
    // @10
    copy_loc l1
    borrow_field Position, pool_addr
    read_ref
    st_loc l0
    copy_loc l0
    // @15
    exists StakingPool
    br_true l1
    move_loc l1
    pop
    ld_u64 0
    // @20
    ld_u64 0
    ld_u64 0
    ret
l1: move_loc l0
    borrow_global StakingPool
    // @25
    st_loc l2
    copy_loc l1
    borrow_field Position, handle
    read_ref
    call amm::lp_supply
    // @30
    st_loc l3
    call timestamp::now_seconds
    st_loc l4
    copy_loc l2
    borrow_field StakingPool, accumulated_per_share
    // @35
    read_ref
    st_loc l5
    copy_loc l4
    copy_loc l2
    borrow_field StakingPool, last_update_secs
    // @40
    read_ref
    gt
    br_false l2
    copy_loc l3
    ld_u128 0
    // @45
    gt
    st_loc l6
l5: move_loc l6
    br_false l3
    move_loc l4
    // @50
    copy_loc l2
    borrow_field StakingPool, last_update_secs
    read_ref
    sub
    cast_u128
    // @55
    move_loc l2
    borrow_field StakingPool, rate_per_sec
    read_ref
    cast_u128
    mul
    // @60
    ld_u128 1000000000000000000
    mul
    move_loc l3
    div
    st_loc l7
    // @65
    move_loc l5
    move_loc l7
    add
    st_loc l5
l4: move_loc l5
    // @70
    copy_loc l1
    borrow_field Position, last_acc_per_share
    read_ref
    sub
    copy_loc l1
    // @75
    borrow_field Position, shares
    read_ref
    mul
    ld_u128 1000000000000000000
    div
    // @80
    cast_u64
    copy_loc l1
    borrow_field Position, handle
    read_ref
    call amm::fee_per_lp
    // @85
    call amm::fee_acc_scale
    st_loc l8
    st_loc l9
    copy_loc l1
    borrow_field Position, last_fee_per_lp_apt
    // @90
    read_ref
    sub
    copy_loc l1
    borrow_field Position, shares
    read_ref
    // @95
    mul
    copy_loc l8
    div
    cast_u64
    move_loc l9
    // @100
    copy_loc l1
    borrow_field Position, last_fee_per_lp_token
    read_ref
    sub
    move_loc l1
    // @105
    borrow_field Position, shares
    read_ref
    mul
    move_loc l8
    div
    // @110
    cast_u64
    ret
l3: move_loc l2
    pop
    branch l4
    // @115
l2: ld_false
    st_loc l6
    branch l5

// Function definition at index 15
#[persistent] public fun position_pending_fees(l0: object::Object<Position>): (u64, u64) acquires Position
    local l1: address
    local l2: &Position
    local l3: u128
    local l4: u128
    local l5: u128
    local l6: u64
    local l7: u64
    borrow_loc l0
    call object::object_address<Position>
    st_loc l1
    copy_loc l1
    exists Position
    // @5
    br_true l0
    ld_u64 0
    ld_u64 0
    ret
l0: move_loc l1
    // @10
    borrow_global Position
    st_loc l2
    copy_loc l2
    borrow_field Position, handle
    read_ref
    // @15
    call amm::fee_per_lp
    call amm::fee_acc_scale
    st_loc l3
    st_loc l4
    copy_loc l2
    // @20
    borrow_field Position, last_fee_per_lp_apt
    read_ref
    sub
    copy_loc l2
    borrow_field Position, shares
    // @25
    read_ref
    mul
    copy_loc l3
    div
    cast_u64
    // @30
    move_loc l4
    copy_loc l2
    borrow_field Position, last_fee_per_lp_token
    read_ref
    sub
    // @35
    move_loc l2
    borrow_field Position, shares
    read_ref
    mul
    move_loc l3
    // @40
    div
    cast_u64
    ret

// Function definition at index 16
#[persistent] public fun position_pool(l0: address): address acquires Position
    copy_loc l0
    exists Position
    br_false l0
    move_loc l0
    borrow_global Position
    // @5
    borrow_field Position, pool_addr
    read_ref
    ret
l0: ld_u64 3
    abort

// Function definition at index 17
#[persistent] public fun position_pool_addr(l0: object::Object<Position>): address acquires Position
    local l1: address
    borrow_loc l0
    call object::object_address<Position>
    st_loc l1
    copy_loc l1
    exists Position
    // @5
    br_false l0
    move_loc l1
    borrow_global Position
    borrow_field Position, pool_addr
    read_ref
    // @10
    ret
l0: ld_u64 3
    abort

// Function definition at index 18
#[persistent] public fun position_recipient_pid(l0: address): address acquires Position
    copy_loc l0
    exists Position
    br_false l0
    move_loc l0
    borrow_global Position
    // @5
    borrow_field Position, recipient_pid
    read_ref
    ret
l0: ld_u64 3
    abort

// Function definition at index 19
#[persistent] public fun position_shares(l0: address): u128 acquires Position
    copy_loc l0
    exists Position
    br_false l0
    move_loc l0
    borrow_global Position
    // @5
    borrow_field Position, shares
    read_ref
    ret
l0: ld_u64 3
    abort

// Function definition at index 20
#[persistent] public fun position_shares_obj(l0: object::Object<Position>): u128 acquires Position
    local l1: address
    borrow_loc l0
    call object::object_address<Position>
    st_loc l1
    copy_loc l1
    exists Position
    // @5
    br_false l0
    move_loc l1
    borrow_global Position
    borrow_field Position, shares
    read_ref
    // @10
    ret
l0: ld_u64 3
    abort

// Function definition at index 21
#[persistent] public fun position_unlock_at(l0: address): u64 acquires Position
    copy_loc l0
    exists Position
    br_false l0
    move_loc l0
    borrow_global Position
    // @5
    borrow_field Position, unlock_at_secs
    read_ref
    ret
l0: ld_u64 3
    abort

// Function definition at index 22
#[persistent] entry public fun remove_liquidity(l0: &signer, l1: address, l2: u64, l3: u64) acquires Position, StakingPool
    local l4: &Position
    local l5: u64
    local l6: vector<u8>
    local l7: address
    local l8: u128
    local l9: fungible_asset::FungibleAsset
    local l10: fungible_asset::FungibleAsset
    local l11: u64
    local l12: u64
    copy_loc l1
    exists Position
    br_false l0
    copy_loc l1
    borrow_global Position
    // @5
    st_loc l4
    copy_loc l4
    borrow_field Position, unlock_at_secs
    read_ref
    st_loc l5
    // @10
    copy_loc l4
    borrow_field Position, pool_addr
    read_ref
    pop
    move_loc l4
    // @15
    borrow_field Position, handle
    read_ref
    st_loc l6
    copy_loc l1
    call object::address_to_object<Position>
    // @20
    call object::owner<Position>
    st_loc l7
    move_loc l0
    call signer::address_of
    copy_loc l7
    // @25
    eq
    br_false l1
    copy_loc l5
    ld_u64 18446744073709551615
    neq
    // @30
    br_false l2
    call timestamp::now_seconds
    move_loc l5
    ge
    br_false l3
    // @35
    copy_loc l1
    call claim_internal
    copy_loc l1
    move_from Position
    unpack Position
    // @40
    pop
    pop
    pop
    pop
    pop
    // @45
    st_loc l8
    pop
    pop
    copy_loc l6
    copy_loc l8
    // @50
    move_loc l2
    move_loc l3
    call amm::remove_liquidity_internal
    st_loc l9
    st_loc l10
    // @55
    borrow_loc l10
    call fungible_asset::amount
    st_loc l11
    borrow_loc l9
    call fungible_asset::amount
    // @60
    st_loc l12
    copy_loc l7
    move_loc l10
    call primary_fungible_store::deposit
    copy_loc l7
    // @65
    move_loc l9
    call primary_fungible_store::deposit
    move_loc l6
    move_loc l1
    move_loc l7
    // @70
    move_loc l8
    move_loc l11
    move_loc l12
    pack PositionRemoved
    call event::emit<PositionRemoved>
    // @75
    ret
l3: ld_u64 6
    abort
l2: ld_u64 7
    abort
    // @80
l1: ld_u64 4
    abort
l0: move_loc l0
    pop
    ld_u64 3
    // @85
    abort

// Function definition at index 23
fun resolve_recipient(l0: address, l1: address): address
    copy_loc l0
    ld_const<address> 0
    eq
    br_false l0
    move_loc l1
    // @5
    call object::address_to_object<Position>
    call object::owner<Position>
    ret
l0: move_loc l0
    call object::address_to_object<object::ObjectCore>
    // @10
    call object::owner<object::ObjectCore>
    ret

// Function definition at index 24
#[persistent] public fun staking_pool_address_of_handle(l0: vector<u8>): address
    local l1: vector<u8>
    local l2: address
    borrow_loc l0
    call pool_seed
    st_loc l1
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    st_loc l2
    // @5
    borrow_loc l2
    move_loc l1
    call object::create_object_address
    ret

// Function definition at index 25
#[persistent] public fun staking_pool_exists(l0: vector<u8>): bool
    move_loc l0
    call staking_pool_address_of_handle
    exists StakingPool
    ret

// Function definition at index 26
#[persistent] public fun unlock_forever_marker(): u64
    ld_u64 18446744073709551615
    ret

// Function definition at index 27
fun update_pool(l0: address) acquires StakingPool
    local l1: &mut StakingPool
    local l2: u64
    local l3: u128
    local l4: &mut u64
    move_loc l0
    mut_borrow_global StakingPool
    st_loc l1
    call timestamp::now_seconds
    st_loc l2
    // @5
    copy_loc l2
    copy_loc l1
    borrow_field StakingPool, last_update_secs
    read_ref
    le
    // @10
    br_false l0
    move_loc l1
    pop
    ret
l0: copy_loc l1
    // @15
    borrow_field StakingPool, handle
    read_ref
    call amm::lp_supply
    st_loc l3
    copy_loc l3
    // @20
    ld_u128 0
    eq
    br_false l1
    move_loc l1
    mut_borrow_field StakingPool, last_update_secs
    // @25
    st_loc l4
    move_loc l2
    move_loc l4
    write_ref
    ret
    // @30
l1: copy_loc l2
    copy_loc l1
    borrow_field StakingPool, last_update_secs
    read_ref
    sub
    // @35
    cast_u128
    copy_loc l1
    borrow_field StakingPool, rate_per_sec
    read_ref
    cast_u128
    // @40
    mul
    ld_u128 1000000000000000000
    mul
    move_loc l3
    div
    // @45
    st_loc l3
    copy_loc l1
    borrow_field StakingPool, accumulated_per_share
    read_ref
    move_loc l3
    // @50
    add
    copy_loc l1
    mut_borrow_field StakingPool, accumulated_per_share
    write_ref
    move_loc l1
    // @55
    mut_borrow_field StakingPool, last_update_secs
    st_loc l4
    move_loc l2
    move_loc l4
    write_ref
    // @60
    ret
```

---

## Module `lp_emission` (1929 bytes)

`sha3_256: 015edb5016286d4b96621f7b971867f7560b63636abc370ceeab2c3d39026745`

### ABI surface

**Structs** (4):

- `LpPulledForClaim` `[drop+store]` {reserve_addr:address, amount:u64, new_balance:u64}
- `LpReserve` `[key]` {token_metadata_addr:address, spec_version:u32, extend_ref:0x1::object::ExtendRef, total_distributed:u64, deployed_at_secs:u64}
- `LpReserveDeployed` `[drop+store]` {reserve_addr:address, token_metadata_addr:address, initial_amount:u64, timestamp_secs:u64}
- `LpReserveToppedUp` `[drop+store]` {reserve_addr:address, depositor:address, amount:u64, new_balance:u64}

**Public fns** (5):

- [view] `token_metadata_addr(address) → address`
- [view] `reserve_balance(address,0x1::object::Object<0x1::fungible_asset::Metadata>) → u64`
- [entry] `topup_reserve(&signer,address,0x1::object::Object<0x1::fungible_asset::Metadata>,u64)`
- [view] `total_distributed(address) → u64`
- [view] `deployed_at_secs(address) → u64`

**Friend fns** (2):

- `deploy(&signer,vector<u8>,address,0x1::fungible_asset::FungibleAsset) → address`
- `pull_for_claim(address,0x1::object::Object<0x1::fungible_asset::Metadata>,u64) → 0x1::fungible_asset::FungibleAsset`

### MASM (disassembled bytecode)

```move
// Bytecode version v9
module 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::lp_emission
use 0x1::object
use 0x1::fungible_asset
use 0x1::timestamp
use 0x1::primary_fungible_store
use 0x1::event
use 0x1::vector
use 0x1::signer
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::lp_staking
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::factory
struct LpPulledForClaim has drop + store
  reserve_addr: address
  amount: u64
  new_balance: u64

struct LpReserve has key
  token_metadata_addr: address
  spec_version: u32
  extend_ref: object::ExtendRef
  total_distributed: u64
  deployed_at_secs: u64

struct LpReserveDeployed has drop + store
  reserve_addr: address
  token_metadata_addr: address
  initial_amount: u64
  timestamp_secs: u64

struct LpReserveToppedUp has drop + store
  reserve_addr: address
  depositor: address
  amount: u64
  new_balance: u64

// Function definition at index 0
#[persistent] public fun token_metadata_addr(l0: address): address acquires LpReserve
    move_loc l0
    borrow_global LpReserve
    borrow_field LpReserve, token_metadata_addr
    read_ref
    ret

// Function definition at index 1
friend fun deploy(l0: &signer, l1: vector<u8>, l2: address, l3: fungible_asset::FungibleAsset): address
    local l4: vector<u8>
    local l5: object::ConstructorRef
    local l6: address
    local l7: object::ExtendRef
    local l8: signer
    local l9: object::TransferRef
    local l10: u64
    local l11: u64
    borrow_loc l1
    call make_seed
    st_loc l4
    move_loc l0
    move_loc l4
    // @5
    call object::create_named_object
    st_loc l5
    borrow_loc l5
    call object::address_from_constructor_ref
    st_loc l6
    // @10
    borrow_loc l5
    call object::generate_extend_ref
    st_loc l7
    borrow_loc l5
    call object::generate_signer
    // @15
    st_loc l8
    borrow_loc l5
    call object::generate_transfer_ref
    st_loc l9
    borrow_loc l9
    // @20
    call object::disable_ungated_transfer
    call timestamp::now_seconds
    st_loc l10
    borrow_loc l3
    call fungible_asset::amount
    // @25
    st_loc l11
    borrow_loc l8
    copy_loc l2
    ld_u32 2
    move_loc l7
    // @30
    ld_u64 0
    copy_loc l10
    pack LpReserve
    move_to LpReserve
    copy_loc l6
    // @35
    move_loc l3
    call primary_fungible_store::deposit
    copy_loc l6
    move_loc l2
    move_loc l11
    // @40
    move_loc l10
    pack LpReserveDeployed
    call event::emit<LpReserveDeployed>
    move_loc l6
    ret

// Function definition at index 2
fun make_seed(l0: &vector<u8>): vector<u8>
    local l1: vector<u8>
    vec_pack <u8>, 0
    st_loc l1
    mut_borrow_loc l1
    ld_const<vector<u8>> [108, 112, 95, 114, 101, 115, 101, 114, 118, 101, 58, 58]
    call vector::append<u8>
    // @5
    mut_borrow_loc l1
    move_loc l0
    read_ref
    call vector::append<u8>
    move_loc l1
    // @10
    ret

// Function definition at index 3
#[persistent] public fun reserve_balance(l0: address, l1: object::Object<fungible_asset::Metadata>): u64
    move_loc l0
    move_loc l1
    call primary_fungible_store::balance<fungible_asset::Metadata>
    ret

// Function definition at index 4
#[persistent] entry public fun topup_reserve(l0: &signer, l1: address, l2: object::Object<fungible_asset::Metadata>, l3: u64)
    local l4: fungible_asset::FungibleAsset
    local l5: u64
    copy_loc l0
    copy_loc l2
    copy_loc l3
    call primary_fungible_store::withdraw<fungible_asset::Metadata>
    st_loc l4
    // @5
    copy_loc l1
    move_loc l4
    call primary_fungible_store::deposit
    copy_loc l1
    move_loc l2
    // @10
    call primary_fungible_store::balance<fungible_asset::Metadata>
    st_loc l5
    move_loc l1
    move_loc l0
    call signer::address_of
    // @15
    move_loc l3
    move_loc l5
    pack LpReserveToppedUp
    call event::emit<LpReserveToppedUp>
    ret

// Function definition at index 5
#[persistent] public fun total_distributed(l0: address): u64 acquires LpReserve
    move_loc l0
    borrow_global LpReserve
    borrow_field LpReserve, total_distributed
    read_ref
    ret

// Function definition at index 6
#[persistent] public fun deployed_at_secs(l0: address): u64 acquires LpReserve
    move_loc l0
    borrow_global LpReserve
    borrow_field LpReserve, deployed_at_secs
    read_ref
    ret

// Function definition at index 7
friend fun pull_for_claim(l0: address, l1: object::Object<fungible_asset::Metadata>, l2: u64): fungible_asset::FungibleAsset acquires LpReserve
    local l3: &mut LpReserve
    local l4: u64
    local l5: u64
    local l6: signer
    local l7: u64
    copy_loc l0
    exists LpReserve
    br_false l0
    copy_loc l0
    mut_borrow_global LpReserve
    // @5
    st_loc l3
    copy_loc l0
    copy_loc l1
    call primary_fungible_store::balance<fungible_asset::Metadata>
    st_loc l4
    // @10
    copy_loc l2
    copy_loc l4
    lt
    br_false l1
    move_loc l2
    // @15
    st_loc l5
l3: copy_loc l5
    ld_u64 0
    eq
    br_false l2
    // @20
    move_loc l3
    pop
    move_loc l1
    call fungible_asset::zero<fungible_asset::Metadata>
    ret
    // @25
l2: copy_loc l3
    borrow_field LpReserve, extend_ref
    call object::generate_signer_for_extending
    st_loc l6
    borrow_loc l6
    // @30
    copy_loc l1
    copy_loc l5
    call primary_fungible_store::withdraw<fungible_asset::Metadata>
    copy_loc l3
    borrow_field LpReserve, total_distributed
    // @35
    read_ref
    copy_loc l5
    add
    move_loc l3
    mut_borrow_field LpReserve, total_distributed
    // @40
    write_ref
    copy_loc l0
    move_loc l1
    call primary_fungible_store::balance<fungible_asset::Metadata>
    st_loc l7
    // @45
    move_loc l0
    move_loc l5
    move_loc l7
    pack LpPulledForClaim
    call event::emit<LpPulledForClaim>
    // @50
    ret
l1: move_loc l4
    st_loc l5
    branch l3
l0: ld_u64 1
    // @55
    abort
```

---

## Module `reaction_emission` (2195 bytes)

`sha3_256: f6c103a82678c2b08d3d4988e19f0464d11148e5a608d901920c25154bab79f0`

### ABI surface

**Structs** (3):

- `ReactionEmitted` `[drop+store]` {reserve_addr:address, recipient:address, post_id:vector<u8>, press_order:u64, emission_amount:u64}
- `ReactionReserve` `[key]` {token_metadata_addr:address, spec_version:u32, extend_ref:0x1::object::ExtendRef, total_distributed:u64, topup_count:u64}
- `ReserveToppedUp` `[drop+store]` {reserve_addr:address, depositor:address, amount:u64, new_balance:u64}

**Public fns** (5):

- [view] `compute_emission(u64,u64) → u64`
- [view] `reserve_balance(address,0x1::object::Object<0x1::fungible_asset::Metadata>) → u64`
- [entry] `topup_reserve(&signer,address,0x1::object::Object<0x1::fungible_asset::Metadata>,u64)`
- [view] `total_distributed(address) → u64`
- [view] `total_post_emission(u64) → u64`

**Friend fns** (2):

- `deploy(&signer,vector<u8>,address,0x1::fungible_asset::FungibleAsset) → address`
- `emit_to_presser(address,address,vector<u8>,u64,u64) → u64`

### MASM (disassembled bytecode)

```move
// Bytecode version v9
module 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::reaction_emission
use 0x1::object
use 0x1::fungible_asset
use 0x1::primary_fungible_store
use 0x1::vector
use 0x1::event
use 0x1::signer
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::factory
struct ReactionEmitted has drop + store
  reserve_addr: address
  recipient: address
  post_id: vector<u8>
  press_order: u64
  emission_amount: u64

struct ReactionReserve has key
  token_metadata_addr: address
  spec_version: u32
  extend_ref: object::ExtendRef
  total_distributed: u64
  topup_count: u64

struct ReserveToppedUp has drop + store
  reserve_addr: address
  depositor: address
  amount: u64
  new_balance: u64

// Function definition at index 0
friend fun deploy(l0: &signer, l1: vector<u8>, l2: address, l3: fungible_asset::FungibleAsset): address
    local l4: vector<u8>
    local l5: object::ConstructorRef
    local l6: address
    local l7: object::ExtendRef
    local l8: signer
    local l9: object::TransferRef
    borrow_loc l1
    call make_seed
    st_loc l4
    move_loc l0
    move_loc l4
    // @5
    call object::create_named_object
    st_loc l5
    borrow_loc l5
    call object::address_from_constructor_ref
    st_loc l6
    // @10
    borrow_loc l5
    call object::generate_extend_ref
    st_loc l7
    borrow_loc l5
    call object::generate_signer
    // @15
    st_loc l8
    borrow_loc l5
    call object::generate_transfer_ref
    st_loc l9
    borrow_loc l9
    // @20
    call object::disable_ungated_transfer
    borrow_loc l8
    move_loc l2
    ld_u32 1
    move_loc l7
    // @25
    ld_u64 0
    ld_u64 0
    pack ReactionReserve
    move_to ReactionReserve
    copy_loc l6
    // @30
    move_loc l3
    call primary_fungible_store::deposit
    move_loc l6
    ret

// Function definition at index 1
fun make_seed(l0: &vector<u8>): vector<u8>
    local l1: vector<u8>
    vec_pack <u8>, 0
    st_loc l1
    mut_borrow_loc l1
    ld_const<vector<u8>> [114, 101, 97, 99, 116, 105, 111, 110, 95, 114, 101, 115, 101, 114, 118, 101, 58, 58]
    call vector::append<u8>
    // @5
    mut_borrow_loc l1
    move_loc l0
    read_ref
    call vector::append<u8>
    move_loc l1
    // @10
    ret

// Function definition at index 2
#[persistent] public fun compute_emission(l0: u64, l1: u64): u64
    local l2: bool
    copy_loc l0
    ld_u64 0
    eq
    br_false l0
    ld_true
    // @5
    st_loc l2
l2: move_loc l2
    br_false l1
    ld_u64 0
    ret
    // @10
l1: move_loc l0
    ld_u64 100000000
    mul
    ret
l0: copy_loc l0
    // @15
    move_loc l1
    gt
    st_loc l2
    branch l2

// Function definition at index 3
friend fun emit_to_presser(l0: address, l1: address, l2: vector<u8>, l3: u64, l4: u64): u64 acquires ReactionReserve
    local l5: bool
    local l6: bool
    local l7: &mut ReactionReserve
    local l8: object::Object<fungible_asset::Metadata>
    local l9: u64
    local l10: u64
    local l11: u64
    local l12: signer
    local l13: fungible_asset::FungibleAsset
    copy_loc l3
    ld_u64 0
    gt
    br_false l0
    copy_loc l3
    // @5
    copy_loc l4
    le
    st_loc l5
l8: move_loc l5
    br_false l1
    // @10
    copy_loc l4
    ld_u64 1
    ge
    br_false l2
    move_loc l4
    // @15
    ld_u64 1000
    le
    st_loc l6
l7: move_loc l6
    br_false l3
    // @20
    copy_loc l0
    mut_borrow_global ReactionReserve
    st_loc l7
    copy_loc l7
    borrow_field ReactionReserve, token_metadata_addr
    // @25
    read_ref
    call object::address_to_object<fungible_asset::Metadata>
    st_loc l8
    copy_loc l3
    ld_u64 100000000
    // @30
    mul
    st_loc l9
    copy_loc l0
    copy_loc l8
    call primary_fungible_store::balance<fungible_asset::Metadata>
    // @35
    st_loc l10
    copy_loc l9
    copy_loc l10
    gt
    br_false l4
    // @40
    move_loc l10
    st_loc l11
l6: copy_loc l11
    ld_u64 0
    eq
    // @45
    br_false l5
    move_loc l7
    pop
    move_loc l0
    move_loc l1
    // @50
    move_loc l2
    move_loc l3
    ld_u64 0
    pack ReactionEmitted
    call event::emit<ReactionEmitted>
    // @55
    ld_u64 0
    ret
l5: copy_loc l7
    borrow_field ReactionReserve, extend_ref
    call object::generate_signer_for_extending
    // @60
    st_loc l12
    borrow_loc l12
    move_loc l8
    copy_loc l11
    call primary_fungible_store::withdraw<fungible_asset::Metadata>
    // @65
    st_loc l13
    copy_loc l1
    move_loc l13
    call primary_fungible_store::deposit
    copy_loc l7
    // @70
    borrow_field ReactionReserve, total_distributed
    read_ref
    copy_loc l11
    add
    move_loc l7
    // @75
    mut_borrow_field ReactionReserve, total_distributed
    write_ref
    move_loc l0
    move_loc l1
    move_loc l2
    // @80
    move_loc l3
    copy_loc l11
    pack ReactionEmitted
    call event::emit<ReactionEmitted>
    move_loc l11
    // @85
    ret
l4: move_loc l9
    st_loc l11
    branch l6
l3: ld_u64 3
    // @90
    abort
l2: ld_false
    st_loc l6
    branch l7
l1: ld_u64 2
    // @95
    abort
l0: ld_false
    st_loc l5
    branch l8

// Function definition at index 4
#[persistent] public fun reserve_balance(l0: address, l1: object::Object<fungible_asset::Metadata>): u64
    move_loc l0
    move_loc l1
    call primary_fungible_store::balance<fungible_asset::Metadata>
    ret

// Function definition at index 5
#[persistent] entry public fun topup_reserve(l0: &signer, l1: address, l2: object::Object<fungible_asset::Metadata>, l3: u64) acquires ReactionReserve
    local l4: &mut ReactionReserve
    local l5: fungible_asset::FungibleAsset
    local l6: u64
    copy_loc l1
    mut_borrow_global ReactionReserve
    st_loc l4
    copy_loc l0
    copy_loc l2
    // @5
    copy_loc l3
    call primary_fungible_store::withdraw<fungible_asset::Metadata>
    st_loc l5
    copy_loc l1
    move_loc l5
    // @10
    call primary_fungible_store::deposit
    copy_loc l4
    borrow_field ReactionReserve, topup_count
    read_ref
    ld_u64 1
    // @15
    add
    move_loc l4
    mut_borrow_field ReactionReserve, topup_count
    write_ref
    copy_loc l1
    // @20
    move_loc l2
    call primary_fungible_store::balance<fungible_asset::Metadata>
    st_loc l6
    move_loc l1
    move_loc l0
    // @25
    call signer::address_of
    move_loc l3
    move_loc l6
    pack ReserveToppedUp
    call event::emit<ReserveToppedUp>
    // @30
    ret

// Function definition at index 6
#[persistent] public fun total_distributed(l0: address): u64 acquires ReactionReserve
    move_loc l0
    borrow_global ReactionReserve
    borrow_field ReactionReserve, total_distributed
    read_ref
    ret

// Function definition at index 7
#[persistent] public fun total_post_emission(l0: u64): u64
    copy_loc l0
    move_loc l0
    ld_u64 1
    add
    mul
    // @5
    ld_u64 2
    div
    ld_u64 100000000
    mul
    ret
```

---

## Module `handle_fee_vault` (2115 bytes)

`sha3_256: c6caf6b4f5ad59d932dee42a4000d3b94e3a7c5b6fbdb422c42623faecf15430`

### ABI surface

**Structs** (2):

- `HandleFeeVault` `[key]` {deployer_beneficiary:address, extend_ref:0x1::object::ExtendRef}
- `Settled` `[drop+store]` {total_apt:u64, to_deployer:u64, desnet_burned:u64}

**Public fns** (10):

- [view] `apt_balance() → u64`
-  `vault_addr() → address`
- [entry] `deposit_apt(&signer,u64)`
- [view] `deployer_beneficiary() → address`
- [entry] `migrate_legacy_fees(&signer)`
- [entry] `settle(&signer)`
- [view] `settle_threshold() → u64`
- [view] `split_burn_bps() → u64`
- [view] `split_deployer_bps() → u64`
-  `vault_exists() → bool`

**Friend fns** (1):

- `deposit_apt_fa(0x1::fungible_asset::FungibleAsset)`

### MASM (disassembled bytecode)

```move
// Bytecode version v9
module 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::handle_fee_vault
use 0x1::object
use 0x1::fungible_asset
use 0x1::primary_fungible_store
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::governance
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::amm
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::factory
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::apt_vault
use 0x1::event
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::profile
struct HandleFeeVault has key
  deployer_beneficiary: address
  extend_ref: object::ExtendRef

struct Settled has drop + store
  total_apt: u64
  to_deployer: u64
  desnet_burned: u64

// Function definition at index 0
fun init_module(l0: &signer)
    local l1: object::ConstructorRef
    local l2: signer
    local l3: object::ExtendRef
    local l4: object::TransferRef
    move_loc l0
    ld_const<vector<u8>> [104, 97, 110, 100, 108, 101, 95, 102, 101, 101, 95, 118, 97, 117, 108, 116]
    call object::create_named_object
    st_loc l1
    borrow_loc l1
    // @5
    call object::generate_signer
    st_loc l2
    borrow_loc l1
    call object::generate_extend_ref
    st_loc l3
    // @10
    borrow_loc l1
    call object::generate_transfer_ref
    st_loc l4
    borrow_loc l4
    call object::disable_ungated_transfer
    // @15
    borrow_loc l2
    ld_const<address> 799008279626092026266606374476533705615973526478392622784892721766771113
    move_loc l3
    pack HandleFeeVault
    move_to HandleFeeVault
    // @20
    ret

// Function definition at index 1
#[persistent] public fun apt_balance(): u64
    local l0: object::Object<fungible_asset::Metadata>
    local l1: address
    call vault_addr
    ld_const<address> 10
    call object::address_to_object<fungible_asset::Metadata>
    call primary_fungible_store::balance<fungible_asset::Metadata>
    ret

// Function definition at index 2
#[persistent] public fun vault_addr(): address
    local l0: address
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    st_loc l0
    borrow_loc l0
    ld_const<vector<u8>> [104, 97, 110, 100, 108, 101, 95, 102, 101, 101, 95, 118, 97, 117, 108, 116]
    call object::create_object_address
    // @5
    ret

// Function definition at index 3
#[persistent] entry public fun deposit_apt(l0: &signer, l1: u64)
    local l2: object::Object<fungible_asset::Metadata>
    ld_const<address> 10
    call object::address_to_object<fungible_asset::Metadata>
    st_loc l2
    move_loc l0
    move_loc l2
    // @5
    move_loc l1
    call primary_fungible_store::withdraw<fungible_asset::Metadata>
    call deposit_apt_fa
    ret

// Function definition at index 4
#[persistent] public fun deployer_beneficiary(): address acquires HandleFeeVault
    local l0: address
    call vault_addr
    st_loc l0
    copy_loc l0
    exists HandleFeeVault
    br_false l0
    // @5
    move_loc l0
    borrow_global HandleFeeVault
    borrow_field HandleFeeVault, deployer_beneficiary
    read_ref
    ret
    // @10
l0: ld_u64 2
    abort

// Function definition at index 5
friend fun deposit_apt_fa(l0: fungible_asset::FungibleAsset)
    call vault_addr
    move_loc l0
    call primary_fungible_store::deposit
    ret

// Function definition at index 6
#[persistent] entry public fun migrate_legacy_fees(l0: &signer)
    local l1: object::Object<fungible_asset::Metadata>
    local l2: u64
    local l3: signer
    ld_const<address> 10
    move_loc l0
    pop
    call object::address_to_object<fungible_asset::Metadata>
    st_loc l1
    // @5
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    copy_loc l1
    call primary_fungible_store::balance<fungible_asset::Metadata>
    st_loc l2
    copy_loc l2
    // @10
    ld_u64 0
    eq
    br_false l0
    ret
l0: call governance::derive_pkg_signer
    // @15
    st_loc l3
    borrow_loc l3
    move_loc l1
    move_loc l2
    call primary_fungible_store::withdraw<fungible_asset::Metadata>
    // @20
    call deposit_apt_fa
    ret

// Function definition at index 7
#[persistent] entry public fun settle(l0: &signer) acquires HandleFeeVault
    local l1: address
    local l2: object::Object<fungible_asset::Metadata>
    local l3: u64
    local l4: u64
    local l5: u64
    local l6: &HandleFeeVault
    local l7: signer
    local l8: object::Object<fungible_asset::Metadata>
    local l9: fungible_asset::FungibleAsset
    local l10: fungible_asset::FungibleAsset
    call vault_addr
    st_loc l1
    move_loc l0
    pop
    copy_loc l1
    // @5
    exists HandleFeeVault
    br_false l0
    ld_const<address> 10
    call object::address_to_object<fungible_asset::Metadata>
    st_loc l2
    // @10
    copy_loc l1
    copy_loc l2
    call primary_fungible_store::balance<fungible_asset::Metadata>
    st_loc l3
    copy_loc l3
    // @15
    ld_u64 10000000
    ge
    br_false l1
    copy_loc l3
    ld_u64 1000
    // @20
    mul
    ld_u64 10000
    div
    st_loc l4
    copy_loc l3
    // @25
    copy_loc l4
    sub
    st_loc l5
    move_loc l1
    borrow_global HandleFeeVault
    // @30
    st_loc l6
    copy_loc l6
    borrow_field HandleFeeVault, extend_ref
    call object::generate_signer_for_extending
    st_loc l7
    // @35
    borrow_loc l7
    st_loc l0
    copy_loc l2
    st_loc l8
    move_loc l0
    // @40
    move_loc l8
    copy_loc l4
    call primary_fungible_store::withdraw<fungible_asset::Metadata>
    st_loc l9
    move_loc l6
    // @45
    borrow_field HandleFeeVault, deployer_beneficiary
    read_ref
    move_loc l9
    call primary_fungible_store::deposit
    borrow_loc l7
    // @50
    st_loc l0
    move_loc l2
    st_loc l8
    move_loc l0
    move_loc l8
    // @55
    move_loc l5
    call primary_fungible_store::withdraw<fungible_asset::Metadata>
    st_loc l9
    ld_const<vector<u8>> [100, 101, 115, 110, 101, 116]
    move_loc l9
    // @60
    ld_u64 0
    call amm::swap_exact_apt_in
    st_loc l10
    borrow_loc l10
    call fungible_asset::amount
    // @65
    st_loc l5
    ld_const<vector<u8>> [100, 101, 115, 110, 101, 116]
    call factory::vault_addr_of_handle
    move_loc l10
    call apt_vault::burn_via_vault
    // @70
    move_loc l3
    move_loc l4
    move_loc l5
    pack Settled
    call event::emit<Settled>
    // @75
    ret
l1: ld_u64 1
    abort
l0: ld_u64 2
    abort

// Function definition at index 8
#[persistent] public fun settle_threshold(): u64
    ld_u64 10000000
    ret

// Function definition at index 9
#[persistent] public fun split_burn_bps(): u64
    ld_u64 9000
    ret

// Function definition at index 10
#[persistent] public fun split_deployer_bps(): u64
    ld_u64 1000
    ret

// Function definition at index 11
#[persistent] public fun vault_exists(): bool
    call vault_addr
    exists HandleFeeVault
    ret
```

---
