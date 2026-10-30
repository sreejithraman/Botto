# Source releases

The first Botto source release is **0.1.0**. Release tags use the `v` prefix,
for example `v0.1.0`.

## Prepare a release

1. Start from the reviewed `main` branch. Set the app and notification extension
   to the same `MARKETING_VERSION` in `project.yml`, then regenerate the project
   with XcodeGen 2.46.0.
2. Run the [contributor checks](../CONTRIBUTING.md#check-a-change), including the
   relevant UI and file-export workflows. Check signed login, real Hermes
   workflows, and physical notification delivery separately from unsigned tests.
   Resolve failures and update the [verification record](verification.md).
3. Clone the exact candidate into a clean directory. Follow the README and run
   checks there without relying on local source checkouts or generated files.
4. Refresh the README's sample-data screenshots. Review source, fixtures,
   documentation, dependencies, media, and archive metadata for private content.
   Keep credentials and signing material out of source and release assets.
5. Preserve `LICENSE`, `LICENSES/`, `THIRD_PARTY_NOTICES.md`, and component licenses.
   Keep source pins and captured-fixture provenance accurate.
6. Update the changelog with the version, actual release date, behavior changes,
   and known limitations. State experimental push prerequisites explicitly.

## Initial repository import

For a source-only import into a new repository, export the reviewed tree into
an unused directory:

```sh
python3 scripts/prepare-source-release.py --output ../Botto
```

The exporter includes tracked and nonignored source files, applies
`.gitattributes` export exclusions, and writes a SHA-256 manifest beside the new
directory. It refuses an existing destination, signing material, local state
directories, symbolic links, and unexpected root files. Git history, remotes,
ignored artifacts, and development records are excluded.

The exporter is not a secret scanner. Inspect its full manifest, run a privacy
scan, and check the final images before importing. Historical captured fixture
names and original copyright notices may retain upstream names.

Initialize the exported directory on `main`, make the initial source commit,
and repeat the clean-clone checks. Create the `Botto` repository with Issues,
private vulnerability reporting, and read-only Actions token permissions by
default. Push only the reviewed source commit.

## Publish

1. Confirm that hosted CI passes on the exact commit to be tagged. Local results
   do not substitute for the hosted run.
2. Create an annotated version tag, such as `v0.1.0`, on that commit.
3. Publish the matching GitHub source release using the changelog entry. Include
   relevant compatibility limits and the verification scope. An App Store or
   TestFlight build is a separate distribution process.

Rebuild and recheck the candidate after any source change. An earlier manifest,
screenshot, or test result does not cover later source.
