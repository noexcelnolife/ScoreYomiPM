"""Compare the colour statistics of a source GIF and a re-encoded GIF.

Why this exists: the first shrink pass produced a README GIF whose colours
looked wrong, so the question "is the palette or the dithering at fault?" needs
numbers instead of impressions. For every sampled timestamp this prints the
mean RGB of the source frame and of the matching output frame, plus the mean
absolute per-channel error. Read-only: it never writes to the repository.

Usage:
    python tool/gif_color_check.py <src.gif> <dst.gif> [samples]
"""

import sys

from PIL import Image, ImageChops, ImageStat


def _frame_at(im, seconds: float) -> Image.Image:
    """Return the RGB frame shown at the given time, honouring cumulative delay."""
    target = seconds * 1000.0
    elapsed = 0.0
    for index in range(im.n_frames):
        im.seek(index)
        elapsed += im.info.get("duration", 60)
        if elapsed >= target:
            return im.convert("RGB")
    im.seek(im.n_frames - 1)
    return im.convert("RGB")


def _mean_rgb(im: Image.Image) -> tuple[float, float, float]:
    stat = ImageStat.Stat(im)
    return tuple(round(value, 1) for value in stat.mean)


def _abs_error(src: Image.Image, dst: Image.Image) -> tuple[float, float, float]:
    """Mean absolute per-channel difference between two same-size RGB images."""
    stat = ImageStat.Stat(ImageChops.difference(src, dst))
    return tuple(round(value, 1) for value in stat.mean)


def main() -> None:
    src_path = sys.argv[1] if len(sys.argv) > 1 else "docs/media/demo.gif"
    dst_path = sys.argv[2] if len(sys.argv) > 2 else "docs/media/demo.gif"
    samples = int(sys.argv[3]) if len(sys.argv) > 3 else 6

    src = Image.open(src_path)
    dst = Image.open(dst_path)
    total = 0.0
    for index in range(src.n_frames):
        src.seek(index)
        total += src.info.get("duration", 60)
    total /= 1000.0
    print(f"src={src_path} {src.size} frames={src.n_frames} total={total:.2f}s")
    print(f"dst={dst_path} {dst.size} frames={dst.n_frames}")

    size = dst.size
    for step in range(samples):
        seconds = total * (step + 0.5) / samples
        src_frame = _frame_at(src, seconds)
        dst_frame = _frame_at(dst, seconds)
        src_mean = _mean_rgb(src_frame)
        dst_mean = _mean_rgb(dst_frame)
        scaled = src_frame.resize(size, Image.LANCZOS)
        err = _abs_error(scaled, dst_frame)
        print(
            f"t={seconds:5.2f}s src_mean={src_mean} dst_mean={dst_mean} "
            f"resized_err={err}"
        )


if __name__ == "__main__":
    main()
