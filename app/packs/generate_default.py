#!/usr/bin/env python3
"""デフォルトのキャラクターパックを描く。依存は rsvg-convert と ffmpeg だけ。
出力: app/web/packs/default/clips/*.mp4 と clips.json（形式は docs/character-pack.md）"""
import json, math, shutil, subprocess, sys, tempfile
from pathlib import Path

OUT = Path(__file__).resolve().parents[1] / "web/packs/default/clips"
W, H, FPS = 836, 1116, 12  # 絵は 12fps で描き、24fps の動画として書き出す

BASE = dict(ex=0, ey=0, eyes=1, shut=0, bx=1, sy=1, tilt=0, dots=0, spark=0, nod=0, phone=0, px=0, py=150, pr=0)
F = dict(BASE)
B = dict(BASE, eyes=0)
T = dict(BASE, ey=-16, ex=-12, tilt=-6, dots=1)
I = dict(BASE, ey=-8, sy=1.05, spark=1)
Q = dict(BASE, ex=16, tilt=9, sy=.98)
P = dict(BASE, ey=10, shut=.35, phone=1, py=0)  # スマホを両手で持ち、画面を見る
R = dict(BASE, ex=14, tilt=9, sy=.98, phone=1, px=150, py=-50, pr=10)  # スマホを横に掲げ、問いかける


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
    "blink_r": blink(R),
    "nod": path([(0, F), (.3, dict(F, nod=1)), (.6, F), (.8, F)]),
    "phone_in": path([(0, F), (.9, P)]),
    "phone_a": path([(0, P), (.4, dict(P, py=-6)), (.6, P), (1, dict(P, py=-6, ex=-6)), (1.2, P), (1.8, P)]),
    "phone_out": path([(0, P), (.3, dict(P, nod=1)), (.5, P), (1.3, F)]),
    "phone_ask": path([(0, P), (1, R)]),
    "reply_wait": sway(R, 2.2, tilt=12, ex=18),
    "reply_got": path([(0, R), (.35, dict(R, nod=1)), (.6, R), (1.4, P)]),
    "reply_out": path([(0, R), (1.2, F)]),
}

SPARK = "M0 -46C5 -14 14 -5 46 0C14 5 5 14 0 46C-5 14 -14 5 -46 0C-14 -5 -5 -14 0 -46Z"
SIZE = 260  # アプリアイコンと同じ角丸四角。窓は縦横 2 倍の座標で描く
CX, CY = 362, H - 34 - SIZE / 2  # 吹き出しの尾の先に寄せ、下端を吹き出しに揃える


def svg(p):
    eye_h = 66 * max(.13, 1 - p["shut"])
    eyes = "".join(f'<rect x="{x - 13 + p["ex"]:.1f}" y="{p["ey"] - eye_h / 2:.1f}" width="26" height="{eye_h:.1f}" rx="13" fill="#fffdf7"/>' for x in (-44, 44))
    dots = "".join(f'<circle cx="{150 + i * 34}" cy="{-150 - i * 30}" r="{8 + i * 3}" fill="#5c7f4f" opacity="{p["dots"]:.2f}"/>' for i in range(3))
    spark = f'<path d="{SPARK}" fill="#d9b45b" transform="translate(165 -165) scale({max(p["spark"] * 1.15, .001):.3f})"/>'
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">
<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#6f9460"/><stop offset="1" stop-color="#4a6b40"/></linearGradient></defs>
<g transform="translate({CX} {CY}) rotate({p["tilt"]:.2f}) scale({p["bx"]:.3f} {p["sy"] - .05 * p["nod"]:.3f})">
<rect x="{-SIZE / 2}" y="{-SIZE / 2}" width="{SIZE}" height="{SIZE}" rx="72" fill="url(#g)"/>
<g opacity="{p["eyes"]:.2f}" transform="translate(0 {12 * p["nod"]:.1f})">{eyes}</g>{dots}{spark}
<g opacity="{min(1, p["phone"] * 1.5):.2f}" transform="translate({p["px"]:.1f} {92 + p["py"]:.1f}) rotate({p["pr"]:.2f})">
<rect x="-32" y="-50" width="64" height="100" rx="14" fill="#2f4229" stroke="#fffdf7" stroke-width="6"/><circle cx="-14" cy="-32" r="6" fill="#8fb27f"/></g>
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
