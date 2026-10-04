# App icon

`AppIcon.png` is the original artwork for UC Watchdog. It has a transparent background.
Generated with the built-in image_gen tool using the user's monitor image as inspiration.

Generation prompt:

> Use case: stylized-concept. Asset type: macOS application icon for UC Watchdog. Input image is inspiration only, not an edit target. Create a polished standalone icon inspired by its front-facing dark widescreen desktop monitor showing a clear turquoise rocky lakeshore, a blue sky and distant pale mountains. Make the monitor the main silhouette, with a thick subtly rounded graphite bezel, restrained metallic silver pedestal, and an elegant simplified illustrated landscape with a few large rocks, clear water and one tiny tree on the far shoreline. Native macOS app icon craft: beautiful precise soft 3D materials, crisp edges, restrained highlights, simple readable shapes at 32px, balanced almost-square composition. Center the whole monitor and pedestal on a 1024x1024 transparent canvas, with about 8 percent transparent margin; monitor roughly 84 percent canvas width and 65 percent canvas height including pedestal. The monitor screen is wider than tall. No surrounding rounded-square tile or background plate. No text, no letters, no badges, no status dots, no arrows, no logos, no watermark. Real transparent background outside the device, including around the base. Preserve the tranquil blue/turquoise palette and recognisable monitor idea from the reference. Output one finished icon, not a presentation sheet.

The application uses `Sources/UCWatchdog/Resources/AppIcon.icns`, containing standard
16, 32, 128, 256 and 512 px representations and their Retina variants. The ICNS
was packed with macOS `sips` and `iconutil`.
