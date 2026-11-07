"""Measure clipping paths from the approved artwork. Never rewrites image pixels.

The runtime draws the unchanged reference PNG through these masks, as the
website companion draws its original PNG through SVG clip paths.
"""
from pathlib import Path
import json
import cv2
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'assets/branding/skivu-cloud-motion-reference.png'
im = np.asarray(Image.open(SOURCE).convert('RGB'))
r, g, b = [im[:, :, i].astype(int) for i in range(3)]
blue = ((r < 145) & (b-r > 45) & (g-r > 15)).astype('uint8') * 255
gold = ((r > 200) & (g > 150) & (b < 190)).astype('uint8') * 255
broad = ((r < 222) & (b-r > 25) & (g-r > 5)).astype('uint8') * 255
barrier = cv2.morphologyEx(blue, cv2.MORPH_CLOSE, np.ones((3, 3), np.uint8))

def contours(mask, minimum=20):
    cs, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    return [cv2.approxPolyDP(c, .65, True).reshape(-1, 2).tolist()
            for c in cs if cv2.contourArea(c) >= minimum]

def region(seed):
    work = barrier.copy()
    cv2.floodFill(work, None, seed, 128)
    found = (work == 128).astype('uint8') * 255
    cs, _ = cv2.findContours(found, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    result = np.zeros_like(found)
    if cs:
        cv2.drawContours(result, [max(cs, key=cv2.contourArea)], -1, 255, -1)
    return result

names = ['idle', 'thinking', 'coding', 'phone', 'permission', 'checking', 'complete', 'failed']
seeds = {
    'idle': [(127, 328), (275, 329)],
    'thinking': [(122, 332), (241, 309)],
    'coding': [(138, 327), (186, 329)],
    'phone': [(131, 335), (237, 324)],
    'permission': [(111, 248), (288, 288)],
    'checking': [(113, 302), (283, 313)],
    'complete': [(112, 288), (292, 298)],
    'failed': [(112, 318), (225, 316)],
}
data = {}
for index, name in enumerate(names):
    x, y = index % 4 * 384, index // 4 * 512
    art_top = 36 if index < 4 else 20
    roi = np.zeros_like(blue)
    roi[y+art_top:y+(420 if index < 4 else 382), x+20:x+366] = 255
    outline = cv2.bitwise_and(cv2.bitwise_or(broad, gold), roi)
    outline = cv2.morphologyEx(outline, cv2.MORPH_CLOSE, np.ones((3, 3), np.uint8))
    whole = np.zeros_like(blue)
    for poly in contours(outline, 65):
        cv2.fillPoly(whole, [np.array(poly, np.int32)], 255)
    head = region((x+190, y+160))
    if index == 5:  # Magnifier/hand overlap opens the lower head outline.
        head[y+252:, :] = 0
    head = cv2.dilate(head, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (13, 13)))
    # The head star is its own closed region, joined to the same head rig.
    star_mask = gold.copy()
    star_mask[:y+art_top] = 0
    star_mask[y+178:] = 0
    star_mask[:, :x+130] = 0
    star_mask[:, x+350:] = 0
    star_cs, _ = cv2.findContours(star_mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if star_cs:
        star = np.zeros_like(head)
        cv2.drawContours(star, [max(star_cs, key=cv2.contourArea)], -1, 255, -1)
        head |= cv2.dilate(star, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (13, 13)))
    head &= whole
    top = np.zeros_like(head)
    hy, hx = np.where(head > 0)
    top[y+art_top:y+160, int(hx.min()):int(hx.max())+1] = 255
    head |= whole & top
    yy, xx = np.where(head > 0)
    bounds = [int(xx.min()), int(yy.min()), int(xx.max()-xx.min()+1), int(yy.max()-yy.min()+1)]
    arms = []
    for hand_index, (sx, sy) in enumerate(seeds[name]):
        arm = region((x+sx, y+sy))
        ay, ax = np.where(arm > 0)
        if not len(ax) or ax.max()-ax.min() > 115 or ay.max()-ay.min() > 110:
            continue
        arm = cv2.dilate(arm, cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7))) & whole
        ab = cv2.boundingRect(arm)
        arms.append({'paths': contours(arm), 'pivot': [ab[0]+ab[2]*(.18 if hand_index == 0 else .82), ab[1]+ab[3]*.45], 'side': hand_index})
    # A few attachments are open at the shoulder, so use source-space clipping
    # polygons as the website's original arm does. Intersect with the artwork.
    fallback = {
      'idle': [(0, [(138,284),(119,301),(111,321),(113,338),(126,347),(139,342),(145,324),(155,302)]),
               (1, [(257,284),(278,301),(293,321),(296,338),(285,347),(271,342),(265,324),(250,302)])],
      'phone': [(0, [(106,307),(124,310),(153,321),(183,324),(190,339),(181,353),(146,355),(117,348),(104,334)]),
                (1, [(206,302),(225,306),(242,319),(242,334),(225,341),(208,330)])],
      'complete': [(0, [(102,265),(118,257),(137,264),(146,279),(140,296),(123,311),(106,304),(98,282)])],
    }
    if not arms and name in fallback:
        for side, points in fallback[name]:
            arm = np.zeros_like(head)
            poly = np.array([[x+px,y+py] for px,py in points], np.int32)
            cv2.fillPoly(arm,[poly],255)
            arm &= whole
            ab = cv2.boundingRect(arm)
            arms.append({'paths':contours(arm), 'pivot':[ab[0]+ab[2]*(.8 if side == 0 else .2),ab[1]+ab[3]*.2], 'side':side})
    eye_mask = (((r < 180) & (b-r > 50) & (g-r > 15)) & (head > 0)).astype('uint8')
    _, _, stats, _ = cv2.connectedComponentsWithStats(eye_mask)
    eyes = []
    for ex, ey, ew, eh, area in stats[1:]:
        if 14 <= ew <= 45 and 25 <= eh <= 45 and ey > y+160 and ey < y+270:
            eyes.append([int(ex), int(ey), int(ew), int(eh)])
    eyes.sort(key=lambda e:e[0])
    if name == 'complete':
        eyes = []
    data[name] = {'whole': contours(whole), 'head': contours(head), 'bounds': bounds,
                  'arms': arms, 'eyes': eyes[:2]}

target = ROOT / 'assets/branding/skivu-cloud-reference-masks.json'
target.write_text(json.dumps({'version': 1, 'width':1536, 'height':1024, 'scenes':data}, separators=(',', ':')), encoding='utf-8')
for name, value in data.items():
    print(name, 'bounds', value['bounds'], 'arms', len(value['arms']), 'eyes',value['eyes'])
print(target)
