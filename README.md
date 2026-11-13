# public-template
Template for new public repositories

## Releasing

PR titles must follow [Conventional Commits](https://conventionalcommits.org/) (checked by the `PR title` workflow), since they become the squash-merge commit message.

[release-please](https://github.com/googleapis/release-please) keeps a release PR open that bumps the version and updates `CHANGELOG.md` from the merged commits. Merging it creates the `vX.Y.Z` tag and GitHub release. Callers pin the tag's commit SHA.

`feat` releases a minor version; `fix`, `perf`, `revert`, `chore` and `docs` release a patch. `ci`, `build`, `refactor`, `test` and `style` do not trigger a release, so use `feat` or `fix` for changes to the reusable workflows and `ci` only for this repo's own workflows. A `!` after the type (e.g. `feat!:`) releases a major version.
