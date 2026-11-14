# Fork notes

This repository is a fork of [bmachek/lrc-immich-plugin](https://github.com/bmachek/lrc-immich-plugin).
`main` tracks upstream plus the fork additions below; it is the only long-lived branch.

## Fork additions

- **Batching (Export and Publish)** — a *Performance* section with *Enable batching* and a
  batch size. Large jobs are processed in chunks to bound peak temporary-disk usage; the
  progress caption shows count, throughput, and ETA.
- **Publish selection prompt** — when only a subset of the pending photos is selected in the
  grid, asks whether to publish the selection or all pending photos before rendering starts.
- **Capture dates on upload** — uploads send the photo's Lightroom capture date as Immich's
  `fileCreatedAt`, so screenshots and social-media downloads without EXIF no longer land on
  their upload date. Videos already received the same treatment via a post-upload update.
- **Sync, Clean & Repair Immich** — a menu command with three actions:
  - *Mobile Culling Sync* (server → Lightroom): finds catalog photos whose known Immich
    assets are missing or trashed, and puts them in the `Immich Mobile Deleted / Culled`
    collection for review. A photo counts as culled only when **every** asset Lightroom
    knows for it is gone, including assets recorded per publish service.
  - *Clean Server Orphans* (Lightroom → server): finds assets in an album (or all albums)
    that no catalog photo references, and trashes them after confirmation. Assets recorded
    by any Immich publish collection are treated as referenced.
  - *Repair Immich Dates* (Lightroom → server): reads each asset's current date, previews
    every change (filename, current date → Lightroom date) and asks for confirmation before
    writing. Runs on the selected photos, or on the whole catalog when nothing is selected.
    Use it once after upgrading to fix assets uploaded with the old upload-date behavior; it
    covers every per-service asset.
- **Immich 3.0 album compatibility** — album asset IDs are resolved through the paginated
  `search/metadata` endpoint, because `GET /albums/{id}` no longer returns assets.
- **O(1) album membership** — publish builds a set of album asset IDs instead of a linear
  lookup per photo.

Upstream's publish asset-identity fixes (#152, #153, #154) are included. They are the reason
the deletion scans collect asset IDs from every Immich publish service, not only from the
single `immichAssetId` metadata field.

## Syncing with upstream

```sh
git fetch upstream
git switch main
git merge upstream/main
```

Resolve conflicts in `PublishTask.lua` by keeping both the fork's batching `state` argument
and upstream's `publishedIdIndex` argument; every signature and call site carries both.

## Branch and tag policy

- `main` is the integration branch. Merge upstream into it; do not keep a separate
  reconcile branch.
- Feature work happens on short-lived topic branches and is merged into `main`.
- Retired experiments are kept as `archive/*` tags, not branches.

## Validation

The same checks run in CI (`.github/workflows/format-lint.yml`):

```sh
stylua --check immich-plugin.lrplugin
luacheck immich-plugin.lrplugin
```

Testing is manual in Lightroom Classic; there is no automated test suite.
