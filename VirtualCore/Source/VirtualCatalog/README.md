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

## Adding New Versions of macOS

To add a new version of macOS to the catalog, use `vctool`, which is included as part of VirtualBuddy.

If you have installed VirtualBuddy in `/Applications`, then `vctool` will be available at `/Applications/VirtualBuddy.app/Contents/MacOS/vctool`.

You may symlink `vctool` to a directory in your `PATH` or just add the corresponding `VirtualBuddy.app/Contents/MacOS` directory to your `PATH` to make running the tool more convenient.

You will also need to clone the VirtualBuddy repository itself so that you can open a pull request with the updated catalog after running `vctool`.

To add a new release to the catalog, use the `vctool catalog image add` command:

```bash
USAGE: vctool catalog image add --ipsw <ipsw> --channel <channel> --name <name> --output <output> [--force]

OPTIONS:
  -i, --ipsw <ipsw>       URL to the IPSW file.
  -c, --channel <channel> ID of the release channel (devbeta or regular).
  -n, --name <name>       User-facing name for the release (ex: "macOS 15.0 Developer Beta 4").
  -o, --output <output>   Path to the software catalog JSON file that will be updated.
  -f, --force             Replace existing build if it already exists in the catalog.
  -h, --help              Show help information.
```

Assuming you have cloned the repository in `~/Developer/VirtualBuddy`, here's an example of how you could add a new image to the catalog:

```bash
vctool catalog image add \
    -i 'https://updates.cdn-apple.com/2025SpringFCS/fullrestores/082-44534/CE6C1054-99A3-4F67-A823-3EE9E6510CDE/UniversalMac_15.5_24F74_Restore.ipsw' \
    -c regular \
    -n 'macOS 15.5' \
    -o ~/Developer/VirtualBuddy/data/ipsws_v2.json
``` 

If successful, the `ipsws_v2.json` file in your clone of the repository will have the new macOS release added to it.

Once the change is on the `main` branch, the new release appears in the app the next time it loads the catalog.

## Updating Existing Versions

If an OS build that's already in the catalog needs to be updated, just use the same command but add the `--force` flag so that it doesn't complain about the version already being in the catalog. Any changes made to the title, channel, or other properties will be updated.

## ⚠️ Important Note About New Major Versions

Adding new major OS versions (ex: macOS ~16~26) requires additional work because a corresponding release group has to be added, and that requires the availability of image assets that follow a certain specification used by the app.

The images go in `data/images`, which is built into the app, so a new release group needs a new version of the app to show its artwork.