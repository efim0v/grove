#!/usr/bin/env python3
"""Check the SEO head of every page in site/ (stdlib only).

Usage: python3 check_seo.py <site-dir> <base-url> [<moved-to-url>]
Example: python3 check_seo.py site https://efimov.page/grove/ https://efimov.page/brow/

A page with <meta http-equiv="refresh"> is a redirect. It needs a lang, a refresh to
its target in 0 seconds, a canonical naming the same target, a script that replaces
the location with it and keeps the hash, a link to it on the page, no hreflang, and no
robots directive that would keep the redirect from counting; the sitemap must not list
it. With <moved-to-url>, every page and 404.html must be such a redirect, each to the
same path under <moved-to-url> (404.html to <moved-to-url> itself).
"""
import json
import pathlib
import re
import sys
import xml.etree.ElementTree as ET
from html.parser import HTMLParser
from urllib.parse import urlparse

REFRESH = re.compile(r"^\s*0\s*;\s*url=(?P<url>\S+)\s*$", re.IGNORECASE)
REPLACE = re.compile(r"""location\.replace\(\s*(["'])(?P<url>[^"']+)\1\s*\+\s*location\.hash\s*\)""")


class Head(HTMLParser):
    def __init__(self):
        super().__init__()
        self.lang = None
        self.canonical = None
        self.alt = {}
        self.meta = {}
        self.refresh = None
        self.ld = []
        self.scripts = []
        self.links = []
        self._script = None

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "html":
            self.lang = a.get("lang")
        elif tag == "link" and a.get("rel") == "canonical":
            self.canonical = a.get("href")
        elif tag == "link" and a.get("rel") == "alternate" and a.get("hreflang"):
            self.alt[a["hreflang"]] = a.get("href")
        elif tag == "meta" and (a.get("http-equiv") or "").lower() == "refresh":
            self.refresh = a.get("content") or ""
        elif tag == "meta":
            self.meta[a.get("name") or a.get("property")] = a.get("content")
        elif tag == "script" and a.get("type") == "application/ld+json":
            self._script = self.ld
            self.ld.append("")
        elif tag == "script" and "src" not in a:
            self._script = self.scripts
            self.scripts.append("")
        elif tag == "a" and a.get("href"):
            self.links.append(a["href"])

    def handle_endtag(self, tag):
        if tag == "script":
            self._script = None

    def handle_data(self, data):
        if self._script is not None:
            self._script[-1] += data


def page_url(base, site, index_file):
    rel = index_file.parent.relative_to(site).as_posix()
    return base if rel == "." else f"{base}{rel}/"


def check_redirect(f, h, own_url, expected):
    errors = []
    match = REFRESH.match(h.refresh)
    target = match.group("url") if match else None
    if not target:
        errors.append(f"{f}: refresh {h.refresh!r} is not '0; url=<target>'")
        return errors
    if urlparse(target).scheme != "https":
        errors.append(f"{f}: redirect target {target!r} is not an absolute https URL")
    if target == own_url:
        errors.append(f"{f}: redirects to itself")
    if expected and target != expected:
        errors.append(f"{f}: redirects to {target!r}, not {expected!r}")
    if h.canonical != target:
        errors.append(f"{f}: canonical {h.canonical!r} != redirect target {target!r}")
    replaced = [m.group("url") for script in h.scripts for m in REPLACE.finditer(script)]
    if replaced != [target]:
        errors.append(f"{f}: needs one location.replace({target!r} + location.hash), has {replaced!r}")
    if target not in h.links:
        errors.append(f"{f}: no link to {target!r} on the page")
    if not h.lang:
        errors.append(f"{f}: <html lang> missing")
    robots = (h.meta.get("robots") or "").lower()
    if any(word in robots for word in ("noindex", "nofollow", "none")):
        errors.append(f"{f}: robots meta {robots!r} works against the redirect")
    if h.alt:
        errors.append(f"{f}: hreflang on a redirect")
    return errors


def main():
    if len(sys.argv) not in (3, 4):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    site, base = pathlib.Path(sys.argv[1]), sys.argv[2]
    moved_to = sys.argv[3] if len(sys.argv) == 4 else None
    errors, pages, redirects = [], {}, {}
    not_found = site / "404.html"
    files = sorted(site.glob("**/index.html")) + ([not_found] if not_found.exists() else [])
    for f in files:
        url = None if f == not_found else page_url(base, site, f)
        h = Head()
        h.feed(f.read_text(encoding="utf-8"))
        if h.refresh is not None:
            expected = None
            if moved_to:
                expected = moved_to if url is None else moved_to + url[len(base):]
            errors += check_redirect(f, h, url, expected)
            redirects[url or f.name] = h
            continue
        if moved_to:
            errors.append(f"{f}: not a redirect to {moved_to}")
        if url is None:
            continue
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
            if other in redirects:
                errors.append(f"{url}: hreflang {lang} -> {other} is a redirect")
            elif other not in pages:
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
            if loc in redirects:
                errors.append(f"sitemap.xml: {loc} is a redirect, not a page")
            elif loc not in pages:
                errors.append(f"sitemap.xml: {loc} is not a page in site/")
    print("\n".join(errors) or f"OK: {len(pages)} page(s), {len(redirects)} redirect(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
