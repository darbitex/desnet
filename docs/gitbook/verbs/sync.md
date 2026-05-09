# Sync (Subscribe)

`Sync` is the verb for subscribing to a profile's content.

## Mechanics

- **Unidirectional**: Syncing is one-way (A syncs to B).
- **Storage**: The list of "who I sync to" is stored in the syncer's `PidSyncSet`.
- **Target Count**: The target profile maintains a `synced_by_count` but not a full list of followers (to keep storage costs low for popular accounts).

## Sync Gates

Profiles can set a profile-level `sync_gate`. To sync to such a profile, the actor must meet specific token balance or LP stake requirements.
