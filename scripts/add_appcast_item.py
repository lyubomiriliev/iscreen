"""Adds a release to the Sparkle appcast (newest first).

Usage: add_appcast_item.py appcast.xml VERSION BUILD MIN_OS URL "SIGNATURE_ATTRS" "NOTES"
SIGNATURE_ATTRS is sign_update's output: sparkle:edSignature="…" length="…"
"""
import email.utils
import html
import os
import sys

MARKER = "    <!-- releases -->\n"
SKELETON = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>iScreen</title>
{MARKER}  </channel>
</rss>
"""


def notes_html(notes: str) -> str:
    lines = [line.strip() for line in notes.splitlines() if line.strip()]
    bullets = [line[1:].strip() for line in lines if line.startswith(("-", "•"))]
    if bullets and len(bullets) == len(lines):
        return "<ul>" + "".join(f"<li>{html.escape(b)}</li>" for b in bullets) + "</ul>"
    return "".join(f"<p>{html.escape(line)}</p>" for line in lines)


def main() -> None:
    path, version, build, min_os, url, signature, notes = sys.argv[1:8]
    content = open(path).read() if os.path.exists(path) else SKELETON
    item = f"""    <item>
      <title>Version {html.escape(version)}</title>
      <pubDate>{email.utils.formatdate(localtime=True)}</pubDate>
      <sparkle:version>{html.escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{html.escape(min_os)}</sparkle:minimumSystemVersion>
      <description><![CDATA[{notes_html(notes)}]]></description>
      <enclosure url="{html.escape(url)}" type="application/octet-stream" {signature.strip()} />
    </item>
"""
    if MARKER not in content:
        sys.exit(f"{path} is missing the '<!-- releases -->' marker")
    with open(path, "w") as f:
        f.write(content.replace(MARKER, MARKER + item, 1))


if __name__ == "__main__":
    main()
