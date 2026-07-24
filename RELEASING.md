# Releasing 0xda Market

The project uses Semantic Versioning. Stable tags have the form `vMAJOR.MINOR.PATCH`;
for example, release `0.1.0` is tagged `v0.1.0` rather than `release_0.1`.

## Release flow

1. Update `VERSION`, move curated entries from `Unreleased` in `CHANGELOG.md`,
   and add `docs/releases/vX.Y.Z.md` on `master`.
2. Require green tests and verify the `master` deployment in the development VPS
   environment with `deploy/vps/verify.sh`.
3. Before schema changes, verify the production PostgreSQL/Supabase recovery
   boundary and record the compatible core + bot pair.
4. Promote the core with a pull request from `master` to the protected production
   branch. Production VPS staging and activation require a reviewed workflow;
   development deployment must never infer or perform the cutover.
5. Promote the matching bot version, then verify `/health`, `/bot/health`,
   `/start`, `/buy`, `/apply_prices` and one controlled price update.
6. Run **Prepare GitHub release** with `vX.Y.Z`, or create
   `release-request/vX.Y.Z` from the exact production-branch HEAD, in this
   repository and then in the bot repository. Each workflow retests the commit,
   builds its image, creates an annotated tag and saves a draft GitHub Release.
7. Review both drafts and publish the core release before the bot release.

Tags are immutable release coordinates: never move or reuse a published tag.
GitHub's immutable-releases setting should be enabled after the draft workflow
has been validated for both repositories.

## Rollback

Prefer a revert pull request or a forward fix; do not force-push the production
branch. Keep the core and bot compatibility pair together. Migrations are not
automatically rolled back.

The VPS deployment attempts to restart the previous release when an active
refresh fails. The environment-switch controller attempts to restore the
previous core + bot pair when activation fails. Follow
[`deploy/vps/OPERATIONS.md`](deploy/vps/OPERATIONS.md) for manual recovery and
restore a verified database backup only when application-level recovery is
insufficient.
