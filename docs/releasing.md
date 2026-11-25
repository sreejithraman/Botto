# Source releases

The first Botto source release is **0.1.0**. Release tags use the `v` prefix,
for example `v0.1.0`.

[Internal TestFlight delivery](testflight.md) has a separate GitHub workflow,
signing setup, and beta acceptance path. A source release does not publish an
Apple build.

## Prepare a release

1. Start from the reviewed `main` branch. Set the app and notification extension
   to the same `MARKETING_VERSION` in `project.yml`, then regenerate the project
   with XcodeGen 2.46.0.
2. Run the [contributor checks](../CONTRIBUTING.md#check-a-change), including the
   relevant UI and file-export workflows. Verify signed T3 pairing, live Space workflows, and physical notification
   delivery separately from unsigned tests.
   Resolve failures and update the [verification record](verification.md).
3. Clone the exact candidate into a clean directory. Follow the README and run
   checks there without relying on local source checkouts or generated files.
4. Refresh any published sample-data screenshots. Review source, fixtures,
   documentation, dependencies, media, and archive metadata for private content.
   Keep credentials and signing material out of source and release assets.
5. Preserve `LICENSE`, `LICENSES/`, `THIRD_PARTY_NOTICES.md`, and component licenses.
   Keep source pins and captured-fixture provenance accurate.
6. Update the changelog with the version, actual release date, behavior changes,
   and known limitations. State experimental push prerequisites explicitly.

## Publish

1. Confirm that hosted CI passes on the exact commit to be tagged. Local results
   do not substitute for the hosted run.
2. Create an annotated version tag, such as `v0.1.0`, on that commit.
3. Publish the matching GitHub source release using the changelog entry. Include
   relevant compatibility limits and the verification scope. An App Store or
   TestFlight build is a separate distribution process.

Rebuild and recheck the candidate after any source change. An earlier manifest,
screenshot, or test result does not cover later source.
