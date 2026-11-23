#!/usr/bin/env python3
"""Localization management tool for Yardlet's `.lproj/Localizable.strings` catalogs.

English (`en.lproj/Localizable.strings`) is the single source of truth. Feature PRs only update
`en.lproj`; non-English catalogs are synced independently via this tool:

  python3 -B scripts/l10n.py status
  python3 -B scripts/l10n.py extract --lang ja --out /tmp/ja-delta.json
  python3 -B scripts/l10n.py merge --lang ja /tmp/ja-translated.json
  python3 -B scripts/l10n.py prune --lang all
  python3 -B scripts/l10n.py check [--strict]
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_RESOURCES_DIR = REPO_ROOT / "Sources" / "NativeHarnessClient" / "Resources"
STRINGS_FILENAME = "Localizable.strings"
SOURCE_LOCALE = "en"

# Matches Apple NSString / printf format specifiers (and literal `%%`).
FORMAT_SPECIFIER_RE = re.compile(
    r"%(?:([1-9][0-9]*)\$)?"
    r"([-+ #0]*)"
    r"(?:([0-9]+|\*))?"
    r"(?:\.([0-9]+|\*))?"
    r"(hh|h|ll|l|q|L|z|t|j)?"
    r"([@dDiIuUxXoOfeEfFgGcCsSpAa%])"
)

CANONICAL_CONVERSION = {
    "i": "d",
    "D": "d",
    "U": "u",
    "O": "o",
    "F": "f",
}


class StringsParseError(ValueError):
    """Raised when a `.strings` file contains invalid syntax."""


@dataclass(frozen=True)
class StringsEntry:
    key: str
    value: str
    line: int


@dataclass
class ParsedCatalog:
    entries: List[StringsEntry]
    mapping: Dict[str, str]
    duplicates: List[Tuple[str, int, int]]  # (key, first_line, duplicate_line)


def unescape_strings_literal(raw: str) -> str:
    """Decode an Apple `.strings` double-quoted literal body (without surrounding quotes)."""
    out: List[str] = []
    i = 0
    n = len(raw)
    while i < n:
        ch = raw[i]
        if ch != "\\":
            out.append(ch)
            i += 1
            continue
        i += 1
        if i >= n:
            raise StringsParseError("unterminated escape sequence")
        esc = raw[i]
        i += 1
        if esc == '"':
            out.append('"')
        elif esc == "\\":
            out.append("\\")
        elif esc == "n":
            out.append("\n")
        elif esc == "r":
            out.append("\r")
        elif esc == "t":
            out.append("\t")
        elif esc == "a":
            out.append("\a")
        elif esc == "b":
            out.append("\b")
        elif esc == "f":
            out.append("\f")
        elif esc == "v":
            out.append("\v")
        elif esc in ("U", "u"):
            if i + 4 > n:
                raise StringsParseError(f"truncated \\{esc} escape sequence")
            hex_digits = raw[i : i + 4]
            try:
                out.append(chr(int(hex_digits, 16)))
            except ValueError as exc:
                raise StringsParseError(f"invalid \\{esc} escape sequence: \\{esc}{hex_digits}") from exc
            i += 4
        else:
            out.append(esc)
    return "".join(out)


def escape_strings_literal(text: str) -> str:
    """Encode a Python string for an Apple `.strings` double-quoted literal."""
    return (
        text.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\n", "\\n")
        .replace("\r", "\\r")
        .replace("\t", "\\t")
    )


def parse_strings(text: str, source_name: str = "<strings>") -> ParsedCatalog:
    """Strictly parse an Apple `.strings` file, recording duplicate keys and exact line numbers."""
    if text.startswith("\ufeff"):
        text = text[1:]

    n = len(text)
    i = 0
    line = 1

    def advance(count: int = 1) -> None:
        nonlocal i, line
        for _ in range(count):
            if text[i] == "\n":
                line += 1
            i += 1

    def skip_ws_and_comments() -> None:
        while i < n:
            ch = text[i]
            if ch in (" ", "\t", "\r", "\n"):
                advance()
            elif ch == "/" and i + 1 < n and text[i + 1] == "/":
                while i < n and text[i] != "\n":
                    advance()
            elif ch == "/" and i + 1 < n and text[i + 1] == "*":
                start_line = line
                advance(2)
                closed = False
                while i + 1 < n:
                    if text[i] == "*" and text[i + 1] == "/":
                        advance(2)
                        closed = True
                        break
                    advance()
                if not closed:
                    raise StringsParseError(f"{source_name}:{start_line}: unterminated block comment")
            else:
                break

    def read_quoted() -> Tuple[str, int]:
        start_line = line
        if i >= n or text[i] != '"':
            raise StringsParseError(f"{source_name}:{line}: expected '\"'")
        advance()
        buf: List[str] = []
        while i < n:
            ch = text[i]
            if ch == '"':
                advance()
                try:
                    return unescape_strings_literal("".join(buf)), start_line
                except StringsParseError as exc:
                    raise StringsParseError(f"{source_name}:{start_line}: {exc}") from exc
            if ch == "\\":
                if i + 1 >= n:
                    raise StringsParseError(f"{source_name}:{start_line}: unterminated escape sequence")
                buf.append(ch)
                advance()
                buf.append(text[i])
                advance()
            else:
                buf.append(ch)
                advance()
        raise StringsParseError(f"{source_name}:{start_line}: unterminated string literal")

    entries: List[StringsEntry] = []
    mapping: Dict[str, str] = {}
    first_lines: Dict[str, int] = {}
    duplicates: List[Tuple[str, int, int]] = []

    while True:
        skip_ws_and_comments()
        if i >= n:
            break
        key, key_line = read_quoted()
        skip_ws_and_comments()
        if i >= n or text[i] != "=":
            raise StringsParseError(f"{source_name}:{line}: expected '=' after key {key!r}")
        advance()
        skip_ws_and_comments()
        value, _ = read_quoted()
        skip_ws_and_comments()
        if i >= n or text[i] != ";":
            raise StringsParseError(f"{source_name}:{line}: expected ';' after value for key {key!r}")
        advance()

        if key in first_lines:
            duplicates.append((key, first_lines[key], key_line))
        else:
            first_lines[key] = key_line
        entries.append(StringsEntry(key=key, value=value, line=key_line))
        mapping[key] = value

    return ParsedCatalog(entries=entries, mapping=mapping, duplicates=duplicates)


def load_catalog(path: Path) -> ParsedCatalog:
    text = path.read_text(encoding="utf-8")
    return parse_strings(text, source_name=str(path))


def format_strings(ordered_items: Sequence[Tuple[str, str]]) -> str:
    """Serialize `(key, value)` pairs into canonical `.strings` text."""
    lines = [
        f'"{escape_strings_literal(key)}" = "{escape_strings_literal(value)}";'
        for key, value in ordered_items
    ]
    return "\n".join(lines) + ("\n" if lines else "")


def extract_format_specifiers(text: str) -> Tuple[Dict[int, str], bool]:
    """Return `(placeholders_by_1based_index, has_stray_percent)`.

    Raises `ValueError` if positional and non-positional specifiers are mixed, or if the same
    positional index is used with conflicting specifier types.
    """
    placeholders: Dict[int, str] = {}
    next_implicit = 1
    saw_positional = False
    saw_implicit = False
    spans: List[Tuple[int, int]] = []

    for match in FORMAT_SPECIFIER_RE.finditer(text):
        spans.append(match.span())
        conv = match.group(6)
        if conv == "%":
            continue

        pos_group = match.group(1)
        length = match.group(5) or ""
        canonical = length + CANONICAL_CONVERSION.get(conv, conv)

        if pos_group is not None:
            saw_positional = True
            arg_index = int(pos_group)
        else:
            saw_implicit = True
            arg_index = next_implicit
            next_implicit += 1

        existing = placeholders.get(arg_index)
        if existing is not None and existing != canonical:
            raise ValueError(
                f"conflicting format specifier types for argument {arg_index}: {existing} vs {canonical}"
            )
        placeholders[arg_index] = canonical

    if saw_positional and saw_implicit:
        raise ValueError("mixes positional and non-positional format specifiers")

    # Remove matched specifiers and `%%` to detect stray unescaped `%`.
    pieces: List[str] = []
    cursor = 0
    for start, end in spans:
        pieces.append(text[cursor:start])
        cursor = end
    pieces.append(text[cursor:])
    remainder = "".join(pieces)
    return placeholders, ("%" in remainder)


def check_format_parity(english: str, translated: str) -> Optional[str]:
    """Return an error description if `translated` is not format-specifier compatible with `english`."""
    try:
        en_specs, _ = extract_format_specifiers(english)
    except ValueError as exc:
        return f"invalid English format string: {exc}"
    try:
        tr_specs, tr_stray_percent = extract_format_specifiers(translated)
    except ValueError as exc:
        return f"invalid translated format string: {exc}"

    if en_specs != tr_specs:
        return f"format specifier mismatch: expected {en_specs}, got {tr_specs}"
    if en_specs and tr_stray_percent:
        return "unescaped '%' in format string (use '%%' for a literal percent)"
    return None


def catalog_path(resources_dir: Path, lang: str) -> Path:
    return resources_dir / f"{lang}.lproj" / STRINGS_FILENAME


def discover_locales(resources_dir: Path) -> List[str]:
    """Return sorted non-English locale codes that have a `Localizable.strings` file."""
    locales: List[str] = []
    if not resources_dir.is_dir():
        return locales
    for entry in sorted(resources_dir.iterdir()):
        if entry.is_dir() and entry.name.endswith(".lproj"):
            code = entry.name[: -len(".lproj")]
            if code in (SOURCE_LOCALE, "Base"):
                continue
            if (entry / STRINGS_FILENAME).is_file():
                locales.append(code)
    return locales


def ordered_unique_keys(catalog: ParsedCatalog) -> List[str]:
    seen = set()
    ordered: List[str] = []
    for entry in catalog.entries:
        if entry.key not in seen:
            seen.add(entry.key)
            ordered.append(entry.key)
    return ordered


def cmd_status(args: argparse.Namespace) -> int:
    resources_dir = Path(args.resources)
    en_path = catalog_path(resources_dir, SOURCE_LOCALE)
    if not en_path.is_file():
        print(f"error: English catalog not found at {en_path}", file=sys.stderr)
        return 1

    en_catalog = load_catalog(en_path)
    en_keys = set(en_catalog.mapping.keys())
    total = len(en_keys)

    rows = []
    locales = discover_locales(resources_dir)
    for lang in locales:
        path = catalog_path(resources_dir, lang)
        try:
            cat = load_catalog(path)
        except StringsParseError as exc:
            rows.append(
                {
                    "locale": lang,
                    "total": total,
                    "translated": 0,
                    "missing": total,
                    "orphan": 0,
                    "format_errors": 1,
                    "coverage": 0.0,
                    "parse_error": str(exc),
                }
            )
            continue

        lang_keys = set(cat.mapping.keys())
        translated = len(en_keys & lang_keys)
        missing = len(en_keys - lang_keys)
        orphan = len(lang_keys - en_keys)
        format_errors = len(cat.duplicates)
        for key in en_keys & lang_keys:
            if not cat.mapping[key].strip() or check_format_parity(en_catalog.mapping[key], cat.mapping[key]):
                format_errors += 1
        coverage = (translated / total * 100.0) if total else 100.0
        rows.append(
            {
                "locale": lang,
                "total": total,
                "translated": translated,
                "missing": missing,
                "orphan": orphan,
                "format_errors": format_errors,
                "coverage": round(coverage, 2),
            }
        )

    if args.json:
        print(
            json.dumps(
                {"source": SOURCE_LOCALE, "total": total, "locales": rows},
                ensure_ascii=False,
                indent=2,
            )
        )
        return 0

    print(f"Source ({SOURCE_LOCALE}): {total} keys")
    if not rows:
        print("No non-English locales found.")
        return 0

    header = f"{'Locale':<12} {'Total':>6} {'Translated':>10} {'Missing':>8} {'Orphan':>7} {'Errors':>7} {'Coverage':>9}"
    print(header)
    print("-" * len(header))
    for row in rows:
        print(
            f"{row['locale']:<12} {row['total']:>6} {row['translated']:>10} "
            f"{row['missing']:>8} {row['orphan']:>7} {row['format_errors']:>7} "
            f"{row['coverage']:>8.1f}%"
        )
    return 0


def cmd_extract(args: argparse.Namespace) -> int:
    lang = args.lang
    if lang == SOURCE_LOCALE:
        print(f"error: cannot extract against source locale {SOURCE_LOCALE!r}", file=sys.stderr)
        return 1

    resources_dir = Path(args.resources)
    en_catalog = load_catalog(catalog_path(resources_dir, SOURCE_LOCALE))
    target_path = catalog_path(resources_dir, lang)
    existing: Dict[str, str] = {}
    if target_path.is_file():
        existing = load_catalog(target_path).mapping

    delta: Dict[str, str] = {}
    for key in ordered_unique_keys(en_catalog):
        if key not in existing:
            delta[key] = en_catalog.mapping[key]

    payload = json.dumps(delta, ensure_ascii=False, indent=2) + "\n"
    if args.out:
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(payload, encoding="utf-8")
        print(f"Extracted {len(delta)} missing keys for {lang} -> {out_path}", file=sys.stderr)
    else:
        sys.stdout.write(payload)
    return 0


def cmd_merge(args: argparse.Namespace) -> int:
    lang = args.lang
    if lang == SOURCE_LOCALE:
        print(f"error: cannot merge translations into source locale {SOURCE_LOCALE!r}", file=sys.stderr)
        return 1

    resources_dir = Path(args.resources)
    en_catalog = load_catalog(catalog_path(resources_dir, SOURCE_LOCALE))
    en_keys_ordered = ordered_unique_keys(en_catalog)
    en_map = en_catalog.mapping

    translations_path = Path(args.translations)
    try:
        raw_data = json.loads(translations_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"error: failed to read {translations_path}: {exc}", file=sys.stderr)
        return 1

    if not isinstance(raw_data, dict):
        print(f"error: {translations_path} must contain a JSON object mapping key -> translation", file=sys.stderr)
        return 1

    errors: List[str] = []
    incoming: Dict[str, str] = {}
    for key, value in raw_data.items():
        if not isinstance(key, str) or not isinstance(value, str):
            errors.append(f"non-string entry for key {key!r}")
            continue
        if key not in en_map:
            errors.append(f"unknown key not in {SOURCE_LOCALE}.lproj: {key!r}")
            continue
        if not value.strip():
            errors.append(f"empty translation value for key {key!r}")
            continue
        parity_err = check_format_parity(en_map[key], value)
        if parity_err:
            errors.append(f"key {key!r}: {parity_err}")
            continue
        incoming[key] = value

    if errors:
        print(f"Refusing to merge {translations_path} into {lang}.lproj ({len(errors)} error(s)):", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    target_path = catalog_path(resources_dir, lang)
    existing_map: Dict[str, str] = {}
    existing_order: List[str] = []
    if target_path.is_file():
        existing_catalog = load_catalog(target_path)
        existing_map = dict(existing_catalog.mapping)
        existing_order = ordered_unique_keys(existing_catalog)

    added = 0
    updated = 0
    for key, value in incoming.items():
        if key not in existing_map:
            added += 1
        elif existing_map[key] != value:
            updated += 1
        existing_map[key] = value

    # Write in deterministic `en.lproj` key order, keeping any existing orphans at the end
    # (so `merge` never silently drops keys; `prune` handles orphan removal explicitly).
    ordered_items: List[Tuple[str, str]] = [
        (key, existing_map[key]) for key in en_keys_ordered if key in existing_map
    ]
    en_key_set = set(en_keys_ordered)
    for key in existing_order:
        if key not in en_key_set and key in existing_map:
            ordered_items.append((key, existing_map[key]))

    target_path.parent.mkdir(parents=True, exist_ok=True)
    target_path.write_text(format_strings(ordered_items), encoding="utf-8")
    print(f"Merged {lang}: +{added} added, ~{updated} updated, {len(ordered_items)} total -> {target_path}")
    return 0


def cmd_prune(args: argparse.Namespace) -> int:
    resources_dir = Path(args.resources)
    en_catalog = load_catalog(catalog_path(resources_dir, SOURCE_LOCALE))
    en_keys_ordered = ordered_unique_keys(en_catalog)
    en_key_set = set(en_keys_ordered)

    if args.lang == "all":
        locales = discover_locales(resources_dir)
    else:
        if args.lang == SOURCE_LOCALE:
            print(f"error: cannot prune source locale {SOURCE_LOCALE!r}", file=sys.stderr)
            return 1
        locales = [args.lang]

    for lang in locales:
        target_path = catalog_path(resources_dir, lang)
        if not target_path.is_file():
            print(f"error: catalog not found at {target_path}", file=sys.stderr)
            return 1
        cat = load_catalog(target_path)
        orphans = [k for k in ordered_unique_keys(cat) if k not in en_key_set]
        if not orphans:
            print(f"{lang}: no orphan keys")
            continue
        ordered_items = [(k, cat.mapping[k]) for k in en_keys_ordered if k in cat.mapping]
        target_path.write_text(format_strings(ordered_items), encoding="utf-8")
        print(f"{lang}: pruned {len(orphans)} orphan key(s)")
    return 0


def cmd_check(args: argparse.Namespace) -> int:
    resources_dir = Path(args.resources)
    en_path = catalog_path(resources_dir, SOURCE_LOCALE)
    errors: List[str] = []

    if not en_path.is_file():
        print(f"error: English catalog not found at {en_path}", file=sys.stderr)
        return 1

    try:
        en_catalog = load_catalog(en_path)
    except StringsParseError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1

    if not en_catalog.mapping:
        errors.append(f"[{SOURCE_LOCALE}] catalog is empty")
    for key, first_line, dup_line in en_catalog.duplicates:
        errors.append(f"[{SOURCE_LOCALE}] duplicate key {key!r} (lines {first_line} and {dup_line})")
    for entry in en_catalog.entries:
        if not entry.key.strip():
            errors.append(f"[{SOURCE_LOCALE}:{entry.line}] empty key")
        if not entry.value.strip():
            errors.append(f"[{SOURCE_LOCALE}:{entry.line}] empty value for key {entry.key!r}")
        try:
            extract_format_specifiers(entry.value)
        except ValueError as exc:
            errors.append(f"[{SOURCE_LOCALE}:{entry.line}] invalid format string for {entry.key!r}: {exc}")

    en_keys = set(en_catalog.mapping.keys())
    locales = discover_locales(resources_dir)

    for lang in locales:
        path = catalog_path(resources_dir, lang)
        try:
            cat = load_catalog(path)
        except StringsParseError as exc:
            errors.append(f"[{lang}] parse error: {exc}")
            continue

        for key, first_line, dup_line in cat.duplicates:
            errors.append(f"[{lang}] duplicate key {key!r} (lines {first_line} and {dup_line})")
        for entry in cat.entries:
            if not entry.key.strip():
                errors.append(f"[{lang}:{entry.line}] empty key")
            if not entry.value.strip():
                errors.append(f"[{lang}:{entry.line}] empty value for key {entry.key!r}")
            if entry.key in en_catalog.mapping:
                parity_err = check_format_parity(en_catalog.mapping[entry.key], entry.value)
                if parity_err:
                    errors.append(f"[{lang}:{entry.line}] key {entry.key!r}: {parity_err}")

        if args.strict:
            lang_keys = set(cat.mapping.keys())
            missing = sorted(en_keys - lang_keys)
            orphan = sorted(lang_keys - en_keys)
            if missing:
                preview = ", ".join(repr(k) for k in missing[:5])
                suffix = f" (+{len(missing) - 5} more)" if len(missing) > 5 else ""
                errors.append(f"[{lang}] missing {len(missing)} key(s): {preview}{suffix}")
            if orphan:
                preview = ", ".join(repr(k) for k in orphan[:5])
                suffix = f" (+{len(orphan) - 5} more)" if len(orphan) > 5 else ""
                errors.append(f"[{lang}] {len(orphan)} orphan key(s): {preview}{suffix}")

    if errors:
        print(f"Localization check failed ({len(errors)} error(s)):", file=sys.stderr)
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 1

    mode = "strict" if args.strict else "standard"
    print(f"OK ({mode}): {SOURCE_LOCALE} ({len(en_keys)} keys) + {len(locales)} locale(s): {', '.join(locales) or 'none'}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Manage Yardlet's `.lproj/Localizable.strings` localization catalogs."
    )
    parser.add_argument(
        "--resources",
        default=str(DEFAULT_RESOURCES_DIR),
        help="Path to the Resources directory containing *.lproj folders.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_status = sub.add_parser("status", help="Show per-locale coverage and health counts.")
    p_status.add_argument("--json", action="store_true", help="Emit JSON output.")
    p_status.set_defaults(func=cmd_status)

    p_extract = sub.add_parser("extract", help="Extract keys missing from a target locale as JSON.")
    p_extract.add_argument("--lang", required=True, help="Target locale code (e.g. ko, ja, zh-Hans).")
    p_extract.add_argument("--out", help="Write JSON output to this file instead of stdout.")
    p_extract.set_defaults(func=cmd_extract)

    p_merge = sub.add_parser("merge", help="Validate and merge a JSON translation delta into a locale.")
    p_merge.add_argument("--lang", required=True, help="Target locale code (e.g. ko, ja, zh-Hans).")
    p_merge.add_argument("translations", help="Path to JSON file mapping key -> translated value.")
    p_merge.set_defaults(func=cmd_merge)

    p_prune = sub.add_parser("prune", help="Remove orphan keys no longer present in en.lproj.")
    p_prune.add_argument("--lang", required=True, help="Target locale code, or 'all'.")
    p_prune.set_defaults(func=cmd_prune)

    p_check = sub.add_parser("check", help="Validate catalog syntax, duplicates, values, and format specifiers.")
    p_check.add_argument(
        "--strict",
        action="store_true",
        help="Also fail if any non-English locale has missing or orphan keys.",
    )
    p_check.set_defaults(func=cmd_check)

    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
