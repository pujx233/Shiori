"""Persistent, offline manga detection/OCR worker. One JSON job directory per input line."""
import os
import sys
import json
import time
import traceback
import base64
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeout

os.environ['HF_HUB_OFFLINE'] = '1'
os.environ['TRANSFORMERS_OFFLINE'] = '1'
os.environ['TOKENIZERS_PARALLELISM'] = 'false'
os.environ['HF_HUB_DISABLE_PROGRESS_BARS'] = '1'


def write_state(directory, **state):
    write_json(directory, 'state', state)


def write_json(directory, name, value):
    if not directory.exists():
        return
    temporary = directory / (name + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False), encoding='utf-8')
    temporary.replace(directory / (name + '.json'))


def cancelled(directory):
    return not directory.exists() or (directory / 'cancel').exists()


def read_hints(directory, pending=False):
    path = directory / 'hints.json'
    deadline = time.monotonic()+30
    while pending and not path.exists() and not cancelled(directory):
        if time.monotonic() >= deadline:
            raise TimeoutError('System OCR did not finish')
        time.sleep(.02)
    return json.loads(path.read_text()) if path.exists() else []


def bubble_regions(gray):
    """Find light interiors, including gray fills and small breaks in outlines."""
    import cv2
    import numpy as np
    outline = (gray < 175).astype(np.uint8)
    outline = cv2.morphologyEx(outline, cv2.MORPH_CLOSE, np.ones((3, 3), np.uint8))
    _, labels, stats, _ = cv2.connectedComponentsWithStats(1-outline, connectivity=4)
    exterior = set(np.concatenate((labels[0], labels[-1], labels[:, 0], labels[:, -1])).tolist())
    exterior.add(0)
    return labels, stats, exterior


def punctuation_only(text):
    import unicodedata
    return bool(text.strip()) and not any(unicodedata.category(c)[0] in 'LN' for c in text)


def recognize_text(ocr, crop, languages, font_size, initial_text=None):
    """Retry a failed tight crop once; punctuation has no translation to recover."""
    import numpy as np
    from PIL import Image, ImageOps
    image = Image.fromarray(crop[:, :, ::-1])
    text = (ocr(image) if initial_text is None else initial_text).strip()
    if japanese_text(text, languages) or punctuation_only(text):
        return text
    border = max(4, int(font_size * .35))
    background = tuple(int(v) for v in np.median(crop.reshape(-1, 3), axis=0)[::-1])
    return ocr(ImageOps.expand(image, border=border, fill=background)).strip()


def recognize_crops(ocr, crops):
    """Run the same Manga OCR decoder over a small batch of equal-size inputs."""
    from PIL import Image
    import torch
    from manga_ocr.ocr import post_process
    images = [Image.fromarray(crop[:, :, ::-1]).convert('L').convert('RGB') for crop in crops]
    if len(images) == 1:
        return [ocr(images[0])]
    with torch.inference_mode():
        values = ocr.processor(images, return_tensors='pt').pixel_values.to(ocr.model.device)
        tokens = ocr.model.generate(values, max_length=300).cpu()
    return [post_process(text) for text in ocr.tokenizer.batch_decode(tokens, skip_special_tokens=True)]


def ocr_segments(crop):
    """Keep long single-line captions readable after the encoder's square resize."""
    import cv2
    import numpy as np
    height, width = crop.shape[:2]
    vertical = height > width
    length, cross = (height, width) if vertical else (width, height)
    if length <= cross * 8 or cross < 8:
        return [crop]
    count = min(12, int(np.ceil(length / (cross * 6))))
    gray = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY)
    ink = gray < 175 if np.median(gray) >= 145 else gray > 175
    projection = ink.mean(axis=1 if vertical else 0)
    cuts = [0]
    for index in range(1, count):
        target = int(length * index / count)
        start, end = max(cuts[-1]+cross*2, target-cross//2), min(length-cross*2, target+cross//2)
        if end <= start:
            continue
        candidates = np.arange(start, end)
        cut = int(candidates[np.argmin(projection[start:end] + abs(candidates-target)/max(1,cross)*.05)])
        cuts.append(cut)
    cuts.append(length)
    return [crop[a:b, :] if vertical else crop[:, a:b] for a,b in zip(cuts,cuts[1:])]


def recognized_boxes(ocr, image, boxes, languages, font_sizes, directory, batch_size, text_mask=None):
    import numpy as np
    large_font = max(40, float(np.median(list(font_sizes.values()))) * 2) if font_sizes else 40
    # Like the width buckets in manga-image-translator, keep short effects out
    # of batches that must decode long dialogue. Original IDs/order are retained.
    order = sorted(enumerate(boxes), key=lambda item:
        (item[1][1][2]-item[1][1][0])*(item[1][1][3]-item[1][1][1]) / max(8,font_sizes[item[1][0]])**2)
    for first in range(0, len(order), batch_size):
        if cancelled(directory):
            return
        indices = [item[0] for item in order[first:first+batch_size]]
        group = [item[1] for item in order[first:first+batch_size]]
        crops = []
        for component, box in group:
            crop = image[box[1]:box[3], box[0]:box[2]]
            if component < 0 and font_sizes[component] > large_font and text_mask is not None:
                mask = text_mask[box[1]:box[3], box[0]:box[2]] > 0
                if .03 < np.mean(mask) < .9 and np.median(crop) >= 145:
                    crop = crop.copy(); crop[~mask] = 255
            crops.append(crop)
        write_state(directory, phase='recognizing', completed=first, total=len(boxes))
        segments = [ocr_segments(crop) for crop in crops]
        flattened = [part for parts in segments for part in parts]
        decoded = []
        for start in range(0, len(flattened), batch_size):
            if cancelled(directory):
                return
            decoded.extend(recognize_crops(ocr, flattened[start:start+batch_size]))
        if len(decoded) != len(flattened):
            raise ValueError('识字结果数量不完整')
        texts, cursor = [], 0
        for parts in segments:
            texts.append(''.join(decoded[cursor:cursor+len(parts)]))
            cursor += len(parts)
        if len(texts) != len(group):
            raise ValueError('识字结果数量不完整')
        for offset, ((component, box), crop, text) in enumerate(zip(group, crops, texts)):
            if cancelled(directory):
                return
            index = indices[offset]
            write_state(directory, phase='recognizing', completed=first+offset, total=len(boxes))
            yield index, component, box, recognize_text(ocr, crop, languages[component], font_sizes[component], text)


def supplement_candidates(candidates, hints):
    """Use system OCR to verify unknown Japanese and recover detector omissions."""
    from types import SimpleNamespace
    def coverage(first, second):
        x1, y1, x2, y2 = first
        left, top, right, bottom = second
        area = max(0, min(x2, right)-max(x1, left)) * max(0, min(y2, bottom)-max(y1, top))
        return area / max(1, (x2-x1)*(y2-y1))
    result = list(candidates)
    for hint in hints:
        box = hint['box']
        matches = [b for b in result if coverage(box, b.xyxy) > .3 or coverage(b.xyxy, box) > .5]
        if matches:
            for block in matches:
                kana = sum('\u3041' <= char <= '\u30fa' for char in hint['text'])
                if block.language == 'unknown' or (block.language == 'eng' and hint['confidence'] >= .5
                    and kana >= 3 and coverage(block.xyxy, box) >= .55):
                    block.language = 'ja'
        elif hint['confidence'] >= .55:
            result.append(SimpleNamespace(xyxy=box, language='ja', font_size=min(box[2]-box[0], box[3]-box[1])))
    return result


def separate_caption_lines(candidates):
    """Keep unrelated header/credit lines out of one rectangular OCR crop."""
    import numpy as np
    from comic_text_detector.utils.textblock import TextBlock
    result = []
    for block in candidates:
        lines = getattr(block, 'lines', [])
        if block.language != 'unknown' or len(lines) < 2:
            result.append(block); continue
        for line in lines:
            points = np.asarray(line).reshape(-1, 2)
            low, high = points.min(axis=0), points.max(axis=0)
            box = [int(low[0]), int(low[1]), int(high[0])+1, int(high[1])+1]
            result.append(TextBlock(box, lines=[line], language='unknown', vertical=block.vertical,
                                    font_size=min(box[2]-box[0],box[3]-box[1])))
    merged = []
    for block in result:
        if block.language == 'unknown' and not block.vertical:
            for old in merged:
                if old.language != 'unknown' or old.vertical:
                    continue
                a, b = old.xyxy, block.xyxy
                ah, bh = a[3]-a[1], b[3]-b[1]
                gap = max(a[0]-b[2],b[0]-a[2],0)
                if (max(ah,bh) <= min(ah,bh)*1.8 and abs((a[1]+a[3])-(b[1]+b[3])) < max(ah,bh)*.7
                    and gap <= max(ah,bh)*.8):
                    old.xyxy = [min(a[0],b[0]),min(a[1],b[1]),max(a[2],b[2]),max(a[3],b[3])]
                    break
            else:
                merged.append(block)
        else:
            merged.append(block)
    return merged


def recover_candidates(image, raw_mask, candidates):
    """Recover lettering present in CTD's segmentation but absent from its boxes."""
    import cv2
    import numpy as np
    from comic_text_detector.utils.textblock import TextBlock
    height, width = raw_mask.shape
    binary = (raw_mask > 140).astype(np.uint8)
    # A dark reader gutter is not page content. Restrict only the recovery pass;
    # ordinary detector boxes and independently verified Vision text stay intact.
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
    def substantial_runs(indices, minimum):
        runs = np.split(indices, np.flatnonzero(np.diff(indices) > 1)+1)
        return np.concatenate([run for run in runs if len(run) >= minimum]) if any(len(run) >= minimum for run in runs) else np.array([], dtype=int)
    columns = substantial_runs(np.flatnonzero((gray > 180).mean(axis=0) > .12), width*.02)
    if len(columns) and columns[0] > width*.05 and columns[-1] < width*.95:
        left, right = int(columns[0]), int(columns[-1])+1
        rows = substantial_runs(np.flatnonzero((gray[:, left:right] > 180).mean(axis=1) > .18), height*.02)
        binary[:, :left] = 0; binary[:, right:] = 0
        if len(rows):
            binary[:rows[0]] = 0; binary[rows[-1]+1:] = 0
    joined = cv2.morphologyEx(binary, cv2.MORPH_CLOSE, np.ones((5, 5), np.uint8))
    _, _, stats, _ = cv2.connectedComponentsWithStats(joined)
    boxes = []
    for x, y, w, h, area in stats[1:]:
        if area < 35 or min(w,h) < 6 or max(w,h) < 16 or w*h > width*height*.08 or area/(w*h) < .09:
            continue
        boxes.append([max(0,int(x)-4), max(0,int(y)-4), min(width,int(x+w)+4), min(height,int(y+h)+4)])
    # Curved letters can form several mask islands whose rectangles overlap.
    merged = []
    for box in boxes:
        index = 0
        while index < len(merged):
            old = merged[index]
            overlap = max(0,min(box[2],old[2])-max(box[0],old[0])) * max(0,min(box[3],old[3])-max(box[1],old[1]))
            area = min((box[2]-box[0])*(box[3]-box[1]), (old[2]-old[0])*(old[3]-old[1]))
            if overlap > area*.05:
                box = [min(box[0],old[0]),min(box[1],old[1]),max(box[2],old[2]),max(box[3],old[3])]
                merged.pop(index); index = 0
            else:
                index += 1
        merged.append(box)
    recovered = []
    for box in merged:
        w, h = box[2]-box[0], box[3]-box[1]
        # Compare whole mask islands. Subtracting detector rectangles first
        # sliced curved glyphs into fragments and produced duplicate OCR crops.
        overlaps = [max(0,min(box[2],b.xyxy[2])-max(box[0],b.xyxy[0])) * max(0,min(box[3],b.xyxy[3])-max(box[1],b.xyxy[1])) for b in candidates]
        if any(area > .3*min(w*h,(b.xyxy[2]-b.xyxy[0])*(b.xyxy[3]-b.xyxy[1])) for area,b in zip(overlaps,candidates)):
            continue
        block = TextBlock(box, language='unknown', font_size=min(w,h), vertical=h > w*1.4)
        block.recovered = True
        recovered.append(block)
    return recovered


def padded_box(box, gray, labels, stats, component, font_size):
    """Add writing space only while the perimeter remains inside this bubble."""
    import numpy as np
    bx, by, bw, bh, _ = stats[component]
    padding = max(6, int(font_size * .65))
    for pad in range(padding, 0, -2):
        x1, y1, x2, y2 = (max(int(bx)+2, box[0]-pad), max(int(by)+2, box[1]-pad),
                          min(int(bx+bw)-2, box[2]+pad), min(int(by+bh)-2, box[3]+pad))
        if x2 <= x1 or y2 <= y1:
            continue
        region = labels[y1:y2, x1:x2]
        perimeter = np.concatenate((region[0], region[-1], region[:, 0], region[:, -1]))
        if np.mean(perimeter == component) >= .9 and np.mean(gray[y1:y2, x1:x2] > 175) > .72:
            return [x1, y1, x2, y2]
    return box


def layout_boxes(labels, stats, component, fallback, font_size):
    """Fit text inside balloon lobes, without using erasure rectangles as layout bounds."""
    import cv2
    import numpy as np
    bx, by, bw, bh, _ = [int(v) for v in stats[component]]
    interior = (labels[by:by+bh, bx:bx+bw] == component).astype(np.uint8)
    contours, _ = cv2.findContours(interior, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return [fallback]
    cv2.drawContours(interior, contours, -1, 1, cv2.FILLED)
    inset = max(2, min(6, int(font_size * .12)))
    interior = cv2.erode(interior, np.ones((inset*2+1, inset*2+1), np.uint8))
    small = cv2.resize(interior.astype(np.float32), (max(1, bw//3), max(1, bh//3)), interpolation=cv2.INTER_AREA) > .98
    sx, sy = bw/small.shape[1], bh/small.shape[0]
    result, areas = [], []
    for _ in range(2):
        heights = np.zeros(small.shape[1], dtype=np.int32)
        best_area, best = 0, None
        for y, row in enumerate(small):
            heights = (heights + 1) * row
            stack = []
            for x in range(len(heights)+1):
                value = int(heights[x]) if x < len(heights) else 0
                left = x
                while stack and stack[-1][1] > value:
                    start, height = stack.pop(); left = start
                    area = (x-start)*height
                    if area > best_area:
                        best_area, best = area, (start, y-height+1, x, y+1)
                if not stack or stack[-1][1] < value:
                    stack.append((left, value))
        if not best or best_area < 9:
            break
        rect = [int(bx+best[0]*sx+1),int(by+best[1]*sy+1),int(bx+best[2]*sx-1),int(by+best[3]*sy-1)]
        if result and (best_area < areas[0]*.45 or min(rect[2]-rect[0],rect[3]-rect[1]) < font_size*1.15):
            break
        result.append(rect); areas.append(best_area)
        small[best[1]:best[3], best[0]:best[2]] = False
    result.sort(key=lambda b:(int(b[1]/max(10,font_size)), -b[0]))
    return result or [fallback]


def group_geometry(candidates, groups):
    """Retain detector direction and the original glyph rectangle for each group."""
    geometry = {}
    for component, box in groups.items():
        members = []
        for candidate in candidates:
            x1,y1,x2,y2 = candidate.xyxy
            cx,cy = (x1+x2)/2,(y1+y2)/2
            if box[0] <= cx <= box[2] and box[1] <= cy <= box[3]:
                members.append(candidate)
        vertical = sum(bool(getattr(b, 'vertical', (b.xyxy[3]-b.xyxy[1]) > (b.xyxy[2]-b.xyxy[0])*1.4)) for b in members)
        geometry[component] = vertical > len(members)/2 if members else box[3]-box[1] > (box[2]-box[0])*1.4
    return geometry


def reliable_hint(box, hints, original='', horizontal=False):
    """Use independent system OCR for oblique captions and small handwritten text."""
    selected = []
    for hint in hints:
        x1,y1,x2,y2 = hint['box']
        overlap = max(0,min(box[2],x2)-max(box[0],x1))*max(0,min(box[3],y2)-max(box[1],y1))
        if hint['confidence'] >= (.3 if horizontal else .7) and overlap / max(1,(x2-x1)*(y2-y1)) >= .85:
            selected.append(hint)
    if not selected:
        return None
    if horizontal and len(selected) == 1 and box[2]-box[0] > (box[3]-box[1])*4:
        from difflib import SequenceMatcher
        import unicodedata
        hint = selected[0]
        def normalized(value):
            return ''.join(c for c in unicodedata.normalize('NFKC', value) if c.isalnum()).casefold()
        if (hint['confidence'] >= .5 and len(hint['text']) >= 8
            and SequenceMatcher(None, normalized(original), normalized(hint['text'])).ratio() >= .55):
            return hint['text']
    if horizontal and (len(selected) < 2 or not any(h['confidence'] >= .9 for h in selected)):
        return None
    selected.sort(key=lambda h:(int(h['box'][1]/max(12,(h['box'][3]-h['box'][1])*.7)), h['box'][0]))
    text = ' '.join(h['text'] for h in selected)
    # A single recognized column must never replace an entire multi-column caption.
    return text if len(text.replace(' ', '')) >= len(original.replace(' ', '')) * .85 else None


def confirm_fragments(ocr, image, box, text, original, hints, directory, budget):
    """Cross-check doubtful Vision fragments, without treating confidence as illegibility.

    Agreement with the independent full-block decoder needs no extra inference.
    Otherwise retry only the relevant line crop, at most four times per page.
    Disagreements remain explicit instead of replacing text with a new guess.
    """
    import unicodedata
    def normalized(value):
        return ''.join(c for c in unicodedata.normalize('NFKC', value) if c.isalnum())
    unknown = []
    for hint in hints:
        fragment = hint['text']
        if hint['confidence'] >= .5 or fragment not in text or not normalized(fragment):
            continue
        x1, y1, x2, y2 = hint['box']
        overlap = max(0, min(box[2], x2)-max(box[0], x1))*max(0, min(box[3], y2)-max(box[1], y1))
        if overlap < .85*max(1, (x2-x1)*(y2-y1)):
            continue
        target = normalized(fragment)
        if target in normalized(original):
            continue
        confirmed = False
        if budget[0] > 0 and not cancelled(directory):
            height, width = image.shape[:2]
            left, top = max(0, int(x1)), max(0, int(y1))
            right, bottom = min(width, int(x2+.999)), min(height, int(y2+.999))
            if right > left and bottom > top:
                budget[0] -= 1
                retry = recognize_crops(ocr, [image[top:bottom, left:right]])[0]
                confirmed = normalized(retry) == target
        if not confirmed and fragment not in unknown:
            unknown.append(fragment)
    return unknown


def reconcile_fragments(ocr, image, box, text, hints, directory, budget):
    """Confirm a single disputed glyph in otherwise matching dialogue.

    Whole-line agreement is free. A strong system reading can nominate a local
    disagreement, but only another crop decode may correct it. This also works
    for closed balloons and vertical columns, without replacing their full text
    with an incomplete system-OCR line. Shared page budget bounds extra decoding.
    """
    import unicodedata
    def normalized(value):
        return ''.join(c for c in unicodedata.normalize('NFKC', value) if c.isalnum())
    uncertain = []
    for hint in hints:
        target = normalized(hint['text'])
        if hint['confidence'] < .95 or not 4 <= len(target) <= 24 or budget[0] <= 0:
            continue
        x1, y1, x2, y2 = hint['box']
        overlap = max(0, min(box[2], x2)-max(box[0], x1))*max(0, min(box[3], y2)-max(box[1], y1))
        if overlap < .9*max(1, (x2-x1)*(y2-y1)):
            continue
        # Preserve source character offsets while ignoring only punctuation and
        # spacing. Multi-codepoint normalizations are not safe edit candidates.
        mapped = [(i, normalized(c)) for i, c in enumerate(text)]
        if any(len(value) > 1 for _, value in mapped):
            continue
        mapped = [(i, value) for i, value in mapped if value]
        source = ''.join(value for _, value in mapped)
        if target in source:
            continue
        matches = []
        for offset in range(len(source)-len(target)+1):
            fragment = source[offset:offset+len(target)]
            if sum(a != b for a, b in zip(fragment, target)) == 1:
                matches.append((offset, fragment))
        # Repeated or weakly matching text is not enough evidence for a repair.
        if len(matches) != 1 or cancelled(directory):
            continue
        offset, original = matches[0]
        height, width = image.shape[:2]
        left, top = max(0, int(x1)), max(0, int(y1))
        right, bottom = min(width, int(x2+.999)), min(height, int(y2+.999))
        if right <= left or bottom <= top:
            continue
        budget[0] -= 1
        retry = normalized(recognize_crops(ocr, [image[top:bottom, left:right]])[0])
        if retry == target:
            # Correct only the one glyph confirmed by both independent readings.
            index = next(i for i, (a, b) in enumerate(zip(original, target)) if a != b)
            position = mapped[offset+index][0]
            text = text[:position] + target[index] + text[position+1:]
        elif retry != original:
            first, last = mapped[offset][0], mapped[offset+len(target)-1][0]+1
            fragment = text[first:last]
            if fragment not in uncertain:
                uncertain.append(fragment)
    return text, uncertain


def restore_voicing(text, box, hints):
    """Recover dropped dakuten only where independent OCR reads the same phrase."""
    import unicodedata
    def base(value):
        return ''.join(c for c in unicodedata.normalize('NFD', value) if c not in '\u3099\u309a')
    for hint in hints:
        phrase = unicodedata.normalize('NFKC', hint['text']).replace(' ', '')
        x1,y1,x2,y2 = hint['box']
        overlap = max(0,min(box[2],x2)-max(box[0],x1))*max(0,min(box[3],y2)-max(box[1],y1))
        if len(phrase) < 4 or overlap/max(1,(x2-x1)*(y2-y1)) < .85:
            continue
        for start in range(len(text)-len(phrase)+1):
            part = text[start:start+len(phrase)]
            if part != phrase and base(part) == base(phrase):
                before = sum(c in '\u3099\u309a' for c in unicodedata.normalize('NFD', part))
                after = sum(c in '\u3099\u309a' for c in unicodedata.normalize('NFD', phrase))
                if after == before+1:
                    text = text[:start]+phrase+text[start+len(phrase):]
    return text


class BackgroundRestorer:
    """One local CPU LaMa model, reused for textured lettering regions."""
    def __init__(self, path):
        import torch
        self.model = torch.jit.load(str(path), map_location='cpu').eval() if path.exists() else None

    def __call__(self, image, mask):
        import cv2
        import numpy as np
        import torch
        if self.model is None:
            return cv2.inpaint(image, mask, 3, cv2.INPAINT_TELEA)
        height, width = mask.shape
        scale = min(1., 384 / max(height, width))
        size = (max(8, round(width*scale)), max(8, round(height*scale)))
        small = cv2.resize(image, size, interpolation=cv2.INTER_AREA) if scale < 1 else image
        holes = cv2.resize(mask, size, interpolation=cv2.INTER_NEAREST) if scale < 1 else mask
        h, w = holes.shape
        rgb = cv2.copyMakeBorder(small[:, :, ::-1], 0, (-h)%8, 0, (-w)%8, cv2.BORDER_REFLECT)
        holes = cv2.copyMakeBorder(holes, 0, (-h)%8, 0, (-w)%8, cv2.BORDER_CONSTANT)
        values = torch.from_numpy(np.ascontiguousarray(rgb)).permute(2,0,1).unsqueeze(0).float()/255
        binary = torch.from_numpy(holes).unsqueeze(0).unsqueeze(0).float()/255
        with torch.inference_mode():
            output = self.model(values, binary)
        restored = np.clip(output[0].permute(1,2,0).numpy()*255, 0, 255).astype(np.uint8)[:h,:w,::-1]
        return cv2.resize(restored, (width,height), interpolation=cv2.INTER_CUBIC) if scale < 1 else restored


def replacement_patch(image, text_mask, box, ink_labels=None, ink_ids=(), open_text=False, restorer=None):
    """Use surrounding pixels for repair; composite only the original glyph mask."""
    import cv2
    import numpy as np
    x1, y1, x2, y2 = box
    crop = image[y1:y2, x1:x2]
    mask = (text_mask[y1:y2, x1:x2] > 0).astype(np.uint8) * 255
    if open_text:
        gray = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY)
        # The neural mask may include gaps between letters. Erase the ink and
        # its antialiasing fringe, leaving artwork visible through those gaps.
        foreground = (gray < 190) if np.median(gray) >= 145 else (gray > 165)
        support = cv2.dilate(foreground.astype(np.uint8), np.ones((3, 3), np.uint8)) * 255
        mask = cv2.bitwise_and(mask, support)
    if ink_labels is not None and ink_ids:
        extra = np.isin(ink_labels[y1:y2, x1:x2], ink_ids).astype(np.uint8) * 255
        extra = cv2.dilate(extra, np.ones((3, 3), np.uint8), iterations=1)
        mask = cv2.bitwise_or(mask, extra)
    if open_text:
        # Include white outlines around black letters, not just their dark cores.
        mask = cv2.dilate(mask, np.ones((7, 7), np.uint8))
    if not np.any(mask) or np.mean(mask > 0) > .95:
        return None
    pad = max(32, min(72, min(x2-x1,y2-y1)))
    left, top = max(0,x1-pad), max(0,y1-pad)
    right, bottom = min(image.shape[1],x2+pad), min(image.shape[0],y2+pad)
    context = image[top:bottom,left:right]
    context_mask = np.zeros(context.shape[:2], np.uint8)
    context_mask[y1-top:y2-top,x1-left:x2-left] = mask
    ring = cv2.dilate(mask, np.ones((11, 11), np.uint8)) > 0
    background = crop[ring & (mask == 0)]
    flat = len(background) >= 12 and np.max(np.std(background, axis=0)) < 10
    if flat:
        restored = np.empty_like(crop); restored[:] = np.median(background, axis=0)
    else:
        restored = (restorer(context, context_mask) if open_text and restorer is not None
                    else cv2.inpaint(context, context_mask, 3, cv2.INPAINT_TELEA))
        restored = restored[y1-top:y2-top,x1-left:x2-left]
    patch = cv2.cvtColor(restored, cv2.COLOR_BGR2BGRA)
    patch[:, :, 3] = mask
    patch[mask == 0, :3] = 0
    ok, encoded = cv2.imencode('.png', patch)
    return base64.b64encode(encoded).decode('ascii') if ok else None


def group_candidates(candidates, labels, stats, exterior):
    """Group closed bubbles, but retain unrenderable text for OCR/translation."""
    import numpy as np
    height, width = labels.shape
    groups, font_sizes, languages = {}, {}, {}
    typical_font = np.median([float(b.font_size) for b in candidates if float(b.font_size) >= 6] or [20])
    component_text_area = {}
    for block in candidates:
        x1,y1,x2,y2 = [int(v) for v in block.xyxy]
        region = labels[max(0,y1):min(height,y2), max(0,x1):min(width,x2)]
        if not region.size or block.language == 'eng':
            continue
        values, counts = np.unique(region, return_counts=True)
        for component, count in zip(values, counts):
            if int(component) not in exterior and count / region.size >= .55:
                component_text_area[int(component)] = component_text_area.get(int(component), 0) + region.size
    japanese_boxes = [(b.xyxy, float(b.font_size)) for b in candidates if b.language == 'ja']
    for index, block in enumerate(candidates):
        if block.language == 'eng':
            continue
        x1, y1, x2, y2 = [int(v) for v in block.xyxy]
        x1, y1, x2, y2 = max(0, x1), max(0, y1), min(width, x2), min(height, y2)
        if x2 <= x1 or y2 <= y1:
            continue
        values, counts = np.unique(labels[y1:y2, x1:x2], return_counts=True)
        valid = [(int(n), int(v)) for v, n in zip(values, counts) if int(v) not in exterior]
        count, component = max(valid) if valid else (0, 0)
        closed = component > 0 and count / ((x2-x1)*(y2-y1)) >= .55
        margin = max(4, int(float(block.font_size) * .20))
        if not closed:
            # A tight detector box can be mostly ink. Its surrounding ring still
            # identifies the bubble, so all lines share one OCR crop and patch.
            ring_box = labels[max(0, y1-margin):min(height, y2+margin),
                              max(0, x1-margin):min(width, x2+margin)]
            ring = np.concatenate((ring_box[0], ring_box[-1], ring_box[:, 0], ring_box[:, -1]))
            ring_values, ring_counts = np.unique(ring, return_counts=True)
            choices = [(int(n), int(v)) for v, n in zip(ring_values, ring_counts) if int(v) not in exterior]
            ring_count, ring_component = max(choices) if choices else (0, 0)
            if ring_component > 0 and ring_count / len(ring) >= .85:
                bx, by, bw, bh, _ = stats[ring_component]
                if bx <= x1 < x2 <= bx+bw and by <= y1 < y2 <= by+bh:
                    component, closed = ring_component, True
        if closed:
            bx, by, bw, bh, area = stats[component]
            text_area = max((x2-x1)*(y2-y1), component_text_area.get(component, 0))
            closed = 100 <= area <= min(width * height * .85, max(text_area*7, float(block.font_size)**2*20))
            # A large effect printed across panel whitespace is not a speech balloon.
            if float(block.font_size) > max(40, typical_font * 2):
                closed = False
        if getattr(block, 'recovered', False):
            # Recovery islands are individual text lines, not evidence that all
            # whitespace connected behind them belongs to a single speech bubble.
            closed = False
        near_japanese = any(
            max(float(other[0])-x2, x1-float(other[2]), 0) ** 2
            + max(float(other[1])-y2, y1-float(other[3]), 0) ** 2
            <= (max(float(block.font_size), font) * 1.25) ** 2
            for other, font in japanese_boxes)
        if not closed and block.language != 'ja' and not near_japanese and not getattr(block, 'recovered', False):
            # Curved lettering often has an unknown language label. Nearby
            # Japanese dialogue can confirm its reading context; isolated URL/UI
            # text still needs independent Japanese evidence from system OCR.
            continue
        if closed:
            box = [max(int(bx)+2, x1-margin), max(int(by)+2, y1-margin),
                   min(int(bx+bw)-2, x2+margin), min(int(by+bh)-2, y2+margin)]
        else:
            component = -index-1
            box = [max(0, x1-margin), max(0, y1-margin), min(width, x2+margin), min(height, y2+margin)]
        if box[2] <= box[0] or box[3] <= box[1]:
            continue
        font_sizes[component] = max(font_sizes.get(component, 0), float(block.font_size))
        languages.setdefault(component, set()).add(block.language)
        if component in groups:
            old = groups[component]
            groups[component] = [min(old[0], box[0]), min(old[1], box[1]), max(old[2], box[2]), max(old[3], box[3])]
        else:
            groups[component] = box
    return groups, font_sizes, languages


def japanese_text(text, languages):
    # Kana is direct evidence; the detector's Japanese label also permits kanji-only dialogue.
    return not punctuation_only(text) and (any('\u3040' <= char <= '\u30ff' for char in text) or (
        'ja' in languages and any('\u3400' <= char <= '\u9fff' for char in text))
    )


def reading_groups(groups, font_sizes):
    """Retain captions anywhere on the page, excluding tiny thumbnail lettering."""
    minimum = 6
    return {c: box for c, box in groups.items() if font_sizes[c] >= minimum}


def nearby_ink_ids(ink_labels, nearby):
    """Only inspect connected components near this bubble, not the whole page."""
    import numpy as np
    height, width = ink_labels.shape
    x1, y1, x2, y2 = nearby
    region = ink_labels[max(0, int(y1)):min(height, int(y2)+1),
                        max(0, int(x1)):min(width, int(x2)+1)]
    return np.unique(region[region > 0])


def unique_blocks(blocks):
    """A detector box and a balloon group can describe the same printed words."""
    import unicodedata
    def key(text):
        return ''.join(c for c in unicodedata.normalize('NFKC', text) if unicodedata.category(c)[0] in 'LN')
    result = []
    for block in sorted(blocks, key=lambda b: b['textStyle'] is not None):
        text = key(block['text'])
        box = block['bounds']
        duplicate = False
        for old in result:
            if key(old['text']) != text:
                continue
            other = old['bounds']
            overlap = max(0, min(box['x']+box['width'], other['x']+other['width'])-max(box['x'],other['x'])) * max(0, min(box['y']+box['height'],other['y']+other['height'])-max(box['y'],other['y']))
            if overlap > .5 * min(box['width']*box['height'],other['width']*other['height']):
                duplicate = True; break
        if not duplicate:
            result.append(block)
    ids = {b['id'] for b in result}
    return [b for b in blocks if b['id'] in ids]


def finish_page(directory, blocks, skipped, patches, start):
    """Publish stable OCR IDs before waiting for the final background repair.

    text.json is a separate durable handoff: a fast repair cannot overwrite the
    ready event before the parent polls. Drafts cannot erase source pixels.
    """
    if cancelled(directory):
        write_state(directory, phase='cancelled')
        return
    result = unique_blocks(blocks)
    draft = [dict(block, replacementPNG=None, replacementAllowed=False) for block in result]
    write_json(directory, 'text', {'blocks': draft, 'skippedCount': skipped, 'elapsed': time.monotonic()-start})
    write_state(directory, phase='repairing')
    for block in result:
        future = patches[block['id']]
        while not cancelled(directory):
            try:
                patch = future.result(timeout=.05)
                block['replacementPNG'] = patch
                block['replacementAllowed'] = block['textStyle'] is None or patch is not None
                break
            except FutureTimeout:
                # Python aliases FutureTimeout to built-in TimeoutError. Do not
                # retry an actual timeout raised by a completed repair forever.
                if future.done():
                    raise
                continue
        if cancelled(directory):
            write_state(directory, phase='cancelled')
            return
    write_state(directory, phase='done', page={'blocks': result, 'skippedCount': skipped,
                'elapsed': time.monotonic()-start})


def main():
    import cv2
    import numpy as np
    import torch
    from manga_ocr import MangaOcr
    from comic_text_detector.inference import TextDetector
    from comic_text_detector.utils.textmask import refine_mask
    from loguru import logger
    logger.remove()
    torch.set_num_threads(4)
    cv2.setNumThreads(2)
    root = Path(sys.argv[1])
    runtime = Path(sys.argv[2])
    device = 'mps' if torch.backends.mps.is_available() else 'cpu'
    detector = TextDetector(root / 'models/comictextdetector.pt', device=device, input_size=1024, act='leaky')
    ocr = MangaOcr(str(root / 'models/manga'))
    ocr.model.generation_config.num_beams = 2
    restorer = BackgroundRestorer(root / 'models/big-lama.pt')
    repairs = ThreadPoolExecutor(max_workers=1, thread_name_prefix='background-repair')
    write_state(runtime, phase='ready')
    for line in sys.stdin:
        request = json.loads(line)
        directory = Path(request['directory'])
        start = time.monotonic()
        patch_jobs = {}
        try:
            if cancelled(directory):
                write_state(directory, phase='cancelled')
                continue
            write_state(directory, phase='detecting')
            image = cv2.imread(str(directory / 'page.png'))
            if image is None:
                raise ValueError('无法读取截图')
            height, width = image.shape[:2]
            # Full-size page detection runs while macOS Vision reads the image.
            # Smaller captures still use Vision's font sizes to choose resolution.
            hints = read_hints(directory, request.get('hintsPending', False)) if max(width,height) <= 1800 else []
            hint_sizes = [min(h['box'][2]-h['box'][0], h['box'][3]-h['box'][1]) for h in hints]
            resolution = 1536 if max(width, height) > 1800 or (hint_sizes and np.median(hint_sizes) < 24) else 1024
            detector.input_size = (resolution, resolution)
            raw_mask, text_mask, candidates = detector(image)
            if max(width,height) > 1800:
                hints = read_hints(directory, request.get('hintsPending', False))
            if cancelled(directory):
                write_state(directory, phase='cancelled'); continue
            recovered = recover_candidates(image, raw_mask, candidates)
            candidates = separate_caption_lines(candidates)
            if recovered:
                text_mask = cv2.bitwise_or(text_mask, refine_mask(image, raw_mask, recovered))
                candidates += recovered
            candidates = supplement_candidates(candidates, hints)
            gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)
            labels, stats, exterior = bubble_regions(gray)
            _, ink_labels, ink_stats, _ = cv2.connectedComponentsWithStats((gray < 215).astype(np.uint8), connectivity=8)
            groups, font_sizes, languages = group_candidates(candidates, labels, stats, exterior)
            filtered = reading_groups(groups, font_sizes)
            skipped = len(groups)-len(filtered)
            groups = filtered
            directions = group_geometry(candidates, groups)
            # Include small punctuation/furigana just outside the detector box.
            # The bubble outline is excluded because it extends beyond its interior.
            extra_ink = {}
            for component, box in groups.items():
                if component < 0:
                    continue
                bx, by, bw, bh, _ = stats[component]
                radius = max(8, font_sizes[component] * 1.5)
                nearby = [box[0]-radius, box[1]-radius, box[2]+radius, box[3]+radius]
                for ink_id in nearby_ink_ids(ink_labels, nearby):
                    ix, iy, iw, ih, area = ink_stats[ink_id]
                    if (area >= 2 and bx < ix and by < iy and ix+iw < bx+bw and iy+ih < by+bh
                        and max(iw, ih) < radius*2 and ix >= nearby[0] and iy >= nearby[1]
                        and ix+iw <= nearby[2] and iy+ih <= nearby[3]
                        and labels[max(0, iy-1), max(0, ix-1)] == component):
                        extra_ink.setdefault(component, []).append(ink_id)
                        box[:] = [min(box[0], int(ix)-3), min(box[1], int(iy)-3),
                                  max(box[2], int(ix+iw)+3), max(box[3], int(iy+ih)+3)]
            # Right page before left page for a spread, then top-to-bottom rows.
            boxes = sorted(groups.items(), key=lambda pair: (int((pair[1][0]+pair[1][2])/2 < width/2) if width > height*1.1 else 0,
                                                             int(pair[1][1]/max(40, height*.08)), -pair[1][0]))
            # CPU background repair overlaps MPS decoding. A single repair worker
            # keeps memory bounded and avoids competing neural inference threads.
            patch_boxes = {}
            for component, box in boxes:
                target = padded_box(box, gray, labels, stats, component, font_sizes[component]) if component > 0 else box
                patch_boxes[component] = target
                patch_jobs[component] = repairs.submit(replacement_patch, image, text_mask, target,
                    ink_labels, extra_ink.get(component, []), component < 0, restorer)
            result, accepted_patches = [], {}
            recognized = list(recognized_boxes(
                ocr, image, boxes, languages, font_sizes, directory, 8 if device == 'mps' else 1, text_mask))
            uncertainty_budget = [4]
            for index, component, box, text in sorted(recognized):
                x1, y1, x2, y2 = box
                original = text
                hint = reliable_hint(box, hints, text, horizontal=not directions[component])
                # Tight, multi-line handwriting is more reliable in Vision than a square manga crop.
                if hint and component < 0 and len(hint) >= 4:
                    text = hint
                text = restore_voicing(text, box, hints)
                text, uncertain = reconcile_fragments(ocr, image, box, text, hints, directory, uncertainty_budget)
                uncertain += confirm_fragments(ocr, image, box, text, original, hints, directory, uncertainty_budget)
                if not japanese_text(text, languages[component]):
                    # Keep "!!" and "…" in the original artwork; they are not failed OCR.
                    if not punctuation_only(text):
                        skipped += 1
                    continue
                closed = component > 0
                layouts = layout_boxes(labels, stats, component, box, font_sizes[component]) if closed else [list(box)]
                layout = layouts[0]
                x1, y1, x2, y2 = patch_boxes[component]
                # Open lettering uses only the detected glyph mask, never a solid
                # white rectangle. An outline keeps Chinese readable over artwork.
                style = None if closed else ('outlinedLight' if np.median(gray[y1:y2, x1:x2]) < 145 else 'outlinedDark')
                result.append({'id': f'b{index+1}', 'text': text,
                    'uncertainFragments': uncertain or None,
                    'replacementAllowed': False,
                    'vertical': directions[component], 'fontSize': font_sizes[component]/height*1000,
                    'layoutRegions': [{'x': b[0]/width*1000, 'y': b[1]/height*1000,
                                       'width': (b[2]-b[0])/width*1000, 'height': (b[3]-b[1])/height*1000} for b in layouts],
                    'layoutBounds': {'x': layout[0]/width*1000, 'y': layout[1]/height*1000,
                                     'width': (layout[2]-layout[0])/width*1000, 'height': (layout[3]-layout[1])/height*1000},
                    'replacementPNG': None, 'textStyle': style,
                    'bounds': {'x': x1/width*1000, 'y': y1/height*1000,
                               'width': (x2-x1)/width*1000, 'height': (y2-y1)/height*1000}})
                accepted_patches[f'b{index+1}'] = patch_jobs[component]
            finish_page(directory, result, skipped, accepted_patches, start)
        except Exception:
            traceback.print_exc(file=sys.stderr)
            write_state(directory, phase='error', message='本地识字失败，请重试。')
        finally:
            for future in patch_jobs.values():
                future.cancel()


if __name__ == '__main__':
    main()
