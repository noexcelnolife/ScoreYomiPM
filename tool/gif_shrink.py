"""Re-encode an animated GIF small enough for a GitHub README.

Why this exists: GitHub serves README images through its camo proxy and is
reported to fail or refuse around the 5 MB mark, while the original demo.gif is
~35 MB at 15 fps / 54 s. Shrinking needs frame dropping (with delay merging),
downscaling and palette reduction. ffmpeg/gifsicle are not installed here, so
Pillow does it. Not part of the app build.

Usage:
    python tool/gif_shrink.py <src> <dst> [fps] [colors] [width] [dither]

Frames are chosen by cumulative time (so fps is real, not "every Nth frame"),
and each kept frame absorbs the delay of the frames dropped before it, keeping
playback speed faithful. A single global palette is built from a sample of the
video and reused for every frame; per-frame adaptive palettes look marginally
better but cost ~2x the bytes, which matters at this size.

Pass "none" as the last argument to disable dithering. Dithering scatters two
adjacent palette colours over flat UI areas, which reads as speckle/grain on
screenshots, so "none" is usually better for app captures.
"""

import sys
from PIL import Image


def _palette(im, colors: int, width: int) -> Image.Image:
    """Build one shared palette from a downscaled sample of the whole GIF.

    The sample is a contact sheet: frames are sampled across the whole clip and
    tiled without gaps. The canvas must be sized from the actual sampled count
    (an earlier version used a fixed 240px height, so every tile past the first
    row was pasted outside the canvas and silently dropped, which left the
    palette built from only the first 4 frames and shifted the colours).
    """
    im.seek(0)
    first = im.convert("RGB")
    scale = min(width / first.width, 240 / first.height)
    cell = (max(1, int(first.width * scale)), max(1, int(first.height * scale)))
    step = max(1, im.n_frames // 24)
    picks = list(range(0, im.n_frames, step))
    columns = 4
    rows = (len(picks) + columns - 1) // columns
    sample = Image.new("RGB", (cell[0] * columns, cell[1] * rows))
    for slot, index in enumerate(picks):
        im.seek(index)
        frame = im.convert("RGB").resize(cell, Image.LANCZOS)
        sample.paste(frame, ((slot % columns) * cell[0], (slot // columns) * cell[1]))
    return sample.quantize(colors=colors, method=Image.MEDIANCUT)


def _frames(im, palette, fps: float, width: int, dither):
    """Return downscaled frames and their delays, chosen by cumulative time."""
    interval = 1000.0 / fps
    frames = []
    durations = []
    carried = 0.0
    for index in range(im.n_frames):
        im.seek(index)
        carried += im.info.get("duration", 60)
        if carried < interval and index != im.n_frames - 1:
            continue
        frame = im.convert("RGB")
        if frame.width > width:
            frame = frame.resize(
                (width, round(frame.height * width / frame.width)), Image.LANCZOS
            )
        frames.append(frame.quantize(palette=palette, dither=dither))
        durations.append(round(carried))
        carried = 0.0
    return frames, durations


def _save(frames, durations, dst: str) -> float:
    """Write the GIF and return its size in MB."""
    frames[0].save(
        dst,
        save_all=True,
        append_images=frames[1:],
        duration=durations,
        loop=0,
        optimize=True,
        disposal=2,
    )
    with open(dst, "rb") as handle:
        return len(handle.read()) / 1024 / 1024


def main() -> None:
    src = sys.argv[1] if len(sys.argv) > 1 else "docs/media/demo.gif"
    dst = sys.argv[2] if len(sys.argv) > 2 else "docs/media/demo_small.gif"
    fps = float(sys.argv[3]) if len(sys.argv) > 3 else 10.0
    colors = int(sys.argv[4]) if len(sys.argv) > 4 else 64
    width = int(sys.argv[5]) if len(sys.argv) > 5 else 320
    # Dithering scatters 2 adjacent palette colours over flat UI areas, which
    # reads as speckle/grain on screenshots. "none" keeps the flat colours.
    dither = Image.NONE if len(sys.argv) > 6 and sys.argv[6] == "none" else Image.FLOYDSTEINBERG

    im = Image.open(src)
    palette = _palette(im, colors, width)
    frames, durations = _frames(im, palette, fps, width, dither)
    size = _save(frames, durations, dst)
    print(f"fps={fps:g} colors={colors} width={width} frames={len(frames)}")
    print(f"out={dst} size={size:.2f} MB")


if __name__ == "__main__":
    main()
