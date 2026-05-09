# Value Flow

Value in DeSNet flows through handle fees, trading fees, and royalties, all governed by protocol-level vaults.

## Handle Fee Split

Handle registration fees are routed to the `HandleFeeVault`:
- **10%** to the protocol deployer/beneficiary.
- **90%** to buy back and burn the native `desnet` token.

## Per-Token Vaults

Every profile token has its own `AptVault`. This vault receives:
- **Secondary Market Royalties**: 5% of all Press NFT trades.
- **Direct Donations**: Any APT sent to the profile's vault.

### Settle Mechanism

When the `AptVault` is settled (triggered by anyone after meeting a balance threshold):
- **50%** of the APT is paid directly to the current owner of the PID NFT.
- **50%** is used to buy back the profile's own token from its AMM and **burn** it.

## MEV Protection

Both the `HandleFeeVault` and the `AptVault` use a **Two-Phase Commit-Reveal** mechanism for settlements. A settle must be requested, followed by a 60-second delay before execution, defeating atomic sandwich attacks.
