#!/usr/bin/env python3
"""
enrich-og.py — add a <media:content> image to each feed item.

Some feeds carry no per-item image field, so readers fall back to scraping the
first <img> in the post body — which can be a WordPress emoji rather than the
post's real featured image. The featured image is usually still reachable: it is
published as og:image on the post page itself.

This reads each item's <link>, pulls og:image from that page, and injects it back
into the feed as <media:content>.

Usage: enrich-og.py <in.xml> <out.xml> [cache.xml]

  cache.xml is the previous copy of the feed. Any item whose guid already carries
  a media:content there is reused instead of refetched, so an unchanged post is
  only ever fetched from the origin once.

Exit codes: 0 = wrote out.xml, 1 = usage, 2 = nothing could be enriched.

The edit is textual on purpose. Re-serialising the XML would rewrite CDATA
sections and namespace prefixes across the whole document; inserting a single
element leaves every other byte of the upstream feed untouched.
"""

import re
import sys
import time
import urllib.error
import urllib.request
from urllib.parse import urljoin
from xml.sax.saxutils import escape as xml_escape

MEDIA_NS = "http://search.yahoo.com/mrss/"
UA = "feed-monitor/1.0 (+feed mirror; og:image lookup)"
TIMEOUT = 20
PAUSE = 0.4  # be gentle on the origin — this runs hourly

ITEM_RE = re.compile(r"<item[\s>].*?</item>", re.S | re.I)
LINK_RE = re.compile(r"<link>\s*(.*?)\s*</link>", re.S | re.I)
GUID_RE = re.compile(r"<guid[^>]*>\s*(.*?)\s*</guid>", re.S | re.I)
MEDIA_RE = re.compile(r"<media:content\b[^>]*?>", re.I)
URL_ATTR_RE = re.compile(r"\burl=[\"']([^\"']+)", re.I)


# og:image, in either attribute order, single or double quoted.
OG_RE = re.compile(
    r"<meta[^>]*?(?:property|name)=[\"']og:image[\"'][^>]*?content=[\"']([^\"']+)[\"']"
    r"|<meta[^>]*?content=[\"']([^\"']+)[\"'][^>]*?(?:property|name)=[\"']og:image[\"']",
    re.I,
)


def existing_image(item):
    """URL of an image already offered by this item, or None.

    Only image media counts. A feed can carry <media:content medium="video">
    for an embedded clip; that is not a thumbnail and must not suppress one.
    """
    for tag in MEDIA_RE.findall(item):
        medium = re.search(r"\bmedium=[\"']([^\"']+)", tag, re.I)
        mtype = re.search(r"\btype=[\"']([^\"']+)", tag, re.I)
        is_image = (medium and medium.group(1).lower() == "image") or (
            mtype and mtype.group(1).lower().startswith("image/")
        )
        if is_image:
            url = URL_ATTR_RE.search(tag)
            if url:
                return url.group(1)
    return None


def og_image(page_url):
    """Return the og:image URL for a page, or None."""
    req = urllib.request.Request(page_url, headers={"User-Agent": UA})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            # og tags live in <head>; no need to read entire post bodies.
            html = r.read(200_000).decode("utf-8", "replace")
            final = r.geturl()
    except (urllib.error.URLError, OSError, ValueError):
        return None
    m = OG_RE.search(html)
    if not m:
        return None
    return urljoin(final, (m.group(1) or m.group(2)).strip())


def cached_images(path):
    """guid -> media:content url, from a previous copy of the feed."""
    out = {}
    if not path:
        return out
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            prev = f.read()
    except OSError:
        return out
    for item in ITEM_RE.findall(prev):
        g = GUID_RE.search(item)
        url = existing_image(item)
        if g and url:
            out[g.group(1).strip()] = url
    return out


def ensure_media_ns(xml):
    """Declare xmlns:media on the root element if it isn't already there."""
    m = re.search(r"<rss\b[^>]*>", xml, re.I)
    if not m or "xmlns:media" in m.group(0):
        return xml
    opening = m.group(0)
    patched = opening[:-1].rstrip() + '\n\txmlns:media="%s"%s' % (
        MEDIA_NS,
        "/>" if opening.endswith("/>") else ">",
    )
    if opening.endswith("/>"):
        patched = opening[:-2].rstrip() + '\n\txmlns:media="%s" />' % MEDIA_NS
    return xml[: m.start()] + patched + xml[m.end():]


def main():
    if len(sys.argv) < 3:
        sys.stderr.write("usage: %s <in.xml> <out.xml> [cache.xml]\n" % sys.argv[0])
        return 1

    src, dst = sys.argv[1], sys.argv[2]
    cache = cached_images(sys.argv[3] if len(sys.argv) > 3 else None)

    with open(src, "r", encoding="utf-8", errors="replace") as f:
        xml = f.read()

    added = reused = skipped = failed = 0
    pieces, pos = [], 0

    for m in ITEM_RE.finditer(xml):
        item = m.group(0)
        pieces.append(xml[pos:m.start()])
        pos = m.end()

        if existing_image(item):
            skipped += 1                      # upstream already supplies an image
            pieces.append(item)
            continue

        link = LINK_RE.search(item)
        guid = GUID_RE.search(item)
        key = guid.group(1).strip() if guid else None

        url = cache.get(key) if key else None
        if url:
            reused += 1
        elif link:
            url = og_image(link.group(1))
            if url:
                added += 1
                time.sleep(PAUSE)
            else:
                failed += 1
        else:
            failed += 1

        if url:
            # Insert at the closing tag without touching the surrounding whitespace,
            # so the diff against upstream is purely additive.
            cut = item.lower().rindex("</item>")
            head = item[:cut]
            indent = re.search(r"[ \t]*$", head).group(0)  # match how </item> is indented
            item = head + '<media:content url="%s" medium="image" />\n%s' % (
                xml_escape(url), indent,
            ) + item[cut:]
        pieces.append(item)

    pieces.append(xml[pos:])
    out = ensure_media_ns("".join(pieces))

    with open(dst, "w", encoding="utf-8", newline="") as f:
        f.write(out)

    sys.stderr.write(
        "enrich-og: added=%d reused=%d already-present=%d unavailable=%d\n"
        % (added, reused, skipped, failed)
    )
    return 0 if (added or reused or skipped) else 2


if __name__ == "__main__":
    sys.exit(main())
