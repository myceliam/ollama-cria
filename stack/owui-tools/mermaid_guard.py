"""
title: Mermaid Render Guard
author: Liam Rooney
version: 1.3.0
license: MIT
description: Repairs a small, deterministic subset of flowchart and timeline syntax inside fenced Mermaid blocks, live during streaming and again on completion.
"""

import re
import time
from typing import Any, Optional

from pydantic import BaseModel, Field


class Filter:
    """Narrow Mermaid syntax guidance plus stream-time and completed-response repair.

    Why the stream hook exists (v1.2.0): the Open WebUI chat renderer draws a Mermaid
    block the moment its closing fence arrives in the stream, which is before outlet()
    runs. outlet() alone therefore fixed the saved message but not what Liam saw live.
    stream() holds each ```mermaid block back until it is complete, repairs it with the
    same repair_content() used by outlet(), and releases it in one piece.

    v1.3.0: Granite also writes square labels that span several lines, and timelines with
    `period → event` arrows. Both are rejected by Mermaid 11. Inner double quotes become
    apostrophes because Mermaid shows `&quot;` literally when htmlLabels is off, as in Open WebUI.
    """

    class Valves(BaseModel):
        priority: int = Field(default=0, description="Filter order; lower runs first.")
        stream_buffering: bool = Field(
            default=True,
            description="Hold each streamed ```mermaid block until complete and release it repaired.",
        )
        max_buffer_chars: int = Field(
            default=24000,
            description="Safety cap: a single Mermaid block larger than this is released unrepaired.",
        )

    _MERMAID_REQUEST = re.compile(r"\bmermaid\b", re.IGNORECASE)
    _MERMAID_FENCE = re.compile(
        r"(?P<open>```[ \t]*mermaid[ \t]*\r?\n)(?P<body>.*?)(?P<close>```)",
        re.IGNORECASE | re.DOTALL,
    )
    # Stream-time fence detection.
    _STREAM_OPEN = re.compile(r"```[ \t]*mermaid[ \t]*\r?\n", re.IGNORECASE)
    # A trailing fragment that could still grow into a Mermaid opener: 1-3 backticks,
    # optional spaces, then a (possibly partial) "mermaid", optional spaces, optional \r.
    _PARTIAL_OPEN = re.compile(r"`{1,3}(?:[ \t]*[A-Za-z]{0,7}[ \t]*\r?)?$")
    _STREAM_STATE_TTL_SECONDS = 1800

    _SQUARE_NODE = re.compile(
        r"(?<![A-Za-z0-9_-])(?P<id>[A-Za-z_][A-Za-z0-9_-]*)\[(?P<label>[^\]\r\n]*)\]"
    )
    # An unquoted square label that spans lines, bounded so a stray bracket cannot swallow edges.
    _MULTILINE_SQUARE = re.compile(
        r"(?<![A-Za-z0-9_-])(?P<id>[A-Za-z_][A-Za-z0-9_-]*)\[(?!\")"
        r"(?P<label>[^\[\]\r\n]*(?:\r?\n[^\[\]\r\n]*){1,8})\]"
    )
    _TIMELINE_HEADER = re.compile(r"^[ \t]*timeline\b", re.IGNORECASE)
    _TIMELINE_ARROW = re.compile(r"[ \t]*(?:→|->|=>)[ \t]*")
    _TIMELINE_PERIOD = re.compile(r"^[0-9~c.][^#;]{0,30}$")
    _FLOWCHART_HEADER = re.compile(
        r"^[ \t]*(?:flowchart|graph)[ \t]+(?:TB|TD|BT|RL|LR)\b", re.IGNORECASE
    )
    _EDGE_LINE = re.compile(
        r"^(?P<indent>[ \t]*)(?P<left>.+?)(?P<before>[ \t]+)-->(?P<after>[ \t]+)"
        r"(?P<right>.+?)(?P<semi>;?)(?P<trailing>[ \t]*)$"
    )
    _BARE_ID = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]*$")
    _NODE_ENDPOINT = re.compile(
        r"^[A-Za-z_][A-Za-z0-9_-]*(?:\[[^\]\r\n]*\])?$"
    )
    _RESERVED_END = re.compile(
        r"(?<![A-Za-z0-9_-])end(?=[ \t]*(?:\[|-->|,|$))"
    )
    _GUIDANCE = (
        "Mermaid flowchart rendering rules: place every human-readable square-node label in double "
        'quotes, for example brain["Brain (hypothalamus)"]. Express fan-in or fan-out as one edge '
        "per line; do not write `A, B --> C` or `A --> B, C`. Do not use lowercase `end` as a node "
        "identifier. Prefer `flowchart` to the legacy `graph` alias. Keep each node label on one "
        "line; use <br/> for a line break inside the quotes and single quotes inside a label. In a "
        "`timeline`, write `period : event`, never `period → event`, and keep colons out of the period."
    )

    def __init__(self) -> None:
        self.valves = self.Valves()
        # Per-stream buffering state, keyed by message id. The Filter instance is cached and
        # shared across concurrent chats, so state must never be kept in a single attribute.
        self._streams: dict[str, dict[str, Any]] = {}

    # ------------------------------------------------------------------ repair core

    @classmethod
    def _latest_user_text(cls, messages: list[dict[str, Any]]) -> str:
        for message in reversed(messages):
            if message.get("role") != "user":
                continue
            content = message.get("content", "")
            if isinstance(content, str):
                return content
            if isinstance(content, list):
                return "\n".join(
                    str(part.get("text", ""))
                    for part in content
                    if isinstance(part, dict) and part.get("type") in {"text", "input_text"}
                )
        return ""

    @staticmethod
    def _quote_square_label(match: re.Match[str]) -> str:
        node_id = match.group("id")
        label = match.group("label").strip()
        if not label or (len(label) >= 2 and label[0] == label[-1] == '"'):
            return match.group(0)
        safe_label = label.replace('"', "'")
        return f'{node_id}["{safe_label}"]'

    @classmethod
    def _quote_multiline_label(cls, match: re.Match[str]) -> str:
        label = match.group("label")
        if "-->" in label or "%%" in label or cls._RESERVED_END.search(label):
            return match.group(0)
        lines = [line.strip() for line in label.splitlines() if line.strip()]
        if not lines:
            return match.group(0)
        safe_label = "<br/>".join(lines).replace('"', "'")
        return f'{match.group("id")}["{safe_label}"]'

    @classmethod
    def _repair_timeline(cls, body: str) -> str:
        """Turn `period → event` lines into `period : event`; leave every other line alone."""

        repaired_lines: list[str] = []
        active = False
        for line in body.splitlines(keepends=True):
            core, newline = cls._line_ending(line)
            stripped = core.strip()
            if not active:
                active = bool(cls._TIMELINE_HEADER.match(core))
                repaired_lines.append(line)
                continue
            if (
                not stripped
                or stripped.startswith(("%%", "title ", "section "))
                or " : " in core
                or not cls._TIMELINE_ARROW.search(core)
            ):
                repaired_lines.append(line)
                continue
            parts = cls._TIMELINE_ARROW.split(stripped)
            # Leading date-like parts form the period (a range keeps both ends); the rest is the event.
            period_parts: list[str] = []
            while len(parts) > 1 and cls._TIMELINE_PERIOD.match(parts[0]):
                period_parts.append(parts.pop(0))
            if not period_parts:
                repaired_lines.append(line)
                continue
            period = " – ".join(period_parts).replace(":", ".")
            event = " – ".join(parts)
            indent = core[: len(core) - len(core.lstrip())]
            repaired_lines.append(f"{indent}{period} : {event}{newline}")
        return "".join(repaired_lines)

    @staticmethod
    def _line_ending(line: str) -> tuple[str, str]:
        if line.endswith("\r\n"):
            return line[:-2], "\r\n"
        if line.endswith("\n"):
            return line[:-1], "\n"
        return line, ""

    @classmethod
    def _is_flowchart(cls, body: str) -> bool:
        """Recognise only flowchart/graph blocks; leave other Mermaid grammars alone."""

        for line in body.splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("%%"):
                continue
            return bool(cls._FLOWCHART_HEADER.match(line))
        return False

    @classmethod
    def _is_timeline(cls, body: str) -> bool:
        for line in body.splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("%%"):
                continue
            return bool(cls._TIMELINE_HEADER.match(line))
        return False

    @staticmethod
    def _split_top_level_commas(value: str) -> Optional[list[str]]:
        """Split commas outside quotes/brackets, or decline malformed/ambiguous input."""

        parts: list[str] = []
        start = 0
        quote: Optional[str] = None
        escaped = False
        stack: list[str] = []
        pairs = {"]": "[", ")": "(", "}": "{"}
        for index, char in enumerate(value):
            if quote is not None:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == quote:
                    quote = None
                continue
            if char in {'"', "'"}:
                quote = char
            elif char in "[({":
                stack.append(char)
            elif char in "])}":
                if not stack or stack.pop() != pairs[char]:
                    return None
            elif char == "," and not stack:
                part = value[start:index].strip()
                if not part:
                    return None
                parts.append(part)
                start = index + 1
        if quote is not None or stack:
            return None
        tail = value[start:].strip()
        if not tail:
            return None
        parts.append(tail)
        return parts

    @classmethod
    def _expand_comma_edge(cls, line: str) -> str:
        """Expand only plain `-->` fan-in/fan-out statements with unambiguous endpoints."""

        core, newline = cls._line_ending(line)
        if "%%" in core or "://" in core or cls._RESERVED_END.search(core):
            return line
        match = cls._EDGE_LINE.fullmatch(core)
        if match is None:
            return line

        left = cls._split_top_level_commas(match.group("left"))
        right = cls._split_top_level_commas(match.group("right"))
        if left is None or right is None:
            return line
        if len(left) > 1 and len(right) == 1:
            if not all(cls._BARE_ID.fullmatch(item) for item in left):
                return line
            if not cls._NODE_ENDPOINT.fullmatch(right[0]):
                return line
            edges = [(item, right[0]) for item in left]
        elif len(left) == 1 and len(right) > 1:
            if not cls._NODE_ENDPOINT.fullmatch(left[0]):
                return line
            if not all(cls._BARE_ID.fullmatch(item) for item in right):
                return line
            edges = [(left[0], item) for item in right]
        else:
            return line

        prefix = match.group("indent")
        separator = match.group("before") + "-->" + match.group("after")
        suffix = match.group("semi") + match.group("trailing")
        joiner = newline or "\n"
        return joiner.join(
            prefix + source + separator + target + suffix for source, target in edges
        ) + newline

    @classmethod
    def _repair_flowchart(cls, body: str) -> str:
        body = cls._MULTILINE_SQUARE.sub(cls._quote_multiline_label, body)
        repaired_lines: list[str] = []
        for line in body.splitlines(keepends=True):
            core, newline = cls._line_ending(line)
            stripped = core.lstrip()
            protected = (
                not stripped
                or stripped.startswith("%%")
                or stripped.lower().startswith("click ")
                or "://" in core
                or cls._RESERVED_END.search(core)
            )
            quoted = core if protected else cls._SQUARE_NODE.sub(cls._quote_square_label, core)
            repaired_lines.append(cls._expand_comma_edge(quoted + newline))
        return "".join(repaired_lines)

    @classmethod
    def repair_content(cls, content: str) -> str:
        """Repair only recognised flowcharts and timelines inside completed Mermaid fences."""

        def repair_fence(match: re.Match[str]) -> str:
            body = match.group("body")
            if cls._is_flowchart(body):
                repaired = cls._repair_flowchart(body)
            elif cls._is_timeline(body):
                repaired = cls._repair_timeline(body)
            else:
                repaired = body
            return match.group("open") + repaired + match.group("close")

        return cls._MERMAID_FENCE.sub(repair_fence, content)

    # ------------------------------------------------------------------ stream buffering

    def _process_stream_text(self, state: dict[str, Any], text: str) -> str:
        """Feed streamed text in; return the text that is safe to release now.

        Outside a Mermaid block, text is released immediately except for a short trailing
        fragment that could still become a ```mermaid opener. Inside a block, everything is
        held until the closing fence arrives, then the whole block is repaired and released.
        """

        pending = state["pending"] + text
        released: list[str] = []
        while True:
            if not state["in_fence"]:
                opener = self._STREAM_OPEN.search(pending)
                if opener is not None:
                    released.append(pending[: opener.start()])
                    pending = pending[opener.start():]
                    state["in_fence"] = True
                    state["open_len"] = opener.end() - opener.start()
                    continue
                partial = self._PARTIAL_OPEN.search(pending)
                if partial is not None and self._could_become_opener(pending[partial.start():]):
                    released.append(pending[: partial.start()])
                    pending = pending[partial.start():]
                else:
                    released.append(pending)
                    pending = ""
                break

            close = pending.find("```", state["open_len"])
            if close != -1:
                block = pending[: close + 3]
                released.append(self.repair_content(block))
                pending = pending[close + 3:]
                state["in_fence"] = False
                state["open_len"] = 0
                continue
            if len(pending) > max(1000, int(self.valves.max_buffer_chars)):
                # Runaway or unterminated block: stop holding it back. The remainder of this
                # block streams raw and outlet() still repairs the saved copy.
                released.append(pending)
                pending = ""
                state["in_fence"] = False
                state["open_len"] = 0
                state["passthrough"] = True
            break

        state["pending"] = pending
        return "".join(released)

    @staticmethod
    def _could_become_opener(fragment: str) -> bool:
        stripped = fragment.lstrip("`")
        ticks = len(fragment) - len(stripped)
        if ticks == 0 or ticks > 3:
            return False
        word = stripped.strip(" \t\r").lower()
        if ticks < 3:
            return word == ""
        return "mermaid".startswith(word)

    def _stream_key(self, event: dict, metadata: Optional[dict]) -> str:
        if isinstance(metadata, dict):
            for field in ("message_id", "chat_id"):
                value = metadata.get(field)
                if value:
                    return f"{field}:{value}"
        event_id = event.get("id") if isinstance(event, dict) else None
        return f"event:{event_id}" if event_id else "default"

    def _prune_streams(self, now: float) -> None:
        stale = [
            key
            for key, state in self._streams.items()
            if now - state.get("touched", now) > self._STREAM_STATE_TTL_SECONDS
        ]
        for key in stale:
            self._streams.pop(key, None)

    def stream(self, event: dict, __metadata__: Optional[dict] = None) -> dict:
        try:
            if not getattr(self.valves, "stream_buffering", True) or not isinstance(event, dict):
                return event
            choices = event.get("choices")
            if not isinstance(choices, list) or not choices or not isinstance(choices[0], dict):
                return event
            choice = choices[0]
            delta = choice.get("delta")
            finish_reason = choice.get("finish_reason")
            text = delta.get("content") if isinstance(delta, dict) else None

            key = self._stream_key(event, __metadata__)
            state = self._streams.get(key)
            if state is None:
                if not isinstance(text, str) or "`" not in text:
                    return event  # Fast path: nothing pending and no backtick in this chunk.
                now = time.time()
                self._prune_streams(now)
                state = {"pending": "", "in_fence": False, "open_len": 0, "touched": now}
                self._streams[key] = state
            state["touched"] = time.time()

            out = self._process_stream_text(state, text) if isinstance(text, str) else ""
            if finish_reason:
                out += state["pending"]
                self._streams.pop(key, None)
            elif not state["pending"] and not state["in_fence"]:
                self._streams.pop(key, None)

            if isinstance(text, str) or out:
                if not isinstance(delta, dict):
                    delta = {}
                    choice["delta"] = delta
                delta["content"] = out
            return event
        except Exception:
            # Never break a chat because of the guard: fail open to the unmodified event.
            return event

    # ------------------------------------------------------------------ inlet / outlet

    async def inlet(self, body: dict, __user__: Optional[dict] = None) -> dict:
        messages = body.get("messages")
        if not isinstance(messages, list) or not self._MERMAID_REQUEST.search(self._latest_user_text(messages)):
            return body

        guidance_message = {"role": "system", "content": self._GUIDANCE}
        insert_at = 1 if messages and messages[0].get("role") == "system" else 0
        messages.insert(insert_at, guidance_message)
        return body

    async def outlet(self, body: dict, __user__: Optional[dict] = None) -> dict:
        messages = body.get("messages")
        if not isinstance(messages, list):
            return body

        for message in reversed(messages):
            if message.get("role") != "assistant":
                continue
            content = message.get("content")
            if isinstance(content, str) and "```" in content and self._MERMAID_REQUEST.search(content):
                message["content"] = self.repair_content(content)
            break
        return body
