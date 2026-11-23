#!/usr/bin/env python3
"""Unit tests for scripts/l10n.py."""

from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from typing import Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import l10n  # noqa: E402


class StringsParserTests(unittest.TestCase):
    def test_parses_comments_escapes_and_round_trips(self) -> None:
        raw = (
            "\ufeff/* Leading comment\n"
            "   spanning lines */\n"
            "// Line comment\n"
            '"Hello \\"world\\"" = "Line 1\\nLine 2\\t\\\\end";\n'
            '"Unicode" = "Snowman \\U2603 Emoji \\UD83D\\UDE00 Lower \\u2603";\n'
        )
        cat = l10n.parse_strings(raw, "test.strings")
        self.assertEqual(cat.duplicates, [])
        self.assertEqual(cat.mapping['Hello "world"'], "Line 1\nLine 2\t\\end")
        # Apple .strings decodes uppercase \UXXXX (including UTF-16 surrogate pairs), not lowercase \u.
        self.assertEqual(cat.mapping["Unicode"], "Snowman ☃ Emoji 😀 Lower u2603")

        serialized = l10n.format_strings([(e.key, e.value) for e in cat.entries])
        reparsed = l10n.parse_strings(serialized, "roundtrip.strings")
        self.assertEqual(reparsed.mapping, cat.mapping)

    def test_rejects_unpaired_surrogates(self) -> None:
        with self.assertRaises(l10n.StringsParseError):
            l10n.parse_strings('"BadHigh" = "\\UD83D";\n')
        with self.assertRaises(l10n.StringsParseError):
            l10n.parse_strings('"BadLow" = "\\UDE00";\n')

    def test_detects_duplicates_and_syntax_errors(self) -> None:
        dup = l10n.parse_strings('"A" = "1";\n"B" = "2";\n"A" = "3";\n')
        self.assertEqual(dup.duplicates, [("A", 1, 3)])
        self.assertEqual(dup.mapping["A"], "3")

        for broken in [
            '"A" = "missing semicolon"',
            '"A" "missing equals";',
            '"unterminated = "x";',
            '/* unterminated comment\n"A" = "1";',
        ]:
            with self.assertRaises(l10n.StringsParseError):
                l10n.parse_strings(broken)


class FormatSpecifierParityTests(unittest.TestCase):
    def test_valid_parity_including_positional_reordering(self) -> None:
        self.assertIsNone(l10n.check_format_parity("Hello %@", "こんにちは %@"))
        self.assertIsNone(l10n.check_format_parity("%1$@ to %2$lld", "%2$lld から %1$@"))
        self.assertIsNone(l10n.check_format_parity("%@ (%lld)", "%2$lld: %1$@"))
        self.assertIsNone(l10n.check_format_parity("%.1f%% of input", "入力の %.1f%%"))
        self.assertIsNone(l10n.check_format_parity("CPU %", "CPU %"))
        self.assertIsNone(l10n.check_format_parity("Battery under 20%", "バッテリー残量 20% 未満"))
        # Prose percentages must not false-positive as space-flagged printf specifiers.
        self.assertIsNone(l10n.check_format_parity("50% done", "50% 完了"))
        self.assertIsNone(l10n.check_format_parity("10% off", "10% オフ"))
        self.assertIsNone(l10n.check_format_parity("20% faster", "20% 高速"))
        self.assertIsNone(l10n.check_format_parity("100% safe", "100% 安全"))
        self.assertIsNone(l10n.check_format_parity("Count %u", "件数 %u"))
        self.assertIsNone(l10n.check_format_parity("Value %d", "値 %i"))

    def test_rejects_broken_or_mismatched_specifiers(self) -> None:
        self.assertIsNotNone(l10n.check_format_parity("Hello %@", "Hello"))
        self.assertIsNotNone(l10n.check_format_parity("Hello %@", "Hello %@ %@"))
        self.assertIsNotNone(l10n.check_format_parity("Count %lld", "Count %d"))
        self.assertIsNotNone(l10n.check_format_parity("Count %lld", "Count %@"))
        self.assertIsNotNone(l10n.check_format_parity("%1$@ %2$@", "%1$@ %@"))
        self.assertIsNotNone(l10n.check_format_parity("Plain text", "Plain %@"))
        self.assertIsNotNone(l10n.check_format_parity("%1$@ %1$@", "%1$@ %1$lld"))

        # "%lld% left" fails specifically due to stray unescaped '%'.
        specs, has_stray = l10n.extract_format_specifiers("%lld% left")
        self.assertEqual(specs, {1: "lld"})
        self.assertTrue(has_stray)
        err = l10n.check_format_parity("%lld%% left", "%lld% left")
        self.assertIsNotNone(err)
        self.assertIn("unescaped '%'", err or "")

        # English format string with unescaped '%' is also flagged.
        en_err = l10n.check_format_parity("%lld% left", "%lld%% left")
        self.assertIsNotNone(en_err)
        self.assertIn("unescaped '%'", en_err or "")

        # Malformed percent sequences like %50%, %1$%, %ll% are not accepted as %%.
        for bad in ("%lld %50%", "%lld %1$%", "%lld %ll%"):
            _, bad_stray = l10n.extract_format_specifiers(bad)
            self.assertTrue(bad_stray, f"expected stray percent for {bad!r}")
            self.assertIsNotNone(l10n.check_format_parity("%lld%% done", bad))

        # Dynamic '*' width/precision specifiers are rejected.
        self.assertIsNotNone(l10n.check_format_parity("Count %d", "Count %*d"))
        self.assertIsNotNone(l10n.check_format_parity("Value %f", "Value %.*f"))


class CLICommandTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.resources = Path(self.tmp.name) / "Resources"
        (self.resources / "en.lproj").mkdir(parents=True)
        (self.resources / "en.lproj" / "Localizable.strings").write_text(
            '"First" = "First";\n'
            '"Archive count" = "Archives %1$lld items in %2$@.";\n'
            '"Third" = "Third";\n',
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def run_cli(self, *argv: str) -> Tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = l10n.main(["--resources", str(self.resources), *argv])
        return code, out.getvalue(), err.getvalue()

    def test_extract_merge_status_prune_and_check(self) -> None:
        # Extracting for a new locale yields all English keys in English order.
        code, stdout, _ = self.run_cli("extract", "--lang", "ja")
        self.assertEqual(code, 0)
        extracted = json.loads(stdout)
        self.assertEqual(
            list(extracted.items()),
            [
                ("First", "First"),
                ("Archive count", "Archives %1$lld items in %2$@."),
                ("Third", "Third"),
            ],
        )

        # Partial merge creates ja.lproj with reordered positional specifiers.
        partial_json = Path(self.tmp.name) / "ja-partial.json"
        partial_json.write_text(
            json.dumps(
                {
                    "Archive count": "%2$@ の %1$lld 件をアーカイブします。",
                    "First": "最初",
                },
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )
        code, _, _ = self.run_cli("merge", "--lang", "ja", str(partial_json))
        self.assertEqual(code, 0)
        ja_path = self.resources / "ja.lproj" / "Localizable.strings"
        self.assertEqual(
            ja_path.read_text(encoding="utf-8"),
            '"First" = "最初";\n'
            '"Archive count" = "%2$@ の %1$lld 件をアーカイブします。";\n',
        )

        # Extract now returns only the single missing key.
        delta_out = Path(self.tmp.name) / "ja-delta.json"
        code, _, _ = self.run_cli("extract", "--lang", "ja", "--out", str(delta_out))
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(delta_out.read_text(encoding="utf-8")), {"Third": "Third"})

        # Non-strict check passes for partial locale; strict check fails on missing key.
        code, _, _ = self.run_cli("check")
        self.assertEqual(code, 0)
        code, _, stderr = self.run_cli("check", "--strict")
        self.assertEqual(code, 1)
        self.assertIn("missing 1 key", stderr)

        # Status JSON reports exact coverage.
        code, stdout, _ = self.run_cli("status", "--json")
        self.assertEqual(code, 0)
        status = json.loads(stdout)
        self.assertEqual(status["total"], 3)
        self.assertEqual(status["locales"][0]["translated"], 2)
        self.assertEqual(status["locales"][0]["missing"], 1)
        self.assertEqual(status["locales"][0]["orphan"], 0)
        self.assertEqual(status["locales"][0]["format_errors"], 0)

        # Merge refuses broken format specifiers and leaves ja.lproj untouched.
        broken_json = Path(self.tmp.name) / "ja-broken.json"
        broken_json.write_text(
            json.dumps({"Archive count": "%2$@ の %1$@ 件をアーカイブします。"}, ensure_ascii=False),
            encoding="utf-8",
        )
        before = ja_path.read_text(encoding="utf-8")
        code, _, stderr = self.run_cli("merge", "--lang", "ja", str(broken_json))
        self.assertEqual(code, 1)
        self.assertIn("format specifier mismatch", stderr)
        self.assertEqual(ja_path.read_text(encoding="utf-8"), before)

        # Finish translating Third -> strict check passes.
        rest_json = Path(self.tmp.name) / "ja-rest.json"
        rest_json.write_text(json.dumps({"Third": "3番目"}, ensure_ascii=False), encoding="utf-8")
        code, _, _ = self.run_cli("merge", "--lang", "ja", str(rest_json))
        self.assertEqual(code, 0)
        code, _, _ = self.run_cli("check", "--strict")
        self.assertEqual(code, 0)

        # Introduce an orphan key in ja.lproj -> non-strict passes, strict fails, prune fixes it.
        ja_path.write_text(ja_path.read_text(encoding="utf-8") + '"Old key" = "古いキー";\n', encoding="utf-8")
        code, _, _ = self.run_cli("check")
        self.assertEqual(code, 0)
        code, _, stderr = self.run_cli("check", "--strict")
        self.assertEqual(code, 1)
        self.assertIn("1 orphan key", stderr)

        code, stdout, _ = self.run_cli("prune", "--lang", "all")
        self.assertEqual(code, 0)
        self.assertIn("pruned 1 orphan", stdout)
        code, _, _ = self.run_cli("check", "--strict")
        self.assertEqual(code, 0)

        # Stray unescaped '%' in an English format string fails `check`.
        en_path = self.resources / "en.lproj" / "Localizable.strings"
        en_path.write_text(
            en_path.read_text(encoding="utf-8") + '"BadEn" = "%lld% left";\n',
            encoding="utf-8",
        )
        code, _, stderr = self.run_cli("check")
        self.assertEqual(code, 1)
        self.assertIn("unescaped '%'", stderr)


if __name__ == "__main__":
    unittest.main()
