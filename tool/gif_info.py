"""Report basic metadata of an animated GIF (frames, size, duration, fps).

Read-only helper used to decide how far to shrink docs/media/demo.gif so that
GitHub's camo image proxy can serve it. Not part of the app build.
"""

import sys
from PIL import Image


def main(path: str) -> None:
    im = Image.open(path)
    durations = []
    for i in range(im.n_frames):
        im.seek(i)
        durations.append(im.info.get("duration", 0))

    total_ms = sum(durations)
    total_s = total_ms / 1000.0
    avg_ms = total_ms / len(durations) if durations else 0
    print(f"path        : {path}")
    print(f"size        : {im.size[0]} x {im.size[1]}")
    print(f"frames      : {im.n_frames}")
    print(f"total       : {total_s:.2f} s")
    print(f"avg delay   : {avg_ms:.1f} ms  (~{1000 / avg_ms:.1f} fps)" if avg_ms else "avg delay: n/a")
    print(f"unique delay: {sorted(set(durations))[:10]}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "docs/media/demo.gif")
