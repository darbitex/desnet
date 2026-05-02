# DeSNet v0.3.2 — Chain Bytecode Bundle (PART 1 governance auth)

**Ground truth = on-chain bytecode fetched from mainnet @desnet on 2026-05-02.**

This is **1 of 3** parts. Each part covers a domain-grouped subset of modules.

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
| `voter_history` | 2,785 | `b69051e8d111f822861139712479ba59433a8dad55eb0afda9d36c918bf2bc50` |
| `governance` | 7,972 | `2e5057dd69b09d4ec8a01df7eb363a878b388833c54a106060b9673039d31092` |
| `factory` | 5,721 | `b477bdfe76de501d905ec24329b7d4fd17ce4e3fe8a616617bb7ddca95cdddca` |
| `profile` | 6,403 | `b61420ac094b99ff7b5dbfba0c63d773f88a41de4bbf04225dcd1977e6332d60` |

To verify each module's sha3 matches: `curl https://fullnode.mainnet.aptoslabs.com/v1/accounts/<@desnet>/module/<name>` → `.bytecode` field → strip `0x` → hex-decode → sha3_256.

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

- [view] `has_per_token_registry() → bool`
- [view] `history_exists(address) → bool`
- [entry] `prune_voter_history(&signer,address)`
- [view] `rewards_earned_30d(address) → u64`
- [view] `rewards_earned_30d_for_token(address,address) → u64`
- [view] `total_received(address) → u64`
- [view] `voting_window_secs() → u64`

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

- [view] `voting_power(address) → u64`
- [entry] `cast_vote(&signer,u64,bool)`
- [entry] `cleanup_upgrade_staging(&signer)`
-  `compute_upgrade_digest(&vector<u8>,&vector<vector<u8>>) → vector<u8>`
- [view] `compute_upgrade_digest_view(vector<u8>,vector<vector<u8>>) → vector<u8>`
- [entry] `dao_publish_chunked_upgrade(&signer,u64,vector<u8>,vector<u16>,vector<vector<u8>>)`
- [entry] `dao_stage_upgrade_chunk(&signer,u64,vector<u8>,vector<u16>,vector<vector<u8>>)`
- [entry] `disable_multisig_upgrade(&signer)`
- [view] `effective_30d_emission_view() → u64`
- [entry] `execute_proposal(&signer,u64,vector<u8>,vector<vector<u8>>)`
- [entry] `multisig_publish_chunked_upgrade(&signer,vector<u8>,vector<u16>,vector<vector<u8>>)`
- [entry] `multisig_stage_upgrade_chunk(&signer,vector<u8>,vector<u16>,vector<vector<u8>>)`
- [entry] `multisig_upgrade(&signer,vector<u8>,vector<vector<u8>>)`
- [view] `proposal_approved_at(u64) → 0x1::option::Option<u64>`
- [view] `proposal_count() → u64`
- [view] `proposal_executed_at(u64) → 0x1::option::Option<u64>`
- [view] `proposal_exists(u64) → bool`
- [view] `proposal_hash(u64) → vector<u8>`
- [view] `proposal_target(u64) → address`
- [view] `proposal_threshold_amount() → u64`
- [entry] `propose_upgrade(&signer,address,vector<u8>)`
- [view] `quorum_amount() → u64`
- [entry] `ratify(&signer,u64)`
- [view] `timelock_secs() → u64`
- [view] `total_30d_emission_auto() → u64`
- [entry] `update_desnet_fa_metadata(&signer,address)`
- [entry] `update_total_30d_emission(&signer,u64)`
- [view] `upgrade_staging_exists() → bool`
- [view] `voting_period_secs() → u64`

**Friend fns** (2):

- `derive_pkg_signer() → signer`
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

- [view] `admin() → address`
- [view] `derive_token_metadata_addr(vector<u8>) → address`
-  `emit_press_to_presser(&signer,address,vector<u8>,u64,u64) → u64`
- [view] `get_token_record(vector<u8>) → 0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::factory::TokenRecord`
- [view] `handle_of_owner(address) → 0x1::string::String`
- [view] `handle_of_token(address) → 0x1::string::String`
- [view] `handle_registered(vector<u8>) → bool`
- [view] `is_factory_token(address) → bool`
- [view] `is_paused() → bool`
- [view] `lp_staking_pool_of_owner(address) → address`
- [view] `owner_has_token(address) → bool`
- [view] `pool_seed_apt_amount() → u64`
- [view] `pool_seed_token_amount() → u64`
- [entry] `rotate_admin(&signer,address)`
- [entry] `set_paused(&signer,bool)`
- [view] `spawn_count() → u64`
- [view] `token_metadata_of_owner(address) → address`
- [entry] `update_token_icon(&signer,vector<u8>,0x1::string::String)`
- [entry] `update_token_project_uri(&signer,vector<u8>,0x1::string::String)`
- [view] `vault_addr_of_handle(vector<u8>) → address`
- [view] `vault_addr_of_pid(address) → address`

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
- [view] `controller_of(address) → address`
- [view] `derive_pid_address(address) → address`
-  `handle_fee_apt(u64) → u64`
- [view] `handle_max_len() → u64`
- [view] `handle_of(address) → 0x1::string::String`
- [view] `handle_of_wallet(address) → 0x1::string::String`
- [view] `handle_to_wallet(vector<u8>) → address`
- [view] `has_signer(address,vector<u8>) → bool`
- [view] `is_registered(vector<u8>) → bool`
- [view] `profile_exists(address) → bool`
- [entry] `register_handle(&signer,vector<u8>,address,vector<u8>,vector<u8>,vector<u8>,vector<u8>,vector<u8>,vector<u8>)`
- [entry] `revoke_signer(&signer,address,vector<u8>)`
- [entry] `rotate_controller(&signer,address,address)`
- [entry] `update_fee_receiver(&signer,address)`
- [entry] `withdraw_pid_token(&signer,address,address,u64,address)`

**Friend fns** (3):

- `assert_pid_exists(address)`
- `derive_pid_signer(address) → signer`
- `get_sync_gate(address) → 0x1::option::Option<0x7ba7ee5a93694aa5943f4ef344737d95795d51395e3d65a1b732c776d34be724::reference_gate::ReferenceGate>`

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
