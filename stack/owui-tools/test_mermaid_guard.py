"""Offline regression suite for Mermaid Render Guard 1.1.0."""

import unittest
import os
import sqlite3
import types

if os.environ.get("MERMAID_GUARD_LIVE_DB"):
    connection = sqlite3.connect(os.environ["MERMAID_GUARD_LIVE_DB"])
    row = connection.execute(
        "SELECT content FROM function WHERE id='mermaid_render_guard'"
    ).fetchone()
    connection.close()
    if row is None:
        raise RuntimeError("Mermaid Render Guard is not installed")
    live_module = types.ModuleType("live_mermaid_render_guard_under_test")
    exec(row[0], live_module.__dict__)
    Filter = live_module.Filter
else:
    from mermaid_guard import Filter


EXACT_FAILED_DIAGRAMS = (
    """```mermaid
flowchart TD
    BindGLP[\"Peptide binds GLP1 receptor\"] --> Cascade[\"Gs‑cAMP‑PKA cascade\"]
    Cascade --> InsulinSec[\"Insulin secretion (glucose‑dependent)\"]
    Cascade --> GlucagonSup[\"Glucagon suppression\"]
    Cascade --> Satiety[\"Hypothalamic satiety signal\"]
    Cascade --> GutDelay[\"Slower gastric emptying\"]
    InsulinSec, GlucagonSup, Satiety, GutDelay --> Result[\"Improved glucose control + weight loss\"]
```""",
    """```mermaid
flowchart TD
    BindDual[\"Peptide binds GLP1R + GIPR\"] --> Cascade[\"Gs‑cAMP‑PKA cascade (shared)\"]
    Cascade --> InsulinSec[\"Insulin secretion (glucose‑dependent)\"]
    Cascade --> GlucagonSup[\"Glucagon suppression\"]
    Cascade --> Satiety[\"Hypothalamic satiety signal\"]
    Cascade --> GutDelay[\"Slower gastric emptying\"]
    GIPR --> LipidMetab[\"Adipose lipid metabolism (improved)\"]
    GIPR --> InsulinSynergy[\"Synergistic insulin sensitivity\"]
    InsulinSec, GlucagonSup, Satiety, GutDelay, LipidMetab, InsulinSynergy --> Result[\"Strong glycemic control + moderate weight loss\"]
```""",
    """```mermaid
flowchart TD
    BindTriple[\"Peptide binds GLP1R + GIPR + GCGR\"] --> Cascade[\"Gs‑cAMP‑PKA cascade (shared)\"]
    Cascade --> InsulinSec[\"Insulin secretion (glucose‑dependent)\"]
    Cascade --> GlucagonSup[\"Glucagon suppression\"]
    Cascade --> Satiety[\"Hypothalamic satiety signal\"]
    Cascade --> GutDelay[\"Slower gastric emptying\"]
    GIPR --> LipidMetab[\"Adipose lipid handling\"]
    GCGR --> LiverEffect[\"Hepatic fat oxidation & ↓ lipid accumulation\"]
    GCGR --> EE[\"Thermogenesis → ↑ resting energy expenditure\"]
    InsulinSec, GlucagonSup, Satiety, GutDelay, LipidMetab, LiverEffect, EE --> Result[\"Potent weight loss (~24–26%); improved glycemia; increased EE\"]
```""",
)


class MermaidGuardTests(unittest.TestCase):
    def test_three_exact_failed_fan_ins(self) -> None:
        expected_sources = (
            ("InsulinSec", "GlucagonSup", "Satiety", "GutDelay"),
            ("InsulinSec", "GlucagonSup", "Satiety", "GutDelay", "LipidMetab", "InsulinSynergy"),
            ("InsulinSec", "GlucagonSup", "Satiety", "GutDelay", "LipidMetab", "LiverEffect", "EE"),
        )
        for original, sources in zip(EXACT_FAILED_DIAGRAMS, expected_sources):
            with self.subTest(sources=sources):
                repaired = Filter.repair_content(original)
                self.assertNotIn(", ".join(sources) + " -->", repaired)
                for source in sources:
                    self.assertIn(f"    {source} --> Result[", repaired)

    def test_aicl_0106_square_label_cases(self) -> None:
        original = (
            "Before\n```mermaid\ngraph LR\n"
            "    A[Retatrutide (LY-3437943)] --> Brain[Brain (hypothalamus)]\n"
            "```\nAfter"
        )
        repaired = Filter.repair_content(original)
        self.assertIn('A["Retatrutide (LY-3437943)"]', repaired)
        self.assertIn('Brain["Brain (hypothalamus)"]', repaired)

    def test_fan_out_and_indentation(self) -> None:
        original = "```mermaid\nflowchart LR\n\tStart --> A, B, C\n```"
        expected = "```mermaid\nflowchart LR\n\tStart --> A\n\tStart --> B\n\tStart --> C\n```"
        self.assertEqual(Filter.repair_content(original), expected)

    def test_crlf_is_preserved(self) -> None:
        original = "```mermaid\r\nflowchart TD\r\n    A, B --> C[Done]\r\n```"
        repaired = Filter.repair_content(original)
        self.assertEqual(repaired.count("\r\n"), 4)
        self.assertNotIn("\n", repaired.replace("\r\n", ""))
        self.assertIn('    A --> C["Done"]\r\n    B --> C["Done"]', repaired)

    def test_multiple_fences_only_flowcharts_change(self) -> None:
        sequence = "```mermaid\nsequenceDiagram\nAlice->>Bob: A[label]\n```"
        flowchart = "```mermaid\nflowchart TD\nA, B --> C[Done]\n```"
        joined = sequence + "\ntext\n" + flowchart
        repaired = Filter.repair_content(joined)
        self.assertIn(sequence, repaired)
        self.assertIn('A --> C["Done"]\nB --> C["Done"]', repaired)

    def test_already_quoted_and_internal_quotes(self) -> None:
        original = (
            "```mermaid\nflowchart TD\n"
            'A["Already safe"] --> B[Say "hello"]\n'
            "```"
        )
        repaired = Filter.repair_content(original)
        self.assertIn('A["Already safe"]', repaired)
        self.assertIn('B["Say \'hello\'"]', repaired)

    def test_comments_directives_clicks_urls_and_reserved_end_are_unchanged(self) -> None:
        protected_lines = (
            "%% A, B --> C[comment]",
            "%%{init: {'flowchart': {'curve': 'basis'}}}%%",
            'click A "https://example.test/A[label]"',
            "A --> https://example.test/B[label]",
            "end --> A[Label]",
        )
        original = "```mermaid\nflowchart TD\n" + "\n".join(protected_lines) + "\n```"
        repaired = Filter.repair_content(original)
        for line in protected_lines:
            self.assertIn(line, repaired)
        self.assertIn(
            'A["The end of the path"]',
            Filter.repair_content("```mermaid\nflowchart TD\nA[The end of the path]\n```"),
        )

    def test_ambiguous_or_advanced_edges_are_unchanged(self) -> None:
        lines = (
            "A, B --> C, D",
            "A, B -.-> C",
            "A -->|label| B, C",
            "A ---o B, C",
            "A[complex, label], B --> C",
        )
        original = "```mermaid\nflowchart TD\n" + "\n".join(lines) + "\n```"
        repaired = Filter.repair_content(original)
        for line in lines[:-1]:
            self.assertIn(line, repaired)
        self.assertIn('A["complex, label"], B --> C', repaired)
        self.assertNotIn('A["complex, label"] --> C', repaired)

    def test_multiline_square_labels_are_joined_and_quoted(self) -> None:
        # Shape taken from a Granite 4.2 8B reply that failed on 12 October 2026.
        original = (
            "```mermaid\nflowchart LR\n"
            "    A[Three Neck Fractures:\n    - Left Hyoid Bone\n    - Two Thyroid Cartilage (Adam's apple)\n"
            '    ] --> B["Pathologist reports"]\n'
            '    C[Baden states: "more indicative of\n    homicidal strangulation than suicide"] --> D[Done]\n'
            "```"
        )
        repaired = Filter.repair_content(original)
        self.assertIn(
            'A["Three Neck Fractures:<br/>- Left Hyoid Bone<br/>- Two Thyroid Cartilage (Adam\'s apple)"] --> B',
            repaired,
        )
        self.assertIn(
            "C[\"Baden states: 'more indicative of<br/>homicidal strangulation than suicide'\"] --> D[\"Done\"]",
            repaired,
        )

    def test_timeline_arrows_become_colons(self) -> None:
        original = (
            "```mermaid\ntimeline\n"
            "    title Events\n"
            "    2019-07-23 01:30 → Found on floor\n"
            "    2019-07-31 → 2019-08-09 → On observation\n"
            "    2019-08-10 : Already valid\n"
            "```"
        )
        repaired = Filter.repair_content(original)
        self.assertIn("    2019-07-23 01.30 : Found on floor\n", repaired)
        self.assertIn("    2019-07-31 – 2019-08-09 : On observation\n", repaired)
        self.assertIn("    2019-08-10 : Already valid\n", repaired)
        self.assertIn("    title Events\n", repaired)

    def test_sequence_arrows_are_unchanged(self) -> None:
        original = "```mermaid\nsequenceDiagram\n    2019 -> Alice: hi\n```"
        self.assertEqual(Filter.repair_content(original), original)

    def test_non_mermaid_and_unclosed_fence_are_byte_identical(self) -> None:
        samples = (
            "Prose A[Retatrutide (LY-3437943)] and A, B --> C",
            "```python\nA[Retatrutide (LY-3437943)]\n```",
            "```mermaid\nflowchart TD\nA, B --> C",
        )
        for sample in samples:
            with self.subTest(sample=sample):
                self.assertEqual(Filter.repair_content(sample), sample)


if __name__ == "__main__":
    unittest.main(verbosity=2)
