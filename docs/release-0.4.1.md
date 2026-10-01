# Lode v0.4.1

Patch release of v0.4.0, including the CI corrections from
`d3c0466c762d0db6497d6c1e395cbb7155fd9fc4`:

- Platform-neutral scratch paths in the native and liaison fixture suites.
- Native immutable repository views and scoped compare-and-publish fixtures,
  with operation-specific warrants and correct gateway payload checks.

The main commit's [Lean Action CI](https://github.com/typednotes/lode/actions/runs/36862826722)
and [image publication](https://github.com/typednotes/lode/actions/runs/36862826912)
passed. The older v0.4.0 tag points to its parent and failed on a hardcoded
macOS temporary directory absent on Ubuntu. That published tag remains unchanged.

The release bump changes version metadata and documentation, not the tested
runtime implementation or its permission/proof contracts. LSP and the bounded
Eff bridge are the same implementation as v0.4.0 plus the corrected test fixtures.

Push the new main commit first. After its **Lean Action CI** and **Publish Docker
image** workflows pass, push **v0.4.1** explicitly. Wait for both workflows on
that tag before moving to Typednotes v0.7.0 publication/deployment. This supersedes
the previous v0.4.0 tag instruction in the app's push guide.

The prepared tag is local until the user publishes it. No remote tag is moved
and preparing this release does not deploy an image or apply the fleet.
