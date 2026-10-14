#!/usr/bin/env python3
"""Check the SEO head of every page in site/ (stdlib only).

Usage: python3 check_seo.py <site-dir> <base-url>
Example: python3 check_seo.py site https://efimov.page/brow/
"""
import json
import pathlib
import sys
import xml.etree.ElementTree as ET
from html.parser import HTMLParser


class Head(HTMLParser):
    def __init__(self):
        super().__init__()
        self.lang = None
        self.canonical = None
        self.alt = {}
        self.meta = {}
        self.ld = []
        self._in_ld = False

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "html":
            self.lang = a.get("lang")
        elif tag == "link" and a.get("rel") == "canonical":
            self.canonical = a.get("href")
        elif tag == "link" and a.get("rel") == "alternate" and a.get("hreflang"):
            self.alt[a["hreflang"]] = a.get("href")
        elif tag == "meta":
            self.meta[a.get("name") or a.get("property")] = a.get("content")
        elif tag == "script" and a.get("type") == "application/ld+json":
            self._in_ld = True
            self.ld.append("")

    def handle_endtag(self, tag):
        if tag == "script":
            self._in_ld = False

    def handle_data(self, data):
        if self._in_ld:
            self.ld[-1] += data


def page_url(base, site, index_file):
    rel = index_file.parent.relative_to(site).as_posix()
    return base if rel == "." else f"{base}{rel}/"


def main():
    site, base = pathlib.Path(sys.argv[1]), sys.argv[2]
    errors, pages = [], {}
    for f in sorted(site.glob("**/index.html")):
        url = page_url(base, site, f)
        h = Head()
        h.feed(f.read_text(encoding="utf-8"))
        pages[url] = h
        if h.canonical != url:
            errors.append(f"{f}: canonical {h.canonical!r} != {url!r}")
        if h.meta.get("og:url") != url:
            errors.append(f"{f}: og:url {h.meta.get('og:url')!r} != {url!r}")
        if not h.lang:
            errors.append(f"{f}: <html lang> missing")
        if "noindex" in (h.meta.get("robots") or ""):
            errors.append(f"{f}: robots meta says noindex")
        if not h.meta.get("description"):
            errors.append(f"{f}: meta description missing")
        for block in h.ld:
            try:
                json.loads(block)
            except ValueError as e:
                errors.append(f"{f}: JSON-LD does not parse: {e}")
    for url, h in pages.items():
        if not h.alt:
            continue
        if url not in h.alt.values():
            errors.append(f"{url}: hreflang set does not list the page itself")
        if "x-default" not in h.alt:
            errors.append(f"{url}: hreflang set has no x-default")
        for lang, other in h.alt.items():
            if lang == "x-default":
                continue
            if other not in pages:
                errors.append(f"{url}: hreflang {lang} -> {other} is not a page in site/")
            elif pages[other].alt != h.alt:
                errors.append(f"{url}: hreflang set differs from the one on {other}")
    sitemap = site / "sitemap.xml"
    if sitemap.exists():
        ns = {"s": "http://www.sitemaps.org/schemas/sitemap/0.9"}
        root = ET.parse(sitemap).getroot()
        locs = {u.findtext("s:loc", namespaces=ns): u.findtext("s:lastmod", namespaces=ns)
                for u in root.findall("s:url", ns)}
        for url in pages:
            if url not in locs:
                errors.append(f"sitemap.xml: {url} is missing")
            elif not locs[url]:
                errors.append(f"sitemap.xml: {url} has no lastmod")
        for loc in locs:
            if loc not in pages:
                errors.append(f"sitemap.xml: {loc} is not a page in site/")
    print("\n".join(errors) or f"OK: {len(pages)} page(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
