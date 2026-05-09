# Mint (Post)

The `Mint` verb is the primary content creation primitive on DeSNet. It represents an original, on-chain post.

## Content Specification

- **Text**: Maximum 333 bytes of UTF-8 text.
- **Media**: Optional media can be attached.
    - **Inline**: Data up to 8KB stored directly in the event.
    - **Reference**: Pointers to external storage (Shelby, Walrus, IPFS) or the `desnet::assets` on-chain media tree.
- **MIME Types**: Supports PNG, JPEG, GIF, WEBP, and SVG.

## Engagement Metadata

A Mint can carry various metadata to facilitate discovery and economy:
- **Mentions**: Up to 10 Aptos addresses.
- **Tags**: Up to 5 tags (1-32 chars, lowercase `a-z`, `0-9`, `-`). Tags are an ownerless folksonomy.
- **Tickers**: Up to 5 factory-spawned $TOKEN tickers.
- **Tips**: Up to 10 atomic tips in any FA-standard token.

## Gating

Authors can attach a **ReferenceGate** to their Mints, requiring engagers (for Voice, Spark, etc.) to hold a certain amount of tokens or LP stake.
