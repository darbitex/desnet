# Profile Tokens

Every profile registered on DeSNet automatically spawns its own fungible token ($TOKEN). This token represents the "speech-economy" of the profile.

## Token Characteristics

- **Fixed Supply**: 1,000,000,000 (1 Billion) tokens.
- **Decimals**: 8.
- **Symbol**: Derived from the handle (e.g., handle `@alice` spawns `$ALICE`).

## Allocation

The total supply is distributed atomically upon registration into four distinct tranches to ensure protocol sustainability and creator alignment:

| Tranche | Amount | Percentage | Purpose |
| :--- | :--- | :--- | :--- |
| **Pool Seed** | 50M | 5% | Paired with 5 APT to seed the initial AMM pool. |
| **Reaction Reserve** | 50M | 5% | Drained via the `Press` verb to reward engagement. |
| **LP Emission** | 900M | 90% | Reserved for LP stakers (yield over ~2.85 years). |
| **Creator Alloc** | 0% | 0% | Creators earn through emissions and fees, not instant extraction. |

## Creator Alignment

Creators do not receive an upfront token allocation. Instead, their "stake" is the forever-locked LP position created during registration. They earn value as their token grows in liquidity and as they claim emissions from the staking pool.
