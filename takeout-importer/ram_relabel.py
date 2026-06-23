#!/usr/bin/env python3
"""
Re-labels all images in the Immich SQLite database using RAM+
(Recognize Anything Model Plus) instead of CLIP.

Clears every 'imageLabeler' row in asset_label_entity, runs RAM on every
image found on disk, and writes the new tags back.  The FTS labels column
is kept in sync so full-text search picks up the new tags immediately.

Usage:
    python ram_relabel.py [options]

Options:
    --db PATH          Path to s3immich.db  (default: output/.meta/s3immich.db)
    --images-dir DIR   Root folder that holds year/month/day/file images
                       (default: output)
    --device DEVICE    Inference device: cpu | cuda | cuda:0 | mps
                       (auto-detected if omitted)
    --dry-run          Print detected tags without writing to the database
    --resume           Skip images that already have RAM labels in the DB
"""

from __future__ import annotations

import argparse
import os
import sqlite3
import sys
from pathlib import Path


# ── helpers ───────────────────────────────────────────────────────────────────

def _find_db(images_dir: Path) -> Path:
    for candidate in [
        images_dir / ".meta" / "s3immich.db",
        images_dir / "metadata" / "s3immich.db",
    ]:
        if candidate.exists():
            return candidate
    raise FileNotFoundError(
        f"Cannot find s3immich.db under {images_dir}. "
        "Pass --db to specify the path explicitly."
    )


def _auto_device() -> str:
    import torch
    if torch.cuda.is_available():
        return "cuda"
    if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def _load_model(device: str):
    from ram.models import ram_plus
    from ram import get_transform
    from huggingface_hub import hf_hub_download
    print("Loading RAM+ model (downloads ~1.5 GB on first run)…", flush=True)
    weights_path = hf_hub_download(
        repo_id="xinyu1205/recognize-anything-plus-model",
        filename="ram_plus_swin_large_14m.pth",
    )
    model = ram_plus(
        pretrained=weights_path,
        image_size=384,
        vit="swin_l",
    )
    model.eval()
    return model.to(device), get_transform(image_size=384)


def _run_ram(model, transform, img_path: str, device: str) -> list[str]:
    from PIL import Image
    import torch
    from ram import inference_ram

    img = transform(Image.open(img_path).convert("RGB")).unsqueeze(0).to(device)
    with torch.no_grad():
        res = inference_ram(img, model)
    return [t.strip() for t in res[0].split("|") if t.strip()]


# ── main ──────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--db", default="")
    parser.add_argument("--images-dir", default="output")
    parser.add_argument("--device", default="")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--resume", action="store_true",
                        help="Skip assets that already have RAM labels")
    args = parser.parse_args()

    images_dir = Path(args.images_dir).resolve()
    db_path = Path(args.db).resolve() if args.db else _find_db(images_dir)
    device = args.device or _auto_device()

    print(f"Device    : {device}")
    print(f"DB        : {db_path}")
    print(f"Images dir: {images_dir}")

    conn = sqlite3.connect(str(db_path))
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA synchronous = NORMAL")
    conn.execute("PRAGMA cache_size = -32000")
    conn.execute("PRAGMA temp_store = MEMORY")

    # All image assets (type=1 = photo)
    rows = conn.execute(
        "SELECT id FROM remote_asset_entity WHERE type = 1"
    ).fetchall()
    all_ids = [r[0] for r in rows]

    if args.resume:
        done = {
            r[0] for r in conn.execute(
                "SELECT DISTINCT asset_id FROM asset_label_entity WHERE source = 'imageLabeler'"
            ).fetchall()
        }
        asset_ids = [a for a in all_ids if a not in done]
        print(f"\n{len(all_ids)} total | {len(done)} already labelled | "
              f"{len(asset_ids)} to process")
    else:
        asset_ids = all_ids
        print(f"\n{len(asset_ids)} image assets to (re)label")

    if not asset_ids:
        print("Nothing to do.")
        conn.close()
        return

    try:
        model, transform = _load_model(device)
    except ImportError:
        print(
            "\nERROR: The 'ram' package is not installed.\n"
            "Run this command first:\n\n"
            "  ! .venv/bin/pip install git+https://github.com/xinyu1205/recognize-anything.git\n",
            file=sys.stderr,
        )
        sys.exit(1)

    print("Model ready.\n")

    if not args.dry_run and not args.resume:
        conn.execute("DELETE FROM asset_label_entity WHERE source = 'imageLabeler'")
        conn.commit()
        print("Cleared existing imageLabeler labels.\n")

    processed = skipped = errors = 0

    for i, asset_id in enumerate(asset_ids, 1):
        img_path = images_dir / asset_id
        if not img_path.exists():
            skipped += 1
            continue

        try:
            tags = _run_ram(model, transform, str(img_path), device)
        except Exception as exc:
            print(f"  WARN [{i}] {asset_id}: {exc}", flush=True)
            errors += 1
            continue

        if args.dry_run:
            print(f"  [{i}/{len(asset_ids)}] {asset_id}")
            print(f"    tags: {' | '.join(tags[:10])}")
            processed += 1
            continue

        for tag in tags:
            conn.execute(
                "INSERT INTO asset_label_entity (asset_id, label, source, confidence) "
                "VALUES (?, ?, 'imageLabeler', 1.0)",
                (asset_id, tag),
            )

        label_str = " ".join(tags)
        existing_fts = conn.execute(
            "SELECT ocr_text FROM asset_fts WHERE asset_id = ?", (asset_id,)
        ).fetchone()
        if existing_fts:
            conn.execute(
                "UPDATE asset_fts SET labels = ? WHERE asset_id = ?",
                (label_str, asset_id),
            )
        else:
            conn.execute(
                "INSERT INTO asset_fts (asset_id, ocr_text, labels) VALUES (?, '', ?)",
                (asset_id, label_str),
            )

        processed += 1

        if i % 100 == 0:
            conn.commit()
            print(f"  {i}/{len(asset_ids)}  ({errors} errors)", flush=True)

    if not args.dry_run:
        conn.commit()

    conn.close()

    print(
        f"\nFinished: {processed} labelled, {skipped} missing on disk, {errors} errors."
    )


if __name__ == "__main__":
    main()
