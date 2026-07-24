# Releasing 0xda Market

The project uses Semantic Versioning. Stable tags have the form `vMAJOR.MINOR.PATCH`;
for example, release `0.1.0` is tagged `v0.1.0` rather than `release_0.1`.

## Release flow

1. Update `VERSION`, move curated entries from `Unreleased` in `CHANGELOG.md`,
   and add `docs/releases/vX.Y.Z.md` on `master`.
2. Require green tests and verify the `master` deployment in the development VPS
   environment with `deploy/vps/verify.sh`. Back up the production database
   before schema changes.
3. Promote the core with a pull request from `master` to `release`. Wait for
   release-branch CI, then stage and activate the production VPS only through a
   separately reviewed production workflow.
4. Promote the matching bot version from its `master` to `release`, then verify
   `/health`, `/bot/health`, `/start`, `/buy`, `/apply_prices` and one controlled
   price update.
5. Run **Prepare GitHub release** with `vX.Y.Z`, or create
   `release-request/vX.Y.Z` from the exact `release` HEAD, in this repository
   and then in the bot repository. Each workflow retests the commit, builds its
   image, creates an annotated tag and saves a draft GitHub Release.
6. Review both drafts and publish the core release before the bot release.

Tags are immutable release coordinates: never move or reuse a published tag.
GitHub's immutable-releases setting should be enabled after the draft workflow
has been validated for both repositories.

## Rollback

Prefer a revert pull request or a forward fix on `release`; do not force-push
the production branch. Keep the core and bot compatibility pair together.
Migrations are not automatically rolled back.

The VPS deployment attempts to restart the previous release when an active
refresh fails. The environment-switch controller attempts to restore the
previous core + bot pair when activation fails. Follow
[`deploy/vps/OPERATIONS.md`](deploy/vps/OPERATIONS.md) for manual recovery.

For `v0.1.0`, migration `008` retains the legacy catalog read columns so the
prior core can be redeployed during the rollback window, while
`product_localizations` remains the source of truth. Restore a verified database
backup only when application-level recovery is insufficient.
