#!/usr/bin/env python3
"""
Google Takeout → S3/SQLite migration tool for server-free Immich fork.

Usage:
    python migrate.py [options]

Options:
    --env FILE          .env file path (default: .env)
    --skip-faces        Skip face detection (app detects on-device)
    --skip-ocr          Skip OCR text extraction
    --skip-labels       Skip image labeling
    --include-trashed   Include photos marked as trashed in Takeout
    --include-archived  Include archived photos (default: True)
    --include-videos    Include video files (default: True)
    --dry-run           Scan and compute checksums but do not write output
    --no-upload DIR     Write all output to DIR (mirrors S3 layout) instead of uploading
    --db-path FILE      Local SQLite output path (default: .migrate_temp.db)
    --progress FILE     Progress file path (default: .migrate_progress.json)
"""

import argparse
import json as _json
import os
import sys
import time
import uuid
from datetime import datetime, timezone

from checksum import sha1_base64
from config import TakeoutConfig
from db_builder import DbBuilder, album_id_for, insert_ocr_text
from face_pipeline import crop_face, load_face_detector
from label_pipeline import load_labeler
from local_writer import LocalWriter
from ocr_pipeline import load_ocr
from progress import ProgressTracker
from s3_uploader import (build_s3_client, content_type_for,
                          write_all, write_file)
from scanner import scan_takeout
from thumbnail import generate_thumbnail, generate_video_thumbnail


def s3_key_for(filename: str, taken_at: datetime, prefix: str = "") -> str:
    name = os.path.basename(filename)
    path = f"{taken_at.year:04d}/{taken_at.month:02d}/{taken_at.day:02d}/{name}"
    return f"{prefix}/{path}" if prefix else path


def log_error(path: str, asset_id: str, error: str,
              errors_file: str = ".migrate_errors.json"):
    errors = []
    if os.path.exists(errors_file):
        with open(errors_file) as f:
            errors = _json.load(f)
    errors.append({"asset_id": asset_id, "path": path, "error": str(error)})
    with open(errors_file, "w") as f:
        _json.dump(errors, f, indent=2)


def main():
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--env", default=".env")
    parser.add_argument("--skip-faces", action="store_true")
    parser.add_argument("--skip-ocr", action="store_true")
    parser.add_argument("--skip-labels", action="store_true")
    parser.add_argument("--include-trashed", action="store_true")
    parser.add_argument("--include-archived", action="store_true", default=True)
    parser.add_argument("--include-videos", action="store_true", default=True)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--resume", action="store_true",
                        help="Skip scan+checksums; load asset list from progress file "
                             "and open existing DB as-is. Use with --skip-ingestion "
                             "and/or --skip-faces etc. to retry only the failing phase.")
    parser.add_argument("--skip-ingestion", action="store_true",
                        help="Skip writing originals/thumbnails/face crops (phases 4-6); "
                             "only scan, build DB, and write the DB")
    parser.add_argument("--no-upload", metavar="DIR",
                        help="Write output to local DIR instead of uploading to S3")
    parser.add_argument("--db-path", default=".migrate_temp.db")
    parser.add_argument("--progress", default=".migrate_progress.json")
    args = parser.parse_args()

    no_upload = args.no_upload
    cfg = TakeoutConfig.from_env(args.env, require_s3=(no_upload is None))
    progress = ProgressTracker(args.progress)

    if args.resume:
        # ── Resume: load asset list from progress file, keep existing DB ──────
        from scanner import TakeoutPhoto, VIDEO_EXTS
        if not os.path.exists(args.progress):
            raise SystemExit(f"--resume requires an existing progress file: {args.progress}")
        if not os.path.exists(args.db_path):
            raise SystemExit(f"--resume requires an existing DB: {args.db_path}")
        db = DbBuilder(args.db_path, create=False)
        asset_list = []
        for local_path, info in progress._data["files"].items():
            asset_id = info["asset_id"]
            ext = local_path.rsplit(".", 1)[-1].lower() if "." in local_path else ""
            stub = TakeoutPhoto(
                local_path=local_path,
                filename=os.path.basename(local_path),
                extension=ext,
                is_video=ext in VIDEO_EXTS,
                sidecar=None,
                album_names=[],
            )
            asset_list.append((asset_id, stub))
        album_map: dict[str, str] = {}
        print(f"Resumed: {len(asset_list)} assets from progress file.")
    else:
        # ── Phase 1: Scan ──────────────────────────────────────────────────
        print(f"Scanning {cfg.takeout_dir} …")
        photos = scan_takeout(cfg.takeout_dir)
        if not args.include_trashed:
            photos = [p for p in photos if not (p.sidecar and p.sidecar.trashed)]
        if not args.include_videos:
            photos = [p for p in photos if not p.is_video]
        print(f"Found {len(photos)} media files.")

        # ── Phase 2: Assign IDs + checksums ───────────────────────────────
        db = DbBuilder(args.db_path)
        db.insert_owner(cfg.owner_id, cfg.owner_name, cfg.owner_email)

        asset_list: list[tuple[str, object]] = []
        seen_checksums: set[str] = set()
        album_map: dict[str, str] = {}

        print("Computing checksums …")
        for photo in photos:
            cached_id = progress.get_asset_id(photo.local_path)
            if cached_id:
                asset_list.append((cached_id, photo))
                continue

            try:
                checksum = sha1_base64(photo.local_path)
            except OSError as e:
                print(f"  SKIP (unreadable): {photo.filename} — {e}")
                continue

            if db.checksum_exists(cfg.owner_id, checksum) or checksum in seen_checksums:
                print(f"  SKIP (duplicate): {photo.filename}")
                existing_id = db.get_id_by_checksum(cfg.owner_id, checksum)
                if existing_id:
                    asset_list.append((existing_id, photo))
                continue

            taken_at = (photo.sidecar.photo_taken_at if photo.sidecar
                        else datetime.now(tz=timezone.utc))
            asset_id = s3_key_for(photo.filename, taken_at, cfg.prefix)
            seen_checksums.add(checksum)
            progress.register_file(photo.local_path, asset_id, checksum)
            db.insert_asset(asset_id, photo, checksum, cfg.owner_id,
                            int(time.time() * 1000))
            asset_list.append((asset_id, photo))

        for asset_id, photo in asset_list:
            for album_name in photo.album_names:
                if album_name not in album_map:
                    aid = album_id_for(album_name)
                    album_map[album_name] = aid
                    db.insert_album(aid, album_name)
                db.link_asset_album(asset_id, album_map[album_name])
        db.commit()
    print(f"Inserted {len(asset_list)} assets, {len(album_map)} albums.")

    # ── Phase 3: ML ────────────────────────────────────────────────────────
    face_crops: list[tuple[str, bytes]] = []
    if not (args.skip_faces and args.skip_ocr and args.skip_labels):
        face_det = None if args.skip_faces else load_face_detector(cfg.face_backend)
        ocr = None if args.skip_ocr else load_ocr(cfg.ocr_backend, cfg.ocr_languages)
        labeler = None if args.skip_labels else load_labeler(cfg.label_backend,
                                                              cfg.label_threshold)

        print(f"Running ML on {len(asset_list)} assets …")
        for i, (asset_id, photo) in enumerate(asset_list):
            if photo.is_video:
                continue
            img_path = photo.local_path

            if face_det is not None:
                try:
                    bboxes = face_det.detect(img_path)
                    for bbox in bboxes:
                        person_id = str(uuid.uuid4())
                        face_id = str(uuid.uuid4())
                        face_key = f"faces/{person_id}.jpg"
                        crop_bytes = crop_face(img_path, bbox.left, bbox.top,
                                               bbox.right, bbox.bottom)
                        if crop_bytes:
                            face_crops.append((f".thumbs/{face_key}", crop_bytes))
                        db.insert_person(person_id, cfg.owner_id,
                                         face_key if crop_bytes else None)
                        db.insert_face(face_id, asset_id, person_id, bbox)
                except Exception as e:
                    log_error(img_path, asset_id, f"face: {e}")

            if ocr is not None:
                try:
                    text = ocr.read(img_path)
                    if text.strip():
                        insert_ocr_text(db.conn(), asset_id, text)
                except Exception as e:
                    log_error(img_path, asset_id, f"ocr: {e}")

            if labeler is not None:
                try:
                    for label, conf in labeler.label(img_path):
                        db.insert_label(asset_id, label, conf)
                except Exception as e:
                    log_error(img_path, asset_id, f"label: {e}")

            if (i + 1) % 50 == 0:
                db.commit()
                print(f"  ML: {i + 1}/{len(asset_list)}")

        db.commit()

    if args.dry_run:
        print("Dry run — skipping output.")
        db.close()
        return

    # ── Build sink ─────────────────────────────────────────────────────────
    if no_upload:
        sink = LocalWriter(no_upload)
        sink_label = f"local:{no_upload}"
    else:
        s3_client = build_s3_client(cfg)
        sink = (s3_client, cfg.bucket)
        sink_label = f"s3://{cfg.bucket}"

    if args.skip_ingestion:
        print("Skipping file ingestion (--skip-ingestion).")
    else:
        # ── Phase 4: Write originals ───────────────────────────────────────
        print(f"\nWriting originals → {sink_label} (workers={cfg.upload_workers}) …")
        for asset_id, photo in asset_list:
            if progress.is_original_done(asset_id):
                continue
            ct = content_type_for(photo.extension)
            try:
                write_file(sink, asset_id, photo.local_path, ct)
                progress.mark_original_done(asset_id)
            except Exception as e:
                log_error(photo.local_path, asset_id, f"upload: {e}")
        print("Originals done.")

        # ── Phase 5: Write thumbnails ──────────────────────────────────────
        print("Generating and writing thumbnails …")
        thumb_items = []
        for asset_id, photo in asset_list:
            if progress.is_thumb_done(asset_id):
                continue
            thumb = (generate_video_thumbnail(photo.local_path)
                     if photo.is_video
                     else generate_thumbnail(photo.local_path))
            if thumb:
                thumb_key = f".thumbs/{asset_id}"
                thumb_items.append((thumb_key, thumb, "image/jpeg"))

        def _mark_thumb(key):
            progress.mark_thumb_done(key.removeprefix(".thumbs/"))

        write_all(sink, thumb_items, cfg.upload_workers, _mark_thumb)
        print(f"Thumbnails done ({len(thumb_items)} written).")

        # ── Phase 6: Write face crops ──────────────────────────────────────
        if face_crops:
            print(f"Writing {len(face_crops)} face crops …")
            write_all(sink, [(k, b, "image/jpeg") for k, b in face_crops],
                      cfg.upload_workers)
            print("Face crops done.")

    # ── Phase 7: Write DB ──────────────────────────────────────────────────
    db.close()
    print("Writing database …")
    with open(args.db_path, "rb") as f:
        db_bytes = f.read()
    write_all(sink, [(".meta/s3immich.db", db_bytes, "application/octet-stream")])
    print(f"Done. Database → {sink_label}/.meta/s3immich.db")
    print(f"Total assets: {len(asset_list)}")


if __name__ == "__main__":
    main()
