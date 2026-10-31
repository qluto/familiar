#!/usr/bin/env python3
"""デフォルトのキャラクターパックを描く。依存は rsvg-convert と ffmpeg だけ。
出力: app/web/packs/default/clips/*.mp4 と clips.json（形式は docs/character-pack.md）"""
import json, math, shutil, subprocess, sys, tempfile
from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / "web/packs/default/clips"
W, H, FPS = 836, 1116, 12  # 絵は 12fps で描き、24fps の動画として書き出す

BASE = dict(ex=0, ey=0, eyes=1, shut=0, bx=1, sy=1, tilt=0, dots=0, spark=0, nod=0)
F = dict(BASE)
B = dict(BASE, eyes=0)
T = dict(BASE, ey=-16, ex=-12, tilt=-6, dots=1)
I = dict(BASE, ey=-8, sy=1.05, spark=1)
Q = dict(BASE, ex=16, tilt=9, sy=.98)


def mix(a, b, k):
    return {n: a[n] + (b[n] - a[n]) * k for n in a}


def ease(k):
    return .5 - .5 * math.cos(math.pi * k)


def path(keys):
    """(秒, ポーズ) の並びを、時刻を受け取ってポーズを返す関数にする。"""
    def at(t):
        for (t0, p0), (t1, p1) in zip(keys, keys[1:]):
            if t <= t1:
                return mix(p0, p1, ease((t - t0) / (t1 - t0)))
        return keys[-1][1]
    return keys[-1][0], at


def sway(hub, sec, **peak):
    """同じポーズへ戻る動き。"""
    return path([(0, hub), (sec / 2, dict(hub, **peak)), (sec, hub)])


def blink(hub):
    return path([(0, hub), (.17, dict(hub, shut=1)), (.38, hub)])


def think(step):
    return path([(0, T), (.9, dict(T, ex=T["ex"] + step, tilt=T["tilt"] + step / 3)), (1.8, T)])


TURN = dict(BASE, ex=70, eyes=0, bx=.92)
CLIPS = {
    "blink": blink(F), "blink_t": blink(T), "blink_q": blink(Q),
    "idle_f": sway(F, 2, sy=1.03), "idle_b": sway(B, 2, sy=1.03),
    "look": path([(0, F), (.5, dict(F, ex=-26)), (1.2, dict(F, ex=-26)), (1.7, dict(F, ex=26)), (2.3, dict(F, ex=26)), (2.8, F)]),
    "stretch": path([(0, F), (.6, dict(F, sy=1.16, bx=.94, shut=.7)), (1.3, dict(F, sy=1.16, bx=.94, shut=.7)), (1.9, dict(F, sy=.96, bx=1.03)), (2.3, F)]),
    "turn_away": path([(0, F), (.7, TURN), (1.3, B)]),
    "turn_back": path([(0, B), (.6, TURN), (1.3, F)]),
    "think_in": path([(0, F), (.9, T)]), "think_out": path([(0, T), (.9, F)]),
    "think_a": think(-14), "think_b": think(16),
    "idea": path([(0, T), (.5, dict(T, sy=.93, bx=1.04)), (.95, I), (1.2, I)]),
    "idea_out": path([(0, I), (.9, F)]),
    "ask_in": path([(0, F), (.9, Q)]), "idea_ask": path([(0, I), (1, Q)]),
    "ask_wait": sway(Q, 2.2, tilt=12, ex=20),
    "ask_ok": path([(0, Q), (.35, dict(Q, nod=1)), (.7, dict(Q, nod=0)), (1, dict(Q, nod=1)), (1.7, F)]),
    "ask_out": path([(0, Q), (1, F)]),
}

BODY = "M0 -292C14 -244 62 -214 104 -166C136 -130 150 -98 150 -66C150 -8 84 0 0 0C-84 0 -150 -8 -150 -66C-150 -118 -96 -160 -52 -204C-22 -234 -6 -258 0 -292Z"
SPARK = "M0 -46C5 -14 14 -5 46 0C14 5 5 14 0 46C-5 14 -14 5 -46 0C-14 -5 -5 -14 0 -46Z"


def svg(p):
    s = 1.45  # 窓の下端に座る
    ry = 19 * max(.08, 1 - p["shut"])
    eyes = "".join(f'<ellipse cx="{x + p["ex"]:.1f}" cy="{-92 + p["ey"]:.1f}" rx="15" ry="{ry:.1f}" fill="#3b3a36"/>' for x in (-48, 48))
    dots = "".join(f'<circle cx="{118 + i * 34}" cy="{-250 - i * 26}" r="{8 + i * 3}" fill="#5c7f4f" opacity="{p["dots"]:.2f}"/>' for i in range(3))
    spark = f'<path d="{SPARK}" fill="#d9b45b" transform="translate(150 -276) scale({max(p["spark"], .001):.3f})"/>'
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">
<g transform="translate({W / 2} {H - 56}) scale({s}) rotate({p["tilt"]:.2f}) scale({p["bx"]:.3f} {p["sy"] - .05 * p["nod"]:.3f})">
<path d="{BODY}" fill="#fffdf7" stroke="#5c7f4f" stroke-width="7" stroke-linejoin="round"/>
<g opacity="{p["eyes"]:.2f}" transform="translate(0 {12 * p["nod"]:.1f})">{eyes}</g>{dots}{spark}
</g></svg>'''


def render(name, tmp):
    sec, at = CLIPS[name]
    count = max(2, round(sec * FPS) + 1)
    frames = tmp / name
    frames.mkdir()
    for i in range(count):
        subprocess.run(["rsvg-convert", "-o", frames / f"{i:03}.png"], input=svg(at(sec * i / (count - 1))).encode(), check=True)
    # 左半分に乗算済みの色（黒の上に重ねた絵と同じ）、右半分にアルファを並べる
    graph = (f"[0]format=rgba,split[c][a];color=black:s={W}x{H}:r={FPS}[bk];[bk][c]overlay=shortest=1,format=rgb24[k];"
             "[a]alphaextract,format=rgb24[m];[k][m]hstack,format=rgb24")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-framerate", str(FPS), "-i", frames / "%03d.png", "-filter_complex", graph,
                    "-r", str(FPS * 2), "-c:v", "h264_videotoolbox", "-b:v", "2M", "-allow_sw", "1", "-pix_fmt", "yuv420p",
                    "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
                    "-movflags", "+faststart", "-an", OUT / f"{name}.mp4"], check=True)
    # 24fps で 1 コマおきに絵が変わる
    total = (count - 1) * 2 + 1
    return {"frames": total, "dur": total / (FPS * 2), "draw": list(range(0, total, 2))}


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True)
    with tempfile.TemporaryDirectory() as tmp:
        meta = {name: render(name, Path(tmp)) for name in CLIPS}
    (OUT / "clips.json").write_text(json.dumps(meta))
    print(f"{len(meta)} clips, {sum(p.stat().st_size for p in OUT.iterdir()) / 1e6:.1f} MB", file=sys.stderr)


if __name__ == "__main__":
    main()
