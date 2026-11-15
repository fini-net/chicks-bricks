# chicks-bricks

![GitHub Issues](https://img.shields.io/github/issues/fini-net/chicks-bricks)
![GitHub Pull Requests](https://img.shields.io/github/issues-pr/fini-net/chicks-bricks)
![GitHub License](https://img.shields.io/github/license/fini-net/chicks-bricks)
![GitHub watchers](https://img.shields.io/github/watchers/fini-net/chicks-bricks)

LEGO-related tools, data, and MOCs

## Tools

### part-colors

`bin/part-colors` answers the recoloring question: given a set of parts,
which colors is it available in? Give it a CSV of parts or a Rebrickable
set number and it reports:

- **Monochrome** - colors in which every part in the list is available
- **Near misses** - colors that almost work, with the parts that block them
- **Bottlenecks** - the parts with the fewest available colors, which
    constrain your palette the most

```shell
# MOC-61370 Business Card Holder, from the bundled example parts list
bin/part-colors --parts-file examples/business_card_holder.parts.csv \
    --title 'MOC-61370 Business Card Holder'

# any official set, straight from the Rebrickable API
bin/part-colors --set 850425-1
```

Output for the [Business Card Holder](https://rebrickable.com/mocs/MOC-61370/chicks/business-card-holder/):

```text
MOC-61370 Business Card Holder
11 distinct parts, 33 pieces

Monochrome: available for all 11 parts
  Black, Blue, Dark Bluish Gray, Green, Light Bluish Gray, Red, White, Yellow

Near misses (>= 50% coverage)
  Dark Blue             10/11 parts
                        missing: 3684
  Dark Turquoise        10/11 parts
                        missing: 3894
  Lime                  10/11 parts
                        missing: 3894
  ...

Bottlenecks (fewest available colors first)
  3894   x1   Technic Brick 1 x 6 with Holes  12 colors
  3895   x1   Technic Brick 1 x 12 with Holes  14 colors
  3684   x12  Slope Brick 75 2 x 2 x 3        19 colors
  ...
```

Requires a free [Rebrickable API key](https://rebrickable.com/users/) in
`REBRICKABLE_API_KEY` (sourcing a local `.env` works too). Responses are
cached under `data/cache/`, so repeat runs are instant and quota-free.
Rebrickable removed MOC inventories from API v3 in April 2020, so MOC parts
lists go through `--parts-file` (see [issue #2][issue-2]). There is much more in
`bin/part-colors --man`: JSON/CSV output, transparent-color filtering, a
rarity filter, and an offline mode.

[issue-2]: https://github.com/fini-net/chicks-bricks/issues/2

## Contributing

- [Code of Conduct](.github/CODE_OF_CONDUCT.md)
- [Contributing Guide](.github/CONTRIBUTING.md) includes a step-by-step guide to our
    [development process](.github/CONTRIBUTING.md#development-process).

## Support & Security

- [Getting Support](.github/SUPPORT.md)
- [Security Policy](.github/SECURITY.md)
