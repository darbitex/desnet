# DeSNet v0.3.2 — Chain Bytecode Bundle (single-paste)

**Ground truth = on-chain bytecode fetched from mainnet @desnet on 2026-05-02.**

Each module section contains:
1. **ABI summary** — public/friend fns + structs + events (machine-readable)
2. **MASM** — disassembled bytecode (the authoritative readable form)

Source files in `sources/*.move` are for cross-reference of intent only.

---

## Package metadata

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

## Module integrity table

| # | module | bytes | sha3_256 |
|---|---|---:|---|
| 0 | `voter_history` | 2,785 | `b69051e8d111f822861139712479ba59433a8dad55eb0afda9d36c918bf2bc50` |
| 1 | `governance` | 7,972 | `2e5057dd69b09d4ec8a01df7eb363a878b388833c54a106060b9673039d31092` |
| 2 | `amm` | 8,165 | `e0a984d031ae2884c914f5d990cad6597bece26507e33c6bb34bbbddcd302618` |
| 3 | `apt_vault` | 3,004 | `764df5444ec37a19ea0d12621de7f411a0a973dd61fe3066f7958d13ae6fb04f` |
| 4 | `assets` | 2,950 | `8de46f4e7e54e19b91eb0d4a627ace336be55ceb3caf2a76fd83c38041472e55` |
| 5 | `reaction_emission` | 2,195 | `f6c103a82678c2b08d3d4988e19f0464d11148e5a608d901920c25154bab79f0` |
| 6 | `lp_emission` | 1,929 | `015edb5016286d4b96621f7b971867f7560b63636abc370ceeab2c3d39026745` |
| 7 | `lp_staking` | 6,047 | `754a12aa6558170945b1985e35a6829736d35ad43b7eea4491f79940ede01c27` |
| 8 | `factory` | 5,721 | `b477bdfe76de501d905ec24329b7d4fd17ce4e3fe8a616617bb7ddca95cdddca` |
| 9 | `reference_gate` | 1,363 | `cd27eaf0bb619c6931ec111574ee42ec5311d8b80d016b71c0db0877162c6c67` |
| 10 | `handle_fee_vault` | 2,115 | `c6caf6b4f5ad59d932dee42a4000d3b94e3a7c5b6fbdb422c42623faecf15430` |
| 11 | `profile` | 6,403 | `b61420ac094b99ff7b5dbfba0c63d773f88a41de4bbf04225dcd1977e6332d60` |
| 12 | `history` | 2,934 | `19bf456b6b20991542b8ad6f953e260cdf2dfe32d5f0556acedec284bf5eaee0` |
| 13 | `link` | 1,981 | `ab14968a728d3a17f8e95677fbe3b905e5d9e589c7728077ab2de3b4b1df9133` |
| 14 | `mint` | 4,704 | `2c4f9f3e89d5070189eec6bbaeb42b5d5ed32324c7625480d271ba00c74b609a` |
| 15 | `giveaway` | 4,753 | `946ef6e50d56488a4cc5e60d666ab88febefd77e2eb3f82707c796002075c570` |
| 16 | `press` | 4,457 | `c3259a61676a4b59b067faf1eaec571e7a22e4812670e17e354e083a56c43893` |
| 17 | `pulse` | 2,490 | `42e1ceef93d19af5bbdfb91efb8e5ebcd6c06505bcec3c3846d37af015b11327` |

To reproduce: `curl https://fullnode.mainnet.aptoslabs.com/v1/accounts/<@desnet>/module/<name>` → `.bytecode` field → strip `0x` → hex-decode → sha3_256.

---

## Module `voter_history` (2785 bytes)

`sha3_256: b69051e8d111f822861139712479ba59433a8dad55eb0afda9d36c918bf2bc50`

### ABI surface

**Structs** (7):

- `Registry` `[key]` {voters:0x1::smart_table::SmartTable<address, 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::voter_history::VoterHistory>}
- `RegistryByToken` `[key]` {voters:0x1::smart_table::SmartTable<address, 0x1::smart_table::SmartTable<address, 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::voter_history::VoterHistory>>}
- `RewardEntry` `[copy+drop+store]` {timestamp_secs:u64, amount:u64}
- `VoterHistory` `[drop+store]` {rewards_history:vector<0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::voter_history::RewardEntry>, total_received:u64}
- `VoterHistoryPruned` `[drop+store]` {voter_addr:address, entries_removed:u64, timestamp_secs:u64}
- `VoterRegistryInitialized` `[drop+store]` {governance_addr:address, timestamp_secs:u64}
- `VoterRewardRecorded` `[drop+store]` {voter_addr:address, amount:u64, cumulative_received:u64, history_entry_index:u64, timestamp_secs:u64}

**Public fns** (7):

- [view] `has_per_token_registry()->bool`
- [view] `history_exists(address)->bool`
- [entry] `prune_voter_history(&signer,address)`
- [view] `rewards_earned_30d(address)->u64`
- [view] `rewards_earned_30d_for_token(address,address)->u64`
- [view] `total_received(address)->u64`
- [view] `voting_window_secs()->u64`

**Friend fns** (3):

- `init_registry(&signer)`
- `record_reward_received(&signer,address,u64)`
- `record_reward_received_for_token(&signer,address,address,u64)`

### MASM (disassembled bytecode)

```move
// Bytecode version v9
module 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::voter_history
use 0x1::smart_table
use 0x1::signer
use 0x1::timestamp
use 0x1::event
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::governance
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::lp_staking
struct Registry has key
  voters: smart_table::SmartTable<address, VoterHistory>

struct RegistryByToken has key
  voters: smart_table::SmartTable<address, smart_table::SmartTable<address, VoterHistory>>

struct RewardEntry has copy + drop + store
  timestamp_secs: u64
  amount: u64

struct VoterHistory has drop + store
  rewards_history: vector<RewardEntry>
  total_received: u64

struct VoterHistoryPruned has drop + store
  voter_addr: address
  entries_removed: u64
  timestamp_secs: u64

struct VoterRegistryInitialized has drop + store
  governance_addr: address
  timestamp_secs: u64

struct VoterRewardRecorded has drop + store
  voter_addr: address
  amount: u64
  cumulative_received: u64
  history_entry_index: u64
  timestamp_secs: u64

// Function definition at index 0
#[persistent] public fun has_per_token_registry(): bool
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    exists RegistryByToken
    ret

// Function definition at index 1
#[persistent] public fun history_exists(l0: address): bool acquires Registry
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    exists Registry
    br_true l0
    ld_false
    ret
    // @5
l0: ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global Registry
    borrow_field Registry, voters
    move_loc l0
    call smart_table::contains<address, VoterHistory>
    // @10
    ret

// Function definition at index 2
friend fun init_registry(l0: &signer)
    local l1: address
    copy_loc l0
    call signer::address_of
    st_loc l1
    copy_loc l1
    exists Registry
    // @5
    br_true l0
    move_loc l0
    call smart_table::new<address, VoterHistory>
    pack Registry
    move_to Registry
    // @10
    move_loc l1
    call timestamp::now_seconds
    pack VoterRegistryInitialized
    call event::emit<VoterRegistryInitialized>
    ret
    // @15
l0: move_loc l0
    pop
    ld_u64 3
    abort

// Function definition at index 3
#[persistent] entry public fun prune_voter_history(l0: &signer, l1: address) acquires Registry
    local l2: &mut Registry
    local l3: &mut VoterHistory
    local l4: u64
    local l5: u64
    local l6: vector<RewardEntry>
    local l7: u64
    local l8: u64
    local l9: u64
    local l10: RewardEntry
    local l11: &mut vector<RewardEntry>
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    move_loc l0
    pop
    exists Registry
    br_true l0
    // @5
    ret
l0: ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    mut_borrow_global Registry
    st_loc l2
    copy_loc l2
    // @10
    borrow_field Registry, voters
    copy_loc l1
    call smart_table::contains<address, VoterHistory>
    br_true l1
    move_loc l2
    // @15
    pop
    ret
l1: move_loc l2
    mut_borrow_field Registry, voters
    copy_loc l1
    // @20
    call smart_table::borrow_mut<address, VoterHistory>
    st_loc l3
    call timestamp::now_seconds
    st_loc l4
    copy_loc l4
    // @25
    ld_u64 5184000
    gt
    br_false l2
    copy_loc l4
    ld_u64 5184000
    // @30
    sub
    st_loc l5
l8: vec_pack <RewardEntry>, 0
    st_loc l6
    ld_u64 0
    // @35
    st_loc l7
    copy_loc l3
    borrow_field VoterHistory, rewards_history
    vec_len <RewardEntry>
    st_loc l8
    // @40
    ld_u64 0
    st_loc l9
l5: copy_loc l9
    copy_loc l8
    lt
    // @45
    br_false l3
    copy_loc l3
    borrow_field VoterHistory, rewards_history
    copy_loc l9
    vec_borrow <RewardEntry>
    // @50
    read_ref
    st_loc l10
    borrow_loc l10
    borrow_field RewardEntry, timestamp_secs
    read_ref
    // @55
    copy_loc l5
    ge
    br_false l4
    mut_borrow_loc l6
    move_loc l10
    // @60
    vec_push_back <RewardEntry>
l6: move_loc l9
    ld_u64 1
    add
    st_loc l9
    // @65
    branch l5
l4: move_loc l7
    ld_u64 1
    add
    st_loc l7
    // @70
    branch l6
l3: move_loc l3
    mut_borrow_field VoterHistory, rewards_history
    st_loc l11
    move_loc l6
    // @75
    move_loc l11
    write_ref
    copy_loc l7
    ld_u64 0
    gt
    // @80
    br_false l7
    move_loc l1
    move_loc l7
    move_loc l4
    pack VoterHistoryPruned
    // @85
    call event::emit<VoterHistoryPruned>
    ret
l7: ret
l2: ld_u64 0
    st_loc l5
    // @90
    branch l8

// Function definition at index 4
friend fun record_reward_received(l0: &signer, l1: address, l2: u64) acquires Registry
    local l3: &mut Registry
    local l4: &mut VoterHistory
    local l5: u64
    local l6: RewardEntry
    local l7: u64
    move_loc l0
    call signer::address_of
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    eq
    br_false l0
    // @5
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    exists Registry
    br_false l1
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    mut_borrow_global Registry
    // @10
    st_loc l3
    copy_loc l3
    borrow_field Registry, voters
    copy_loc l1
    call smart_table::contains<address, VoterHistory>
    // @15
    br_false l2
    branch l3
l2: copy_loc l3
    mut_borrow_field Registry, voters
    copy_loc l1
    // @20
    vec_pack <RewardEntry>, 0
    ld_u64 0
    pack VoterHistory
    call smart_table::add<address, VoterHistory>
l3: move_loc l3
    // @25
    mut_borrow_field Registry, voters
    copy_loc l1
    call smart_table::borrow_mut<address, VoterHistory>
    st_loc l4
    call timestamp::now_seconds
    // @30
    st_loc l5
    copy_loc l5
    copy_loc l2
    pack RewardEntry
    st_loc l6
    // @35
    copy_loc l4
    mut_borrow_field VoterHistory, rewards_history
    move_loc l6
    vec_push_back <RewardEntry>
    copy_loc l4
    // @40
    borrow_field VoterHistory, total_received
    read_ref
    copy_loc l2
    add
    copy_loc l4
    // @45
    mut_borrow_field VoterHistory, total_received
    write_ref
    copy_loc l4
    borrow_field VoterHistory, rewards_history
    vec_len <RewardEntry>
    // @50
    ld_u64 1
    sub
    st_loc l7
    move_loc l1
    move_loc l2
    // @55
    move_loc l4
    borrow_field VoterHistory, total_received
    read_ref
    move_loc l7
    move_loc l5
    // @60
    pack VoterRewardRecorded
    call event::emit<VoterRewardRecorded>
    ret
l1: ld_u64 2
    abort
    // @65
l0: ld_u64 1
    abort

// Function definition at index 5
friend fun record_reward_received_for_token(l0: &signer, l1: address, l2: address, l3: u64) acquires Registry, RegistryByToken
    local l4: &mut RegistryByToken
    local l5: &mut smart_table::SmartTable<address, VoterHistory>
    local l6: &mut VoterHistory
    local l7: &mut vector<RewardEntry>
    local l8: u64
    local l9: RewardEntry
    copy_loc l0
    copy_loc l1
    copy_loc l3
    call record_reward_received
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    // @5
    exists RegistryByToken
    br_true l0
    move_loc l0
    call smart_table::new<address, smart_table::SmartTable<address, VoterHistory>>
    pack RegistryByToken
    // @10
    move_to RegistryByToken
l5: ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    mut_borrow_global RegistryByToken
    st_loc l4
    copy_loc l4
    // @15
    borrow_field RegistryByToken, voters
    copy_loc l1
    call smart_table::contains<address, smart_table::SmartTable<address, VoterHistory>>
    br_false l1
    branch l2
    // @20
l1: copy_loc l4
    mut_borrow_field RegistryByToken, voters
    copy_loc l1
    call smart_table::new<address, VoterHistory>
    call smart_table::add<address, smart_table::SmartTable<address, VoterHistory>>
    // @25
l2: move_loc l4
    mut_borrow_field RegistryByToken, voters
    move_loc l1
    call smart_table::borrow_mut<address, smart_table::SmartTable<address, VoterHistory>>
    st_loc l5
    // @30
    copy_loc l5
    freeze_ref
    copy_loc l2
    call smart_table::contains<address, VoterHistory>
    br_false l3
    // @35
    branch l4
l3: copy_loc l5
    copy_loc l2
    vec_pack <RewardEntry>, 0
    ld_u64 0
    // @40
    pack VoterHistory
    call smart_table::add<address, VoterHistory>
l4: move_loc l5
    move_loc l2
    call smart_table::borrow_mut<address, VoterHistory>
    // @45
    st_loc l6
    call timestamp::now_seconds
    copy_loc l6
    mut_borrow_field VoterHistory, rewards_history
    st_loc l7
    // @50
    copy_loc l3
    pack RewardEntry
    st_loc l9
    move_loc l7
    move_loc l9
    // @55
    vec_push_back <RewardEntry>
    copy_loc l6
    borrow_field VoterHistory, total_received
    read_ref
    move_loc l3
    // @60
    add
    move_loc l6
    mut_borrow_field VoterHistory, total_received
    write_ref
    ret
    // @65
l0: move_loc l0
    pop
    branch l5

// Function definition at index 6
#[persistent] public fun rewards_earned_30d(l0: address): u64 acquires Registry
    local l1: &Registry
    local l2: &VoterHistory
    local l3: u64
    local l4: u64
    local l5: u64
    local l6: u64
    local l7: u64
    local l8: RewardEntry
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    exists Registry
    br_true l0
    ld_u64 0
    ret
    // @5
l0: ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global Registry
    st_loc l1
    copy_loc l1
    borrow_field Registry, voters
    // @10
    copy_loc l0
    call smart_table::contains<address, VoterHistory>
    br_true l1
    move_loc l1
    pop
    // @15
    ld_u64 0
    ret
l1: move_loc l1
    borrow_field Registry, voters
    move_loc l0
    // @20
    call smart_table::borrow<address, VoterHistory>
    st_loc l2
    call timestamp::now_seconds
    st_loc l3
    copy_loc l3
    // @25
    ld_u64 2592000
    gt
    br_false l2
    move_loc l3
    ld_u64 2592000
    // @30
    sub
    st_loc l4
l7: ld_u64 0
    st_loc l5
    copy_loc l2
    // @35
    borrow_field VoterHistory, rewards_history
    vec_len <RewardEntry>
    st_loc l6
    ld_u64 0
    st_loc l7
    // @40
l6: copy_loc l7
    copy_loc l6
    lt
    br_false l3
    copy_loc l2
    // @45
    borrow_field VoterHistory, rewards_history
    copy_loc l7
    vec_borrow <RewardEntry>
    read_ref
    st_loc l8
    // @50
    borrow_loc l8
    borrow_field RewardEntry, timestamp_secs
    read_ref
    copy_loc l4
    ge
    // @55
    br_true l4
    branch l5
l4: move_loc l5
    borrow_loc l8
    borrow_field RewardEntry, amount
    // @60
    read_ref
    add
    st_loc l5
l5: move_loc l7
    ld_u64 1
    // @65
    add
    st_loc l7
    branch l6
l3: move_loc l2
    pop
    // @70
    move_loc l5
    ret
l2: ld_u64 0
    st_loc l4
    branch l7

// Function definition at index 7
#[persistent] public fun rewards_earned_30d_for_token(l0: address, l1: address): u64 acquires RegistryByToken
    local l2: &RegistryByToken
    local l3: &smart_table::SmartTable<address, VoterHistory>
    local l4: &VoterHistory
    local l5: u64
    local l6: u64
    local l7: u64
    local l8: u64
    local l9: u64
    local l10: &RewardEntry
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    exists RegistryByToken
    br_true l0
    ld_u64 0
    ret
    // @5
l0: ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global RegistryByToken
    st_loc l2
    copy_loc l2
    borrow_field RegistryByToken, voters
    // @10
    copy_loc l0
    call smart_table::contains<address, smart_table::SmartTable<address, VoterHistory>>
    br_true l1
    move_loc l2
    pop
    // @15
    ld_u64 0
    ret
l1: move_loc l2
    borrow_field RegistryByToken, voters
    move_loc l0
    // @20
    call smart_table::borrow<address, smart_table::SmartTable<address, VoterHistory>>
    st_loc l3
    copy_loc l3
    copy_loc l1
    call smart_table::contains<address, VoterHistory>
    // @25
    br_true l2
    move_loc l3
    pop
    ld_u64 0
    ret
    // @30
l2: move_loc l3
    move_loc l1
    call smart_table::borrow<address, VoterHistory>
    st_loc l4
    call timestamp::now_seconds
    // @35
    st_loc l5
    copy_loc l5
    ld_u64 2592000
    gt
    br_false l3
    // @40
    move_loc l5
    ld_u64 2592000
    sub
    st_loc l6
l8: ld_u64 0
    // @45
    st_loc l7
    copy_loc l4
    borrow_field VoterHistory, rewards_history
    vec_len <RewardEntry>
    st_loc l8
    // @50
    ld_u64 0
    st_loc l9
l6: copy_loc l9
    copy_loc l8
    lt
    // @55
    br_false l4
    copy_loc l4
    borrow_field VoterHistory, rewards_history
    copy_loc l9
    vec_borrow <RewardEntry>
    // @60
    st_loc l10
    copy_loc l10
    borrow_field RewardEntry, timestamp_secs
    read_ref
    copy_loc l6
    // @65
    ge
    br_false l5
    move_loc l7
    move_loc l10
    borrow_field RewardEntry, amount
    // @70
    read_ref
    add
    st_loc l7
l7: move_loc l9
    ld_u64 1
    // @75
    add
    st_loc l9
    branch l6
l5: move_loc l10
    pop
    // @80
    branch l7
l4: move_loc l4
    pop
    move_loc l7
    ret
    // @85
l3: ld_u64 0
    st_loc l6
    branch l8

// Function definition at index 8
#[persistent] public fun total_received(l0: address): u64 acquires Registry
    local l1: &Registry
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    exists Registry
    br_true l0
    ld_u64 0
    ret
    // @5
l0: ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global Registry
    st_loc l1
    copy_loc l1
    borrow_field Registry, voters
    // @10
    copy_loc l0
    call smart_table::contains<address, VoterHistory>
    br_true l1
    move_loc l1
    pop
    // @15
    ld_u64 0
    ret
l1: move_loc l1
    borrow_field Registry, voters
    move_loc l0
    // @20
    call smart_table::borrow<address, VoterHistory>
    borrow_field VoterHistory, total_received
    read_ref
    ret

// Function definition at index 9
#[persistent] public fun voting_window_secs(): u64
    ld_u64 2592000
    ret
```

---

## Module `governance` (7972 bytes)

`sha3_256: 2e5057dd69b09d4ec8a01df7eb363a878b388833c54a106060b9673039d31092`

### ABI surface

**Structs** (13):

- `Proposal` `[store]` {id:u64, proposer:address, target_package_addr:address, new_module_bytes_hash:vector<u8>, votes_for:u64, votes_against:u64, voters:0x1::smart_table::SmartTable<address, 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::governance::ProposalVote>, created_at_secs:u64, voting_end_secs:u64, approved_at_secs:0x1::option::Option<u64>, executed_at_secs:0x1::option::Option<u64>, cancelled:bool}
- `Emission30dRollingBucket` `[key]` {daily_amounts:vector<u64>, daily_day_nums:vector<u64>}
- `GovernanceInitialized` `[drop+store]` {governance_addr:address, deployer:address, timestamp_secs:u64}
- `GovernanceState` `[key]` {signer_cap:0x1::account::SignerCapability, proposal_count:u64, proposals:0x1::smart_table::SmartTable<u64, 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::governance::Proposal>, desnet_fa_metadata:address, total_30d_emission:u64, multisig_upgrade_disabled:bool}
- `MultisigUpgrade` `[drop+store]` {multisig:address, timestamp_secs:u64}
- `MultisigUpgradeDisabled` `[drop+store]` {disabled_by:address, timestamp_secs:u64}
- `ProposalCreated` `[drop+store]` {proposal_id:u64, proposer:address, target_package_addr:address, new_module_bytes_hash:vector<u8>, voting_end_secs:u64}
- `ProposalExecuted` `[drop+store]` {proposal_id:u64, target_package_addr:address, executor:address}
- `ProposalRatified` `[drop+store]` {proposal_id:u64, votes_for_final:u64, votes_against_final:u64, timelock_until:u64}
- `ProposalVote` `[copy+drop+store]` {voter:address, weight:u64, support:bool, cast_at_secs:u64}
- `UpgradeStaging` `[drop+key]` {metadata:vector<u8>, code:vector<vector<u8>>}
- `UpgradeStagingCleanup` `[drop+store]` {multisig:address, timestamp_secs:u64}
- `VoteCast` `[drop+store]` {proposal_id:u64, voter:address, support:bool, weight:u64}

**Public fns** (29):

- [view] `voting_power(address)->u64`
- [entry] `cast_vote(&signer,u64,bool)`
- [entry] `cleanup_upgrade_staging(&signer)`
-  `compute_upgrade_digest(&vector<u8>,&vector<vector<u8>>)->vector<u8>`
- [view] `compute_upgrade_digest_view(vector<u8>,vector<vector<u8>>)->vector<u8>`
- [entry] `dao_publish_chunked_upgrade(&signer,u64,vector<u8>,vector<u16>,vector<vector<u8>>)`
- [entry] `dao_stage_upgrade_chunk(&signer,u64,vector<u8>,vector<u16>,vector<vector<u8>>)`
- [entry] `disable_multisig_upgrade(&signer)`
- [view] `effective_30d_emission_view()->u64`
- [entry] `execute_proposal(&signer,u64,vector<u8>,vector<vector<u8>>)`
- [entry] `multisig_publish_chunked_upgrade(&signer,vector<u8>,vector<u16>,vector<vector<u8>>)`
- [entry] `multisig_stage_upgrade_chunk(&signer,vector<u8>,vector<u16>,vector<vector<u8>>)`
- [entry] `multisig_upgrade(&signer,vector<u8>,vector<vector<u8>>)`
- [view] `proposal_approved_at(u64)->0x1::option::Option<u64>`
- [view] `proposal_count()->u64`
- [view] `proposal_executed_at(u64)->0x1::option::Option<u64>`
- [view] `proposal_exists(u64)->bool`
- [view] `proposal_hash(u64)->vector<u8>`
- [view] `proposal_target(u64)->address`
- [view] `proposal_threshold_amount()->u64`
- [entry] `propose_upgrade(&signer,address,vector<u8>)`
- [view] `quorum_amount()->u64`
- [entry] `ratify(&signer,u64)`
- [view] `timelock_secs()->u64`
- [view] `total_30d_emission_auto()->u64`
- [entry] `update_desnet_fa_metadata(&signer,address)`
- [entry] `update_total_30d_emission(&signer,u64)`
- [view] `upgrade_staging_exists()->bool`
- [view] `voting_period_secs()->u64`

**Friend fns** (2):

- `derive_pkg_signer()->signer`
- `record_emission_for_window(u64)`

### MASM (disassembled bytecode)

```move
// Bytecode version v9
module 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::governance
use 0x1::smart_table
use 0x1::option
use 0x1::account
use 0x1::fungible_asset
use 0x1::object
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::voter_history
use 0x1::primary_fungible_store
use 0x73c4dd3fa51260b4cd8b6878191214df1e6dcd4dbcd1ed906c05c3aaa9a9::publisher
use 0x1::signer
use 0x1::timestamp
use 0x1::event
use 0x1::bcs
use 0x1::vector
use 0x1::hash
use 0x1::code
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::amm
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::lp_staking
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::factory
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::handle_fee_vault
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::profile
struct Proposal has store
  id: u64
  proposer: address
  target_package_addr: address
  new_module_bytes_hash: vector<u8>
  votes_for: u64
  votes_against: u64
  voters: smart_table::SmartTable<address, ProposalVote>
  created_at_secs: u64
  voting_end_secs: u64
  approved_at_secs: option::Option<u64>
  executed_at_secs: option::Option<u64>
  cancelled: bool

struct Emission30dRollingBucket has key
  daily_amounts: vector<u64>
  daily_day_nums: vector<u64>

struct GovernanceInitialized has drop + store
  governance_addr: address
  deployer: address
  timestamp_secs: u64

struct GovernanceState has key
  signer_cap: account::SignerCapability
  proposal_count: u64
  proposals: smart_table::SmartTable<u64, Proposal>
  desnet_fa_metadata: address
  total_30d_emission: u64
  multisig_upgrade_disabled: bool

struct MultisigUpgrade has drop + store
  multisig: address
  timestamp_secs: u64

struct MultisigUpgradeDisabled has drop + store
  disabled_by: address
  timestamp_secs: u64

struct ProposalCreated has drop + store
  proposal_id: u64
  proposer: address
  target_package_addr: address
  new_module_bytes_hash: vector<u8>
  voting_end_secs: u64

struct ProposalExecuted has drop + store
  proposal_id: u64
  target_package_addr: address
  executor: address

struct ProposalRatified has drop + store
  proposal_id: u64
  votes_for_final: u64
  votes_against_final: u64
  timelock_until: u64

struct ProposalVote has copy + drop + store
  voter: address
  weight: u64
  support: bool
  cast_at_secs: u64

struct UpgradeStaging has drop + key
  metadata: vector<u8>
  code: vector<vector<u8>>

struct UpgradeStagingCleanup has drop + store
  multisig: address
  timestamp_secs: u64

struct VoteCast has drop + store
  proposal_id: u64
  voter: address
  support: bool
  weight: u64

// Function definition at index 0
#[persistent] public fun voting_power(l0: address): u64 acquires GovernanceState
    local l1: &GovernanceState
    local l2: u64
    local l3: object::Object<fungible_asset::Metadata>
    local l4: u64
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global GovernanceState
    pop
    ld_const<address> 31098278133965860165911002478625071607922378364132260533573856085805326542055
    call object::object_exists<fungible_asset::Metadata>
    // @5
    br_true l0
    ld_u64 0
    ret
l0: call voter_history::has_per_token_registry
    br_false l1
    // @10
    copy_loc l0
    ld_const<address> 31098278133965860165911002478625071607922378364132260533573856085805326542055
    call voter_history::rewards_earned_30d_for_token
    st_loc l2
l3: ld_const<address> 31098278133965860165911002478625071607922378364132260533573856085805326542055
    // @15
    call object::address_to_object<fungible_asset::Metadata>
    st_loc l3
    move_loc l0
    move_loc l3
    call primary_fungible_store::balance<fungible_asset::Metadata>
    // @20
    st_loc l4
    copy_loc l2
    copy_loc l4
    lt
    br_false l2
    // @25
    move_loc l2
    ret
l2: move_loc l4
    ret
l1: copy_loc l0
    // @30
    call voter_history::rewards_earned_30d
    st_loc l2
    branch l3

// Function definition at index 1
fun init_module(l0: &signer)
    local l1: &signer
    local l2: address
    local l3: account::SignerCapability
    local l4: GovernanceState
    copy_loc l0
    call publisher::take_cap_for_desnet
    copy_loc l0
    call signer::address_of
    copy_loc l0
    // @5
    st_loc l1
    st_loc l2
    ld_u64 0
    call smart_table::new<u64, Proposal>
    ld_const<address> 0
    // @10
    ld_u64 0
    ld_false
    pack GovernanceState
    st_loc l4
    move_loc l1
    // @15
    move_loc l4
    move_to GovernanceState
    move_loc l0
    call voter_history::init_registry
    move_loc l2
    // @20
    ld_const<address> 799008279626092026266606374476533705615973526478392622784892721766771113
    call timestamp::now_seconds
    pack GovernanceInitialized
    call event::emit<GovernanceInitialized>
    ret

// Function definition at index 2
#[persistent] entry public fun cast_vote(l0: &signer, l1: u64, l2: bool) acquires GovernanceState
    local l3: address
    local l4: u64
    local l5: &mut GovernanceState
    local l6: &mut Proposal
    local l7: u64
    local l8: ProposalVote
    move_loc l0
    call signer::address_of
    st_loc l3
    copy_loc l3
    call voting_power
    // @5
    st_loc l4
    copy_loc l4
    ld_u64 0
    gt
    br_false l0
    // @10
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    mut_borrow_global GovernanceState
    st_loc l5
    copy_loc l5
    borrow_field GovernanceState, proposals
    // @15
    copy_loc l1
    call smart_table::contains<u64, Proposal>
    br_false l1
    move_loc l5
    mut_borrow_field GovernanceState, proposals
    // @20
    copy_loc l1
    call smart_table::borrow_mut<u64, Proposal>
    st_loc l6
    call timestamp::now_seconds
    st_loc l7
    // @25
    copy_loc l6
    borrow_field Proposal, cancelled
    read_ref
    br_true l2
    copy_loc l6
    // @30
    borrow_field Proposal, approved_at_secs
    call option::is_none<u64>
    br_false l3
    copy_loc l7
    copy_loc l6
    // @35
    borrow_field Proposal, voting_end_secs
    read_ref
    lt
    br_false l4
    copy_loc l6
    // @40
    borrow_field Proposal, voters
    copy_loc l3
    call smart_table::contains<address, ProposalVote>
    br_true l5
    copy_loc l3
    // @45
    copy_loc l4
    copy_loc l2
    move_loc l7
    pack ProposalVote
    st_loc l8
    // @50
    copy_loc l6
    mut_borrow_field Proposal, voters
    copy_loc l3
    move_loc l8
    call smart_table::add<address, ProposalVote>
    // @55
    copy_loc l2
    br_false l6
    copy_loc l6
    borrow_field Proposal, votes_for
    read_ref
    // @60
    copy_loc l4
    add
    move_loc l6
    mut_borrow_field Proposal, votes_for
    write_ref
    // @65
l7: move_loc l1
    move_loc l3
    move_loc l2
    move_loc l4
    pack VoteCast
    // @70
    call event::emit<VoteCast>
    ret
l6: copy_loc l6
    borrow_field Proposal, votes_against
    read_ref
    // @75
    copy_loc l4
    add
    move_loc l6
    mut_borrow_field Proposal, votes_against
    write_ref
    // @80
    branch l7
l5: move_loc l6
    pop
    ld_u64 9
    abort
    // @85
l4: move_loc l6
    pop
    ld_u64 4
    abort
l3: move_loc l6
    // @90
    pop
    ld_u64 17
    abort
l2: move_loc l6
    pop
    // @95
    ld_u64 3
    abort
l1: move_loc l5
    pop
    ld_u64 2
    // @100
    abort
l0: ld_u64 1
    abort

// Function definition at index 3
#[persistent] entry public fun cleanup_upgrade_staging(l0: &signer) acquires UpgradeStaging
    copy_loc l0
    call signer::address_of
    ld_const<address> 799008279626092026266606374476533705615973526478392622784892721766771113
    eq
    br_false l0
    // @5
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    exists UpgradeStaging
    br_false l1
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    move_from UpgradeStaging
    // @10
    pop
    move_loc l0
    call signer::address_of
    call timestamp::now_seconds
    pack UpgradeStagingCleanup
    // @15
    call event::emit<UpgradeStagingCleanup>
    ret
l1: move_loc l0
    pop
    ret
    // @20
l0: move_loc l0
    pop
    ld_u64 15
    abort

// Function definition at index 4
#[persistent] public fun compute_upgrade_digest(l0: &vector<u8>, l1: &vector<vector<u8>>): vector<u8>
    local l2: vector<u8>
    local l3: u64
    local l4: u64
    local l5: vector<u8>
    move_loc l0
    call bcs::to_bytes<vector<u8>>
    st_loc l2
    ld_u64 0
    st_loc l3
    // @5
    copy_loc l1
    vec_len <vector<u8>>
    st_loc l4
l1: copy_loc l3
    copy_loc l4
    // @10
    lt
    br_false l0
    copy_loc l1
    copy_loc l3
    vec_borrow <vector<u8>>
    // @15
    call bcs::to_bytes<vector<u8>>
    st_loc l5
    mut_borrow_loc l2
    move_loc l5
    call vector::append<u8>
    // @20
    move_loc l3
    ld_u64 1
    add
    st_loc l3
    branch l1
    // @25
l0: move_loc l1
    pop
    move_loc l2
    call hash::sha3_256
    ret

// Function definition at index 5
#[persistent] public fun compute_upgrade_digest_view(l0: vector<u8>, l1: vector<vector<u8>>): vector<u8>
    borrow_loc l0
    borrow_loc l1
    call compute_upgrade_digest
    ret

// Function definition at index 6
#[persistent] entry public fun dao_publish_chunked_upgrade(l0: &signer, l1: u64, l2: vector<u8>, l3: vector<u16>, l4: vector<vector<u8>>) acquires GovernanceState, UpgradeStaging
    local l5: &GovernanceState
    local l6: &Proposal
    local l7: option::Option<u64>
    local l8: u64
    local l9: u64
    local l10: address
    local l11: vector<u8>
    local l12: signer
    local l13: vector<vector<u8>>
    local l14: vector<u8>
    local l15: &mut Proposal
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global GovernanceState
    st_loc l5
    copy_loc l5
    borrow_field GovernanceState, proposals
    // @5
    copy_loc l1
    call smart_table::contains<u64, Proposal>
    br_false l0
    move_loc l5
    borrow_field GovernanceState, proposals
    // @10
    copy_loc l1
    call smart_table::borrow<u64, Proposal>
    st_loc l6
    copy_loc l6
    borrow_field Proposal, approved_at_secs
    // @15
    read_ref
    st_loc l7
    borrow_loc l7
    call option::is_some<u64>
    br_false l1
    // @20
    copy_loc l6
    borrow_field Proposal, executed_at_secs
    call option::is_none<u64>
    br_false l2
    borrow_loc l7
    // @25
    call option::borrow<u64>
    read_ref
    call timestamp::now_seconds
    st_loc l8
    ld_u64 2592000
    // @30
    add
    st_loc l9
    move_loc l8
    move_loc l9
    ge
    // @35
    br_false l3
    copy_loc l6
    borrow_field Proposal, target_package_addr
    read_ref
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    // @40
    eq
    br_false l4
    copy_loc l6
    borrow_field Proposal, target_package_addr
    read_ref
    // @45
    st_loc l10
    move_loc l6
    borrow_field Proposal, new_module_bytes_hash
    read_ref
    st_loc l11
    // @50
    call derive_pkg_signer
    st_loc l12
    borrow_loc l12
    move_loc l2
    move_loc l3
    // @55
    move_loc l4
    call stage_chunks_into_staging
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    move_from UpgradeStaging
    unpack UpgradeStaging
    // @60
    st_loc l13
    st_loc l14
    ld_u64 0
    st_loc l9
    borrow_loc l13
    // @65
    vec_len <vector<u8>>
    st_loc l8
l7: copy_loc l9
    copy_loc l8
    lt
    // @70
    br_false l5
    borrow_loc l13
    copy_loc l9
    vec_borrow <vector<u8>>
    call vector::is_empty<u8>
    // @75
    br_true l6
    move_loc l9
    ld_u64 1
    add
    st_loc l9
    // @80
    branch l7
l6: move_loc l0
    pop
    ld_u64 23
    abort
    // @85
l5: borrow_loc l14
    borrow_loc l13
    call compute_upgrade_digest
    move_loc l11
    eq
    // @90
    br_false l8
    call timestamp::now_seconds
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    mut_borrow_global GovernanceState
    mut_borrow_field GovernanceState, proposals
    // @95
    copy_loc l1
    call smart_table::borrow_mut<u64, Proposal>
    st_loc l15
    call option::some<u64>
    move_loc l15
    // @100
    mut_borrow_field Proposal, executed_at_secs
    write_ref
    borrow_loc l12
    move_loc l14
    move_loc l13
    // @105
    call code::publish_package_txn
    move_loc l1
    move_loc l10
    move_loc l0
    call signer::address_of
    // @110
    pack ProposalExecuted
    call event::emit<ProposalExecuted>
    ret
l8: move_loc l0
    pop
    // @115
    ld_u64 18
    abort
l4: move_loc l0
    pop
    move_loc l6
    // @120
    pop
    ld_u64 20
    abort
l3: move_loc l0
    pop
    // @125
    move_loc l6
    pop
    ld_u64 8
    abort
l2: move_loc l0
    // @130
    pop
    move_loc l6
    pop
    ld_u64 16
    abort
    // @135
l1: move_loc l0
    pop
    move_loc l6
    pop
    ld_u64 6
    // @140
    abort
l0: move_loc l0
    pop
    move_loc l5
    pop
    // @145
    ld_u64 2
    abort

// Function definition at index 7
#[persistent] entry public fun dao_stage_upgrade_chunk(l0: &signer, l1: u64, l2: vector<u8>, l3: vector<u16>, l4: vector<vector<u8>>) acquires GovernanceState, UpgradeStaging
    local l5: &GovernanceState
    local l6: &Proposal
    local l7: option::Option<u64>
    local l8: u64
    local l9: u64
    local l10: signer
    local l11: vector<u16>
    local l12: vector<u8>
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    move_loc l0
    pop
    borrow_global GovernanceState
    st_loc l5
    // @5
    copy_loc l5
    borrow_field GovernanceState, proposals
    copy_loc l1
    call smart_table::contains<u64, Proposal>
    br_false l0
    // @10
    move_loc l5
    borrow_field GovernanceState, proposals
    move_loc l1
    call smart_table::borrow<u64, Proposal>
    st_loc l6
    // @15
    copy_loc l6
    borrow_field Proposal, approved_at_secs
    read_ref
    st_loc l7
    borrow_loc l7
    // @20
    call option::is_some<u64>
    br_false l1
    copy_loc l6
    borrow_field Proposal, executed_at_secs
    call option::is_none<u64>
    // @25
    br_false l2
    borrow_loc l7
    call option::borrow<u64>
    read_ref
    call timestamp::now_seconds
    // @30
    st_loc l8
    ld_u64 2592000
    add
    st_loc l9
    move_loc l8
    // @35
    move_loc l9
    ge
    br_false l3
    move_loc l6
    borrow_field Proposal, target_package_addr
    // @40
    read_ref
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    eq
    br_false l4
    call derive_pkg_signer
    // @45
    st_loc l10
    borrow_loc l10
    st_loc l0
    move_loc l2
    move_loc l3
    // @50
    st_loc l11
    st_loc l12
    move_loc l0
    move_loc l12
    move_loc l11
    // @55
    move_loc l4
    call stage_chunks_into_staging
    ret
l4: ld_u64 20
    abort
    // @60
l3: move_loc l6
    pop
    ld_u64 8
    abort
l2: move_loc l6
    // @65
    pop
    ld_u64 16
    abort
l1: move_loc l6
    pop
    // @70
    ld_u64 6
    abort
l0: move_loc l5
    pop
    ld_u64 2
    // @75
    abort

// Function definition at index 8
friend fun derive_pkg_signer(): signer acquires GovernanceState
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global GovernanceState
    borrow_field GovernanceState, signer_cap
    call account::create_signer_with_capability
    ret

// Function definition at index 9
#[persistent] entry public fun disable_multisig_upgrade(l0: &signer) acquires GovernanceState
    copy_loc l0
    call signer::address_of
    ld_const<address> 799008279626092026266606374476533705615973526478392622784892721766771113
    eq
    br_false l0
    // @5
    ld_true
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    mut_borrow_global GovernanceState
    mut_borrow_field GovernanceState, multisig_upgrade_disabled
    write_ref
    // @10
    move_loc l0
    call signer::address_of
    call timestamp::now_seconds
    pack MultisigUpgradeDisabled
    call event::emit<MultisigUpgradeDisabled>
    // @15
    ret
l0: move_loc l0
    pop
    ld_u64 15
    abort

// Function definition at index 10
fun effective_30d_emission(): u64 acquires Emission30dRollingBucket, GovernanceState
    local l0: u64
    local l1: u64
    call total_30d_emission_auto
    st_loc l0
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global GovernanceState
    borrow_field GovernanceState, total_30d_emission
    // @5
    read_ref
    st_loc l1
    copy_loc l0
    copy_loc l1
    gt
    // @10
    br_false l0
    move_loc l0
    ret
l0: move_loc l1
    ret

// Function definition at index 11
#[persistent] public fun effective_30d_emission_view(): u64 acquires Emission30dRollingBucket, GovernanceState
    call effective_30d_emission
    ret

// Function definition at index 12
#[persistent] entry public fun execute_proposal(l0: &signer, l1: u64, l2: vector<u8>, l3: vector<vector<u8>>) acquires GovernanceState
    local l4: vector<u8>
    local l5: signer
    local l6: &mut GovernanceState
    local l7: &mut Proposal
    local l8: option::Option<u64>
    local l9: u64
    local l10: u64
    local l11: u64
    local l12: address
    borrow_loc l2
    borrow_loc l3
    call compute_upgrade_digest
    st_loc l4
    call derive_pkg_signer
    // @5
    st_loc l5
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    mut_borrow_global GovernanceState
    st_loc l6
    copy_loc l6
    // @10
    borrow_field GovernanceState, proposals
    copy_loc l1
    call smart_table::contains<u64, Proposal>
    br_false l0
    move_loc l6
    // @15
    mut_borrow_field GovernanceState, proposals
    copy_loc l1
    call smart_table::borrow_mut<u64, Proposal>
    st_loc l7
    copy_loc l7
    // @20
    borrow_field Proposal, approved_at_secs
    read_ref
    st_loc l8
    borrow_loc l8
    call option::is_some<u64>
    // @25
    br_false l1
    copy_loc l7
    borrow_field Proposal, executed_at_secs
    call option::is_none<u64>
    br_false l2
    // @30
    borrow_loc l8
    call option::borrow<u64>
    read_ref
    call timestamp::now_seconds
    st_loc l9
    // @35
    copy_loc l9
    st_loc l10
    ld_u64 2592000
    add
    st_loc l11
    // @40
    move_loc l10
    move_loc l11
    ge
    br_false l3
    move_loc l4
    // @45
    copy_loc l7
    borrow_field Proposal, new_module_bytes_hash
    read_ref
    eq
    br_false l4
    // @50
    copy_loc l7
    borrow_field Proposal, target_package_addr
    read_ref
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    eq
    // @55
    br_false l5
    move_loc l9
    call option::some<u64>
    copy_loc l7
    mut_borrow_field Proposal, executed_at_secs
    // @60
    write_ref
    move_loc l7
    borrow_field Proposal, target_package_addr
    read_ref
    st_loc l12
    // @65
    borrow_loc l5
    move_loc l2
    move_loc l3
    call code::publish_package_txn
    move_loc l1
    // @70
    move_loc l12
    move_loc l0
    call signer::address_of
    pack ProposalExecuted
    call event::emit<ProposalExecuted>
    // @75
    ret
l5: move_loc l0
    pop
    move_loc l7
    pop
    // @80
    ld_u64 20
    abort
l4: move_loc l0
    pop
    move_loc l7
    // @85
    pop
    ld_u64 18
    abort
l3: move_loc l0
    pop
    // @90
    move_loc l7
    pop
    ld_u64 8
    abort
l2: move_loc l0
    // @95
    pop
    move_loc l7
    pop
    ld_u64 16
    abort
    // @100
l1: move_loc l0
    pop
    move_loc l7
    pop
    ld_u64 6
    // @105
    abort
l0: move_loc l0
    pop
    move_loc l6
    pop
    // @110
    ld_u64 2
    abort

// Function definition at index 13
#[persistent] entry public fun multisig_publish_chunked_upgrade(l0: &signer, l1: vector<u8>, l2: vector<u16>, l3: vector<vector<u8>>) acquires GovernanceState, UpgradeStaging
    local l4: signer
    local l5: vector<vector<u8>>
    local l6: vector<u8>
    local l7: u64
    local l8: u64
    copy_loc l0
    call signer::address_of
    ld_const<address> 799008279626092026266606374476533705615973526478392622784892721766771113
    eq
    br_false l0
    // @5
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global GovernanceState
    borrow_field GovernanceState, multisig_upgrade_disabled
    read_ref
    br_true l1
    // @10
    call derive_pkg_signer
    st_loc l4
    borrow_loc l4
    move_loc l1
    move_loc l2
    // @15
    move_loc l3
    call stage_chunks_into_staging
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    move_from UpgradeStaging
    unpack UpgradeStaging
    // @20
    st_loc l5
    st_loc l6
    ld_u64 0
    st_loc l7
    borrow_loc l5
    // @25
    vec_len <vector<u8>>
    st_loc l8
l4: copy_loc l7
    copy_loc l8
    lt
    // @30
    br_false l2
    borrow_loc l5
    copy_loc l7
    vec_borrow <vector<u8>>
    call vector::is_empty<u8>
    // @35
    br_true l3
    move_loc l7
    ld_u64 1
    add
    st_loc l7
    // @40
    branch l4
l3: move_loc l0
    pop
    ld_u64 23
    abort
    // @45
l2: borrow_loc l4
    move_loc l6
    move_loc l5
    call code::publish_package_txn
    move_loc l0
    // @50
    call signer::address_of
    call timestamp::now_seconds
    pack MultisigUpgrade
    call event::emit<MultisigUpgrade>
    ret
    // @55
l1: move_loc l0
    pop
    ld_u64 19
    abort
l0: move_loc l0
    // @60
    pop
    ld_u64 15
    abort

// Function definition at index 14
#[persistent] entry public fun multisig_stage_upgrade_chunk(l0: &signer, l1: vector<u8>, l2: vector<u16>, l3: vector<vector<u8>>) acquires GovernanceState, UpgradeStaging
    local l4: signer
    move_loc l0
    call signer::address_of
    ld_const<address> 799008279626092026266606374476533705615973526478392622784892721766771113
    eq
    br_false l0
    // @5
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global GovernanceState
    borrow_field GovernanceState, multisig_upgrade_disabled
    read_ref
    br_true l1
    // @10
    call derive_pkg_signer
    st_loc l4
    borrow_loc l4
    move_loc l1
    move_loc l2
    // @15
    move_loc l3
    call stage_chunks_into_staging
    ret
l1: ld_u64 19
    abort
    // @20
l0: ld_u64 15
    abort

// Function definition at index 15
#[persistent] entry public fun multisig_upgrade(l0: &signer, l1: vector<u8>, l2: vector<vector<u8>>) acquires GovernanceState
    local l3: signer
    copy_loc l0
    call signer::address_of
    ld_const<address> 799008279626092026266606374476533705615973526478392622784892721766771113
    eq
    br_false l0
    // @5
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global GovernanceState
    borrow_field GovernanceState, multisig_upgrade_disabled
    read_ref
    br_true l1
    // @10
    call derive_pkg_signer
    st_loc l3
    borrow_loc l3
    move_loc l1
    move_loc l2
    // @15
    call code::publish_package_txn
    move_loc l0
    call signer::address_of
    call timestamp::now_seconds
    pack MultisigUpgrade
    // @20
    call event::emit<MultisigUpgrade>
    ret
l1: move_loc l0
    pop
    ld_u64 19
    // @25
    abort
l0: move_loc l0
    pop
    ld_u64 15
    abort

// Function definition at index 16
#[persistent] public fun proposal_approved_at(l0: u64): option::Option<u64> acquires GovernanceState
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global GovernanceState
    borrow_field GovernanceState, proposals
    move_loc l0
    call smart_table::borrow<u64, Proposal>
    // @5
    borrow_field Proposal, approved_at_secs
    read_ref
    ret

// Function definition at index 17
#[persistent] public fun proposal_count(): u64 acquires GovernanceState
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global GovernanceState
    borrow_field GovernanceState, proposal_count
    read_ref
    ret

// Function definition at index 18
#[persistent] public fun proposal_executed_at(l0: u64): option::Option<u64> acquires GovernanceState
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global GovernanceState
    borrow_field GovernanceState, proposals
    move_loc l0
    call smart_table::borrow<u64, Proposal>
    // @5
    borrow_field Proposal, executed_at_secs
    read_ref
    ret

// Function definition at index 19
#[persistent] public fun proposal_exists(l0: u64): bool acquires GovernanceState
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global GovernanceState
    borrow_field GovernanceState, proposals
    move_loc l0
    call smart_table::contains<u64, Proposal>
    // @5
    ret

// Function definition at index 20
#[persistent] public fun proposal_hash(l0: u64): vector<u8> acquires GovernanceState
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global GovernanceState
    borrow_field GovernanceState, proposals
    move_loc l0
    call smart_table::borrow<u64, Proposal>
    // @5
    borrow_field Proposal, new_module_bytes_hash
    read_ref
    ret

// Function definition at index 21
#[persistent] public fun proposal_target(l0: u64): address acquires GovernanceState
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global GovernanceState
    borrow_field GovernanceState, proposals
    move_loc l0
    call smart_table::borrow<u64, Proposal>
    // @5
    borrow_field Proposal, target_package_addr
    read_ref
    ret

// Function definition at index 22
#[persistent] public fun proposal_threshold_amount(): u64 acquires Emission30dRollingBucket, GovernanceState
    local l0: u64
    call effective_30d_emission
    st_loc l0
    copy_loc l0
    ld_u64 0
    eq
    // @5
    br_false l0
    ld_u64 18446744073709551615
    ret
l0: move_loc l0
    ld_u64 500
    // @10
    mul
    ld_u64 10000
    div
    ret

// Function definition at index 23
#[persistent] entry public fun propose_upgrade(l0: &signer, l1: address, l2: vector<u8>) acquires Emission30dRollingBucket, GovernanceState
    local l3: address
    local l4: &mut GovernanceState
    local l5: u64
    local l6: u64
    local l7: u64
    local l8: Proposal
    copy_loc l1
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    eq
    br_false l0
    call effective_30d_emission
    // @5
    ld_u64 0
    gt
    br_false l1
    move_loc l0
    call signer::address_of
    // @10
    st_loc l3
    copy_loc l3
    call voting_power
    call proposal_threshold_amount
    ge
    // @15
    br_false l2
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    mut_borrow_global GovernanceState
    st_loc l4
    copy_loc l4
    // @20
    borrow_field GovernanceState, proposal_count
    read_ref
    st_loc l5
    copy_loc l5
    ld_u64 1
    // @25
    add
    copy_loc l4
    mut_borrow_field GovernanceState, proposal_count
    write_ref
    call timestamp::now_seconds
    // @30
    st_loc l6
    copy_loc l6
    ld_u64 604800
    add
    st_loc l7
    // @35
    copy_loc l5
    copy_loc l3
    copy_loc l1
    copy_loc l2
    ld_u64 0
    // @40
    ld_u64 0
    call smart_table::new<address, ProposalVote>
    move_loc l6
    copy_loc l7
    call option::none<u64>
    // @45
    call option::none<u64>
    ld_false
    pack Proposal
    st_loc l8
    move_loc l4
    // @50
    mut_borrow_field GovernanceState, proposals
    copy_loc l5
    move_loc l8
    call smart_table::add<u64, Proposal>
    move_loc l5
    // @55
    move_loc l3
    move_loc l1
    move_loc l2
    move_loc l7
    pack ProposalCreated
    // @60
    call event::emit<ProposalCreated>
    ret
l2: ld_u64 1
    abort
l1: move_loc l0
    // @65
    pop
    ld_u64 11
    abort
l0: move_loc l0
    pop
    // @70
    ld_u64 20
    abort

// Function definition at index 24
#[persistent] public fun quorum_amount(): u64 acquires Emission30dRollingBucket, GovernanceState
    local l0: u64
    call effective_30d_emission
    st_loc l0
    copy_loc l0
    ld_u64 0
    eq
    // @5
    br_false l0
    ld_u64 18446744073709551615
    ret
l0: move_loc l0
    ld_u64 3500
    // @10
    mul
    ld_u64 10000
    div
    ret

// Function definition at index 25
#[persistent] entry public fun ratify(l0: &signer, l1: u64) acquires Emission30dRollingBucket, GovernanceState
    local l2: u64
    local l3: &mut GovernanceState
    local l4: &mut Proposal
    local l5: u64
    local l6: u64
    call quorum_amount
    st_loc l2
    move_loc l0
    pop
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    // @5
    mut_borrow_global GovernanceState
    st_loc l3
    copy_loc l3
    borrow_field GovernanceState, proposals
    copy_loc l1
    // @10
    call smart_table::contains<u64, Proposal>
    br_false l0
    move_loc l3
    mut_borrow_field GovernanceState, proposals
    copy_loc l1
    // @15
    call smart_table::borrow_mut<u64, Proposal>
    st_loc l4
    call timestamp::now_seconds
    st_loc l5
    copy_loc l5
    // @20
    copy_loc l4
    borrow_field Proposal, voting_end_secs
    read_ref
    ge
    br_false l1
    // @25
    copy_loc l4
    borrow_field Proposal, approved_at_secs
    call option::is_none<u64>
    br_false l2
    copy_loc l4
    // @30
    borrow_field Proposal, cancelled
    read_ref
    br_true l3
    copy_loc l4
    borrow_field Proposal, votes_for
    // @35
    read_ref
    copy_loc l4
    borrow_field Proposal, votes_against
    read_ref
    add
    // @40
    st_loc l6
    copy_loc l6
    move_loc l2
    ge
    br_false l4
    // @45
    copy_loc l4
    borrow_field Proposal, votes_for
    read_ref
    ld_u64 10000
    mul
    // @50
    ld_u64 7000
    move_loc l6
    mul
    ge
    br_false l5
    // @55
    copy_loc l5
    call option::some<u64>
    copy_loc l4
    mut_borrow_field Proposal, approved_at_secs
    write_ref
    // @60
    move_loc l1
    copy_loc l4
    borrow_field Proposal, votes_for
    read_ref
    move_loc l4
    // @65
    borrow_field Proposal, votes_against
    read_ref
    move_loc l5
    ld_u64 2592000
    add
    // @70
    pack ProposalRatified
    call event::emit<ProposalRatified>
    ret
l5: move_loc l4
    pop
    // @75
    ld_u64 7
    abort
l4: move_loc l4
    pop
    ld_u64 6
    // @80
    abort
l3: move_loc l4
    pop
    ld_u64 3
    abort
    // @85
l2: move_loc l4
    pop
    ld_u64 17
    abort
l1: move_loc l4
    // @90
    pop
    ld_u64 5
    abort
l0: move_loc l3
    pop
    // @95
    ld_u64 2
    abort

// Function definition at index 26
friend fun record_emission_for_window(l0: u64) acquires Emission30dRollingBucket, GovernanceState
    local l1: u64
    local l2: signer
    local l3: vector<u64>
    local l4: vector<u64>
    local l5: u64
    local l6: &mut Emission30dRollingBucket
    local l7: &mut u64
    local l8: u64
    copy_loc l0
    ld_u64 0
    eq
    br_false l0
    ret
    // @5
l0: call timestamp::now_seconds
    ld_u64 86400
    div
    st_loc l1
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    // @10
    exists Emission30dRollingBucket
    br_false l1
    branch l2
l1: call derive_pkg_signer
    st_loc l2
    // @15
    vec_pack <u64>, 0
    st_loc l3
    vec_pack <u64>, 0
    st_loc l4
    ld_u64 0
    // @20
    st_loc l5
l4: copy_loc l5
    ld_u64 30
    lt
    br_false l3
    // @25
    mut_borrow_loc l3
    ld_u64 0
    vec_push_back <u64>
    mut_borrow_loc l4
    ld_u64 0
    // @30
    vec_push_back <u64>
    move_loc l5
    ld_u64 1
    add
    st_loc l5
    // @35
    branch l4
l3: borrow_loc l2
    move_loc l3
    move_loc l4
    pack Emission30dRollingBucket
    // @40
    move_to Emission30dRollingBucket
l2: ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    mut_borrow_global Emission30dRollingBucket
    st_loc l6
    copy_loc l1
    // @45
    ld_u64 30
    mod
    st_loc l5
    copy_loc l6
    borrow_field Emission30dRollingBucket, daily_day_nums
    // @50
    copy_loc l5
    vec_borrow <u64>
    read_ref
    copy_loc l1
    neq
    // @55
    br_true l5
    branch l6
l5: ld_u64 0
    copy_loc l6
    mut_borrow_field Emission30dRollingBucket, daily_amounts
    // @60
    copy_loc l5
    vec_mut_borrow <u64>
    write_ref
    copy_loc l6
    mut_borrow_field Emission30dRollingBucket, daily_day_nums
    // @65
    copy_loc l5
    vec_mut_borrow <u64>
    st_loc l7
    move_loc l1
    move_loc l7
    // @70
    write_ref
l6: copy_loc l6
    borrow_field Emission30dRollingBucket, daily_amounts
    copy_loc l5
    vec_borrow <u64>
    // @75
    read_ref
    st_loc l1
    copy_loc l1
    ld_u64 18446744073709551615
    copy_loc l0
    // @80
    sub
    gt
    br_false l7
    ld_u64 18446744073709551615
    st_loc l8
    // @85
l8: move_loc l6
    mut_borrow_field Emission30dRollingBucket, daily_amounts
    move_loc l5
    vec_mut_borrow <u64>
    st_loc l7
    // @90
    move_loc l8
    move_loc l7
    write_ref
    ret
l7: move_loc l1
    // @95
    move_loc l0
    add
    st_loc l8
    branch l8

// Function definition at index 27
fun stage_chunks_into_staging(l0: &signer, l1: vector<u8>, l2: vector<u16>, l3: vector<vector<u8>>) acquires UpgradeStaging
    local l4: &mut UpgradeStaging
    local l5: u64
    local l6: u64
    local l7: u64
    local l8: vector<u8>
    local l9: &mut vector<u8>
    borrow_loc l2
    vec_len <u16>
    borrow_loc l3
    vec_len <vector<u8>>
    eq
    // @5
    br_false l0
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    exists UpgradeStaging
    br_true l1
    move_loc l0
    // @10
    vec_pack <u8>, 0
    vec_pack <vector<u8>>, 0
    pack UpgradeStaging
    move_to UpgradeStaging
l6: ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    // @15
    mut_borrow_global UpgradeStaging
    st_loc l4
    copy_loc l4
    mut_borrow_field UpgradeStaging, metadata
    move_loc l1
    // @20
    call vector::append<u8>
    borrow_loc l3
    vec_len <vector<u8>>
    st_loc l5
    ld_u64 0
    // @25
    st_loc l6
l5: copy_loc l6
    copy_loc l5
    lt
    br_false l2
    // @30
    borrow_loc l2
    copy_loc l6
    vec_borrow <u16>
    read_ref
    cast_u64
    // @35
    st_loc l7
l4: copy_loc l4
    borrow_field UpgradeStaging, code
    vec_len <vector<u8>>
    copy_loc l7
    // @40
    le
    br_false l3
    copy_loc l4
    mut_borrow_field UpgradeStaging, code
    vec_pack <u8>, 0
    // @45
    vec_push_back <vector<u8>>
    branch l4
l3: copy_loc l4
    mut_borrow_field UpgradeStaging, code
    move_loc l7
    // @50
    vec_mut_borrow <vector<u8>>
    borrow_loc l3
    copy_loc l6
    vec_borrow <vector<u8>>
    read_ref
    // @55
    call vector::append<u8>
    move_loc l6
    ld_u64 1
    add
    st_loc l6
    // @60
    branch l5
l2: move_loc l4
    pop
    ret
l1: move_loc l0
    // @65
    pop
    branch l6
l0: move_loc l0
    pop
    ld_u64 21
    // @70
    abort

// Function definition at index 28
#[persistent] public fun timelock_secs(): u64
    ld_u64 2592000
    ret

// Function definition at index 29
#[persistent] public fun total_30d_emission_auto(): u64 acquires Emission30dRollingBucket
    local l0: &Emission30dRollingBucket
    local l1: u64
    local l2: u64
    local l3: u64
    local l4: u64
    local l5: u64
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    exists Emission30dRollingBucket
    br_true l0
    ld_u64 0
    ret
    // @5
l0: ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global Emission30dRollingBucket
    st_loc l0
    call timestamp::now_seconds
    ld_u64 86400
    // @10
    div
    st_loc l1
    copy_loc l1
    ld_u64 29
    ge
    // @15
    br_false l1
    move_loc l1
    ld_u64 29
    sub
    st_loc l2
    // @20
l7: ld_u64 0
    st_loc l3
    ld_u64 0
    st_loc l4
l6: copy_loc l4
    // @25
    ld_u64 30
    lt
    br_false l2
    copy_loc l0
    borrow_field Emission30dRollingBucket, daily_day_nums
    // @30
    copy_loc l4
    vec_borrow <u64>
    read_ref
    copy_loc l2
    ge
    // @35
    br_true l3
    branch l4
l3: copy_loc l0
    borrow_field Emission30dRollingBucket, daily_amounts
    copy_loc l4
    // @40
    vec_borrow <u64>
    read_ref
    st_loc l5
    copy_loc l3
    ld_u64 18446744073709551615
    // @45
    copy_loc l5
    sub
    gt
    br_false l5
    ld_u64 18446744073709551615
    // @50
    st_loc l3
l4: move_loc l4
    ld_u64 1
    add
    st_loc l4
    // @55
    branch l6
l5: move_loc l3
    move_loc l5
    add
    st_loc l3
    // @60
    branch l4
l2: move_loc l0
    pop
    move_loc l3
    ret
    // @65
l1: ld_u64 0
    st_loc l2
    branch l7

// Function definition at index 30
#[persistent] entry public fun update_desnet_fa_metadata(l0: &signer, l1: address) acquires GovernanceState
    local l2: &GovernanceState
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    move_loc l0
    pop
    borrow_global GovernanceState
    pop
    // @5
    ld_u64 22
    abort

// Function definition at index 31
#[persistent] entry public fun update_total_30d_emission(l0: &signer, l1: u64) acquires GovernanceState
    local l2: &GovernanceState
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    move_loc l0
    pop
    borrow_global GovernanceState
    pop
    // @5
    ld_u64 22
    abort

// Function definition at index 32
#[persistent] public fun upgrade_staging_exists(): bool
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    exists UpgradeStaging
    ret

// Function definition at index 33
#[persistent] public fun voting_period_secs(): u64
    ld_u64 604800
    ret
```

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

-  `swap(address,address,0x1::fungible_asset::FungibleAsset,u64)->0x1::fungible_asset::FungibleAsset`
- [view] `compute_amount_out(u64,u64,u64)->u64`
-  `compute_flash_fee(u64)->u64`
- [view] `creator_pid(vector<u8>)->address`
- [view] `creator_pid_at(address)->address`
- [view] `fee_acc_scale()->u128`
- [view] `fee_bps(vector<u8>)->u64`
- [view] `fee_buckets(vector<u8>)->u64,u64`
- [view] `fee_buckets_at(address)->u64,u64`
- [view] `fee_per_lp(vector<u8>)->u128,u128`
-  `flash_borrow(address,0x1::object::Object<0x1::fungible_asset::Metadata>,u64)->0x1::fungible_asset::FungibleAsset,0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::amm::FlashReceipt`
- [view] `flash_fee_bps()->u64`
-  `flash_repay(address,0x1::fungible_asset::FungibleAsset,0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::amm::FlashReceipt)`
- [view] `lp_fee_per_share(address)->u128,u128`
- [view] `lp_fee_per_share_by_handle(vector<u8>)->u128,u128`
- [view] `lp_supply(vector<u8>)->u128`
- [view] `lp_supply_at(address)->u128`
-  `pool_address_of_handle(vector<u8>)->address`
-  `pool_exists(vector<u8>)->bool`
-  `pool_exists_at(address)->bool`
- [view] `pool_locked(address)->bool`
- [view] `pool_locked_by_handle(vector<u8>)->bool`
- [view] `pool_tokens(address)->0x1::object::Object<0x1::fungible_asset::Metadata>,0x1::object::Object<0x1::fungible_asset::Metadata>`
- [view] `quote_swap_exact_in(vector<u8>,u64,bool)->u64`
- [view] `quote_swap_exact_in_at(address,u64,bool)->u64`
- [view] `read_warning()->vector<u8>`
- [view] `reserves(vector<u8>)->u64,u64`
- [view] `reserves_at(address)->u64,u64`
- [entry] `swap_apt_for_token(&signer,vector<u8>,u64,u64)`
-  `swap_exact_apt_in(vector<u8>,0x1::fungible_asset::FungibleAsset,u64)->0x1::fungible_asset::FungibleAsset`
-  `swap_exact_apt_in_actor(vector<u8>,0x1::fungible_asset::FungibleAsset,u64,address)->0x1::fungible_asset::FungibleAsset`
-  `swap_exact_token_in(vector<u8>,0x1::fungible_asset::FungibleAsset,u64)->0x1::fungible_asset::FungibleAsset`
-  `swap_exact_token_in_actor(vector<u8>,0x1::fungible_asset::FungibleAsset,u64,address)->0x1::fungible_asset::FungibleAsset`
- [entry] `swap_token_for_apt(&signer,vector<u8>,u64,u64)`
- [view] `token_metadata_addr(vector<u8>)->address`

**Friend fns** (4):

- `add_liquidity_internal(vector<u8>,0x1::fungible_asset::FungibleAsset,0x1::fungible_asset::FungibleAsset,u64)->u128,0x1::fungible_asset::FungibleAsset,0x1::fungible_asset::FungibleAsset`
- `create_pool_atomic(vector<u8>,0x1::fungible_asset::FungibleAsset,0x1::fungible_asset::FungibleAsset,address)->u128`
- `extract_fees_for_claim(vector<u8>,u64,u64)->0x1::fungible_asset::FungibleAsset,0x1::fungible_asset::FungibleAsset`
- `remove_liquidity_internal(vector<u8>,u128,u64,u64)->0x1::fungible_asset::FungibleAsset,0x1::fungible_asset::FungibleAsset`

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

- [view] `handle(address)->vector<u8>`
- [view] `pool_addr(address)->address`
- [view] `apt_balance(address)->u64`
- [view] `current_owner(address)->address`
- [entry] `deposit_apt(&signer,address,u64)`
- [entry] `execute_settle(&signer,address)`
- [view] `pending_settle_at_secs(address)->u64`
- [entry] `request_settle(&signer,address)`
- [view] `settle_executable_at_secs(address)->u64`
- [view] `token_metadata(address)->address`

**Friend fns** (2):

- `burn_via_vault(address,0x1::fungible_asset::FungibleAsset)`
- `deploy(&signer,vector<u8>,address,address,address,0x1::fungible_asset::BurnRef)->address`

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

- [view] `chunk_size(address)->u64`
- [view] `chunk_size_max()->u64`
- [view] `creator_pid_of(address)->address`
- [entry] `deploy_chunk(&signer,address,vector<u8>)`
- [entry] `deploy_node(&signer,address,vector<address>)`
- [view] `depth_of(address)->u8`
- [entry] `finalize(&signer,address,address,u8)`
- [view] `is_sealed(address)->bool`
- [view] `master_exists(address)->bool`
- [view] `max_total_size()->u64`
- [view] `mime_gif()->u8`
- [view] `mime_jpeg()->u8`
- [view] `mime_of(address)->u8`
- [view] `mime_png()->u8`
- [view] `mime_svg()->u8`
- [view] `mime_webp()->u8`
- [view] `read_chunk(address)->vector<u8>`
- [view] `read_node(address)->vector<address>`
- [view] `root_of(address)->address`
- [entry] `start_upload(&signer,u8,u64,address)`
- [view] `total_size_of(address)->u64`

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

## Module `reaction_emission` (2195 bytes)

`sha3_256: f6c103a82678c2b08d3d4988e19f0464d11148e5a608d901920c25154bab79f0`

### ABI surface

**Structs** (3):

- `ReactionEmitted` `[drop+store]` {reserve_addr:address, recipient:address, post_id:vector<u8>, press_order:u64, emission_amount:u64}
- `ReactionReserve` `[key]` {token_metadata_addr:address, spec_version:u32, extend_ref:0x1::object::ExtendRef, total_distributed:u64, topup_count:u64}
- `ReserveToppedUp` `[drop+store]` {reserve_addr:address, depositor:address, amount:u64, new_balance:u64}

**Public fns** (5):

- [view] `compute_emission(u64,u64)->u64`
- [view] `reserve_balance(address,0x1::object::Object<0x1::fungible_asset::Metadata>)->u64`
- [entry] `topup_reserve(&signer,address,0x1::object::Object<0x1::fungible_asset::Metadata>,u64)`
- [view] `total_distributed(address)->u64`
- [view] `total_post_emission(u64)->u64`

**Friend fns** (2):

- `deploy(&signer,vector<u8>,address,0x1::fungible_asset::FungibleAsset)->address`
- `emit_to_presser(address,address,vector<u8>,u64,u64)->u64`

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

## Module `lp_emission` (1929 bytes)

`sha3_256: 015edb5016286d4b96621f7b971867f7560b63636abc370ceeab2c3d39026745`

### ABI surface

**Structs** (4):

- `LpPulledForClaim` `[drop+store]` {reserve_addr:address, amount:u64, new_balance:u64}
- `LpReserve` `[key]` {token_metadata_addr:address, spec_version:u32, extend_ref:0x1::object::ExtendRef, total_distributed:u64, deployed_at_secs:u64}
- `LpReserveDeployed` `[drop+store]` {reserve_addr:address, token_metadata_addr:address, initial_amount:u64, timestamp_secs:u64}
- `LpReserveToppedUp` `[drop+store]` {reserve_addr:address, depositor:address, amount:u64, new_balance:u64}

**Public fns** (5):

- [view] `token_metadata_addr(address)->address`
- [view] `reserve_balance(address,0x1::object::Object<0x1::fungible_asset::Metadata>)->u64`
- [entry] `topup_reserve(&signer,address,0x1::object::Object<0x1::fungible_asset::Metadata>,u64)`
- [view] `total_distributed(address)->u64`
- [view] `deployed_at_secs(address)->u64`

**Friend fns** (2):

- `deploy(&signer,vector<u8>,address,0x1::fungible_asset::FungibleAsset)->address`
- `pull_for_claim(address,0x1::object::Object<0x1::fungible_asset::Metadata>,u64)->0x1::fungible_asset::FungibleAsset`

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

- [view] `acc_scale()->u128`
- [entry] `add_liquidity(&signer,vector<u8>,u64,u64,u64)`
- [entry] `add_liquidity_with_lock(&signer,vector<u8>,u64,u64,u64,u64)`
- [entry] `claim(&signer,address)`
- [view] `default_rate_per_sec()->u64`
- [view] `has_position(address)->bool`
- [view] `pool_acc_per_share(address)->u128`
- [view] `pool_rate_per_sec(address)->u64`
- [view] `position_fee_debt(0x1::object::Object<0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::lp_staking::Position>)->u128,u128`
- [view] `position_owner(address)->address`
- [view] `position_pending_all(address)->u64,u64,u64`
- [view] `position_pending_fees(0x1::object::Object<0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::lp_staking::Position>)->u64,u64`
- [view] `position_pool(address)->address`
- [view] `position_pool_addr(0x1::object::Object<0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::lp_staking::Position>)->address`
- [view] `position_recipient_pid(address)->address`
- [view] `position_shares(address)->u128`
- [view] `position_shares_obj(0x1::object::Object<0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::lp_staking::Position>)->u128`
- [view] `position_unlock_at(address)->u64`
- [entry] `remove_liquidity(&signer,address,u64,u64)`
-  `staking_pool_address_of_handle(vector<u8>)->address`
-  `staking_pool_exists(vector<u8>)->bool`
- [view] `unlock_forever_marker()->u64`

**Friend fns** (1):

- `create_pool_and_lock(vector<u8>,address,address,address,&signer,u128)->address`

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

## Module `factory` (5721 bytes)

`sha3_256: b477bdfe76de501d905ec24329b7d4fd17ce4e3fe8a616617bb7ddca95cdddca`

### ABI surface

**Structs** (6):

- `FactoryInitialized` `[drop+store]` {factory_addr:address, deployer:address}
- `FactoryRegistry` `[key]` {records:0x1::smart_table::SmartTable<0x1::string::String, 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::factory::TokenRecord>, metadata_index:0x1::smart_table::SmartTable<address, 0x1::string::String>, owner_index:0x1::smart_table::SmartTable<address, 0x1::string::String>}
- `FactoryState` `[key]` {spawn_count:u64, paused:bool, admin:address}
- `TokenMetadataMutRef` `[key]` {mutate_ref:0x1::fungible_asset::MutateMetadataRef}
- `TokenRecord` `[copy+drop+store]` {handle:0x1::string::String, token_metadata:address, owner_addr:address, apt_vault:address, reaction_reserve:address, lp_reserve:address, lp_staking_pool:address, amm_pool:address, spec_version:u32, spawned_at_secs:u64}
- `TokenSpawned` `[drop+store]` {handle:0x1::string::String, token_metadata:address, owner_addr:address, amm_pool:address, lp_staking_pool:address, apt_vault:address, lp_reserve:address, reaction_reserve:address, spec_version:u32, timestamp_secs:u64}

**Public fns** (21):

- [view] `admin()->address`
- [view] `derive_token_metadata_addr(vector<u8>)->address`
-  `emit_press_to_presser(&signer,address,vector<u8>,u64,u64)->u64`
- [view] `get_token_record(vector<u8>)->0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::factory::TokenRecord`
- [view] `handle_of_owner(address)->0x1::string::String`
- [view] `handle_of_token(address)->0x1::string::String`
- [view] `handle_registered(vector<u8>)->bool`
- [view] `is_factory_token(address)->bool`
- [view] `is_paused()->bool`
- [view] `lp_staking_pool_of_owner(address)->address`
- [view] `owner_has_token(address)->bool`
- [view] `pool_seed_apt_amount()->u64`
- [view] `pool_seed_token_amount()->u64`
- [entry] `rotate_admin(&signer,address)`
- [entry] `set_paused(&signer,bool)`
- [view] `spawn_count()->u64`
- [view] `token_metadata_of_owner(address)->address`
- [entry] `update_token_icon(&signer,vector<u8>,0x1::string::String)`
- [entry] `update_token_project_uri(&signer,vector<u8>,0x1::string::String)`
- [view] `vault_addr_of_handle(vector<u8>)->address`
- [view] `vault_addr_of_pid(address)->address`

**Friend fns** (1):

- `create_token_atomic(vector<u8>,address,&signer,0x1::fungible_asset::FungibleAsset,0x1::string::String,0x1::string::String,0x1::string::String,0x1::string::String)`

### MASM (disassembled bytecode)

```move
// Bytecode version v9
module 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::factory
use 0x1::smart_table
use 0x1::string
use 0x1::fungible_asset
use 0x1::signer
use 0x1::event
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::governance
use 0x1::object
use 0x1::option
use 0x1::primary_fungible_store
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::lp_emission
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::reaction_emission
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::amm
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::apt_vault
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::lp_staking
use 0x1::timestamp
use 0x1::vector
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::profile
struct FactoryInitialized has drop + store
  factory_addr: address
  deployer: address

struct FactoryRegistry has key
  records: smart_table::SmartTable<string::String, TokenRecord>
  metadata_index: smart_table::SmartTable<address, string::String>
  owner_index: smart_table::SmartTable<address, string::String>

struct FactoryState has key
  spawn_count: u64
  paused: bool
  admin: address

struct TokenMetadataMutRef has key
  mutate_ref: fungible_asset::MutateMetadataRef

struct TokenRecord has copy + drop + store
  handle: string::String
  token_metadata: address
  owner_addr: address
  apt_vault: address
  reaction_reserve: address
  lp_reserve: address
  lp_staking_pool: address
  amm_pool: address
  spec_version: u32
  spawned_at_secs: u64

struct TokenSpawned has drop + store
  handle: string::String
  token_metadata: address
  owner_addr: address
  amm_pool: address
  lp_staking_pool: address
  apt_vault: address
  lp_reserve: address
  reaction_reserve: address
  spec_version: u32
  timestamp_secs: u64

// Function definition at index 0
fun init_module(l0: &signer)
    copy_loc l0
    call signer::address_of
    copy_loc l0
    ld_u64 0
    ld_false
    // @5
    ld_const<address> 799008279626092026266606374476533705615973526478392622784892721766771113
    pack FactoryState
    move_to FactoryState
    move_loc l0
    call smart_table::new<string::String, TokenRecord>
    // @10
    call smart_table::new<address, string::String>
    call smart_table::new<address, string::String>
    pack FactoryRegistry
    move_to FactoryRegistry
    ld_const<address> 799008279626092026266606374476533705615973526478392622784892721766771113
    // @15
    pack FactoryInitialized
    call event::emit<FactoryInitialized>
    ret

// Function definition at index 1
#[persistent] public fun admin(): address acquires FactoryState
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global FactoryState
    borrow_field FactoryState, admin
    read_ref
    ret

// Function definition at index 2
friend fun create_token_atomic(l0: vector<u8>, l1: address, l2: &signer, l3: fungible_asset::FungibleAsset, l4: string::String, l5: string::String, l6: string::String, l7: string::String) acquires FactoryRegistry, FactoryState
    local l8: string::String
    local l9: signer
    local l10: vector<u8>
    local l11: object::ConstructorRef
    local l12: address
    local l13: fungible_asset::MintRef
    local l14: fungible_asset::BurnRef
    local l15: fungible_asset::MutateMetadataRef
    local l16: signer
    local l17: object::TransferRef
    local l18: fungible_asset::FungibleAsset
    local l19: fungible_asset::FungibleAsset
    local l20: fungible_asset::FungibleAsset
    local l21: address
    local l22: address
    local l23: address
    local l24: address
    local l25: u128
    local l26: address
    local l27: u64
    local l28: TokenRecord
    local l29: &mut FactoryRegistry
    local l30: &mut FactoryState
    borrow_loc l0
    call validate_handle
    borrow_loc l4
    borrow_loc l5
    borrow_loc l6
    // @5
    borrow_loc l7
    call validate_token_metadata_strings
    copy_loc l0
    call string::utf8
    st_loc l8
    // @10
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global FactoryRegistry
    borrow_field FactoryRegistry, records
    copy_loc l8
    call smart_table::contains<string::String, TokenRecord>
    // @15
    br_true l0
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global FactoryState
    borrow_field FactoryState, paused
    read_ref
    // @20
    br_true l1
    borrow_loc l3
    call fungible_asset::amount
    ld_u64 500000000
    eq
    // @25
    br_false l2
    call governance::derive_pkg_signer
    st_loc l9
    borrow_loc l0
    call make_token_seed
    // @30
    st_loc l10
    borrow_loc l9
    move_loc l10
    call object::create_named_object
    st_loc l11
    // @35
    borrow_loc l11
    call object::address_from_constructor_ref
    st_loc l12
    borrow_loc l11
    ld_u128 100000000000000000
    // @40
    call option::some<u128>
    move_loc l4
    move_loc l5
    ld_u8 8
    move_loc l6
    // @45
    move_loc l7
    call primary_fungible_store::create_primary_store_enabled_fungible_asset
    borrow_loc l11
    call fungible_asset::generate_mint_ref
    st_loc l13
    // @50
    borrow_loc l11
    call fungible_asset::generate_burn_ref
    st_loc l14
    borrow_loc l11
    call fungible_asset::generate_mutate_metadata_ref
    // @55
    st_loc l15
    borrow_loc l11
    call object::generate_signer
    st_loc l16
    borrow_loc l16
    // @60
    move_loc l15
    pack TokenMetadataMutRef
    move_to TokenMetadataMutRef
    borrow_loc l11
    call object::generate_transfer_ref
    // @65
    st_loc l17
    borrow_loc l17
    call object::disable_ungated_transfer
    borrow_loc l11
    call object::object_from_constructor_ref<fungible_asset::Metadata>
    // @70
    pop
    borrow_loc l13
    ld_u64 5000000000000000
    call fungible_asset::mint
    st_loc l18
    // @75
    borrow_loc l13
    ld_u64 5000000000000000
    call fungible_asset::mint
    st_loc l19
    borrow_loc l13
    // @80
    ld_u64 90000000000000000
    call fungible_asset::mint
    st_loc l20
    borrow_loc l9
    copy_loc l0
    // @85
    copy_loc l12
    move_loc l20
    call lp_emission::deploy
    st_loc l21
    borrow_loc l9
    // @90
    copy_loc l0
    copy_loc l12
    move_loc l19
    call reaction_emission::deploy
    st_loc l22
    // @95
    copy_loc l0
    call amm::pool_address_of_handle
    st_loc l23
    borrow_loc l9
    copy_loc l0
    // @100
    copy_loc l12
    copy_loc l23
    copy_loc l1
    move_loc l14
    call apt_vault::deploy
    // @105
    st_loc l24
    copy_loc l0
    move_loc l3
    move_loc l18
    copy_loc l1
    // @110
    call amm::create_pool_atomic
    st_loc l25
    copy_loc l0
    copy_loc l12
    copy_loc l21
    // @115
    copy_loc l1
    move_loc l2
    move_loc l25
    call lp_staking::create_pool_and_lock
    st_loc l26
    // @120
    call timestamp::now_seconds
    st_loc l27
    move_loc l8
    copy_loc l12
    copy_loc l1
    // @125
    copy_loc l24
    copy_loc l22
    copy_loc l21
    copy_loc l26
    copy_loc l23
    // @130
    ld_u32 3
    copy_loc l27
    pack TokenRecord
    st_loc l28
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    // @135
    mut_borrow_global FactoryRegistry
    st_loc l29
    copy_loc l29
    mut_borrow_field FactoryRegistry, records
    copy_loc l0
    // @140
    call string::utf8
    move_loc l28
    call smart_table::add<string::String, TokenRecord>
    copy_loc l29
    mut_borrow_field FactoryRegistry, metadata_index
    // @145
    copy_loc l12
    copy_loc l0
    call string::utf8
    call smart_table::add<address, string::String>
    move_loc l29
    // @150
    mut_borrow_field FactoryRegistry, owner_index
    copy_loc l1
    copy_loc l0
    call string::utf8
    call smart_table::add<address, string::String>
    // @155
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    mut_borrow_global FactoryState
    st_loc l30
    copy_loc l30
    borrow_field FactoryState, spawn_count
    // @160
    read_ref
    ld_u64 1
    add
    move_loc l30
    mut_borrow_field FactoryState, spawn_count
    // @165
    write_ref
    move_loc l0
    call string::utf8
    move_loc l12
    move_loc l1
    // @170
    move_loc l23
    move_loc l26
    move_loc l24
    move_loc l21
    move_loc l22
    // @175
    ld_u32 3
    move_loc l27
    pack TokenSpawned
    call event::emit<TokenSpawned>
    ret
    // @180
l2: move_loc l2
    pop
    ld_u64 12
    abort
l1: move_loc l2
    // @185
    pop
    ld_u64 8
    abort
l0: move_loc l2
    pop
    // @190
    ld_u64 3
    abort

// Function definition at index 3
#[persistent] public fun derive_token_metadata_addr(l0: vector<u8>): address
    local l1: vector<u8>
    local l2: address
    borrow_loc l0
    call make_token_seed
    st_loc l1
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    st_loc l2
    // @5
    borrow_loc l2
    move_loc l1
    call object::create_object_address
    ret

// Function definition at index 4
#[persistent] public fun emit_press_to_presser(l0: &signer, l1: address, l2: vector<u8>, l3: u64, l4: u64): u64 acquires FactoryRegistry
    local l5: address
    local l6: &FactoryRegistry
    local l7: string::String
    move_loc l0
    call signer::address_of
    st_loc l5
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global FactoryRegistry
    // @5
    st_loc l6
    copy_loc l6
    borrow_field FactoryRegistry, owner_index
    copy_loc l5
    call smart_table::contains<address, string::String>
    // @10
    br_false l0
    copy_loc l6
    borrow_field FactoryRegistry, owner_index
    move_loc l5
    call smart_table::borrow<address, string::String>
    // @15
    read_ref
    st_loc l7
    move_loc l6
    borrow_field FactoryRegistry, records
    move_loc l7
    // @20
    call smart_table::borrow<string::String, TokenRecord>
    borrow_field TokenRecord, reaction_reserve
    read_ref
    move_loc l1
    move_loc l2
    // @25
    move_loc l3
    move_loc l4
    call reaction_emission::emit_to_presser
    ret
l0: move_loc l6
    // @30
    pop
    ld_u64 10
    abort

// Function definition at index 5
#[persistent] public fun get_token_record(l0: vector<u8>): TokenRecord acquires FactoryRegistry
    local l1: &FactoryRegistry
    local l2: string::String
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global FactoryRegistry
    st_loc l1
    move_loc l0
    call string::utf8
    // @5
    st_loc l2
    copy_loc l1
    borrow_field FactoryRegistry, records
    copy_loc l2
    call smart_table::contains<string::String, TokenRecord>
    // @10
    br_false l0
    move_loc l1
    borrow_field FactoryRegistry, records
    move_loc l2
    call smart_table::borrow<string::String, TokenRecord>
    // @15
    read_ref
    ret
l0: move_loc l1
    pop
    ld_u64 19
    // @20
    abort

// Function definition at index 6
#[persistent] public fun handle_of_owner(l0: address): string::String acquires FactoryRegistry
    local l1: &FactoryRegistry
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global FactoryRegistry
    st_loc l1
    copy_loc l1
    borrow_field FactoryRegistry, owner_index
    // @5
    copy_loc l0
    call smart_table::contains<address, string::String>
    br_false l0
    move_loc l1
    borrow_field FactoryRegistry, owner_index
    // @10
    move_loc l0
    call smart_table::borrow<address, string::String>
    read_ref
    ret
l0: move_loc l1
    // @15
    pop
    ld_u64 19
    abort

// Function definition at index 7
#[persistent] public fun handle_of_token(l0: address): string::String acquires FactoryRegistry
    local l1: &FactoryRegistry
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global FactoryRegistry
    st_loc l1
    copy_loc l1
    borrow_field FactoryRegistry, metadata_index
    // @5
    copy_loc l0
    call smart_table::contains<address, string::String>
    br_false l0
    move_loc l1
    borrow_field FactoryRegistry, metadata_index
    // @10
    move_loc l0
    call smart_table::borrow<address, string::String>
    read_ref
    ret
l0: move_loc l1
    // @15
    pop
    ld_u64 19
    abort

// Function definition at index 8
#[persistent] public fun handle_registered(l0: vector<u8>): bool acquires FactoryRegistry
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global FactoryRegistry
    borrow_field FactoryRegistry, records
    move_loc l0
    call string::utf8
    // @5
    call smart_table::contains<string::String, TokenRecord>
    ret

// Function definition at index 9
#[persistent] public fun is_factory_token(l0: address): bool acquires FactoryRegistry
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global FactoryRegistry
    borrow_field FactoryRegistry, metadata_index
    move_loc l0
    call smart_table::contains<address, string::String>
    // @5
    ret

// Function definition at index 10
#[persistent] public fun is_paused(): bool acquires FactoryState
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global FactoryState
    borrow_field FactoryState, paused
    read_ref
    ret

// Function definition at index 11
#[persistent] public fun lp_staking_pool_of_owner(l0: address): address acquires FactoryRegistry
    local l1: &FactoryRegistry
    local l2: string::String
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global FactoryRegistry
    st_loc l1
    copy_loc l1
    borrow_field FactoryRegistry, owner_index
    // @5
    copy_loc l0
    call smart_table::contains<address, string::String>
    br_false l0
    copy_loc l1
    borrow_field FactoryRegistry, owner_index
    // @10
    move_loc l0
    call smart_table::borrow<address, string::String>
    read_ref
    st_loc l2
    move_loc l1
    // @15
    borrow_field FactoryRegistry, records
    move_loc l2
    call smart_table::borrow<string::String, TokenRecord>
    borrow_field TokenRecord, lp_staking_pool
    read_ref
    // @20
    ret
l0: move_loc l1
    pop
    ld_u64 19
    abort

// Function definition at index 12
fun make_token_seed(l0: &vector<u8>): vector<u8>
    local l1: vector<u8>
    vec_pack <u8>, 0
    st_loc l1
    mut_borrow_loc l1
    ld_const<vector<u8>> [116, 111, 107, 101, 110, 58, 58]
    call vector::append<u8>
    // @5
    mut_borrow_loc l1
    move_loc l0
    read_ref
    call vector::append<u8>
    move_loc l1
    // @10
    ret

// Function definition at index 13
#[persistent] public fun owner_has_token(l0: address): bool acquires FactoryRegistry
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global FactoryRegistry
    borrow_field FactoryRegistry, owner_index
    move_loc l0
    call smart_table::contains<address, string::String>
    // @5
    ret

// Function definition at index 14
#[persistent] public fun pool_seed_apt_amount(): u64
    ld_u64 500000000
    ret

// Function definition at index 15
#[persistent] public fun pool_seed_token_amount(): u64
    ld_u64 5000000000000000
    ret

// Function definition at index 16
#[persistent] entry public fun rotate_admin(l0: &signer, l1: address) acquires FactoryState
    local l2: &mut FactoryState
    local l3: &mut address
    copy_loc l1
    ld_const<address> 0
    neq
    br_false l0
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    // @5
    mut_borrow_global FactoryState
    st_loc l2
    move_loc l0
    call signer::address_of
    copy_loc l2
    // @10
    borrow_field FactoryState, admin
    read_ref
    eq
    br_false l1
    move_loc l2
    // @15
    mut_borrow_field FactoryState, admin
    st_loc l3
    move_loc l1
    move_loc l3
    write_ref
    // @20
    ret
l1: move_loc l2
    pop
    ld_u64 13
    abort
    // @25
l0: move_loc l0
    pop
    ld_u64 14
    abort

// Function definition at index 17
#[persistent] entry public fun set_paused(l0: &signer, l1: bool) acquires FactoryState
    local l2: &mut FactoryState
    local l3: &mut bool
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    mut_borrow_global FactoryState
    st_loc l2
    move_loc l0
    call signer::address_of
    // @5
    copy_loc l2
    borrow_field FactoryState, admin
    read_ref
    eq
    br_false l0
    // @10
    move_loc l2
    mut_borrow_field FactoryState, paused
    st_loc l3
    move_loc l1
    move_loc l3
    // @15
    write_ref
    ret
l0: move_loc l2
    pop
    ld_u64 13
    // @20
    abort

// Function definition at index 18
#[persistent] public fun spawn_count(): u64 acquires FactoryState
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global FactoryState
    borrow_field FactoryState, spawn_count
    read_ref
    ret

// Function definition at index 19
#[persistent] public fun token_metadata_of_owner(l0: address): address acquires FactoryRegistry
    local l1: &FactoryRegistry
    local l2: string::String
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global FactoryRegistry
    st_loc l1
    copy_loc l1
    borrow_field FactoryRegistry, owner_index
    // @5
    copy_loc l0
    call smart_table::contains<address, string::String>
    br_false l0
    copy_loc l1
    borrow_field FactoryRegistry, owner_index
    // @10
    move_loc l0
    call smart_table::borrow<address, string::String>
    read_ref
    st_loc l2
    move_loc l1
    // @15
    borrow_field FactoryRegistry, records
    move_loc l2
    call smart_table::borrow<string::String, TokenRecord>
    borrow_field TokenRecord, token_metadata
    read_ref
    // @20
    ret
l0: move_loc l1
    pop
    ld_u64 19
    abort

// Function definition at index 20
#[persistent] entry public fun update_token_icon(l0: &signer, l1: vector<u8>, l2: string::String) acquires FactoryRegistry, TokenMetadataMutRef
    local l3: &signer
    local l4: string::String
    local l5: &FactoryRegistry
    local l6: &TokenRecord
    local l7: address
    local l8: address
    borrow_loc l2
    call string::length
    ld_u64 512
    le
    br_false l0
    // @5
    move_loc l0
    st_loc l3
    move_loc l1
    call string::utf8
    st_loc l4
    // @10
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global FactoryRegistry
    st_loc l5
    copy_loc l5
    borrow_field FactoryRegistry, records
    // @15
    copy_loc l4
    call smart_table::contains<string::String, TokenRecord>
    br_false l1
    move_loc l5
    borrow_field FactoryRegistry, records
    // @20
    move_loc l4
    call smart_table::borrow<string::String, TokenRecord>
    st_loc l6
    copy_loc l6
    borrow_field TokenRecord, owner_addr
    // @25
    read_ref
    move_loc l6
    borrow_field TokenRecord, token_metadata
    read_ref
    st_loc l7
    // @30
    call object::address_to_object<object::ObjectCore>
    call object::owner<object::ObjectCore>
    st_loc l8
    move_loc l3
    call signer::address_of
    // @35
    move_loc l8
    eq
    br_false l2
    move_loc l7
    borrow_global TokenMetadataMutRef
    // @40
    borrow_field TokenMetadataMutRef, mutate_ref
    call option::none<string::String>
    call option::none<string::String>
    call option::none<u8>
    move_loc l2
    // @45
    call option::some<string::String>
    call option::none<string::String>
    call fungible_asset::mutate_metadata
    ret
l2: ld_u64 18
    // @50
    abort
l1: move_loc l3
    pop
    move_loc l5
    pop
    // @55
    ld_u64 19
    abort
l0: move_loc l0
    pop
    ld_u64 17
    // @60
    abort

// Function definition at index 21
#[persistent] entry public fun update_token_project_uri(l0: &signer, l1: vector<u8>, l2: string::String) acquires FactoryRegistry, TokenMetadataMutRef
    local l3: &signer
    local l4: string::String
    local l5: &FactoryRegistry
    local l6: &TokenRecord
    local l7: address
    local l8: address
    borrow_loc l2
    call string::length
    ld_u64 512
    le
    br_false l0
    // @5
    move_loc l0
    st_loc l3
    move_loc l1
    call string::utf8
    st_loc l4
    // @10
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global FactoryRegistry
    st_loc l5
    copy_loc l5
    borrow_field FactoryRegistry, records
    // @15
    copy_loc l4
    call smart_table::contains<string::String, TokenRecord>
    br_false l1
    move_loc l5
    borrow_field FactoryRegistry, records
    // @20
    move_loc l4
    call smart_table::borrow<string::String, TokenRecord>
    st_loc l6
    copy_loc l6
    borrow_field TokenRecord, owner_addr
    // @25
    read_ref
    move_loc l6
    borrow_field TokenRecord, token_metadata
    read_ref
    st_loc l7
    // @30
    call object::address_to_object<object::ObjectCore>
    call object::owner<object::ObjectCore>
    st_loc l8
    move_loc l3
    call signer::address_of
    // @35
    move_loc l8
    eq
    br_false l2
    move_loc l7
    borrow_global TokenMetadataMutRef
    // @40
    borrow_field TokenMetadataMutRef, mutate_ref
    call option::none<string::String>
    call option::none<string::String>
    call option::none<u8>
    call option::none<string::String>
    // @45
    move_loc l2
    call option::some<string::String>
    call fungible_asset::mutate_metadata
    ret
l2: ld_u64 18
    // @50
    abort
l1: move_loc l3
    pop
    move_loc l5
    pop
    // @55
    ld_u64 19
    abort
l0: move_loc l0
    pop
    ld_u64 20
    // @60
    abort

// Function definition at index 22
fun validate_handle(l0: &vector<u8>)
    local l1: u64
    local l2: u64
    local l3: u8
    local l4: bool
    local l5: bool
    local l6: bool
    local l7: bool
    local l8: bool
    copy_loc l0
    vec_len <u8>
    st_loc l1
    copy_loc l1
    ld_u64 1
    // @5
    ge
    br_false l0
    copy_loc l1
    ld_u64 64
    le
    // @10
    br_false l1
    ld_u64 0
    st_loc l2
l8: copy_loc l2
    copy_loc l1
    // @15
    lt
    br_false l2
    copy_loc l0
    copy_loc l2
    vec_borrow <u8>
    // @20
    read_ref
    st_loc l3
    copy_loc l3
    ld_u8 97
    ge
    // @25
    br_false l3
    copy_loc l3
    ld_u8 122
    le
    st_loc l4
    // @30
l12: copy_loc l3
    ld_u8 48
    ge
    br_false l4
    copy_loc l3
    // @35
    ld_u8 57
    le
    st_loc l5
l11: move_loc l3
    ld_u8 45
    // @40
    eq
    st_loc l6
    move_loc l4
    br_false l5
    ld_true
    // @45
    st_loc l7
l10: move_loc l7
    br_false l6
    ld_true
    st_loc l8
    // @50
l9: move_loc l8
    br_false l7
    move_loc l2
    ld_u64 1
    add
    // @55
    st_loc l2
    branch l8
l7: move_loc l0
    pop
    ld_u64 6
    // @60
    abort
l6: move_loc l6
    st_loc l8
    branch l9
l5: move_loc l5
    // @65
    st_loc l7
    branch l10
l4: ld_false
    st_loc l5
    branch l11
    // @70
l3: ld_false
    st_loc l4
    branch l12
l2: move_loc l0
    pop
    // @75
    ret
l1: move_loc l0
    pop
    ld_u64 5
    abort
    // @80
l0: move_loc l0
    pop
    ld_u64 4
    abort

// Function definition at index 23
fun validate_token_metadata_strings(l0: &string::String, l1: &string::String, l2: &string::String, l3: &string::String)
    move_loc l0
    call string::length
    ld_u64 32
    le
    br_false l0
    // @5
    move_loc l1
    call string::length
    ld_u64 32
    le
    br_false l1
    // @10
    move_loc l2
    call string::length
    ld_u64 512
    le
    br_false l2
    // @15
    move_loc l3
    call string::length
    ld_u64 512
    le
    br_false l3
    // @20
    ret
l3: ld_u64 20
    abort
l2: move_loc l3
    pop
    // @25
    ld_u64 17
    abort
l1: move_loc l2
    pop
    move_loc l3
    // @30
    pop
    ld_u64 16
    abort
l0: move_loc l1
    pop
    // @35
    move_loc l2
    pop
    move_loc l3
    pop
    ld_u64 15
    // @40
    abort

// Function definition at index 24
#[persistent] public fun vault_addr_of_handle(l0: vector<u8>): address acquires FactoryRegistry
    local l1: &FactoryRegistry
    local l2: string::String
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global FactoryRegistry
    st_loc l1
    move_loc l0
    call string::utf8
    // @5
    st_loc l2
    copy_loc l1
    borrow_field FactoryRegistry, records
    copy_loc l2
    call smart_table::contains<string::String, TokenRecord>
    // @10
    br_false l0
    move_loc l1
    borrow_field FactoryRegistry, records
    move_loc l2
    call smart_table::borrow<string::String, TokenRecord>
    // @15
    borrow_field TokenRecord, apt_vault
    read_ref
    ret
l0: move_loc l1
    pop
    // @20
    ld_u64 19
    abort

// Function definition at index 25
#[persistent] public fun vault_addr_of_pid(l0: address): address acquires FactoryRegistry
    local l1: &FactoryRegistry
    local l2: string::String
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global FactoryRegistry
    st_loc l1
    copy_loc l1
    borrow_field FactoryRegistry, owner_index
    // @5
    copy_loc l0
    call smart_table::contains<address, string::String>
    br_false l0
    copy_loc l1
    borrow_field FactoryRegistry, owner_index
    // @10
    move_loc l0
    call smart_table::borrow<address, string::String>
    read_ref
    st_loc l2
    move_loc l1
    // @15
    borrow_field FactoryRegistry, records
    move_loc l2
    call smart_table::borrow<string::String, TokenRecord>
    borrow_field TokenRecord, apt_vault
    read_ref
    // @20
    ret
l0: move_loc l1
    pop
    ld_u64 10
    abort
```

---

## Module `reference_gate` (1363 bytes)

`sha3_256: cd27eaf0bb619c6931ec111574ee42ec5311d8b80d016b71c0db0877162c6c67`

### ABI surface

**Structs** (1):

- `ReferenceGate` `[copy+drop+store]` {target_pid:address, min_token_balance:u64, max_token_balance:u64, min_lp_stake:u64}

**Public fns** (7):

-  `new(address,u64,u64,u64)->0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::reference_gate::ReferenceGate`
-  `check(&0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::reference_gate::ReferenceGate,address,bool,bool,address)->bool`
-  `is_open_for(&0x1::option::Option<0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::reference_gate::ReferenceGate>,address,bool,bool,address)->bool`
-  `max_token_balance(&0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::reference_gate::ReferenceGate)->u64`
-  `min_lp_stake(&0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::reference_gate::ReferenceGate)->u64`
-  `min_token_balance(&0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::reference_gate::ReferenceGate)->u64`
-  `target_pid(&0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::reference_gate::ReferenceGate)->address`

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

## Module `handle_fee_vault` (2115 bytes)

`sha3_256: c6caf6b4f5ad59d932dee42a4000d3b94e3a7c5b6fbdb422c42623faecf15430`

### ABI surface

**Structs** (2):

- `HandleFeeVault` `[key]` {deployer_beneficiary:address, extend_ref:0x1::object::ExtendRef}
- `Settled` `[drop+store]` {total_apt:u64, to_deployer:u64, desnet_burned:u64}

**Public fns** (10):

- [view] `apt_balance()->u64`
-  `vault_addr()->address`
- [entry] `deposit_apt(&signer,u64)`
- [view] `deployer_beneficiary()->address`
- [entry] `migrate_legacy_fees(&signer)`
- [entry] `settle(&signer)`
- [view] `settle_threshold()->u64`
- [view] `split_burn_bps()->u64`
- [view] `split_deployer_bps()->u64`
-  `vault_exists()->bool`

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

## Module `profile` (6403 bytes)

`sha3_256: b61420ac094b99ff7b5dbfba0c63d773f88a41de4bbf04225dcd1977e6332d60`

### ABI surface

**Structs** (14):

- `ControllerRotated` `[drop+store]` {pid_addr:address, old_controller:address, new_controller:address, timestamp_secs:u64}
- `HandleRegistered` `[drop+store]` {handle:0x1::string::String, wallet:address, pid_addr:address, fee_paid_apt:u64, timestamp_secs:u64}
- `HandleRegistry` `[key]` {handle_to_wallet:0x1::smart_table::SmartTable<0x1::string::String, address>}
- `PidTokenWithdrawn` `[drop+store]` {pid_addr:address, token_metadata:address, amount:u64, recipient:address, timestamp_secs:u64}
- `Profile` `[key]` {handle:0x1::string::String, controller:address, signers_:0x1::smart_table::SmartTable<vector<u8>, 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::profile::SignerEntry>, metadata_uri:0x1::string::String, avatar_blob_id:vector<u8>, banner_blob_id:vector<u8>, bio:0x1::string::String, sync_gate:0x1::option::Option<0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::reference_gate::ReferenceGate>, extend_ref:0x1::object::ExtendRef, registered_at_secs:u64}
- `ProfileMetadataUpdated` `[drop+store]` {pid_addr:address, timestamp_secs:u64}
- `ProtocolInitialized` `[drop+store]` {protocol_addr:address, timestamp_secs:u64}
- `ProtocolState` `[key]` {fee_receiver:address, admin:address}
- `SignerAdded` `[drop+store]` {pid_addr:address, pubkey:vector<u8>, app_label:0x1::string::String, timestamp_secs:u64}
- `SignerEntry` `[copy+drop+store]` {app_label:0x1::string::String, added_at_secs:u64, last_used_secs:u64}
- `SignerRevoked` `[drop+store]` {pid_addr:address, pubkey:vector<u8>, timestamp_secs:u64}
- `SyncGateAttached` `[drop+store]` {pid_addr:address, timestamp_secs:u64}
- `SyncGateCleared` `[drop+store]` {pid_addr:address, timestamp_secs:u64}
- `TransferVault` `[key]` {transfer_ref:0x1::object::TransferRef}

**Public fns** (20):

- [entry] `update_metadata(&signer,address,vector<u8>,vector<u8>,vector<u8>,vector<u8>)`
- [entry] `rotate_admin(&signer,address)`
- [entry] `add_signer(&signer,address,vector<u8>,vector<u8>)`
- [entry] `attach_sync_gate(&signer,address,address,u64,u64,u64)`
- [entry] `clear_sync_gate(&signer,address)`
- [view] `controller_of(address)->address`
- [view] `derive_pid_address(address)->address`
-  `handle_fee_apt(u64)->u64`
- [view] `handle_max_len()->u64`
- [view] `handle_of(address)->0x1::string::String`
- [view] `handle_of_wallet(address)->0x1::string::String`
- [view] `handle_to_wallet(vector<u8>)->address`
- [view] `has_signer(address,vector<u8>)->bool`
- [view] `is_registered(vector<u8>)->bool`
- [view] `profile_exists(address)->bool`
- [entry] `register_handle(&signer,vector<u8>,address,vector<u8>,vector<u8>,vector<u8>,vector<u8>,vector<u8>,vector<u8>)`
- [entry] `revoke_signer(&signer,address,vector<u8>)`
- [entry] `rotate_controller(&signer,address,address)`
- [entry] `update_fee_receiver(&signer,address)`
- [entry] `withdraw_pid_token(&signer,address,address,u64,address)`

**Friend fns** (3):

- `assert_pid_exists(address)`
- `derive_pid_signer(address)->signer`
- `get_sync_gate(address)->0x1::option::Option<0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::reference_gate::ReferenceGate>`

### MASM (disassembled bytecode)

```move
// Bytecode version v9
module 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::profile
use 0x1::string
use 0x1::smart_table
use 0x1::option
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::reference_gate
use 0x1::object
use 0x1::signer
use 0x1::timestamp
use 0x1::event
use 0x1::vector
use 0x1::bcs
use 0x1::fungible_asset
use 0x1::primary_fungible_store
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::handle_fee_vault
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::factory
use 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::governance
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::history
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::link
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::mint
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::giveaway
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::press
friend 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::pulse
struct ControllerRotated has drop + store
  pid_addr: address
  old_controller: address
  new_controller: address
  timestamp_secs: u64

struct HandleRegistered has drop + store
  handle: string::String
  wallet: address
  pid_addr: address
  fee_paid_apt: u64
  timestamp_secs: u64

struct HandleRegistry has key
  handle_to_wallet: smart_table::SmartTable<string::String, address>

struct PidTokenWithdrawn has drop + store
  pid_addr: address
  token_metadata: address
  amount: u64
  recipient: address
  timestamp_secs: u64

struct Profile has key
  handle: string::String
  controller: address
  signers_: smart_table::SmartTable<vector<u8>, SignerEntry>
  metadata_uri: string::String
  avatar_blob_id: vector<u8>
  banner_blob_id: vector<u8>
  bio: string::String
  sync_gate: option::Option<reference_gate::ReferenceGate>
  extend_ref: object::ExtendRef
  registered_at_secs: u64

struct ProfileMetadataUpdated has drop + store
  pid_addr: address
  timestamp_secs: u64

struct ProtocolInitialized has drop + store
  protocol_addr: address
  timestamp_secs: u64

struct ProtocolState has key
  fee_receiver: address
  admin: address

struct SignerAdded has drop + store
  pid_addr: address
  pubkey: vector<u8>
  app_label: string::String
  timestamp_secs: u64

struct SignerEntry has copy + drop + store
  app_label: string::String
  added_at_secs: u64
  last_used_secs: u64

struct SignerRevoked has drop + store
  pid_addr: address
  pubkey: vector<u8>
  timestamp_secs: u64

struct SyncGateAttached has drop + store
  pid_addr: address
  timestamp_secs: u64

struct SyncGateCleared has drop + store
  pid_addr: address
  timestamp_secs: u64

struct TransferVault has key
  transfer_ref: object::TransferRef

// Function definition at index 0
fun init_module(l0: &signer)
    local l1: address
    copy_loc l0
    call signer::address_of
    st_loc l1
    copy_loc l0
    copy_loc l1
    // @5
    ld_const<address> 799008279626092026266606374476533705615973526478392622784892721766771113
    pack ProtocolState
    move_to ProtocolState
    move_loc l0
    call smart_table::new<string::String, address>
    // @10
    pack HandleRegistry
    move_to HandleRegistry
    move_loc l1
    call timestamp::now_seconds
    pack ProtocolInitialized
    // @15
    call event::emit<ProtocolInitialized>
    ret

// Function definition at index 1
#[persistent] entry public fun update_metadata(l0: &signer, l1: address, l2: vector<u8>, l3: vector<u8>, l4: vector<u8>, l5: vector<u8>) acquires Profile
    local l6: &mut Profile
    local l7: &mut vector<u8>
    move_loc l0
    copy_loc l1
    call assert_controller
    borrow_loc l2
    vec_len <u8>
    // @5
    ld_u64 8192
    le
    br_false l0
    borrow_loc l3
    vec_len <u8>
    // @10
    ld_u64 8192
    le
    br_false l1
    borrow_loc l4
    vec_len <u8>
    // @15
    ld_u64 333
    le
    br_false l2
    copy_loc l1
    mut_borrow_global Profile
    // @20
    st_loc l6
    copy_loc l6
    mut_borrow_field Profile, avatar_blob_id
    st_loc l7
    move_loc l2
    // @25
    move_loc l7
    write_ref
    copy_loc l6
    mut_borrow_field Profile, banner_blob_id
    st_loc l7
    // @30
    move_loc l3
    move_loc l7
    write_ref
    move_loc l4
    call string::utf8
    // @35
    copy_loc l6
    mut_borrow_field Profile, bio
    write_ref
    move_loc l5
    call string::utf8
    // @40
    move_loc l6
    mut_borrow_field Profile, metadata_uri
    write_ref
    move_loc l1
    call timestamp::now_seconds
    // @45
    pack ProfileMetadataUpdated
    call event::emit<ProfileMetadataUpdated>
    ret
l2: ld_u64 13
    abort
    // @50
l1: ld_u64 12
    abort
l0: ld_u64 12
    abort

// Function definition at index 2
#[persistent] entry public fun rotate_admin(l0: &signer, l1: address) acquires ProtocolState
    local l2: &mut ProtocolState
    local l3: &mut address
    copy_loc l1
    ld_const<address> 0
    neq
    br_false l0
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    // @5
    mut_borrow_global ProtocolState
    st_loc l2
    move_loc l0
    call signer::address_of
    copy_loc l2
    // @10
    borrow_field ProtocolState, admin
    read_ref
    eq
    br_false l1
    move_loc l2
    // @15
    mut_borrow_field ProtocolState, admin
    st_loc l3
    move_loc l1
    move_loc l3
    write_ref
    // @20
    ret
l1: move_loc l2
    pop
    ld_u64 14
    abort
    // @25
l0: move_loc l0
    pop
    ld_u64 18
    abort

// Function definition at index 3
fun validate_handle(l0: &vector<u8>)
    local l1: u64
    local l2: u64
    local l3: u8
    local l4: bool
    local l5: bool
    local l6: bool
    copy_loc l0
    vec_len <u8>
    st_loc l1
    copy_loc l1
    ld_u64 1
    // @5
    ge
    br_false l0
    copy_loc l1
    ld_u64 64
    le
    // @10
    br_false l1
    ld_u64 0
    st_loc l2
l7: copy_loc l2
    copy_loc l1
    // @15
    lt
    br_false l2
    copy_loc l0
    copy_loc l2
    vec_borrow <u8>
    // @20
    read_ref
    st_loc l3
    copy_loc l3
    ld_u8 97
    ge
    // @25
    br_false l3
    copy_loc l3
    ld_u8 122
    le
    st_loc l4
    // @30
l11: move_loc l4
    br_false l4
    ld_true
    st_loc l5
l10: move_loc l5
    // @35
    br_false l5
    ld_true
    st_loc l6
l8: move_loc l6
    br_false l6
    // @40
    move_loc l2
    ld_u64 1
    add
    st_loc l2
    branch l7
    // @45
l6: move_loc l0
    pop
    ld_u64 4
    abort
l5: move_loc l3
    // @50
    ld_u8 45
    eq
    st_loc l6
    branch l8
l4: copy_loc l3
    // @55
    ld_u8 48
    ge
    br_false l9
    copy_loc l3
    ld_u8 57
    // @60
    le
    st_loc l5
    branch l10
l9: ld_false
    st_loc l5
    // @65
    branch l10
l3: ld_false
    st_loc l4
    branch l11
l2: move_loc l0
    // @70
    pop
    ret
l1: move_loc l0
    pop
    ld_u64 3
    // @75
    abort
l0: move_loc l0
    pop
    ld_u64 2
    abort

// Function definition at index 4
#[persistent] entry public fun add_signer(l0: &signer, l1: address, l2: vector<u8>, l3: vector<u8>) acquires Profile
    local l4: SignerEntry
    move_loc l0
    copy_loc l1
    call assert_controller
    copy_loc l1
    mut_borrow_global Profile
    // @5
    copy_loc l3
    call string::utf8
    ld_u64 0
    ld_u64 0
    pack SignerEntry
    // @10
    st_loc l4
    mut_borrow_field Profile, signers_
    copy_loc l2
    move_loc l4
    call smart_table::add<vector<u8>, SignerEntry>
    // @15
    move_loc l1
    move_loc l2
    move_loc l3
    call string::utf8
    call timestamp::now_seconds
    // @20
    pack SignerAdded
    call event::emit<SignerAdded>
    ret

// Function definition at index 5
fun assert_controller(l0: &signer, l1: address) acquires Profile
    copy_loc l1
    exists Profile
    br_false l0
    move_loc l1
    borrow_global Profile
    // @5
    borrow_field Profile, controller
    read_ref
    move_loc l0
    call signer::address_of
    eq
    // @10
    br_false l1
    ret
l1: ld_u64 6
    abort
l0: move_loc l0
    // @15
    pop
    ld_u64 8
    abort

// Function definition at index 6
fun assert_controller_or_owner(l0: &signer, l1: address) acquires Profile
    local l2: address
    copy_loc l1
    exists Profile
    br_false l0
    move_loc l0
    call signer::address_of
    // @5
    st_loc l2
    copy_loc l1
    borrow_global Profile
    borrow_field Profile, controller
    read_ref
    // @10
    copy_loc l2
    eq
    br_false l1
    ret
l1: move_loc l1
    // @15
    call object::address_to_object<Profile>
    call object::owner<Profile>
    move_loc l2
    eq
    br_false l2
    // @20
    ret
l2: ld_u64 15
    abort
l0: move_loc l0
    pop
    // @25
    ld_u64 8
    abort

// Function definition at index 7
fun assert_owner(l0: &signer, l1: address)
    copy_loc l1
    exists Profile
    br_false l0
    move_loc l1
    call object::address_to_object<Profile>
    // @5
    call object::owner<Profile>
    move_loc l0
    call signer::address_of
    eq
    br_false l1
    // @10
    ret
l1: ld_u64 7
    abort
l0: move_loc l0
    pop
    // @15
    ld_u64 8
    abort

// Function definition at index 8
friend fun assert_pid_exists(l0: address)
    move_loc l0
    exists Profile
    br_false l0
    ret
l0: ld_u64 8
    // @5
    abort

// Function definition at index 9
#[persistent] entry public fun attach_sync_gate(l0: &signer, l1: address, l2: address, l3: u64, l4: u64, l5: u64) acquires Profile
    local l6: &mut Profile
    move_loc l0
    copy_loc l1
    call assert_controller
    copy_loc l1
    mut_borrow_global Profile
    // @5
    st_loc l6
    copy_loc l6
    borrow_field Profile, sync_gate
    call option::is_none<reference_gate::ReferenceGate>
    br_false l0
    // @10
    move_loc l2
    move_loc l3
    move_loc l4
    move_loc l5
    call reference_gate::new
    // @15
    call option::some<reference_gate::ReferenceGate>
    move_loc l6
    mut_borrow_field Profile, sync_gate
    write_ref
    move_loc l1
    // @20
    call timestamp::now_seconds
    pack SyncGateAttached
    call event::emit<SyncGateAttached>
    ret
l0: move_loc l6
    // @25
    pop
    ld_u64 16
    abort

// Function definition at index 10
#[persistent] entry public fun clear_sync_gate(l0: &signer, l1: address) acquires Profile
    local l2: &mut Profile
    move_loc l0
    copy_loc l1
    call assert_controller
    copy_loc l1
    mut_borrow_global Profile
    // @5
    st_loc l2
    call option::none<reference_gate::ReferenceGate>
    move_loc l2
    mut_borrow_field Profile, sync_gate
    write_ref
    // @10
    move_loc l1
    call timestamp::now_seconds
    pack SyncGateCleared
    call event::emit<SyncGateCleared>
    ret

// Function definition at index 11
#[persistent] public fun controller_of(l0: address): address acquires Profile
    copy_loc l0
    exists Profile
    br_false l0
    move_loc l0
    borrow_global Profile
    // @5
    borrow_field Profile, controller
    read_ref
    ret
l0: ld_u64 8
    abort

// Function definition at index 12
#[persistent] public fun derive_pid_address(l0: address): address
    local l1: vector<u8>
    local l2: address
    vec_pack <u8>, 0
    st_loc l1
    mut_borrow_loc l1
    ld_const<vector<u8>> [112, 105, 100, 58, 58]
    call vector::append<u8>
    // @5
    mut_borrow_loc l1
    borrow_loc l0
    call bcs::to_bytes<address>
    call vector::append<u8>
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    // @10
    st_loc l2
    borrow_loc l2
    move_loc l1
    call object::create_object_address
    ret

// Function definition at index 13
friend fun derive_pid_signer(l0: address): signer acquires Profile
    copy_loc l0
    exists Profile
    br_false l0
    move_loc l0
    borrow_global Profile
    // @5
    borrow_field Profile, extend_ref
    call object::generate_signer_for_extending
    ret
l0: ld_u64 8
    abort

// Function definition at index 14
friend fun get_sync_gate(l0: address): option::Option<reference_gate::ReferenceGate> acquires Profile
    copy_loc l0
    exists Profile
    br_true l0
    call option::none<reference_gate::ReferenceGate>
    ret
    // @5
l0: move_loc l0
    borrow_global Profile
    borrow_field Profile, sync_gate
    read_ref
    ret

// Function definition at index 15
#[persistent] public fun handle_fee_apt(l0: u64): u64
    copy_loc l0
    ld_u64 1
    eq
    br_false l0
    ld_u64 10000000000
    // @5
    ret
l0: copy_loc l0
    ld_u64 2
    eq
    br_false l1
    // @10
    ld_u64 5000000000
    ret
l1: copy_loc l0
    ld_u64 3
    eq
    // @15
    br_false l2
    ld_u64 2000000000
    ret
l2: copy_loc l0
    ld_u64 4
    // @20
    eq
    br_false l3
    ld_u64 1000000000
    ret
l3: move_loc l0
    // @25
    ld_u64 5
    eq
    br_false l4
    ld_u64 500000000
    ret
    // @30
l4: ld_u64 100000000
    ret

// Function definition at index 16
#[persistent] public fun handle_max_len(): u64
    ld_u64 64
    ret

// Function definition at index 17
#[persistent] public fun handle_of(l0: address): string::String acquires Profile
    copy_loc l0
    exists Profile
    br_false l0
    move_loc l0
    borrow_global Profile
    // @5
    borrow_field Profile, handle
    read_ref
    ret
l0: ld_u64 8
    abort

// Function definition at index 18
#[persistent] public fun handle_of_wallet(l0: address): string::String acquires Profile
    move_loc l0
    call derive_pid_address
    call handle_of
    ret

// Function definition at index 19
#[persistent] public fun handle_to_wallet(l0: vector<u8>): address acquires HandleRegistry
    local l1: &HandleRegistry
    local l2: string::String
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global HandleRegistry
    st_loc l1
    move_loc l0
    call string::utf8
    // @5
    st_loc l2
    copy_loc l1
    borrow_field HandleRegistry, handle_to_wallet
    copy_loc l2
    call smart_table::contains<string::String, address>
    // @10
    br_false l0
    move_loc l1
    borrow_field HandleRegistry, handle_to_wallet
    move_loc l2
    call smart_table::borrow<string::String, address>
    // @15
    read_ref
    ret
l0: move_loc l1
    pop
    ld_u64 8
    // @20
    abort

// Function definition at index 20
#[persistent] public fun has_signer(l0: address, l1: vector<u8>): bool acquires Profile
    copy_loc l0
    exists Profile
    br_true l0
    ld_false
    ret
    // @5
l0: move_loc l0
    borrow_global Profile
    borrow_field Profile, signers_
    move_loc l1
    call smart_table::contains<vector<u8>, SignerEntry>
    // @10
    ret

// Function definition at index 21
#[persistent] public fun is_registered(l0: vector<u8>): bool acquires HandleRegistry
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global HandleRegistry
    borrow_field HandleRegistry, handle_to_wallet
    move_loc l0
    call string::utf8
    // @5
    call smart_table::contains<string::String, address>
    ret

// Function definition at index 22
fun make_pid_seed(l0: address): vector<u8>
    local l1: vector<u8>
    vec_pack <u8>, 0
    st_loc l1
    mut_borrow_loc l1
    ld_const<vector<u8>> [112, 105, 100, 58, 58]
    call vector::append<u8>
    // @5
    mut_borrow_loc l1
    borrow_loc l0
    call bcs::to_bytes<address>
    call vector::append<u8>
    move_loc l1
    // @10
    ret

// Function definition at index 23
#[persistent] public fun profile_exists(l0: address): bool
    move_loc l0
    exists Profile
    ret

// Function definition at index 24
#[persistent] entry public fun register_handle(l0: &signer, l1: vector<u8>, l2: address, l3: vector<u8>, l4: vector<u8>, l5: vector<u8>, l6: vector<u8>, l7: vector<u8>, l8: vector<u8>) acquires HandleRegistry, ProtocolState
    local l9: address
    local l10: option::Option<address>
    local l11: address
    local l12: string::String
    local l13: &mut HandleRegistry
    local l14: &ProtocolState
    local l15: u64
    local l16: object::Object<fungible_asset::Metadata>
    local l17: u64
    local l18: fungible_asset::FungibleAsset
    local l19: signer
    local l20: vector<u8>
    local l21: object::ConstructorRef
    local l22: signer
    local l23: object::ExtendRef
    local l24: object::TransferRef
    local l25: object::Object<Profile>
    borrow_loc l1
    call validate_handle
    borrow_loc l3
    vec_len <u8>
    ld_u64 8192
    // @5
    le
    br_false l0
    borrow_loc l4
    vec_len <u8>
    ld_u64 333
    // @10
    le
    br_false l1
    copy_loc l0
    call signer::address_of
    st_loc l9
    // @15
    borrow_loc l1
    call reserved_handle_claimer
    st_loc l10
    borrow_loc l10
    call option::is_some<address>
    // @20
    br_true l2
    branch l3
l2: borrow_loc l10
    call option::borrow<address>
    read_ref
    // @25
    st_loc l11
    copy_loc l9
    move_loc l11
    eq
    br_false l4
    // @30
    branch l3
l3: copy_loc l9
    call derive_pid_address
    st_loc l11
    copy_loc l1
    // @35
    call string::utf8
    st_loc l12
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    mut_borrow_global HandleRegistry
    st_loc l13
    // @40
    copy_loc l13
    borrow_field HandleRegistry, handle_to_wallet
    copy_loc l12
    call smart_table::contains<string::String, address>
    br_true l5
    // @45
    copy_loc l11
    exists Profile
    br_true l6
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    borrow_global ProtocolState
    // @50
    pop
    borrow_loc l1
    vec_len <u8>
    call handle_fee_apt
    st_loc l15
    // @55
    ld_const<address> 10
    call object::address_to_object<fungible_asset::Metadata>
    st_loc l16
    copy_loc l15
    ld_u64 0
    // @60
    gt
    br_true l7
    branch l8
l7: copy_loc l0
    copy_loc l16
    // @65
    copy_loc l15
    call primary_fungible_store::withdraw<fungible_asset::Metadata>
    call handle_fee_vault::deposit_apt_fa
l8: call factory::pool_seed_apt_amount
    st_loc l17
    // @70
    move_loc l0
    move_loc l16
    move_loc l17
    call primary_fungible_store::withdraw<fungible_asset::Metadata>
    st_loc l18
    // @75
    call governance::derive_pkg_signer
    st_loc l19
    copy_loc l9
    call make_pid_seed
    st_loc l20
    // @80
    borrow_loc l19
    move_loc l20
    call object::create_named_object
    st_loc l21
    borrow_loc l21
    // @85
    call object::generate_signer
    st_loc l22
    borrow_loc l21
    call object::generate_extend_ref
    st_loc l23
    // @90
    borrow_loc l21
    call object::generate_transfer_ref
    st_loc l24
    call timestamp::now_seconds
    st_loc l17
    // @95
    borrow_loc l22
    move_loc l12
    move_loc l2
    call smart_table::new<vector<u8>, SignerEntry>
    ld_const<vector<u8>> []
    // @100
    call string::utf8
    move_loc l3
    vec_pack <u8>, 0
    move_loc l4
    call string::utf8
    // @105
    call option::none<reference_gate::ReferenceGate>
    move_loc l23
    copy_loc l17
    pack Profile
    move_to Profile
    // @110
    borrow_loc l22
    move_loc l24
    pack TransferVault
    move_to TransferVault
    copy_loc l11
    // @115
    call object::address_to_object<Profile>
    st_loc l25
    borrow_loc l19
    move_loc l25
    copy_loc l9
    // @120
    call object::transfer<Profile>
    move_loc l13
    mut_borrow_field HandleRegistry, handle_to_wallet
    copy_loc l1
    call string::utf8
    // @125
    copy_loc l9
    call smart_table::add<string::String, address>
    copy_loc l1
    copy_loc l11
    borrow_loc l22
    // @130
    move_loc l18
    move_loc l5
    call string::utf8
    move_loc l6
    call string::utf8
    // @135
    move_loc l7
    call string::utf8
    move_loc l8
    call string::utf8
    call factory::create_token_atomic
    // @140
    move_loc l1
    call string::utf8
    move_loc l9
    move_loc l11
    move_loc l15
    // @145
    move_loc l17
    pack HandleRegistered
    call event::emit<HandleRegistered>
    ret
l6: move_loc l0
    // @150
    pop
    move_loc l13
    pop
    ld_u64 5
    abort
    // @155
l5: move_loc l0
    pop
    move_loc l13
    pop
    ld_u64 1
    // @160
    abort
l4: move_loc l0
    pop
    ld_u64 17
    abort
    // @165
l1: move_loc l0
    pop
    ld_u64 13
    abort
l0: move_loc l0
    // @170
    pop
    ld_u64 12
    abort

// Function definition at index 25
fun reserved_handle_claimer(l0: &vector<u8>): option::Option<address>
    local l1: vector<u8>
    move_loc l0
    read_ref
    st_loc l1
    copy_loc l1
    ld_const<vector<u8>> [100, 101, 115, 110, 101, 116]
    // @5
    eq
    br_false l0
    ld_const<address> 799008279626092026266606374476533705615973526478392622784892721766771113
    call option::some<address>
    ret
    // @10
l0: copy_loc l1
    ld_const<vector<u8>> [100, 97, 114, 98, 105, 116, 101, 120]
    eq
    br_false l1
    ld_const<address> 91156634194166803861100151592865738330905051539249711567309633464034624633053
    // @15
    call option::some<address>
    ret
l1: copy_loc l1
    ld_const<vector<u8>> [100]
    eq
    // @20
    br_false l2
    ld_const<address> 40023506704883894749682276227229583180850019028010612816341397443451990191223
    call option::some<address>
    ret
l2: copy_loc l1
    // @25
    ld_const<vector<u8>> [97, 112, 116, 111, 115]
    eq
    br_false l3
    ld_const<address> 99421430338818662237406370481488542422223213608239145475291835155559109072246
    call option::some<address>
    // @30
    ret
l3: move_loc l1
    ld_const<vector<u8>> [97, 112, 116]
    eq
    br_false l4
    // @35
    ld_const<address> 109327436956588036023951424363556437029595267519607070162281657297992626562406
    call option::some<address>
    ret
l4: call option::none<address>
    ret

// Function definition at index 26
#[persistent] entry public fun revoke_signer(l0: &signer, l1: address, l2: vector<u8>) acquires Profile
    local l3: &mut Profile
    move_loc l0
    copy_loc l1
    call assert_controller_or_owner
    copy_loc l1
    mut_borrow_global Profile
    // @5
    st_loc l3
    copy_loc l3
    borrow_field Profile, signers_
    copy_loc l2
    call smart_table::contains<vector<u8>, SignerEntry>
    // @10
    br_false l0
    move_loc l3
    mut_borrow_field Profile, signers_
    copy_loc l2
    call smart_table::remove<vector<u8>, SignerEntry>
    // @15
    pop
l1: move_loc l1
    move_loc l2
    call timestamp::now_seconds
    pack SignerRevoked
    // @20
    call event::emit<SignerRevoked>
    ret
l0: move_loc l3
    pop
    branch l1

// Function definition at index 27
#[persistent] entry public fun rotate_controller(l0: &signer, l1: address, l2: address) acquires Profile
    local l3: &mut Profile
    local l4: address
    local l5: &mut address
    move_loc l0
    copy_loc l1
    call assert_owner
    copy_loc l1
    mut_borrow_global Profile
    // @5
    st_loc l3
    copy_loc l3
    borrow_field Profile, controller
    read_ref
    st_loc l4
    // @10
    move_loc l3
    mut_borrow_field Profile, controller
    st_loc l5
    copy_loc l2
    move_loc l5
    // @15
    write_ref
    move_loc l1
    move_loc l4
    move_loc l2
    call timestamp::now_seconds
    // @20
    pack ControllerRotated
    call event::emit<ControllerRotated>
    ret

// Function definition at index 28
#[persistent] entry public fun update_fee_receiver(l0: &signer, l1: address) acquires ProtocolState
    local l2: &ProtocolState
    ld_const<address> 55931188893109713473377936165989862777849437759270464167622070126626736957220
    move_loc l0
    pop
    borrow_global ProtocolState
    pop
    // @5
    ld_u64 19
    abort

// Function definition at index 29
#[persistent] entry public fun withdraw_pid_token(l0: &signer, l1: address, l2: address, l3: u64, l4: address) acquires Profile
    local l5: signer
    local l6: object::Object<fungible_asset::Metadata>
    local l7: fungible_asset::FungibleAsset
    move_loc l0
    copy_loc l1
    call assert_owner
    copy_loc l1
    call derive_pid_signer
    // @5
    st_loc l5
    copy_loc l2
    call object::address_to_object<fungible_asset::Metadata>
    st_loc l6
    borrow_loc l5
    // @10
    move_loc l6
    copy_loc l3
    call primary_fungible_store::withdraw<fungible_asset::Metadata>
    st_loc l7
    copy_loc l4
    // @15
    move_loc l7
    call primary_fungible_store::deposit
    move_loc l1
    move_loc l2
    move_loc l3
    // @20
    move_loc l4
    call timestamp::now_seconds
    pack PidTokenWithdrawn
    call event::emit<PidTokenWithdrawn>
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

- [view] `history_exists(address)->bool`
- [view] `chunk_entries_count(address)->u64`
- [view] `chunk_entry_at(address,u64)->u8,u64,0x1::option::Option<address>,vector<u8>,0x1::option::Option<address>`
- [view] `chunk_is_sealed(address)->bool`
- [view] `chunk_rotate_threshold()->u64`
- [view] `count_verb(address,u8)->u64`
- [view] `head_chunk_addr(address)->address`
- [view] `max_payload_bytes()->u64`
- [view] `sealed_chunks_list(address)->vector<address>`
- [view] `total_bytes(address)->u64`
- [view] `total_entries(address)->u64`
- [view] `verb_echo()->u8`
- [view] `verb_mint()->u8`
- [view] `verb_press()->u8`
- [view] `verb_remix()->u8`
- [view] `verb_spark()->u8`
- [view] `verb_sync()->u8`
- [view] `verb_voice()->u8`

**Friend fns** (2):

- `append(address,0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::history::Entry)`
- `new_entry(u8,u64,0x1::option::Option<address>,vector<u8>,0x1::option::Option<address>)->0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::history::Entry`

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

- [view] `sync_count(address)->u64`
- [view] `is_synced(address,address)->bool`
- [view] `state_add()->u8`
- [view] `state_remove()->u8`
- [entry] `sync(&signer,address,address)`
- [view] `sync_kind()->u8`
- [view] `synced_by_count(address)->u64`
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

- [view] `mint_count(address)->u64`
- [entry] `attach_mint_gate(&signer,u64,address,u64,u64,u64)`
- [view] `content_text_max_bytes()->u64`
- [entry] `create_mint(&signer,u8,vector<u8>,u8,u8,vector<u8>,u8,vector<u8>,vector<u8>,address,u64,bool,address,u64,bool,vector<address>,vector<vector<u8>>,vector<address>,vector<address>,vector<address>,vector<u64>,address,bool)`
- [view] `media_inline_max_bytes()->u64`
- [view] `mentions_max()->u64`
- [view] `next_seq(address)->u64`
- [view] `tags_max()->u64`
- [view] `tickers_max()->u64`
- [view] `tips_max()->u64`

**Friend fns** (1):

- `get_mint_gate(address,u64)->0x1::option::Option<0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::reference_gate::ReferenceGate>`

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
- [view] `claims_made(address)->u64`
- [entry] `create_fa_giveaway(&signer,u64,0x1::object::Object<0x1::fungible_asset::Metadata>,u64,u64,u64,bool,address,bool,address,bool)`
- [view] `deadline_secs(address)->u64`
- [entry] `create_nft_giveaway(&signer,u64,address,vector<address>,u64,bool,address,bool,address,bool)`
- [view] `giveaway_addr_for_mint(address,u64)->address`
- [view] `has_claimed(address,address)->bool`
- [view] `kind_fa()->u8`
- [view] `kind_nft()->u8`
- [view] `settle_bounty_bps()->u64`
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
- [view] `supply_cap(address,u64)->u16`
- [view] `deadline_us(address,u64)->u64`
- [entry] `enable_press(&signer,u64,u16,u8)`
- [view] `has_pressed(address,address,u64)->bool`
- [view] `is_press_enabled(address,u64)->bool`
- [view] `pressed_count(address,u64)->u16`
- [view] `royalty_bps()->u64`

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

- [view] `state_add()->u8`
- [view] `state_remove()->u8`
- [entry] `echo(&signer,address,u64,address)`
- [view] `echo_kind()->u8`
- [view] `has_reacted(address,address,u64,u8)->bool`
- [entry] `spark(&signer,address,u64,address)`
- [view] `spark_kind()->u8`
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
