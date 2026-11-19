# Social preview prompt

The [social media preview](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/customizing-your-repositorys-social-media-preview) is the card that shows up when somebody pastes a link to this repo into Slack, X, or Discord. GitHub stores it in repo settings rather than in the repo itself, so it's the one bit of repo branding that doesn't travel with a clone - exactly the kind of thing that gets re-derived from scratch every couple of years if nobody writes it down. This file is the write-it-down: a Nano Banana 2.1 prompt, the crop that turns model output into GitHub's exact spec, and the upload step.

## Model settings

- Model: Nano Banana 2.1 (`gemini-nano-banana-2.1`)
- Aspect ratio: 16:9, the closest the model gets to GitHub's 2:1 (see
  [Why 16:9](#why-169))
- Resolution: 2K, which lands at 2752×1536 (1K works too; 2K just gives
  the final resize more pixels to work with)

## The prompt

Paste this into [AI Studio](https://aistudio.google.com) with the
settings above:

```text
Wide landscape social media preview banner for a GitHub repository. A dark
charcoal studio backdrop, nearly uniform, with a very subtle soft vignette.
In the lower half of the frame, a single tidy horizontal row of classic
interlocking plastic toy building bricks, photographed at a slight
three-quarter angle so the round studs on top are visible. The bricks step
through a smooth color gradient from left to right: red, orange, yellow,
lime green, green, azure, blue, and purple. They sit on a dark glossy
surface with soft reflections and gentle contact shadows. Photorealistic
studio product photography, macro sharpness, soft diffused lighting.
Centered in the upper half of the frame, large bold white geometric
sans-serif text reading exactly "chicks-bricks", and directly beneath it a
smaller light gray subtitle reading exactly "LEGO tools, data & MOCs". The
text is crisp, high-contrast, and legible at small sizes. All content
stays within the middle 80% of the frame, with generous empty dark margins
on all four edges, so the image survives a center crop to a 2:1 aspect
ratio. No other text, no logos, no watermarks, no interface elements, no
people.
```

Two choices in there are deliberate. The near-uniform dark backdrop means
the top-and-bottom crop below is invisible, whatever it happens to trim.
And it says "interlocking plastic toy building bricks" rather than naming
a brand: the model knows exactly what's meant - a stud on top of every
brick - and the card stays trademark-clean.

## From generation to upload

Save the raw generation as `preview.png`.

### Crop and resize

Center-crop the middle 2:1 strip out of the generation, then resize to
exactly 1280×640. The numbers by generation size:

| Generation | Crop to | Resize to |
| --- | --- | --- |
| 1K (1376×768) | 1376×688 | 1280×640 |
| 2K (2752×1536) | 2752×1376 | 1280×640 |
| 4K (5504×3072) | 5504×2752 | 1280×640 |

Mind the argument order: `sips` takes height then width, ImageMagick
geometry takes width then height. That asymmetry has bitten smarter
people than us.

With `sips`, which ships with every Mac (2K shown):

```shell
# for a 1K generation, use -c 688 1376 instead
sips -c 1376 2752 preview.png --out social-preview.png
sips -z 640 1280 social-preview.png
```

With ImageMagick, one command does both steps:

```shell
# for a 1K generation, use -crop 1376x688+0+0 instead
magick preview.png -gravity center -crop 2752x1376+0+0 +repage -resize 1280x640 social-preview.png
```

### Check the size

GitHub's limit is a surprisingly tight 1 MB (PNG, JPG, or GIF), with a
floor of 640×320. The dark backdrop keeps the PNG small - usually a few
hundred KB - but check:

```shell
ls -lh social-preview.png
```

If it somehow lands over 1 MB, trade it for a JPG:

```shell
sips -s format jpeg -s formatOptions 90 social-preview.png --out social-preview.jpg
```

### Upload

Repo Settings → General → "Social preview" → Edit → upload → Save.
There's nothing to commit - the card lives in GitHub's settings - though
keeping a copy of the final image next to this prompt (say,
`docs/social-preview.png`) gives the next person a look at what the
recipe produces.

### Verify

Paste the repo URL into a Slack DM or a private Discord channel and
eyeball the card. If this re-uploads over an old preview, give the
caches a few minutes before deciding the upload didn't take.

## Why 16:9

GitHub's recommendation is 1280×640 - a 2:1 ratio - and its floor is
640×320. Nano Banana 2.1 offers fourteen aspect ratios, none of them
2:1. The two closest:

| Aspect ratio | Actual | 1K output | Distance from 2:1 |
| --- | --- | --- | --- |
| 16:9 | 1.78:1 | 1376×768 | 0.22 |
| 21:9 | 2.33:1 | 1584×672 | 0.33 |

So 16:9 it is: generate wide, crop the top and bottom off the middle,
and resize down. Every step only shrinks the image - no upscaling, no
softening. The alternative, feeding GitHub the 16:9 file as-is, hands the
cropping to whatever platform renders the card, which is how titles lose
their ascenders.

## Alternate concepts

The gradient row is the intended look, but the same settings and crop
steps work with a different scene.

### Terminal and bricks

For leaning into the command-line nature of the tools:

```text
Wide landscape social media preview banner for a GitHub repository. A
dark computer terminal window fills the frame, softly blurred and
glowing, showing green and white monospace text like the output of a
color report: rows of color names with counts, a command prompt at the
bottom. In the foreground, sharply in focus, a loose arrangement of
classic interlocking plastic toy building bricks in red, orange, yellow,
blue, and green sits on the desk in front of the screen. Soft studio
lighting, shallow depth of field, photorealistic. Near the top of the
frame, bold white sans-serif text reading exactly "chicks-bricks", with a
smaller light gray subtitle reading exactly "LEGO tools, data & MOCs".
All content stays within the middle 80% of the frame, so a center crop
to a 2:1 aspect ratio loses nothing. No text other than the terminal
output and the title, no logos, no people.
```

### MOC homage

For the deep cut - the [Business Card Holder, MOC-61370](https://rebrickable.com/mocs/MOC-61370/chicks/business-card-holder/) that serves as the running example throughout the README:

```text
Wide landscape social media preview banner for a GitHub repository. On a
dark walnut desk sits a small business card holder built entirely from
classic interlocking plastic toy building bricks, every brick the same
deep red, with a few plain white business cards fanned upright in its
slot. A few loose spare bricks rest nearby. Photorealistic studio
photography, warm soft light from the upper left, gentle shadows,
shallow depth of field, dark moody background. Near the top of the
frame, bold white sans-serif text reading exactly "chicks-bricks", with
a smaller light gray subtitle reading exactly "LEGO tools, data & MOCs".
All content stays within the middle 80% of the frame, so a center crop
to a 2:1 aspect ratio loses nothing. No other text, no logos, no
people.
```

## Notes

- Every Nano Banana generation carries an invisible
  [SynthID](https://deepmind.google/technologies/synthid/) watermark
  baked into the pixels. Harmless for a social card, but worth knowing
  before anybody goes looking for a pristine original.
- The middle-80% instruction in each prompt exists because every consumer
  crops the card a little differently - our 2:1 crop first, then whatever
  Slack, X, or Discord do with the leftovers. Centered content survives
  all of it.
- For prompt tweaks, Google's own
  [prompting guide for Nano Banana](https://cloud.google.com/blog/products/ai-machine-learning/ultimate-prompting-guide-for-nano-banana)
  is the best map of how the model reads phrasing.
