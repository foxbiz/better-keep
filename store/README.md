# Better Keep store release kit

The metadata in `metadata/` is the copy source for App Store Connect and Play
Console. English is ready for a final owner review. Japanese, Korean,
Indonesian, Brazilian Portuguese, and Simplified Chinese are deliberately
marked `needs-native-review`; the validator prevents them from being treated as
publish-ready without a human reviewer changing that state.

Run:

```bash
npm run test:store
```

## Creative production

`creative/screenshot-plan.json` defines one benefit per frame and points only to
authentic UI captures. Frames 1, 2, 3, and 6 have usable source captures. Capture
the offline/device, importer report, reminder, and organization screens from the
release build before composing or uploading those frames. Do not substitute
mock UI, login, payment, subscription, or settings screens.

For each approved locale:

1. Have a native reviewer approve the metadata and the eight screenshot lines.
2. Compose 1290×2796 source frames, keeping text inside platform safe areas.
3. Check the claims against `site/src/data/product-facts.json`.
4. Upload the first three frames as the initial experiment.
5. Route privacy, rich-text, and voice campaigns to matching custom pages.

Do not publish Turkish metadata until the Turkish in-app locale is enabled and
verified.

## Console work that remains manual

- Export the previous 28 days into `operations/baseline-template.csv`.
- Connect Search Console and Bing Webmaster Tools and submit `/sitemap.xml`.
- After a production deploy, run `npm run submit:indexnow` to notify IndexNow
  using the public key served at `/indexnow-key.txt`.
- Configure Plausible goals for the five names in the product-facts file.
- Create one Play Store Listing Experiment at a time.
- Create App Store Product Page Optimization treatments for control, privacy,
  and rich text.
- Reply to reviews constructively and add recurring issues to the backlog.
- Use a reviewed screenshot set and metadata only after the matching app build
  is approved for release.
