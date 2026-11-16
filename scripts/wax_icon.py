"""Wax app icon. Every shape and colour is a number in P; run `python3 wax_icon.py wax-icon.svg`.
Units: the icon is a 1024 x 1024 square (1 unit = 1/1024 of the icon)."""
import math, sys, json

P = {
    "rx": 271,                                # corner radius of the rounded square
    "top": [0, 44, 198], "bottom": [0, 30, 158], # background, vertical gradient
    "cx": 511.4, "cy": 507.8,                   # record centre
    "R": 444.5,                                 # record outer radius
    "rim_w": 9.6, "rim": [70, 93, 196],         # thin light rim on the record edge
    "disc": [0,  38,  172],                       # record body
    "g_in": 169.0, "g_out": 428.0, "g_n": 37,   # grooves: first radius, last radius, count
    "g_w": 2.06, "g_col": [71,  85,  186],         # groove line width and colour
    "s1_ang": 50.5, "s1_w": 29.9, "s1": 0.93,    # light streak 1: angle (deg, clockwise from 3 o'clock), width, strength
    "s2_ang": 235.8, "s2_w": 29.6, "s2": 0.99,   # light streak 2
    "s_col": [244, 235, 255], "s_fill": 0.344,   # streak colour; how much it also lights the gaps between grooves
    "label_r": 143.0, "label": [245, 242, 237], # paper label
    "hole_r": 19.0, "hole": [4, 33, 166],       # spindle hole
}

def hexc(c): return "#%02X%02X%02X" % tuple(max(0, min(255, int(round(v)))) for v in c)

def streak(p, a):
    v = 0.0
    for k in ("s1", "s2"):
        d = (a - p[k + "_ang"] + 180) % 360 - 180
        v = max(v, p[k] * math.exp(-(d / p[k + "_w"]) ** 2))
    return v

def svg(p=P):
    cx, cy = p["cx"], p["cy"]
    o = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">', "<defs>",
         f'<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{hexc(p["top"])}"/>'
         f'<stop offset="1" stop-color="{hexc(p["bottom"])}"/></linearGradient>',
         '<mask id="streak" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">']
    R = p["R"] + 4
    for d in range(360):  # one wedge per degree, grey = streak strength there
        g = round(255 * min(1.0, streak(p, d + 0.5)))
        a0, a1 = math.radians(d - 0.1), math.radians(d + 1.1)
        o.append(f'<path d="M{cx:.2f} {cy:.2f}L{cx+R*math.cos(a0):.2f} {cy+R*math.sin(a0):.2f}'
                 f'L{cx+R*math.cos(a1):.2f} {cy+R*math.sin(a1):.2f}Z" fill="rgb({g},{g},{g})"/>')
    o += ["</mask>", "</defs>",
          f'<rect width="1024" height="1024" rx="{p["rx"]:.1f}" fill="url(#bg)"/>',
          f'<circle cx="{cx}" cy="{cy}" r="{p["R"]:.2f}" fill="{hexc(p["rim"])}"/>',
          f'<circle cx="{cx}" cy="{cy}" r="{p["R"]-p["rim_w"]:.2f}" fill="{hexc(p["disc"])}"/>']
    n = int(p["g_n"])
    rings = "".join(f'<circle cx="{cx}" cy="{cy}" r="{p["g_in"]+(p["g_out"]-p["g_in"])*i/(n-1):.2f}"/>' for i in range(n))
    o.append(f'<g fill="none" stroke="{hexc(p["g_col"])}" stroke-width="{p["g_w"]:.2f}">{rings}</g>')
    o.append(f'<g mask="url(#streak)"><circle cx="{cx}" cy="{cy}" r="{(p["g_in"]+p["g_out"])/2:.2f}" fill="none" '
             f'stroke="{hexc(p["s_col"])}" stroke-opacity="{p["s_fill"]:.3f}" stroke-width="{p["g_out"]-p["g_in"]+p["g_w"]:.2f}"/>'
             f'<g fill="none" stroke="{hexc(p["s_col"])}" stroke-width="{p["g_w"]:.2f}">{rings}</g></g>')
    o += [f'<circle cx="{cx}" cy="{cy}" r="{p["label_r"]:.2f}" fill="{hexc(p["label"])}"/>',
          f'<circle cx="{cx}" cy="{cy}" r="{p["hole_r"]:.2f}" fill="{hexc(p["hole"])}"/>', "</svg>"]
    return "\n".join(o)

if __name__ == "__main__":
    if len(sys.argv) > 2:
        P.update(json.load(open(sys.argv[2])))
    open(sys.argv[1], "w").write(svg())
