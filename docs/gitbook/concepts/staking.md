# LP Staking

Liquidity Provider (LP) staking is the engine of the DeSNet economy, distributing the 90% token reserve to participants.

## Two Types of Stakes

1.  **Locked Stake (Creator)**: Created atomically during registration. This represents the creator's initial liquidity (5 APT + 50M tokens). It is **forever-locked** and cannot be withdrawn, ensuring permanent liquidity.
2.  **Free Stake (Public)**: Anyone can add liquidity to any profile's AMM pool and stake their LP shares to earn emissions. These are withdrawable at any time.

## Rewards & Emissions

Stakers earn rewards from two sources:
- **Token Emissions**: Drained from the 900M $TOKEN reserve at a fixed rate of **10 tokens per second**.
- **Trading Fees**: Accumulated APT and $TOKEN fees from AMM swaps.

## Governance Power

Voting power in the DeSNet DAO is derived from a user's cumulative rewards earned via LP staking. This ensures that those with "skin in the game" and long-term alignment have the most influence.

## Precision Math

Rewards are calculated using a cumulative "per-share" model (C-variant), ensuring fair distribution even with frequent deposits and withdrawals.
