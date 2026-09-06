#!/usr/bin/env python3
"""Draw rime/spellless.ico, the tray and language-bar icon for the schema.

Weasel reads `schema/icon` from the schema and shows it in the notification
area, on the language bar and in the candidate panel, so the mode indicator
for an English input method can stop saying 中.  The drawing follows Weasel's
own zh.ico and en.ico -- an opaque white tile, a square frame inset 6.25% of
the canvas with a stroke 5.9% of it, one glyph inside -- so the three sit
together in the same tray without one of them looking foreign.

Deterministic: same font, same numbers, same bytes.  Run `make icon` after
changing anything here, and commit the .ico alongside.
"""

from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

REPO = Path(__file__).resolve().parent.parent
OUT = REPO / "rime" / "spellless.ico"

# The one Weasel uses for 中: dark enough to read on a white tile, and the
# same grey as the frame so the icon reads as one mark rather than two.
INK = (69, 69, 69, 255)
GROUND = (255, 255, 255, 255)

FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"

MASTER = 1024                  # drawn here, then reduced -- the frame lands on
SIZES = [16, 24, 32, 48, 64, 256]   # whole pixels at 16 and 32 either way
INSET = 0.0625                 # zh.ico: frame starts 16px into 256
STROKE = 0.0586                # zh.ico: 15px of 256
CAP = 0.66                     # glyph height as a fraction of the canvas


def master() -> Image.Image:
    im = Image.new("RGBA", (MASTER, MASTER), GROUND)
    d = ImageDraw.Draw(im)

    inset = round(INSET * MASTER)
    stroke = round(STROKE * MASTER)
    d.rectangle([inset, inset, MASTER - 1 - inset, MASTER - 1 - inset],
                outline=INK, width=stroke)

    # Size the S by its own ink rather than by the font's line height, which
    # carries space for accents and descenders this glyph never uses.
    target = CAP * MASTER
    size = round(target * 1.3)
    for _ in range(40):
        font = ImageFont.truetype(FONT, size)
        box = font.getbbox("S")
        height = box[3] - box[1]
        if abs(height - target) <= 1:
            break
        size = max(1, round(size * target / height))
    font = ImageFont.truetype(FONT, size)

    box = font.getbbox("S")
    width, height = box[2] - box[0], box[3] - box[1]
    d.text(((MASTER - width) / 2 - box[0], (MASTER - height) / 2 - box[1]),
           "S", font=font, fill=INK)
    return im


def main() -> None:
    big = master()
    frames = [big.resize((n, n), Image.LANCZOS) for n in SIZES]
    frames[-1].save(OUT, format="ICO", sizes=[(n, n) for n in SIZES],
                    append_images=frames[:-1])
    print(f"{OUT.relative_to(REPO)}  {OUT.stat().st_size} bytes  "
          f"{', '.join(f'{n}x{n}' for n in SIZES)}")


if __name__ == "__main__":
    main()
