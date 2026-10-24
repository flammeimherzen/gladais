import re

html = open("/tmp/f5demo.html", encoding="utf-8", errors="replace").read()
print("len", len(html))
found = sorted(set(re.findall(r"[\w./:?=&%-]+\.(?:wav|mp3|flac|ogg)", html)))
print("count", len(found))
for item in found:
    if "promt" in item or "prompt" in item or "ref" in item:
        print(item)
