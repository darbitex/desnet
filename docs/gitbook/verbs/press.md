# Press (Collect)

`Press` is a unique social primitive that turns a post into a collectible NFT.

## Vinyl-Pressing Metaphor

Original Recording (Mint) → Physical Vinyl (Press NFT).

## Configuration

Authors can opt-in to "presses" for their posts by setting a `PressConfig`:
- **Supply Cap**: 1 to 1,000 NFTs.
- **Window**: 1 to 7 days.

## Emission Curve

Pressing a post rewards the presser with profile tokens from the **Reaction Reserve**. The amount follows a linear **INCREASING** curve to reward later participants and prevent front-running:
- Press #1 = 1 token-unit
- Press #100 = 100 token-units
- Press #1,000 = 1,000 token-units

## NFT Collection

Press NFTs are minted into a collection named `<handle>'s Presses`.
- **Royalty**: 5% native royalty, paid to the author's PID (and subsequently their Vault).
- **Secondary Market**: Press NFTs can be traded on any Aptos NFT marketplace.
