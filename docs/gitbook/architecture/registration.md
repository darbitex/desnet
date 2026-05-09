# Atomic Registration

DeSNet uses an all-or-nothing atomic registration pipeline. Identity, currency, and market are created in a single transaction.

## The Pipeline

When a user calls `register_handle`:

1.  **Identity Creation**: A PID Object NFT is minted to the user.
2.  **Token Spawn**: The per-profile $TOKEN is created with a 1B supply.
3.  **Reserves Initialized**:
    - 5% (50M) to the AMM seed.
    - 5% (50M) to the Reaction Emission reserve.
    - 90% (900M) to the LP Emission reserve.
4.  **AMM Creation**: An APT/$TOKEN pool is created and seeded with 5 APT (from the user) and 50M $TOKEN.
5.  **Forever-Lock**: The resulting LP shares are permanently locked into a staking pool associated with the PID.

## Atomicity Guarantee

Because this is a single Move transaction, if any step fails (e.g., insufficient APT, handle already taken), the entire transaction reverts, leaving no partial state or "zombie" tokens.
