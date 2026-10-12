"""
title: Command Builder
author: Liam Rooney
version: 1.3.2
license: MIT
description: Attached to the Command Guide model only. "build brave command" opens popups: pick a command from a numbered list, fill in its options (blank skips), then write your prompt, and the reply is the whole message (command plus prompt) in a code block, ready to paste into another chat. "diagram list" and "brave list" return the full lists word for word. It runs nothing; the command is assembled in code, not by the model.
"""

import re
from typing import Any, Callable, Optional

from pydantic import BaseModel, Field

SKIP = "(skip)"
TIME = [SKIP, "past day", "past week", "past month", "past year"]
TIME_FLAGS = {"past day": "+day", "past week": "+week", "past month": "+month", "past year": "+year"}
YES_NO = [SKIP, "yes", "no"]

# Each field: (key, kind, title, message, extra). Kinds: main (required text), text (optional text, written as key="..."),
# list (several items separated by |, each quoted), select (options -> flag), sources, time, number.
F_SOURCES = ("sources", "select", "Numbered sources?", "Add numbered citations with links? Pick yes if you may want to check or share the sources.", {"options": YES_NO, "flags": {"yes": "+sources"}})
F_TIME = ("time", "select", "Time window", "Limit results to a period? E.g. past week for breaking news, past year for a slower story.", {"options": TIME, "flags": TIME_FLAGS})
F_DEPTH = ("depth", "select", "Research depth", "How much research? Quick = a few sources, fast. Standard = the default. Deep = more sources, slower.", {"options": [SKIP, "quick", "standard", "deep"], "flags": {"quick": "+quick", "deep": "+deep"}})
F_UK = ("uk", "select", "UK only?", "Keep results to UK sites? E.g. '.uk sites' for UK news and shops; 'UK government, NHS and universities' for official guidance.", {"options": [SKIP, ".uk sites", "UK government, NHS and universities"], "flags": {".uk sites": "+uk", "UK government, NHS and universities": "+ukgov"}})
F_SITES = ("site", "text", "Only these websites", "Websites to search, separated by commas. E.g. bbc.co.uk, theguardian.com or which.co.uk. Leave blank for all.", {})

COMMANDS: list[dict[str, Any]] = [
    # Liam's eight favourites first, in his order. "short" is his short name (e.g. "build forum command").
    {"name": "search", "short": "search-summary", "label": "Quick fact search", "fields": [
        ("query", "main", "Search for", "What do you want to look up? E.g. 'current UK energy price cap' or 'Ollama latest version'.", {}), F_TIME, F_SITES, F_UK,
        ("snippets", "select", "Extra text", "Include extra text from each result? Yes gives the model more to work with.", {"options": YES_NO, "flags": {"yes": "+snippets"}})]},
    {"name": "news", "short": "search-news", "label": "News", "fields": [
        ("query", "main", "News about", "What topic? E.g. 'Open WebUI release' or 'UK interest rates'. Defaults to the past week.", {}), F_TIME, F_SITES, F_UK]},
    {"name": "discuss", "short": "search-forum", "label": "Forums and discussions", "fields": [
        ("query", "main", "Discussion about", "What topic do you want people's views on? E.g. 'the war in Gaza' or 'Proxmox vs Unraid for a home server'.", {}),
        ("site", "text", "Forum websites", "Leave blank for Reddit, Quora, Substack, Hacker News, Stack Exchange, Mumsnet and Medium. Or list your own, e.g. reddit.com, lemmy.world.", {}),
        F_TIME,
        ("anyforum", "select", "Brave's own forum lane", "Use Brave's own forum results instead of the sites above? Usually leave this; it is often empty for news topics.", {"options": YES_NO, "flags": {"yes": "+anyforum"}})]},
    {"name": "sweep", "short": "research-sweep", "label": "Compiled list (find all)", "fields": [
        ("request", "main", "What to compile", "What list do you want built? E.g. 'self-hosted text-to-speech engines' or 'UK pubs with live music in Leeds'.", {}),
        ("queries", "list", "Search query", "Type one search. Use different wordings or angles, e.g. 'open source TTS', then 'local TTS docker', then 'Kokoro alternatives'. You need at least two.", {"min": 2, "max": 6}),
        ("include", "text", "Must include", "What must an item have to qualify? E.g. 'runs offline' or 'open on Sundays'. Leave blank for no rule.", {}),
        ("exclude", "text", "Leave out", "What should be left out? E.g. 'cloud-only services' or 'chains'. Leave blank for nothing.", {}),
        F_TIME, F_SOURCES]},
    {"name": "topic", "short": "research-topic", "label": "Researched answer", "fields": [
        ("question", "main", "Your question", "What do you want answered? E.g. 'how does Tailscale route traffic between devices?' or 'is intermittent fasting safe?'", {}), F_DEPTH, F_SOURCES, F_TIME, F_SITES, F_UK]},
    {"name": "portfolio", "short": "research-deepdive", "label": "Deep dive", "fields": [
        ("subject", "main", "Subject", "What do you want a deep dive on? E.g. 'solid-state batteries' or 'GLP-1 weight-loss drugs'.", {}),
        ("focus", "text", "Focus", "Any particular angle? E.g. 'consumer readiness', 'long-term risks' or 'UK availability'. Leave blank for everything.", {}), F_SOURCES,
        ("nodiagrams", "select", "Diagrams", "Include diagrams? Pick no for text only.", {"options": [SKIP, "yes", "no"], "flags": {"no": "+nodiagrams"}}), F_TIME, F_SITES, F_UK]},
    {"name": "wiki", "short": "research-wiki", "label": "Wikipedia article", "fields": [
        ("topic", "main", "Wikipedia topic", "What should the article be about? E.g. 'Alan Turing' or 'Treaty of Versailles'. A popup then lets you pick the exact article.", {})]},
    {"name": "videos", "short": "research-videos", "label": "Videos", "fields": [
        ("query", "main", "Videos about", "What topic? E.g. 'Tailscale exit node setup' or 'how to sharpen a kitchen knife'.", {})]},
    # Everything else.
    {"name": "compare", "label": "Side-by-side comparison", "fields": [
        ("subjects", "list", "Thing to compare", "Type one thing to compare, e.g. 'Proxmox', then 'Unraid'. You need at least two.", {"min": 2, "max": 6}),
        ("by", "text", "Compare on", "Criteria, separated by commas. E.g. 'price, ease of use, Docker support'. Leave blank for all differences.", {}),
        ("depth", "select", "Depth", "Standard or deep? Deep reads more sources.", {"options": [SKIP, "standard", "deep"], "flags": {"deep": "+deep"}}), F_SOURCES, F_TIME]},
    {"name": "summarise", "label": "Plain-English summary", "fields": [
        ("subject", "main", "Subject", "What should be summarised? E.g. 'the EU AI Act' or 'the Online Safety Act'.", {}),
        ("focus", "text", "Focus", "Any particular angle? E.g. 'what it means for hobbyists'. Leave blank for a general overview.", {}), F_DEPTH, F_SOURCES, F_TIME]},
    {"name": "claim", "label": "Check a claim", "fields": [
        ("claim", "main", "The claim", "Write the claim exactly as you heard it. E.g. 'Ollama sends usage data to the internet'.", {}),
        ("context", "text", "Context", "Who said it, and when? E.g. 'a Reddit post, October 2026'. Leave blank if unknown.", {}), F_SOURCES, F_TIME]},
    {"name": "brief", "label": "Brief on a company or public figure", "fields": [
        ("subject", "main", "Company or public figure", "Who is the brief about? E.g. 'Mullvad VPN' or 'Ofcom'.", {}),
        ("angle", "text", "Angle", "Any particular angle? E.g. 'ownership and privacy record'. Leave blank for their public record.", {}), F_SOURCES, F_TIME]},
    {"name": "profile", "label": "Public person's link to an organisation", "fields": [
        ("subject", "main", "Public person", "Which genuinely public person? E.g. 'Satya Nadella'.", {}),
        ("org", "text", "Organisation", "Which organisation? E.g. 'Microsoft'. Leave blank if any.", {}),
        ("focus", "text", "Focus", "Any particular angle? E.g. 'role in the OpenAI deal'. Leave blank for none.", {}), F_SOURCES]},
    {"name": "read", "label": "Read one web page", "fields": [
        ("url", "main", "Web address", "Paste the full link, starting with https://", {}),
        ("engine", "select", "Reader mode", "Use a browser for pages that need JavaScript (e.g. some news or shop sites)?", {"options": [SKIP, "browser", "plain fetch"], "flags": {"browser": "+browser", "plain fetch": "+curl"}})]},
    {"name": "save", "label": "Save a page to this chat's shelf", "fields": [
        ("url", "main", "Web address", "Paste the full link, starting with https://", {}),
        ("engine", "select", "Reader mode", "Use a browser for pages that need JavaScript?", {"options": [SKIP, "browser"], "flags": {"browser": "+browser"}})]},
    {"name": "library", "label": "List saved pages", "fields": []},
    {"name": "ask", "label": "Ask about a saved page", "fields": [
        ("question", "main", "Question", "What do you want to know from the saved page? E.g. 'what are the main conclusions?'", {}),
        ("doc", "text", "Document id", "Leave blank for the latest saved page.", {})]},
    {"name": "overview", "label": "Overview of a saved page", "fields": [
        ("focus", "optmain", "Focus", "Any particular part? E.g. 'the methodology'. Leave blank for the general idea.", {}),
        ("doc", "text", "Document id", "Leave blank for the latest saved page.", {})]},
    {"name": "quote", "label": "Exact quote from a saved page", "fields": [
        ("phrase", "main", "Phrase to find", "What wording should it find? E.g. 'energy price cap'.", {}),
        ("lines", "number", "Lines of context", "How many lines around each match? Leave blank for 2.", {}),
        ("doc", "text", "Document id", "Leave blank for the latest saved page.", {})]},
    {"name": "help", "label": "Command reference table", "fields": []},
]
# Suggestions shown on the last popup ("Your prompt"), per command.
PROMPT_EXAMPLES = {
    "search": ["give me the one-line answer first", "show the top three results with links"],
    "news": ["summarise the five biggest stories in bullet points", "what changed this week?"],
    "discuss": ["summarise the main viewpoints and where people disagree", "what do most people recommend?", "list the common complaints"],
    "sweep": ["summarise the main viewpoints and where people disagree", "put them in a table with a link for each", "rank them by how often they come up"],
    "topic": ["explain it simply, as if to a friend", "finish with a three-line summary", "focus on the UK"],
    "portfolio": ["finish with the three key takeaways", "keep it under 800 words", "explain the science in plain English"],
    "wiki": ["explain it for a ten-year-old", "list the key dates"],
    "videos": ["pick the three best for a beginner", "only ones under 20 minutes"],
    "compare": ["finish with a clear recommendation for a beginner", "show it as a table", "which is cheaper over three years?"],
    "summarise": ["use bullet points", "what does it mean for me?"],
    "claim": ["give a clear verdict first: true, false or misleading", "explain where the claim came from"],
    "brief": ["keep it to one page", "highlight any controversies"],
    "profile": ["list their roles in date order"],
    "read": ["summarise it in five bullet points", "pull out every date and figure"],
    "save": ["just confirm it saved"],
    "ask": ["quote the relevant lines"],
    "overview": ["keep it short"],
    "quote": ["show every match"],
}
MENU_COUNT = 8
MAX_RETRIES = 2
CANCELLED = "Command builder cancelled. Type **build brave command** to start again."
MORE = "More commands…"
_TRIGGER = re.compile(r"\bbuild\b.*\bcommand", re.IGNORECASE)
# Short list requests answered word for word from the Command Guide's own system prompt sections.
_LISTS = [
    (re.compile(r"^\s*(?:list\s+(?:all\s+)?(?:the\s+)?diagrams?|diagrams?\s+(?:list|commands|skills))\b", re.I), "DIAGRAM SKILLS", "Diagram skills"),
    (re.compile(r"^\s*(?:list\s+(?:all\s+)?(?:the\s+)?brave(?:\s+commands)?|brave\s+(?:list|commands)|command\s+list)\b", re.I), "BRAVE COMMANDS", "Brave commands"),
]


def _clean(value: str) -> str:
    return " ".join(str(value or "").replace('"', "'").replace("“", "'").replace("”", "'").split())


def assemble(cmd: dict[str, Any], answers: dict[str, str]) -> str:
    """Turn the chosen command and popup answers into one command line."""
    parts = [f"!{cmd['name']}"]
    flags: list[str] = []
    for key, kind, _title, _message, extra in cmd["fields"]:
        value = answers.get(key, "")
        if not value or value == SKIP:
            continue
        if kind in {"main", "optmain"}:
            parts.append(f'"{_clean(value)}"')
        elif kind == "list":
            items = [_clean(v) for v in value.split("|") if _clean(v)][: extra.get("max", 6)]
            parts.extend(f'"{item}"' for item in items)
        elif kind == "text":
            parts.append(f'{key}="{_clean(value)}"')
        elif kind == "number":
            if value.strip().isdigit():
                parts.append(f"{key}={int(value.strip())}")
        elif kind == "select":
            flag = extra.get("flags", {}).get(value)
            if flag:
                flags.append(flag)
    line = " ".join(parts + flags)
    note = _clean(answers.get("__prompt__", "")).replace(";", ",")  # ";" would start a new command in the router
    return f"{line} -- {note}" if note else line


class Filter:
    class Valves(BaseModel):
        priority: int = Field(default=0, description="Runs after the Brave Command Router (-10), which ignores builder requests.")
        ENABLED: bool = Field(default=True, description="Master switch for the builder.")

    def __init__(self) -> None:
        self.valves = self.Valves()
        self._pending: dict[str, str] = {}

    @staticmethod
    def _text(message: dict[str, Any]) -> str:
        content = message.get("content", "")
        if isinstance(content, list):
            return "\n".join(str(p.get("text", "")) for p in content if isinstance(p, dict) and p.get("type") == "text")
        return str(content or "")

    @staticmethod
    def _value(reply: Any) -> Optional[str]:
        """Popup reply -> string; None when cancelled."""
        if reply is False or reply is None:
            return None
        if isinstance(reply, dict):
            reply = reply.get("value", "")
        return str(reply).strip()

    async def _select(self, call: Callable, title: str, message: str, options: list[str]) -> Optional[str]:
        return self._value(await call({"type": "input", "data": {"title": title, "message": message,
                                                                    "input": {"type": "select", "options": options}}}))

    async def _ask(self, call: Callable, title: str, message: str) -> Optional[str]:
        return self._value(await call({"type": "input", "data": {"title": title, "message": message, "placeholder": "Leave blank to skip"}}))

    async def _pick(self, call: Callable, preset: Optional[dict]) -> Optional[dict]:
        if preset:
            return preset
        def line(i: int, c: dict) -> str:
            return f"{i} — !{c['name']}: {c['label']}"
        first = COMMANDS[:MENU_COUNT]
        options = [line(i, c) for i, c in enumerate(first, 1)] + [MORE]
        choice = await self._select(call, "Build a Brave command (1 of 2)", "Which command do you want to build?", options)
        if choice is None:
            return None
        if choice == MORE:
            rest = COMMANDS[MENU_COUNT:]
            options = [line(i, c) for i, c in enumerate(rest, MENU_COUNT + 1)]
            choice = await self._select(call, "Build a Brave command (1 of 2)", "More commands:", options)
            if choice is None or choice not in options:
                return None
            return rest[options.index(choice)]
        return first[options.index(choice)] if choice in options else None

    def _preset(self, text: str) -> Optional[dict]:
        """'build forum command' or 'build !compare command' skips the list."""
        lowered = text.lower()
        common = {"read", "save", "ask", "help", "library", "quote"}  # everyday words: only match as !name
        for cmd in COMMANDS:
            names = {"!" + cmd["name"]} | ({cmd["name"]} - common)
            if cmd.get("short"):  # "search-forum", "forum", "brave-search-forum"
                names |= {cmd["short"], "brave-" + cmd["short"], cmd["short"].split("-", 1)[-1]}
            if any(re.search(rf"(?<![\w-]){re.escape(n)}(?![\w-])", lowered) for n in names):
                return cmd
        return None

    @staticmethod
    def _section(system: str, heading: str) -> str:
        """Text of one '# HEADING' section of the Command Guide system prompt, up to the next '# ' heading."""
        match = re.search(rf"^# {re.escape(heading)}\s*$(.*?)(?=^# |\Z)", system or "", re.M | re.S)
        return match.group(1).strip() if match else ""

    @staticmethod
    async def _system_prompt(body: dict, model: Optional[dict]) -> str:
        """The Command Guide's stored system prompt. __model__ does not carry it in OWUI 0.12, so read the model record."""
        system = (((model or {}).get("info") or {}).get("params") or {}).get("system") or ""
        if system:
            return system
        from open_webui.models.models import Models

        record = Models.get_model_by_id(str((model or {}).get("id") or body.get("model") or ""))
        if hasattr(record, "__await__"):
            record = await record
        params = getattr(record, "params", None)
        params = params.model_dump() if hasattr(params, "model_dump") else (params or {})
        return str(params.get("system") or "")

    def _deliver(self, messages: list, metadata: Optional[dict], result: str, echo: Optional[str] = None) -> None:
        """Hand the model fixed text to repeat (or a short stand-in); the outlet then pins the saved reply to exactly `result`."""
        chat_id = (metadata or {}).get("chat_id")
        if chat_id:
            self._pending[chat_id] = result
        shown = echo if (echo and chat_id) else result
        messages[-1]["content"] = (
            "[COMMAND BUILDER] Reply with exactly the text between the markers and nothing else.\n<<<\n" + shown + "\n>>>"
        )

    async def inlet(self, body: dict, __event_call__: Optional[Callable] = None, __user__: Optional[dict] = None,
                    __metadata__: Optional[dict] = None, __model__: Optional[dict] = None) -> dict:
        messages = body.get("messages") or []
        if not self.valves.ENABLED or not messages or messages[-1].get("role") != "user":
            return body
        text = self._text(messages[-1]).strip()
        # A message the Brave router already expanded starts with "[BRAVE COMMAND ROUTER"; never treat it as a builder request.
        if text.startswith("["):
            return body
        for pattern, heading, title in _LISTS:
            if pattern.search(text):
                section = self._section(await self._system_prompt(body, __model__), heading)
                if section:
                    # Long lists: the model only writes one line; the outlet swaps in the exact list (keeps the prompt small).
                    self._deliver(messages, __metadata__, f"## {title}\n\n{section}", echo=f"Here is the {title.lower()} list.")
                return body
        if not _TRIGGER.search(text):
            return body
        if not __event_call__:
            messages[-1]["content"] = "[COMMAND BUILDER] Popups are not available here. Tell Liam in one line to open the Command Guide in a normal chat and type: build brave command"
            return body

        self._deliver(messages, __metadata__, await self._build(__event_call__, self._preset(text)))
        return body

    async def _build(self, call: Callable, preset: Optional[dict]) -> str:
        cmd = await self._pick(call, preset)
        if cmd is None:
            return CANCELLED
        answers: dict[str, str] = {}
        step = f"Build !{cmd['name']} (2 of 2)"
        for key, kind, title, message, extra in cmd["fields"]:
            if kind == "select":
                value = await self._select(call, f"{step}: {title}", message, extra["options"])
            elif kind == "list":
                value = await self._ask_list(call, f"{step}: {title}", message, extra)
            else:
                value = await self._ask(call, f"{step}: {title}", message + (" (required)" if kind == "main" else ""))
                tries = 0
                while kind == "main" and value is not None and not value.strip():
                    tries += 1
                    if tries > MAX_RETRIES:  # never trap Liam in a loop of empty popups
                        return f"Command builder stopped: **{title}** was left empty. Type **build brave command** to start again."
                    value = await self._ask(call, f"{step}: {title}", f"This one is needed (or press Cancel to stop). {message}")
            if value is None:
                return CANCELLED
            answers[key] = value
        if cmd["fields"]:
            examples = " / ".join(f"'{e}'" for e in PROMPT_EXAMPLES.get(cmd["name"], ["summarise it in bullet points"]))
            prompt = await self._ask(call, f"{step}: Your prompt",
                                     f"What should the answer do with the results? Write it as you would in chat. Examples: {examples}. "
                                     "Leave blank for a normal answer.")
            if prompt is None:
                return CANCELLED
            answers["__prompt__"] = prompt
        command = assemble(cmd, answers)
        what = "message (command and prompt)" if answers.get("__prompt__") else "command"
        return f"Here is your **!{cmd['name']}** {what}. Copy the whole block into your other chat and send it.\n\n```\n{command}\n```"

    async def _ask_list(self, call: Callable, title: str, message: str, extra: dict) -> Optional[str]:
        """One item per popup; a blank entry finishes once the minimum is reached. Returns items joined by |."""
        low, high = extra.get("min", 2), extra.get("max", 6)
        items: list[str] = []
        blanks = 0
        while len(items) < high:
            n = len(items) + 1
            need = n <= low
            hint = f"Item {n} of up to {high}." + (" (required)" if need else " Leave blank and press Confirm to finish.")
            value = await self._ask(call, f"{title} {n}", f"{hint} {message}")
            if value is None:
                return None
            parts = [v.strip() for v in value.split("|") if v.strip()]
            if parts:
                items.extend(parts)
                blanks = 0
                continue
            if len(items) >= low:
                break
            blanks += 1
            if blanks > MAX_RETRIES:
                return None
        return " | ".join(items[:high])

    async def outlet(self, body: dict, __user__: Optional[dict] = None) -> dict:
        """Guarantee the saved reply is exactly the assembled text, whatever the model wrote."""
        result = self._pending.pop(body.get("chat_id") or "", None)
        messages = body.get("messages") or []
        if result and messages and messages[-1].get("role") == "assistant":
            last = messages[-1]
            last["content"] = result
            # OWUI 0.12 renders and stores the reply from its output items (thinking + message), so replace those too.
            if "output" in last:
                old_id = next((i.get("id") for i in last["output"] or [] if isinstance(i, dict) and i.get("type") == "message"), None)
                last["output"] = [{"type": "message", "id": old_id or "msg_command_builder", "status": "completed", "role": "assistant",
                                   "content": [{"type": "output_text", "text": result}]}]
        return body
