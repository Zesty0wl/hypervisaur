# VirtualCatalog

This directory includes models and associated logic used by Hypervisaur to inspect and resolve downloadable restore images for virtual machines.

The catalog itself is a pair of JSON files in the `data` folder of the repository:

- `ipsws_v2.json`: for macOS virtual machines
- `linux_v2.json`: for Linux virtual machines

Hypervisaur reads them from the `main` branch on GitHub, so changes reach everyone without a new version of the app. The same files are built into the app, which uses its own copy when it can't reach GitHub.

Because every released version of the app reads these files, changes to them must be ones that those versions can still read. New properties must be optional. A change that older versions can't read needs new file names, such as `linux_v3.json`, and a version of the app that reads them.

## Releases That Are Updated in Place

Some distributions replace their images with each point release, so a link to a particular image stops working. A restore image can name where the distribution lists its images, and the app downloads the newest one that matches when the user chooses it:

```json
"releaseSource" : {
  "indexes" : [
    "https://cdimage.debian.org/debian-cd/current/arm64/iso-dvd/SHA256SUMS",
    "https://cdimage.debian.org/cdimage/archive/latest-oldstable/arm64/iso-dvd/SHA256SUMS"
  ],
  "fileNamePattern" : "debian-13\\.\\d+\\.\\d+-arm64-DVD-1\\.iso"
}
```

The indexes are tried in order, so a release can still be found after it moves to an archive. An index can be a list of checksums, a directory listing or any other file that names the images, either by file name relative to the index or by URL. The pattern must match the whole file name, and versions in file names are compared as numbers. The restore image's `url` is used if no image can be found, so keep it pointing at a current image.

Channels with betas or other test builds have `"prerelease" : true`, which lists them after releases.

## New Versions of macOS

New versions of macOS don't need adding to the catalog. Each time the list of versions is shown, or reloaded with its Check for New Versions button, the app adds the ones that the catalog doesn't have yet:

- [AppleDB](https://appledb.dev) lists every build of macOS, including betas and release candidates, along with whether Apple still signs it for virtual machines. Builds that Apple doesn't sign can't be installed, so they're left out. The list is about 5 MB, and it's only downloaded again once it's changed.
- Apple's own list, which Virtualization reads, only has the newest release, but has it as soon as it's out.

Restore images are only downloaded from Apple's servers, whatever the list says.

A new build is shown with the requirements of the newest image of the same version of macOS in the catalog, or of the same major version, because they're decided by how Hypervisaur installs each version rather than by the restore image. The version of the MobileDevice framework that it needs is read from its build manifest, which the app downloads from the restore image without downloading the rest of it, and keeps in its caches. When a release candidate turns out to be the release, it's listed as the release.

The restore images in `ipsws_v2.json` are the ones that the app shows without a connection to AppleDB. They can still be added with `vctool catalog image add`, but they don't need to be.

## New Major Versions of macOS

A new major version of macOS is listed as soon as its first beta is out, in a release group of its own that has the artwork of the newest group. Its own artwork goes in `data/images`, which is built into the app, along with a group in `ipsws_v2.json` that has the same major version:

```json
{
  "id" : "goldengate",
  "name" : "macOS Golden Gate",
  "majorVersion" : "27.0.0",
  ...
}
```

The images follow the specification of the other groups' images, and the app shows them from its next version.
