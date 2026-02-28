#!/usr/bin/env bash
set -euo pipefail

word_file="/Users/pengyu/Documents/Github Project/anki_tools/clean/5 考研-乱序-单词.txt"
start_line=1
end_line=197
jobs=10

while [[ $# -gt 0 ]]; do
    case "$1" in
        --file)
            word_file="$2"
            shift 2
            ;;
        --start)
            start_line="$2"
            shift 2
            ;;
        --end)
            end_line="$2"
            shift 2
            ;;
        --jobs)
            jobs="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

if [[ ! -f "$word_file" ]]; then
    printf '%s\n' "未找到单词文件: $word_file"
    exit 1
fi

TAG="${TAG:-考研-乱序-单词}"
APP_TAG="${APP_TAG:-BatchImport}"
TARGET_DECK="${TARGET_DECK:-Default}"
NOTE_TYPE="${NOTE_TYPE:-PopClip}"
FRONT_FIELD="${FRONT_FIELD:-Front}"
BACK_FIELD="${BACK_FIELD:-Back}"
SOURCE_FIELD="${SOURCE_FIELD:-Source}"

TAG="$TAG" APP_TAG="$APP_TAG" TARGET_DECK="$TARGET_DECK" NOTE_TYPE="$NOTE_TYPE" FRONT_FIELD="$FRONT_FIELD" BACK_FIELD="$BACK_FIELD" SOURCE_FIELD="$SOURCE_FIELD" \
python3 - "$word_file" "$start_line" "$end_line" "$jobs" <<'PY'
import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from html import unescape
from html.parser import HTMLParser
from urllib.parse import quote, urlparse
from urllib.request import Request, urlopen

word_file = sys.argv[1]
start_line = int(sys.argv[2])
end_line = int(sys.argv[3])
jobs = int(sys.argv[4])

tag = os.environ.get("TAG", "考研-乱序-单词")
app_tag = os.environ.get("APP_TAG", "BatchImport")
target_deck = os.environ.get("TARGET_DECK", "Default")
note_type = os.environ.get("NOTE_TYPE", "PopClip")
front_field = os.environ.get("FRONT_FIELD", "Front")
back_field = os.environ.get("BACK_FIELD", "Back")
source_field = os.environ.get("SOURCE_FIELD", "Source")


class CambridgeParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.pos_depth = 0
        self.def_depth = 0
        self.def_body_depth = 0
        self.examp_depth = 0
        self.pos_text = []
        self.def_text = []
        self.examp_text = []
        self.span_stack = []
        self.current_pos = None
        self.last_def_key = None
        self.last_def_index = None
        self.order = []
        self.defs = {}

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        classes = set(attrs.get("class", "").split())
        if self.def_depth > 0 or self.examp_depth > 0:
            if tag in ("i", "em", "b", "strong", "u"):
                target = self.examp_text if self.examp_depth > 0 else self.def_text
                target.append(f"<{tag}>")
            if tag == "span":
                if "b" in classes or "bold" in classes:
                    target = self.examp_text if self.examp_depth > 0 else self.def_text
                    target.append("<b>")
                    self.span_stack.append("b")
                elif "i" in classes or "italic" in classes:
                    target = self.examp_text if self.examp_depth > 0 else self.def_text
                    target.append("<i>")
                    self.span_stack.append("i")
                elif self.examp_depth > 0 and ("lu" in classes or "dlu" in classes):
                    self.examp_text.append("<b>")
                    self.span_stack.append("b")
                else:
                    self.span_stack.append("")
        if self.pos_depth > 0:
            self.pos_depth += 1
        if self.def_depth > 0:
            self.def_depth += 1
        if self.def_body_depth > 0:
            self.def_body_depth += 1
        if self.examp_depth > 0:
            self.examp_depth += 1
        if self.pos_depth == 0 and ("dpos" in classes or ("pos" in classes and "dpos" in classes)):
            self.pos_depth = 1
            self.pos_text = []
            return
        if self.def_depth == 0 and ("ddef_d" in classes or ("def" in classes and "ddef_d" in classes)):
            self.def_depth = 1
            self.def_text = []
            return
        if self.def_body_depth == 0 and ("def-body" in classes or "ddef_b" in classes):
            self.def_body_depth = 1
            return
        if self.def_body_depth > 0 and self.examp_depth == 0:
            if "examp" in classes or "dexamp" in classes:
                self.examp_depth = 1
                self.examp_text = []
                return
        if self.last_def_key is not None and self.last_def_index is not None:
            if tag in ("amp-img", "img"):
                if "dimg_i" not in classes:
                    return
                src = attrs.get("src") or attrs.get("data-src")
                if src and "{{" not in src:
                    if src.startswith("/"):
                        if not src.startswith("/images/"):
                            return
                        src = f"https://dictionary.cambridge.org{src}"
                    if "/external/images/" in src or "/rss/images/" in src:
                        return
                    images = self.defs[self.last_def_key][self.last_def_index]["images"]
                    if src not in images:
                        images.append(src)

    def handle_endtag(self, tag):
        if tag in ("i", "em", "b", "strong", "u"):
            if self.examp_depth > 0:
                self.examp_text.append(f"</{tag}>")
            elif self.def_depth > 0:
                self.def_text.append(f"</{tag}>")
        if tag == "span":
            if self.examp_depth > 0 or self.def_depth > 0:
                if self.span_stack:
                    closing = self.span_stack.pop()
                    if closing:
                        target = self.examp_text if self.examp_depth > 0 else self.def_text
                        target.append(f"</{closing}>")
        if self.examp_depth > 0:
            self.examp_depth -= 1
            if self.examp_depth == 0:
                text = clean(self.examp_text)
                if text and self.last_def_key is not None and self.last_def_index is not None:
                    self.defs[self.last_def_key][self.last_def_index]["examples"].append(text)
        if self.def_body_depth > 0:
            self.def_body_depth -= 1
        if self.pos_depth > 0:
            self.pos_depth -= 1
            if self.pos_depth == 0:
                text = clean(self.pos_text)
                if text:
                    self.current_pos = text
                    if self.current_pos not in self.defs:
                        self.defs[self.current_pos] = []
                        self.order.append(self.current_pos)
        if self.def_depth > 0:
            self.def_depth -= 1
            if self.def_depth == 0:
                text = clean(self.def_text)
                if text:
                    pos = self.current_pos or "definition"
                    if pos not in self.defs:
                        self.defs[pos] = []
                        self.order.append(pos)
                    if not self.defs[pos] or self.defs[pos][-1]["text"] != text:
                        self.defs[pos].append({"text": text, "examples": [], "images": []})
                        self.last_def_key = pos
                        self.last_def_index = len(self.defs[pos]) - 1

    def handle_data(self, data):
        if self.pos_depth > 0:
            self.pos_text.append(data)
        if self.def_depth > 0:
            self.def_text.append(data)
        if self.examp_depth > 0:
            self.examp_text.append(data)


def clean(parts):
    text = unescape("".join(parts))
    text = re.sub(r"\s+", " ", text).strip()
    text = text.replace(" :", ":")
    return text


def extract_meta(html, entry):
    m = re.search(r'<meta\s+name="description"\s+content="([^"]+)"', html, re.IGNORECASE)
    if not m:
        return ""
    text = unescape(m.group(1)).strip()
    if not text:
        return ""
    entry_text = entry.strip().lower() if entry else ""
    if entry_text and entry_text not in text.lower():
        return ""
    return (
        '<div class="entry">'
        '<h3 style="color: rgb(255, 56, 60);">definition</h3>'
        "<ol><li>"
        + text
        + "</li></ol></div>"
    )


def extract_defs(html, entry):
    parser = CambridgeParser()
    try:
        parser.feed(html)
        parser.close()
    except Exception:
        return extract_meta(html, entry)
    parts = []
    for pos in parser.order:
        defs = parser.defs.get(pos, [])
        if not defs:
            continue
        parts.append('<div class="entry">')
        parts.append(f'<h3 style="color: rgb(255, 56, 60);">{pos}</h3>')
        parts.append("<ol>")
        for definition in defs:
            parts.append("<li>")
            parts.append(definition["text"])
            if definition["examples"]:
                parts.append("<ul>")
                for example in definition["examples"]:
                    parts.append(f"<li>{example}</li>")
                parts.append("</ul>")
            if definition["images"]:
                parts.append('<div class="entry-images">')
                for image in definition["images"]:
                    parts.append(f'<img src="{image}" alt="">')
                parts.append("</div>")
            parts.append("</li>")
        parts.append("</ol>")
        parts.append("</div>")
    if parts:
        return "".join(parts)
    return extract_meta(html, entry)


def cambridge_definition(entry):
    raw = entry.strip()
    normalized = re.sub(r"\s+", "-", raw.lower()).strip("-")
    candidates = []
    if normalized:
        candidates.append(normalized)
    if raw:
        candidates.append(raw.lower())
    output = ""
    had_error = False
    for cand in candidates:
        if not cand:
            continue
        path = quote(cand, safe="-")
        url = f"https://dictionary.cambridge.org/dictionary/english/{path}"
        try:
            req = Request(url, headers={"User-Agent": "Mozilla/5.0", "Accept-Language": "en"})
            html = urlopen(req, timeout=20).read().decode("utf-8", errors="ignore")
        except Exception:
            had_error = True
            continue
        output = extract_defs(html, raw)
        if output:
            break
    if output:
        return output
    if had_error:
        return "__CAM_DICT_ERROR__"
    return ""


def anki_request(payload):
    req = Request(
        "http://localhost:8765",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    return json.loads(urlopen(req, timeout=20).read().decode("utf-8"))


def anki_available():
    try:
        res = anki_request({"action": "version", "version": 6})
    except Exception:
        return False
    return res.get("error") is None


def start_anki():
    try:
        subprocess.Popen(["open", "-a", "Anki"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        try:
            subprocess.Popen(["open", "/Applications/Anki.app"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass


def ensure_anki_connect():
    if anki_available():
        return True
    start_anki()
    for _ in range(20):
        time.sleep(0.5)
        if anki_available():
            return True
    return False


def note_exists(entry):
    def esc(s):
        return s.replace('"', '\\"')

    query = f'deck:"{esc(target_deck)}" {esc(front_field)}:"{esc(entry)}"'
    res = anki_request({"action": "findNotes", "version": 6, "params": {"query": query}})
    if res.get("error") is not None:
        return None
    result = res.get("result") or []
    return len(result) > 0


def store_images(html, entry):
    img_urls = re.findall(r'<img[^>]+src="([^"]+)"', html)
    seen = set()
    replacements = {}

    for url in img_urls:
        if url in seen:
            continue
        seen.add(url)
        try:
            req = Request(url, headers={"User-Agent": "Mozilla/5.0"})
            data = urlopen(req, timeout=20).read()
        except Exception:
            continue
        path = urlparse(url).path
        ext = path.rsplit(".", 1)[-1].lower() if "." in path else "jpg"
        digest = hashlib.sha256(url.encode("utf-8")).hexdigest()[:12]
        base = re.sub(r"\s+", "_", entry).strip("_") or "image"
        filename = f"{base}_{digest}.{ext}"
        payload = {
            "action": "storeMediaFile",
            "version": 5,
            "params": {"filename": filename, "data": base64.b64encode(data).decode("ascii")},
        }
        try:
            res = anki_request(payload)
        except Exception:
            continue
        if res.get("error") is not None:
            continue
        replacements[url] = filename

    for src, filename in replacements.items():
        html = html.replace(f'src="{src}"', f'src="{filename}"')
    return html


def add_note(entry, definition):
    payload = {
        "action": "addNote",
        "version": 5,
        "params": {
            "note": {
                "fields": {
                    front_field: entry,
                    back_field: definition,
                    source_field: "",
                },
                "modelName": note_type,
                "deckName": target_deck,
                "tags": [tag, app_tag],
            }
        },
    }
    res = anki_request(payload)
    return res.get("error")


def process_word(word):
    exists = note_exists(word)
    if exists is None:
        return word, False, "查询重复卡片失败"
    if exists:
        return word, True, "已存在"
    definition = cambridge_definition(word)
    if definition == "__CAM_DICT_ERROR__":
        return word, False, "查询 Cambridge 失败"
    if not definition:
        return word, False, "未找到释义"
    definition = store_images(definition, word)
    err = add_note(word, definition)
    if err:
        return word, False, str(err)
    return word, True, "已添加"


def read_words(path, start, end):
    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()
    start = max(start, 1)
    end = min(end, len(lines))
    return [line.strip() for line in lines[start - 1 : end] if line.strip()]


words = read_words(word_file, start_line, end_line)
if not words:
    print("未读取到单词")
    sys.exit(1)

if not ensure_anki_connect():
    print("无法连接 Anki Connect，请确认 Anki 已启动并启用 AnkiConnect。")
    sys.exit(1)

errors = 0
success_words = set()
with ThreadPoolExecutor(max_workers=max(jobs, 1)) as executor:
    futures = {executor.submit(process_word, w): w for w in words}
    for future in as_completed(futures):
        word, ok, msg = future.result()
        status = "成功" if ok else "失败"
        print(f"{status}\t{word}\t{msg}")
        if not ok:
            errors += 1
        elif msg in ("已存在", "已添加"):
            success_words.add(word)

if success_words:
    with open(word_file, "r", encoding="utf-8") as f:
        original_lines = f.readlines()
    remaining_lines = [
        line for line in original_lines if not (line.strip() and line.strip() in success_words)
    ]
    with open(word_file, "w", encoding="utf-8") as f:
        f.writelines(remaining_lines)

sys.exit(1 if errors else 0)
PY
