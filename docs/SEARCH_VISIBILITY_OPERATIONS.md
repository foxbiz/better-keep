# Search visibility operations

The repository now covers the changes that can be implemented safely in code.
The remaining work depends on owner access to analytics and store consoles.

## Before the website deploy

1. Export the previous 28 complete days from Search Console, App Store Connect,
   and Play Console into `store/operations/baseline-template.csv`.
2. Create a Plausible site for `betterkeep.app` and define these custom goals:
   `store_click_ios`, `store_click_android`, `open_web_app`, `github_click`, and
   `keep_import_guide_start`.
3. Run `npm run build web`, `npm test search`, `npm test lighthouse`, and
   `npm test hosting` against the running Firebase Hosting emulator.
4. Review `site/src/data/product-facts.json` whenever a platform, cipher,
   license, price, or public URL changes.

## Immediately after the website deploy

1. Confirm `/`, `/app/`, `/robots.txt`, `/sitemap.xml`, `/llms.txt`, and an
   unknown URL in production.
2. Add the domain property to Google Search Console and submit `/sitemap.xml`.
3. Add the site to Bing Webmaster Tools, submit the same sitemap, then run
   `npm run deploy indexnow`.
4. Inspect the homepage and `/google-keep-alternative` in the URL inspection
   tools. Do not request indexing for `/app/`, auth, checkout, reset, or shared
   note routes.
5. Annotate the launch date in the baseline sheet and Plausible.

## Before the app/store release

1. Import representative Takeout fixtures on Android, iOS, macOS, Windows, and
   Web. Verify that no archive request appears in network logs.
2. Confirm importer rollback, report counts, duplicate skipping, attachment
   warnings, and post-import sync behavior.
3. Capture authentic release-build UI for the four screenshot frames marked
   `needs-authentic-capture` in `store/creative/screenshot-plan.json`.
4. Have native reviewers approve every localized metadata and screenshot line,
   then change the relevant `reviewStatus` only after approval.
5. Copy the validated English metadata into both consoles. Do not include
   competitor names, Linux, OSS, open-source, or audit claims.

## Experiment sequence

- Play: first three screenshots, icon, then short description. Run one at a
  time for at least seven days and keep retained installers as the guardrail.
- Apple: control, privacy-led, and rich-text-led product-page treatments. Wait
  for 90% confidence where volume permits.
- Require at least a 10% relative conversion/CTR improvement at 90% confidence.
  If traffic is insufficient, keep the control and collect more data.

## Cadence

- Weekly: index coverage, crawler errors, ratings/reviews, listing conversion,
  crashes/ANRs, and importer failure reports.
- Monthly: non-brand queries, store search terms, landing-page gaps,
  localization performance, and one active store experiment.
- Quarterly: comparison facts, screenshots, supported platforms, the security
  page, product facts, and a public product/security update.

Ranks and downloads are outcomes, not promises. Judge the program by qualified
non-brand discovery, store CTR/conversion, retained installs, ratings, crash
health, and correctly indexed public pages.
