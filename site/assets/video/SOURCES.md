# Hero video

`hero-wide-*` and `hero-tall-*` are 30 fps loops with AAC audio, cut from the
30-second widescreen and vertical Better Keep promos. Each size is encoded as
AV1 and H.264, except 1920 wide, which is AV1 only because H.264 would be 2.8 MB.
`site/src/data/hero-video.json` lists the sizes and bitrates the page chooses from. The `-poster.png` files are the 6.9-second frame of each
promo, and the site build makes the AVIF and WebP posters from them.

Regenerate everything with `site/scripts/encode_hero_video.sh`, then update the
bitrates in `hero-video.json`. The site build fails if they do not match.

`hero.en.vtt` captions the narration and applies to every size, because they share
one timeline. It stops where the loop does, before the promo's closing line.

Hosting caches `/media/**` for 24 hours under these names, so visitors can see the
previous promo for up to a day after it is replaced. Rename the files to avoid that.
