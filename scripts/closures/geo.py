import json, math, heapq, collections
R = 6371008.8
def dist(a, b):
    la1, lo1, la2, lo2 = map(math.radians, (a[0], a[1], b[0], b[1]))
    h = math.sin((la2-la1)/2)**2 + math.cos(la1)*math.cos(la2)*math.sin((lo2-lo1)/2)**2
    return 2*R*math.atan2(math.sqrt(h), math.sqrt(1-h))
def seg_dist(p, a, b):
    k = math.cos(math.radians(p[0])) * 111195; m = 111195
    ax, ay = (a[1]-p[1])*k, (a[0]-p[0])*m; bx, by = (b[1]-p[1])*k, (b[0]-p[0])*m
    dx, dy = bx-ax, by-ay; L = dx*dx+dy*dy
    t = 0 if L == 0 else max(0, min(1, -(ax*dx+ay*dy)/L))
    return math.hypot(ax+t*dx, ay+t*dy)
def to_lines(polys, p):  # min distance from point to set of polylines
    return min(seg_dist(p, l[i], l[i+1]) for l in polys for i in range(len(l)-1))
def length(l): return sum(dist(l[i], l[i+1]) for i in range(len(l)-1))
def shortest(polys, A, B, cell=6/111195):
    key = lambda v: (round(v[0]/cell), round(v[1]/cell))
    co, adj = {}, collections.defaultdict(list)
    for l in polys:
        prev = None
        for v in l:
            k = key(v); co.setdefault(k, v)
            if prev is not None and prev != k:
                w = dist(co[prev], v); adj[prev].append((k, w)); adj[k].append((prev, w))
            prev = k
    s = min(co, key=lambda k: dist(co[k], A)); e = min(co, key=lambda k: dist(co[k], B))
    g, came, pq = {s: 0}, {}, [(0, s)]
    while pq:
        d, u = heapq.heappop(pq)
        if u == e: break
        if d > g[u]: continue
        for v, w in adj[u]:
            if d+w < g.get(v, 1e18): g[v] = d+w; came[v] = u; heapq.heappush(pq, (d+w, v))
    if e not in g: return None
    out = [e]
    while out[-1] in came: out.append(came[out[-1]])
    return [co[k] for k in reversed(out)]
def sample(l, spacing):
    pts, acc = [l[0]], 0.0
    for i in range(len(l)-1):
        a, b = l[i], l[i+1]; d = dist(a, b); pos = 0.0
        while acc + (d-pos) >= spacing:
            pos += spacing - acc; acc = 0; t = pos/d
            pts.append((a[0]+(b[0]-a[0])*t, a[1]+(b[1]-a[1])*t))
        acc += d - pos
    if dist(pts[-1], l[-1]) > spacing/3: pts.append(l[-1])
    return pts
