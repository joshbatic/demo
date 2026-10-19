# Liquid Glass app icons

These are the layers for the Liquid Glass versions of the two app icons, for Apple's Icon Composer. Icon Composer is free with Xcode 26: open Xcode, then choose Xcode › Open Developer Tool › Icon Composer.

| Folder | App | Background |
|---|---|---|
| `demo/` | *[demo] (main app) | brushed silver |
| `dev/` | [developer] | brushed graphite |

Each folder has three layers, all on a 1024 × 1024 canvas with no rounded corners (iOS and macOS add those):

1. `1-background.png`: the brushed metal. It's a picture, so it stays as it is, with no glass.
2. `2-label.svg`: the black centre disc.
3. `3-asterisk.svg`: the white asterisk.

The DEMO/DEV lettering is left out because it's too small to read once it's glass. The silver and graphite backgrounds tell the two apps apart.

## Make the main icon (about 5 minutes)

1. In Icon Composer, choose File › New.
2. Drag the three files from `demo/` into the left sidebar.
3. Put the layers in this order, from bottom to top: background, label, asterisk.
4. Put each one in its own group, so you have three groups. Each group is a separate depth of glass.
5. Select the **background** group and turn **Liquid Glass off**. The metal should stay solid.
6. Select the **label** group and turn **Liquid Glass on**. Leave Specular on, and set Shadow to Neutral.
7. Select the **asterisk** group and turn **Liquid Glass on**, with Specular on. This is where the highlight shows most.
8. Check the different looks with the buttons along the bottom: Default, Dark, Clear and Tinted.
   - If Dark looks too bright, select the background, switch the inspector to Dark, and lower the background's opacity a little.
9. Choose File › Save, and name it **`AppIcon.icon`**.

Repeat with the files in `dev/` to make the [developer] icon, also named `AppIcon.icon`. It's for a different project, so the same name is fine.

## Put it in the iPhone apps

1. In Xcode, open `~/Documents/songpad-ios/ios/App/App.xcworkspace`.
2. Drag `AppIcon.icon` into the left sidebar, next to `Assets.xcassets` in the App folder. When asked, tick "Copy items if needed" and the App target.
3. Click the blue App project at the top of the sidebar, choose the App target, then General. Under "App Icons and Launch Screen", check that App Icon says `AppIcon`.
4. Leave the old AppIcon in `Assets.xcassets` where it is. Apple recommends keeping it for older iOS versions until a known bug is fixed. Xcode uses the `.icon` file on iOS 26.
5. Build to your phone.

Then do the same in `~/Documents/songpad-ios-dev` with the dev `AppIcon.icon`.

## The Mac apps

The Mac apps are built with Electron rather than Xcode, so they can't use the `.icon` file directly yet. They keep the flat icon for now. To give them a Liquid Glass look:

1. In Icon Composer, choose File › Export.
2. Export the macOS Default image at 1024 × 1024.
3. Send it to Claude to turn into the Mac app's `icon.icns`.
