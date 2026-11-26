#!/usr/bin/env python3
"""
Deterministic High-DPI 9-Slice TGA Art Kit Generator for ForeverSuite v5.0.
Generates 100% original, supersampled, 32-bit uncompressed straight-alpha POT TGA textures
into v2/ForeverSuite_Media_Assets/UI/ plus assets.manifest.json.
"""
import hashlib
import json
import math
import os
import random
from PIL import Image, ImageDraw, ImageFilter

OUT_DIR = "/Users/choyoungseo/workspace/ForeverSuite/v2/ForeverSuite_Media_Assets/UI"
os.makedirs(OUT_DIR, exist_ok=True)


def clamp(v, lo=0, hi=255):
    return max(lo, min(hi, int(round(v))))


def lerp(a, b, t):
    return a + (b - a) * t


def lerp_rgb(c1, c2, t):
    return (
        clamp(lerp(c1[0], c2[0], t)),
        clamp(lerp(c1[1], c2[1], t)),
        clamp(lerp(c1[2], c2[2], t)),
    )


def save_tga(img: Image.Image, filename: str, meta: dict, manifest: dict):
    path = os.path.join(OUT_DIR, filename)
    rgba = img.convert("RGBA")
    # Save uncompressed 32-bit TGA (WoW 1.60.1 native straight-alpha support)
    rgba.save(path, format="TGA", compression=None)
    with open(path, "rb") as f:
        data = f.read()
    manifest[filename] = {
        "width": rgba.width,
        "height": rgba.height,
        "bytes": len(data),
        "md5": hashlib.md5(data).hexdigest(),
        **meta,
    }


def make_window_frame(size: int, shadow_pad: int, theme: str):
    """Sculpted 9-slice window frame with real baked Gaussian outer drop shadow."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    # 1. Real soft outer drop shadow (DialogueUI-style baked shadow)
    sh = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sh)
    r_outer = max(10, size // 32)
    sd.rounded_rectangle(
        [shadow_pad - 2, shadow_pad, size - shadow_pad + 2, size - shadow_pad + 4],
        radius=r_outer,
        fill=(0, 0, 0, 205),
    )
    sh = sh.filter(ImageFilter.GaussianBlur(radius=max(6, shadow_pad // 2)))
    img = Image.alpha_composite(img, sh)

    # 2. Outer metallic rim with vertical gradient
    box_l, box_t = shadow_pad, shadow_pad
    box_r, box_b = size - shadow_pad - 1, size - shadow_pad - 1
    rim_w = 6 if size >= 512 else 4
    body_h = max(1, box_b - box_t)

    if theme == "gold":
        rim_top = (232, 198, 106)
        rim_mid = (162, 124, 52)
        rim_bot = (104, 78, 32)
        inner_top = (28, 25, 31)
        inner_bot = (14, 13, 17)
        spec_col = (255, 240, 196, 84)
        corner_hi = (248, 218, 130, 235)
        corner_lo = (128, 96, 38, 220)
    else:
        rim_top = (76, 84, 98)
        rim_mid = (52, 58, 68)
        rim_bot = (34, 38, 46)
        inner_top = (22, 24, 30)
        inner_bot = (13, 15, 19)
        spec_col = (205, 220, 245, 48)
        corner_hi = (118, 134, 158, 190)
        corner_lo = (48, 54, 66, 180)

    # Render rounded outer rim mask & vertical metallic fill
    rim_mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(rim_mask).rounded_rectangle([box_l, box_t, box_r, box_b], radius=r_outer, fill=255)
    rim_grad = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    rp = rim_grad.load()
    for y in range(box_t, box_b + 1):
        t = (y - box_t) / body_h
        col = lerp_rgb(rim_top, rim_mid, t * 2) if t < 0.5 else lerp_rgb(rim_mid, rim_bot, (t - 0.5) * 2)
        for x in range(box_l, box_r + 1):
            rp[x, y] = (col[0], col[1], col[2], 255)
    rim_grad.putalpha(rim_mask)
    img = Image.alpha_composite(img, rim_grad)

    # 3. Dark recessed groove inside outer rim (gives luxury double-bevel depth)
    gl, gt, gr, gb = box_l + rim_w, box_t + rim_w, box_r - rim_w, box_b - rim_w
    groove_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(groove_layer).rounded_rectangle(
        [gl, gt, gr, gb], radius=max(4, r_outer - rim_w), fill=(7, 6, 9, 252)
    )
    img = Image.alpha_composite(img, groove_layer)

    # 4. Warm obsidian interior with subtle vertical depth + deterministic micro-grain
    il, it, ir, ib = gl + 2, gt + 2, gr - 2, gb - 2
    inner_mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(inner_mask).rounded_rectangle(
        [il, it, ir, ib], radius=max(3, r_outer - rim_w - 2), fill=244
    )
    rng = random.Random(50100 if theme == "gold" else 50101)
    inner_img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ip = inner_img.load()
    ih = max(1, ib - it)
    for y in range(it, ib + 1):
        t = (y - it) / ih
        base = lerp_rgb(inner_top, inner_bot, t)
        for x in range(il, ir + 1):
            n = rng.randint(-2, 2)
            ip[x, y] = (clamp(base[0] + n), clamp(base[1] + n), clamp(base[2] + n), 244)
    inner_img.putalpha(inner_mask)
    img = Image.alpha_composite(img, inner_img)

    # 5. Crisp top inner specular + bottom inner shadow + sculpted corner filigree brackets
    detail = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    dd = ImageDraw.Draw(detail)
    dd.line([(il + 12, it + 1), (ir - 12, it + 1)], fill=spec_col, width=2)
    dd.line([(il + 12, ib - 1), (ir - 12, ib - 1)], fill=(0, 0, 0, 140), width=2)

    # Corner L-ornaments strictly inside the 9-slice corner margins (never stretched)
    clen = 32 if size >= 512 else 18
    cthick = 4 if size >= 512 else 3
    corners = [
        # Top-Left
        [(box_l + 2, box_t + 2, box_l + clen, box_t + 2 + cthick),
         (box_l + 2, box_t + 2, box_l + 2 + cthick, box_t + clen)],
        # Top-Right
        [(box_r - clen, box_t + 2, box_r - 2, box_t + 2 + cthick),
         (box_r - 2 - cthick, box_t + 2, box_r - 2, box_t + clen)],
        # Bottom-Left
        [(box_l + 2, box_b - 2 - cthick, box_l + clen, box_b - 2),
         (box_l + 2, box_b - clen, box_l + 2 + cthick, box_b - 2)],
        # Bottom-Right
        [(box_r - clen, box_b - 2 - cthick, box_r - 2, box_b - 2),
         (box_r - 2 - cthick, box_b - clen, box_r - 2, box_b - 2)],
    ]
    for idx, rects in enumerate(corners):
        col = corner_hi if idx < 2 else corner_lo
        for rect in rects:
            dd.rectangle(rect, fill=col)

    img = Image.alpha_composite(img, detail)
    return img


def make_button_9slice(variant: str):
    """256x128 true POT tactile 9-slice RPG button (normal / brass / crimson)."""
    w, h = 256, 128
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    palettes = {
        "normal": ((52, 48, 54), (30, 28, 33), (126, 100, 56), (62, 50, 30), (255, 240, 200, 56)),
        "brass":  ((102, 74, 28), (58, 40, 14), (232, 194, 96), (138, 102, 38), (255, 244, 198, 110)),
        "crimson": ((118, 34, 38), (64, 16, 20), (206, 86, 86), (112, 36, 38), (255, 200, 195, 78)),
    }
    top_c, bot_c, rim_hi, rim_lo, spec = palettes[variant]
    pad = 4
    rad = 12

    # Outer rim
    rmask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(rmask).rounded_rectangle([pad, pad, w - pad - 1, h - pad - 1], radius=rad, fill=255)
    rim = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    rp = rim.load()
    for y in range(pad, h - pad):
        t = (y - pad) / max(1, h - 2 * pad - 1)
        c = lerp_rgb(rim_hi, rim_lo, t)
        for x in range(pad, w - pad):
            rp[x, y] = (c[0], c[1], c[2], 245)
    rim.putalpha(rmask)
    img = Image.alpha_composite(img, rim)

    # Inner metallic face
    ip = pad + 3
    imask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(imask).rounded_rectangle([ip, ip, w - ip - 1, h - ip - 1], radius=max(4, rad - 3), fill=250)
    face = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    fp = face.load()
    for y in range(ip, h - ip):
        t = (y - ip) / max(1, h - 2 * ip - 1)
        c = lerp_rgb(top_c, bot_c, t)
        for x in range(ip, w - ip):
            fp[x, y] = (c[0], c[1], c[2], 250)
    face.putalpha(imask)
    img = Image.alpha_composite(img, face)

    # Crisp top specular + bottom inner shadow
    ov = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    od = ImageDraw.Draw(ov)
    od.line([(ip + 8, ip + 1), (w - ip - 9, ip + 1)], fill=spec, width=2)
    od.line([(ip + 8, h - ip - 2), (w - ip - 9, h - ip - 2)], fill=(0, 0, 0, 130), width=2)
    return Image.alpha_composite(img, ov)


def make_statusbar_textures():
    """Details!/ElvUI-grade smooth glossy statusbar fill + dark groove + crisp border."""
    # Fill (128x32): neutral bright white with subtle vertical gloss curve (tintable via SetVertexColor!)
    fill = Image.new("RGBA", (128, 32), (255, 255, 255, 255))
    fp = fill.load()
    for y in range(32):
        t = y / 31.0
        # Top subtle sheen highlight -> smooth rich mid -> subtle bottom shade
        if t < 0.35:
            lum = lerp(255, 232, t / 0.35)
        else:
            lum = lerp(232, 168, (t - 0.35) / 0.65)
        v = clamp(lum)
        for x in range(128):
            fp[x, y] = (v, v, v, 255)

    # Groove (128x32): recessed dark bar well
    groove = Image.new("RGBA", (128, 32), (0, 0, 0, 210))
    gp = groove.load()
    for y in range(32):
        t = y / 31.0
        lum = clamp(lerp(8, 22, t))
        for x in range(128):
            gp[x, y] = (lum, lum, clamp(lum + 3), 215)

    # Border (256x64): crisp thin bronze-compatible neutral border
    border = Image.new("RGBA", (256, 64), (0, 0, 0, 0))
    bd = ImageDraw.Draw(border)
    bd.rounded_rectangle([1, 1, 254, 62], radius=6, outline=(225, 210, 170, 220), width=3)
    bd.rounded_rectangle([4, 4, 251, 59], radius=4, outline=(0, 0, 0, 180), width=2)
    return fill, groove, border


def make_icon_ring():
    """64x64 crisp neutral white icon frame with chamfered corner ticks (quality tintable)."""
    img = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, 63, 63], outline=(0, 0, 0, 230), width=2)
    d.rectangle([2, 2, 61, 61], outline=(245, 240, 228, 255), width=2)
    # Corner accent ticks
    for cx, cy in [(2, 2), (56, 2), (2, 56), (56, 56)]:
        d.rectangle([cx, cy, cx + 5, cy + 5], fill=(255, 255, 255, 255))
    d.rectangle([4, 4, 59, 59], outline=(0, 0, 0, 180), width=1)
    return img


def make_scrim_radial():
    """256x256 smooth elliptical radial scrim for borderless L0 HUD readability."""
    size = 256
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    px = img.load()
    half = (size - 1) / 2.0
    for y in range(size):
        dy = (y - half) / half
        for x in range(size):
            dx = (x - half) / half
            r = math.sqrt(dx * dx + dy * dy)
            if r < 1.0:
                # Smoothstep falloff: strong readable core, feather-soft zero edge
                s = 1.0 - r
                a = s * s * (3.0 - 2.0 * s)
                px[x, y] = (10, 9, 13, clamp(a * 170))
    return img


def make_combo_gems():
    """128x128 sculpted faceted ruby-gold combo orb (Lit, Empty socket, ADD Glow)."""
    size = 128
    half = (size - 1) / 2.0

    lit = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    empty = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    lp, ep, gp = lit.load(), empty.load(), glow.load()

    for y in range(size):
        dy = (y - half) / half
        for x in range(size):
            dx = (x - half) / half
            r = math.sqrt(dx * dx + dy * dy)

            # Glow texture (ADD blend)
            if r < 1.0:
                s = (1.0 - r) ** 2.2
                gp[x, y] = (255, 196, 84, clamp(s * 220))

            if r > 0.88:
                continue

            # Outer dark drop rim
            if r > 0.80:
                t = (0.88 - r) / 0.08
                a = clamp(t * 220)
                lp[x, y] = (12, 9, 6, a)
                ep[x, y] = (10, 9, 11, a)
                continue

            # Sculpted antique gold bezel ring
            if r > 0.66:
                bt = (r - 0.66) / 0.14
                # Highlight at top-left, darker at bottom-right
                light = clamp(185 - (dx * 45 + dy * 55) + math.sin(bt * math.pi) * 45)
                lp[x, y] = (clamp(light * 1.05), clamp(light * 0.82), clamp(light * 0.34), 255)
                el = clamp(light * 0.55)
                ep[x, y] = (clamp(el * 1.02), clamp(el * 0.84), clamp(el * 0.45), 235)
                continue

            # Inner orb face
            nr = r / 0.66
            # Lit: luminous faceted ruby-amber orb with bright specular highlight at (-0.24, -0.26)
            sx = dx + 0.24
            sy = dy + 0.26
            spec = math.exp(-(sx * sx + sy * sy) * 18.0)
            core = max(0.0, 1.0 - nr * 0.68)
            rr = clamp(210 * core + 45 + spec * 240)
            gg = clamp(72 * core + 18 + spec * 210)
            bb = clamp(28 * core + 10 + spec * 150)
            lp[x, y] = (rr, gg, bb, 255)

            # Empty: recessed dark obsidian socket
            ed = clamp(18 + nr * 14)
            ep[x, y] = (ed, clamp(ed * 0.95), clamp(ed * 1.08), 215)

    return lit, empty, glow


def make_zone_ribbon():
    """512x128 true POT sculpted RPG quest tracker region banner (left gold crest -> smooth fade right)."""
    w, h = 512, 128
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    px = img.load()
    for y in range(h):
        vy = y / (h - 1.0)
        # Vertical bevel shading
        v_shade = lerp(1.18, 0.72, vy)
        is_top_edge = (y in (2, 3))
        is_bot_edge = (y in (h - 4, h - 3))
        for x in range(w):
            ux = x / (w - 1.0)
            # Smooth horizontal fade-out after 55% width
            if ux < 0.52:
                fade = 1.0
            else:
                ft = (ux - 0.52) / 0.48
                fade = max(0.0, 1.0 - ft * ft)
            if x < 10:
                # Left sculpted antique gold vertical crest
                c = lerp_rgb((245, 212, 114), (156, 114, 42), vy)
                px[x, y] = (c[0], c[1], c[2], 245)
            elif is_top_edge or is_bot_edge:
                a = clamp((195 if is_top_edge else 145) * fade)
                px[x, y] = (218, 178, 86, a)
            elif 4 <= y <= h - 5:
                # Warm neutral-tinted bronze/basalt banner (tintable via SetVertexColor!)
                base = clamp(198 * v_shade)
                px[x, y] = (base, clamp(base * 0.92), clamp(base * 0.78), clamp(210 * fade))
    return img


def main():
    manifest = {}
    save_tga(make_window_frame(512, 32, "gold"), "FS-Frame-Gold.tga", {"slice": 160, "shadow": 16}, manifest)
    save_tga(make_window_frame(512, 32, "dark"), "FS-Frame-Dark.tga", {"slice": 160, "shadow": 16}, manifest)
    save_tga(make_window_frame(256, 16, "gold"), "FS-Frame-Small.tga", {"slice": 80, "shadow": 8}, manifest)
    save_tga(make_window_frame(256, 16, "dark"), "FS-Frame-Small-Dark.tga", {"slice": 80, "shadow": 8}, manifest)

    save_tga(make_button_9slice("normal"), "FS-Button-Normal.tga", {"slice": 32}, manifest)
    save_tga(make_button_9slice("brass"), "FS-Button-Brass.tga", {"slice": 32}, manifest)
    save_tga(make_button_9slice("crimson"), "FS-Button-Crimson.tga", {"slice": 32}, manifest)

    fill, groove, border = make_statusbar_textures()
    save_tga(fill, "FS-StatusBar-Fill.tga", {"tile": True}, manifest)
    save_tga(groove, "FS-StatusBar-Groove.tga", {"tile": True}, manifest)
    save_tga(border, "FS-StatusBar-Border.tga", {"slice": 16}, manifest)

    save_tga(make_icon_ring(), "FS-IconRing.tga", {}, manifest)
    save_tga(make_scrim_radial(), "FS-Scrim-Radial.tga", {}, manifest)

    lit, empty, glow = make_combo_gems()
    save_tga(lit, "FS-Gem-Lit.tga", {}, manifest)
    save_tga(empty, "FS-Gem-Empty.tga", {}, manifest)
    save_tga(glow, "FS-Gem-Glow.tga", {"blend": "ADD"}, manifest)

    save_tga(make_zone_ribbon(), "FS-ZoneRibbon.tga", {}, manifest)

    for fname, info in manifest.items():
        w, h = info["width"], info["height"]
        assert (w & (w - 1)) == 0 and (h & (h - 1)) == 0, f"Non-POT asset {fname}: {w}x{h}"
    mpath = os.path.join(OUT_DIR, "assets.manifest.json")
    with open(mpath, "w", encoding="utf-8") as f:
        json.dump({"version": "5.0.0", "count": len(manifest), "assets": manifest}, f, indent=2, sort_keys=True)
    total_kb = sum(v["bytes"] for v in manifest.values()) / 1024.0
    print(f"[OK] Generated {len(manifest)} high-DPI POT TGA UI assets ({total_kb:.1f} KB) in {OUT_DIR}")


if __name__ == "__main__":
    main()
