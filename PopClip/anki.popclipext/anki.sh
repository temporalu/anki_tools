#!/usr/bin/env bash
#  anki.sh
#  Created by cdpath on 2018/4/19.
#  Copyright © 2018 cdpath. All rights reserved.

#set -xeuo pipefail


## PopClip Env
entry=${POPCLIP_TEXT:-debug}
safe_entry=${POPCLIP_URLENCODED_TEXT:-debug}
target_deck=${POPCLIP_OPTION_TARGET_DECK:-Default}
note_type=${POPCLIP_OPTION_NOTE_TYPE:-Basic}
front_field=${POPCLIP_OPTION_FRONT_FIELD:-Front}
back_field=${POPCLIP_OPTION_BACK_FIELD:-Back}
source_field=${POPCLIP_OPTION_SOURCE_FIELD:-Source}
tag=${POPCLIP_OPTION_TAG:-debug}
app_tag=${POPCLIP_APP_NAME// /_} # replace spaces with underscore

if [[ -z "$POPCLIP_BROWSER_URL" ]]; then
    browser_source_html=
else
    browser_source_html="<a href=\\\"${POPCLIP_BROWSER_URL}\\\">${POPCLIP_BROWSER_TITLE}</a>"
fi

_cambridge()
{
    local safe_entry=$1
    python_script=$(cat <<'PY'
import re
import sys
from html import unescape
from html.parser import HTMLParser
from urllib.parse import unquote, quote
from urllib.request import Request, urlopen


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
        if self.pos_depth == 0 and "pos" in classes and "dpos" in classes:
            self.pos_depth = 1
            self.pos_text = []
            return
        if self.def_depth == 0 and "def" in classes and "ddef_d" in classes:
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


def extract_defs(html):
    parser = CambridgeParser()
    parser.feed(html)
    parts = []
    for pos in parser.order:
        defs = parser.defs.get(pos, [])
        if not defs:
            continue
        parts.append('<div class="entry">')
        parts.append(f'<h3 style="color: rgb(255, 56, 60);">{pos}</h3>')
        parts.append('<ol>')
        for i, definition in enumerate(defs, 1):
            parts.append('<li>')
            parts.append(definition["text"])
            if definition["examples"]:
                parts.append('<ul>')
                for example in definition["examples"]:
                    parts.append(f"<li>{example}</li>")
                parts.append('</ul>')
            if definition["images"]:
                parts.append('<div class="entry-images">')
                for image in definition["images"]:
                    parts.append(f'<img src="{image}" alt="">')
                parts.append('</div>')
            parts.append('</li>')
        parts.append('</ol>')
        parts.append('</div>')
    return "".join(parts)


entry = sys.argv[1] if len(sys.argv) > 1 else ""
raw = unquote(entry).strip()
normalized = re.sub(r"\s+", "-", raw.lower()).strip("-")
candidates = []
if normalized:
    candidates.append((normalized, False))
if raw:
    candidates.append((raw.lower(), False))
if entry:
    candidates.append((entry, "%" in entry))

output = ""
for cand, encoded in candidates:
    if not cand:
        continue
    path = cand if encoded else quote(cand, safe="-")
    url = f"https://dictionary.cambridge.org/dictionary/english/{path}"
    try:
        req = Request(url, headers={"User-Agent": "Mozilla/5.0", "Accept-Language": "en"})
        html = urlopen(req, timeout=20).read().decode("utf-8", errors="ignore")
    except Exception:
        continue
    output = extract_defs(html)
    if output:
        break
if output:
    print(output)
PY
)
    python3 -c "$python_script" "$safe_entry"
}

look_up()
{
    local safe_entry=$1
    definition=$(_cambridge "$safe_entry")

    if [[ -z "$definition" ]]; then
        echo "Word Not Found"
        exit 1
    else
        echo "$definition"
    fi
}


## AnkiConnect
json_escape()
{
    python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])'
}

store_images()
{
    local html=$1
    python3 - "$html" "$entry" <<'PY'
import base64
import hashlib
import json
import re
import sys
from urllib.parse import urlparse
from urllib.request import Request, urlopen

html = sys.argv[1]
entry = sys.argv[2]

img_urls = re.findall(r'<img[^>]+src="([^"]+)"', html)
seen = set()
replacements = {}

def store_image(url):
    try:
        req = Request(url, headers={"User-Agent": "Mozilla/5.0"})
        data = urlopen(req, timeout=20).read()
    except Exception:
        return None
    path = urlparse(url).path
    ext = path.rsplit(".", 1)[-1].lower() if "." in path else "jpg"
    digest = hashlib.sha256(url.encode("utf-8")).hexdigest()[:12]
    base = re.sub(r"\s+", "_", entry).strip("_") or "image"
    filename = f"{base}_{digest}.{ext}"
    payload = {
        "action": "storeMediaFile",
        "version": 5,
        "params": {
            "filename": filename,
            "data": base64.b64encode(data).decode("ascii"),
        },
    }
    try:
        req = Request(
            "http://localhost:8765",
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        res = json.loads(urlopen(req, timeout=20).read().decode("utf-8"))
    except Exception:
        return None
    if res.get("error") is not None:
        return None
    return filename

for url in img_urls:
    if url in seen:
        continue
    seen.add(url)
    filename = store_image(url)
    if filename:
        replacements[url] = filename

for src, filename in replacements.items():
    html = html.replace(f'src="{src}"', f'src="{filename}"')

print(html)
PY
}

note_exists()
{
    local query
    local escaped_query
    query=$(python3 - "$target_deck" "$front_field" "$entry" <<'PY'
import sys
deck = sys.argv[1]
field = sys.argv[2]
value = sys.argv[3]
def esc(s):
    return s.replace('"', '\\"')
query = f'deck:"{esc(deck)}" "{esc(field)}":"{esc(value)}"'
print(query)
PY
)
    escaped_query=$(printf '%s' "$query" | json_escape)
    payload=$(cat <<EOF
{
  "action": "findNotes",
  "version": 5,
  "params": {
    "query": "$escaped_query"
  }
}
EOF
)
    res=$(curl -sX POST -d "$payload" "localhost:8765")
    python3 - "$res" <<'PY'
import json,sys
raw = sys.argv[1]
if not raw:
    sys.exit(1)
try:
    data = json.loads(raw)
except Exception:
    sys.exit(1)
if data.get("error") is not None:
    sys.exit(1)
result = data.get("result") or []
sys.exit(0 if len(result) > 0 else 1)
PY
}

gen_post_data()
{
    local definition=$1
    local escaped_entry escaped_definition escaped_source
    local escaped_front_field escaped_back_field escaped_source_field
    local escaped_note_type escaped_target_deck escaped_tag escaped_app_tag
    escaped_entry=$(printf '%s' "$entry" | json_escape)
    escaped_definition=$(printf '%s' "$definition" | json_escape)
    escaped_source=$(printf '%s' "$browser_source_html" | json_escape)
    escaped_front_field=$(printf '%s' "$front_field" | json_escape)
    escaped_back_field=$(printf '%s' "$back_field" | json_escape)
    escaped_source_field=$(printf '%s' "$source_field" | json_escape)
    escaped_note_type=$(printf '%s' "$note_type" | json_escape)
    escaped_target_deck=$(printf '%s' "$target_deck" | json_escape)
    escaped_tag=$(printf '%s' "$tag" | json_escape)
    escaped_app_tag=$(printf '%s' "$app_tag" | json_escape)
    cat <<EOF
{
  "action": "addNote",
  "version": 5,
  "params": {
    "note": {
      "fields": {
        "$escaped_front_field": "$escaped_entry",
        "$escaped_back_field": "$escaped_definition",
        "$escaped_source_field": "$escaped_source"
      },
      "modelName": "$escaped_note_type",
      "deckName": "$escaped_target_deck",
      "tags": [
        "$escaped_tag",
        "$escaped_app_tag"
      ]
    }
  }
}
EOF
}

check_result()
{
    local resp=$1
    local definition=$2
    if [[ $resp != *'"error": null'* ]]; then
        if [[ $resp = "null" ]]; then
            msg="Invalid post data for AnkiConnect"
        else
            msg=$(echo "$resp" | perl -pe 's/^.*?(?<="error": ")(.*?[^\\])(?=[\."]).*?$/$1/' | sed -e 's/^"//' -e 's/"$//')
        fi
        if [[ -z "$resp" ]]; then
            msg="Did you open anki?"
        fi
        if [[ -n "$msg" ]]; then
            echo "$msg"
        fi
        exit 1
    else
        exit 0
    fi
}


## main
main()
{
    local definition
    definition=$(look_up $safe_entry) || exit 1
    if note_exists; then
        exit 0
    fi
    definition=$(store_images "$definition")
    payload=$(gen_post_data "$definition")
    res=$(curl -sX POST -d "$payload" "localhost:8765")
    check_result "$res" "$definition"
}


main
