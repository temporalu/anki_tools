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
skip_open_on_fail=0
user_cancelled=0
LOOKUP_DEFINITION=
LOOKUP_MESSAGE=

url_encode()
{
    python3 - "$1" <<'PY'
import sys
from urllib.parse import quote

text = sys.argv[1] if len(sys.argv) > 1 else ""
print(quote(text, safe="-"))
PY
}

update_entry()
{
    entry=$1
    safe_entry=$entry
}

prompt_for_entry()
{
    local current=$1
    local result
    local status
    result=$(
/usr/bin/osascript - "$current" 2>/dev/null <<'APPLESCRIPT'
on run argv
    set currentText to item 1 of argv
    tell application "System Events"
        set frontApp to name of first application process whose frontmost is true
    end tell
    if frontApp is not "" then
        tell application frontApp to activate
    end if
    set dialogResult to display dialog "请输入要查询的内容：" default answer currentText buttons {"取消", "确定"} default button "确定"
    if button returned of dialogResult is "取消" then
        error number -128
    end if
    return text returned of dialogResult
end run
APPLESCRIPT
)
    status=$?
    if [[ $status -ne 0 ]]; then
        return 130
    fi
    result=$(printf '%s' "$result" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [[ -z "$result" ]]; then
        return 1
    fi
    printf '%s' "$result"
    return 0
}

has_option_key()
{
    local flags=${POPCLIP_MODIFIER_FLAGS:-0}
    if [[ -z "$flags" ]]; then
        echo "0"
        return 0
    fi
    if (( (flags & 524288) != 0 )); then
        echo "1"
    else
        echo "0"
    fi
}

_cambridge()
{
    local raw_entry=$1
    python_script=$(cat <<'PY'
import re
import sys
from html import unescape
from html.parser import HTMLParser
from urllib.parse import quote
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
    m = re.search(r'<meta\\s+name=\"description\"\\s+content=\"([^\"]+)\"', html, re.IGNORECASE)
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
        '<ol><li>'
        + text
        + '</li></ol></div>'
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
    if parts:
        return "".join(parts)
    return extract_meta(html, entry)


entry = sys.argv[1] if len(sys.argv) > 1 else ""
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
    print(output)
elif had_error:
    print("__CAM_DICT_ERROR__")
    sys.exit(2)
PY
)
    local output
    output=$(python3 -c "$python_script" "$raw_entry")
    status=$?
    if (( status == 2 )); then
        printf '%s' "$output"
        return 2
    fi
    if (( status != 0 )); then
        return 3
    fi
    printf '%s' "$output"
}

look_up()
{
    local definition
    local attempts=0
    local max_attempts=2
    local allow_prompt=${1:-1}
    LOOKUP_DEFINITION=
    LOOKUP_MESSAGE=
    while (( attempts < max_attempts )); do
        definition=$(_cambridge "$entry")
        status=$?
        if (( status == 2 )); then
            LOOKUP_MESSAGE="查询 Cambridge 失败，请检查网络。"
            return 1
        fi
        if (( status == 3 )); then
            LOOKUP_MESSAGE="解析 Cambridge 失败，请稍后再试。"
            return 1
        fi
        if [[ -n "$definition" ]]; then
            LOOKUP_DEFINITION="$definition"
            return 0
        fi
        attempts=$((attempts + 1))
        if (( attempts >= max_attempts )); then
            break
        fi
        if [[ "$allow_prompt" != "1" ]]; then
            break
        fi
        new_entry=$(prompt_for_entry "$entry")
        prompt_status=$?
        if (( prompt_status != 0 )); then
            skip_open_on_fail=1
            if (( prompt_status == 130 )); then
                user_cancelled=1
                LOOKUP_MESSAGE="已取消查询。"
            else
                LOOKUP_MESSAGE="未输入查询词。"
            fi
            return 1
        fi
        update_entry "$new_entry"
        allow_prompt=0
    done
    LOOKUP_MESSAGE="未找到释义。"
    return 1
}


## AnkiConnect
json_escape()
{
    python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])'
}

anki_connect_available()
{
    local resp
    resp=$(curl -s --max-time 2 -X POST -d '{"action":"version","version":6}' "http://localhost:8765")
    [[ $resp == *'"error": null'* ]]
}

start_anki_app()
{
    if [[ -d "/Applications/Anki.app" ]]; then
        open "/Applications/Anki.app" >/dev/null 2>&1
    else
        open -a "Anki" >/dev/null 2>&1
    fi
}

ensure_anki_connect()
{
    if anki_connect_available; then
        return 0
    fi
    start_anki_app
    local attempts=0
    local max_attempts=20
    while (( attempts < max_attempts )); do
        sleep 0.5
        if anki_connect_available; then
            return 0
        fi
        attempts=$((attempts + 1))
    done
    return 1
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
    local allow_prompt=1
    if [[ "$(has_option_key)" == "1" ]]; then
        new_entry=$(prompt_for_entry "$entry")
        prompt_status=$?
        if (( prompt_status != 0 )); then
            skip_open_on_fail=1
            if (( prompt_status == 130 )); then
                user_cancelled=1
                message="已取消查询。"
            else
                message="未输入查询词。"
            fi
            if [[ -n "$message" ]]; then
                echo "$message"
            fi
            exit 1
        fi
        update_entry "$new_entry"
        allow_prompt=0
    fi
    look_up "$allow_prompt"
    status=$?
    definition=$LOOKUP_DEFINITION
    message=$LOOKUP_MESSAGE
    if (( status != 0 )); then
        if [[ -n "$definition" ]]; then
            echo "$definition"
        else
            if [[ -n "$message" ]]; then
                echo "$message"
            else
                echo "未找到释义。"
            fi
        fi
        if [[ "$skip_open_on_fail" != "1" && "$user_cancelled" != "1" && -n "$entry" ]]; then
            encoded=$(url_encode "$entry")
            if [[ -n "$encoded" ]]; then
                open "https://dictionary.cambridge.org/dictionary/english/$encoded" >/dev/null 2>&1
            fi
        fi
        exit 1
    fi
    if ! ensure_anki_connect; then
        echo "无法连接 Anki Connect，请确认 Anki 已启动并启用 AnkiConnect。"
        exit 1
    fi
    if note_exists; then
        exit 0
    fi
    definition=$(store_images "$definition")
    payload=$(gen_post_data "$definition")
    res=$(curl -sX POST -d "$payload" "localhost:8765")
    check_result "$res" "$definition"
}


main
