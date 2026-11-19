import json, sys, uuid, os
S = os.path.expanduser("~/Library/Containers/io.github.corvinus2003.toolbox/Data/Documents/Samples/")
EARTH, ASTRO, VID = S+"NASA - Blue Marble (Apollo 17).jpg", S+"NASA - Bruce McCandless EVA 1984.jpg", S+"NASA - Seeing Earth as Only NASA Can.mp4"
def n(kind, x, y, **p): return {"id": str(uuid.uuid4()).upper(), "kind": kind, "position": [x, y], "params": p}
def num(v): return {"number": {"_0": v}}
def txt(v): return {"text": {"_0": v}}
def b(v): return {"bool": {"_0": v}}
def files(*v): return {"files": {"_0": list(v)}}
def e(a, c, port=0): return {"id": str(uuid.uuid4()).upper(), "from": a["id"], "to": c["id"], "toPort": port}
scenes = {}
# 1 photo
img = n("image", 0, 120, file=files(EARTH)); d = n("dither", 300, 0, palette=txt("sunset"), pixel=num(12))
ex1 = n("exportImage", 600, 0); a = n("ascii", 300, 260, columns=num(64)); ex2 = n("exportImage", 600, 260, format=txt("png"))
scenes["photo"] = ([img, d, ex1, a, ex2], [e(img, d), e(d, ex1), e(img, a), e(a, ex2)], "dither")
# 2 video
v = n("video", 0, 130, file=files(VID)); r = n("resize", 300, 0, percent=num(50)); dg = n("dither", 600, 0, palette=txt("gameboy"))
xv = n("exportVideo", 900, 0, format=txt("gif")); ea = n("extractAudio", 300, 280); nm = n("normalize", 600, 280); xa = n("exportAudio", 900, 280)
scenes["video"] = ([v, r, dg, xv, ea, nm, xa], [e(v, r), e(r, dg), e(dg, xv), e(v, ea), e(ea, nm), e(nm, xa)], "dither")
# 3 lift
i3 = n("image", 0, 0, file=files(ASTRO)); l = n("lift", 300, 0, crop=b(True)); x3 = n("exportImage", 600, 0, format=txt("png"))
scenes["lift"] = ([i3, l, x3], [e(i3, l), e(l, x3)], "lift")
# 4 pdf
im = n("images", 0, 120, files=files(EARTH, ASTRO)); ip = n("imagesToPDF", 300, 0); pn = n("pageNumbers", 600, 0, format=txt("Page {n}"))
wm = n("watermark", 600, 260, text=txt("SAMPLE"), color=txt("red"), opacity=num(0.55), size=num(28)); xp = n("exportPDF", 900, 260)
scenes["pdf"] = ([im, ip, pn, wm, xp], [e(im, ip), e(ip, pn), e(pn, wm), e(wm, xp)], "watermark")
nodes, edges, sel = scenes[sys.argv[1]]
out = os.path.expanduser("~/Library/Containers/io.github.corvinus2003.toolbox/Data/Library/Application Support/Toolbox Pro Max/graph.json")
json.dump({"nodes": nodes, "edges": edges}, open(out, "w"))
print(sel)
