#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Dict, List, Set

import requests
from PIL import Image

API_BASE = "https://wallhaven.cc/api/v1"
ID_RE = re.compile(r"([a-z0-9]{6})", re.IGNORECASE)


def load_api_key(path: Path) -> str:
    if not path.exists():
        raise RuntimeError(f"API key file missing: {path}")
    key = path.read_text(encoding="utf-8").strip()
    if not key or key in {"PUT_YOUR_WALLHAVEN_API_KEY_HERE", "YOUR_API_KEY_HERE"}:
        raise RuntimeError(f"API key is missing/placeholder in: {path}")
    return key


def request_json(session: requests.Session, url: str, params: Dict[str, str]) -> Dict:
    r = session.get(url, params=params, timeout=30)
    r.raise_for_status()
    payload = r.json()
    err = payload.get("error")
    if err:
        raise RuntimeError(f"API error: {err}")
    return payload


def extract_id(item: Dict) -> str:
    wid = item.get("id", "")
    if wid:
        return str(wid)
    p = str(item.get("path", ""))
    m = ID_RE.search(p)
    return m.group(1) if m else ""


def collect_existing_ids(*dirs: Path) -> Set[str]:
    out: Set[str] = set()
    for d in dirs:
        if not d.exists():
            continue
        for f in d.glob("*"):
            m = ID_RE.search(f.name)
            if m:
                out.add(m.group(1).lower())
    return out


def collect_ids_from_dir(d: Path) -> Set[str]:
    out: Set[str] = set()
    if not d.exists():
        return out
    for f in d.glob("*"):
        m = ID_RE.search(f.name)
        if m:
            out.add(m.group(1).lower())
    return out


def crop_preserve_height(img: Image.Image, target_w: int, target_h: int) -> Image.Image:
    # Preserve full height and crop width to target aspect when possible.
    target_ratio = target_w / target_h
    new_w = int(round(img.height * target_ratio))
    if img.width > new_w:
        left = (img.width - new_w) // 2
        return img.crop((left, 0, left + new_w, img.height))
    return img


def process_image(src: Path, dst: Path, target_w: int, target_h: int) -> None:
    with Image.open(src) as im:
        im = im.convert("RGB")
        im = crop_preserve_height(im, target_w, target_h)
        im = im.resize((target_w, target_h), Image.Resampling.LANCZOS)
        dst.parent.mkdir(parents=True, exist_ok=True)
        im.save(dst, format="PNG", optimize=True)


def list_collection_items(session: requests.Session, key: str, username: str, label: str, max_pages: int) -> List[Dict]:
    c = request_json(session, f"{API_BASE}/collections", {"apikey": key})
    target_id = None
    for entry in c.get("data", []):
        if str(entry.get("label", "")) == label:
            target_id = str(entry.get("id"))
            break
    if not target_id:
        raise RuntimeError(f"Collection not found by name: {label}")

    items: List[Dict] = []
    for page in range(1, max_pages + 1):
        p = request_json(
            session,
            f"{API_BASE}/collections/{username}/{target_id}",
            {"apikey": key, "page": str(page)},
        )
        data = p.get("data", [])
        if not data:
            break
        items.extend(data)
    return items


def list_search_items(session: requests.Session, key: str, count: int, max_pages: int, params: Dict[str, str]) -> List[Dict]:
    items: List[Dict] = []
    for page in range(1, max_pages + 1):
        qp = dict(params)
        qp.update({"apikey": key, "page": str(page)})
        p = request_json(session, f"{API_BASE}/search", qp)
        data = p.get("data", [])
        if not data:
            break
        items.extend(data)
        if len(items) >= count:
            break
    return items[:count]


def download_file(session: requests.Session, url: str, out: Path) -> None:
    r = session.get(url, timeout=60)
    r.raise_for_status()
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(r.content)


def ext_from_url(url: str) -> str:
    s = url.rsplit(".", 1)
    if len(s) == 2 and len(s[1]) <= 5:
        return "." + s[1].lower()
    return ".jpg"


def find_existing_raw(raw_dir: Path, wid: str) -> Path | None:
    matches = sorted(raw_dir.glob(f"{wid}.*"))
    return matches[0] if matches else None


def main() -> int:
    ap = argparse.ArgumentParser(description="Laptop Wallhaven sync + Kobo Libra Colour post-process")
    ap.add_argument("--mode", choices=["search", "collection"], required=True)
    ap.add_argument("--api-key-file", default="wallhaven.cred")
    ap.add_argument("--download-dir", default="laptop-download/raw")
    ap.add_argument("--output-dir", default="laptop-download/processed")
    ap.add_argument("--max-pages", type=int, default=20)

    ap.add_argument("--query", default="")
    ap.add_argument("--categories", default="111")
    ap.add_argument("--purity", default="100")
    ap.add_argument("--sorting", default="date_added")
    ap.add_argument("--order", default="desc")
    ap.add_argument("--atleast", default="")
    ap.add_argument("--ratios", default="")
    ap.add_argument("--colors", default="")
    ap.add_argument("--top-range", dest="top_range", default="")
    ap.add_argument("--count", type=int, default=10)

    ap.add_argument("--collection-name", default="")
    ap.add_argument("--collection-username", default="")

    ap.add_argument("--target-width", type=int, default=1680)
    ap.add_argument("--target-height", type=int, default=1264)

    args = ap.parse_args()

    key = load_api_key(Path(args.api_key_file))
    raw_dir = Path(args.download_dir)
    out_dir = Path(args.output_dir)
    raw_dir.mkdir(parents=True, exist_ok=True)
    out_dir.mkdir(parents=True, exist_ok=True)

    raw_ids = collect_ids_from_dir(raw_dir)
    processed_ids = collect_ids_from_dir(out_dir)

    # First: process backlog from raw/ that has not been processed yet.
    backlog = sorted(raw_ids - processed_ids)
    if backlog:
        print(f"Processing {len(backlog)} raw-only wallpaper(s) not yet processed.")
        for i, wid in enumerate(backlog, start=1):
            raw_path = find_existing_raw(raw_dir, wid)
            if not raw_path:
                continue
            out_path = out_dir / f"{wid}_kobo_{args.target_width}x{args.target_height}.png"
            print(f"[backlog {i}/{len(backlog)}] {wid}")
            process_image(raw_path, out_path, args.target_width, args.target_height)
        processed_ids = collect_ids_from_dir(out_dir)

    with requests.Session() as session:
        if args.mode == "collection":
            if not args.collection_name or not args.collection_username:
                raise RuntimeError("collection mode requires --collection-name and --collection-username")
            items = list_collection_items(session, key, args.collection_username, args.collection_name, args.max_pages)
        else:
            q = {
                "q": args.query,
                "categories": args.categories,
                "purity": args.purity,
                "sorting": args.sorting,
                "order": args.order,
            }
            if args.atleast:
                q["atleast"] = args.atleast
            if args.ratios:
                q["ratios"] = args.ratios
            if args.colors:
                q["colors"] = args.colors
            if args.sorting == "toplist" and args.top_range:
                q["topRange"] = args.top_range
            items = list_search_items(session, key, args.count, args.max_pages, q)

        candidates = []
        seen_this_run: Set[str] = set()
        for item in items:
            wid = extract_id(item).lower()
            path = item.get("path", "")
            if not wid or not path:
                continue
            # Only skip if already processed. Raw-only should still be processed.
            if wid in processed_ids or wid in seen_this_run:
                continue
            seen_this_run.add(wid)
            candidates.append((wid, path))

        if not candidates:
            print("No new wallpapers to download (all already present).")
            return 0

        print(f"Will download and process {len(candidates)} new wallpaper(s).")
        for i, (wid, url) in enumerate(candidates, start=1):
            ext = ext_from_url(url)
            raw_path = find_existing_raw(raw_dir, wid) or (raw_dir / f"{wid}{ext}")
            out_path = out_dir / f"{wid}_kobo_{args.target_width}x{args.target_height}.png"
            print(f"[{i}/{len(candidates)}] {wid}")
            if not raw_path.exists():
                download_file(session, url, raw_path)
            # pipeline order: crop(preserve height) -> resize
            process_image(raw_path, out_path, args.target_width, args.target_height)

    print(f"Done. Raw: {raw_dir} | Processed: {out_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
