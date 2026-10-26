# Safe at Home app mark

The original house and open doorway use the app's warm ivory (`#F8F5EE`) and
deep teal (`#174E49`) colors. The artwork contains no font, downloaded image or
external asset. The square iOS image stays opaque so the operating system can
apply its own shape.

`safe-at-home-mark.svg` is a portable vector export. The normalized paths in
`tool/generate_app_icons.swift` are the source for both the SVG and platform
assets, keeping their geometry consistent. To regenerate reviewable outputs
on macOS without modifying the installed assets:

```sh
swift tool/generate_app_icons.swift /tmp/safe-at-home-icons \
  ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json
```

The generator reads every existing iOS catalog filename and size, renders the
five Android bitmap densities, and writes Android API 26 adaptive resources.
It verifies each PNG's dimensions and lack of alpha. The adaptive foreground
has a transparent doorway and a control-point hull inside the centered
66/108 safe circle described in the [Android adaptive icon guidance](https://developer.android.com/develop/ui/compose/system/icon_design_adaptive).
Older Android launchers use the opaque bitmap assets.

Review generated previews before copying the named outputs into the platform
asset folders. The generator never edits a project or invokes Git. A later
native build must verify any changed resources.
