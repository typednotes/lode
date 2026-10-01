# Lode v0.4.2

Publication-policy patch of v0.4.1, coordinated with Typednotes v0.7.2.

- CI runs on main and PRs targeting main; version tags do not repeat the suite.
- Docker publication requires the latest exact-commit push-to-main CI run to
  complete successfully and checks out that verified commit.
- Main no longer publishes an edge image; stable version tags update latest.
- Living README documentation/source links point to GitHub main.

The runtime, permission/proof contracts and Linen/Liaison/Lun dependency pins
are unchanged. Offline gate cases and workflow-policy checks passed locally.
Hosted CI and publication for this new release remain pending the user's push.

Push main first, wait for **Lean Action CI**, then push **v0.4.2** explicitly.
Wait for **Publish Docker image** before updating the deployed Lode service.
