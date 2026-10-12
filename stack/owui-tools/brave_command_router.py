"""
title: Brave Command Router
author: Liam Rooney
version: 1.3.4
license: MIT
description: Deterministic !commands for the Brave suite. A message containing !portfolio, !sweep, !read etc. (or the matching brave-* skill picked from the / or $ menu) is parsed before the model sees it; the router runs the named Brave tool function itself over the normal protected route and hands the model the finished results to write up. Natural-language messages without a command are untouched.
"""

import datetime as _dt
import inspect
import re
from typing import Any, Callable, Optional

from pydantic import BaseModel, Field

# --------------------------------------------------------------------------
# Command table: name -> (tool_id, method, usage, one-line purpose)
# --------------------------------------------------------------------------
COMMANDS: dict[str, dict[str, str]] = {
    "search":    {"tool": "brave_search",   "fn": "web",                   "usage": '!search "query" [count=8] [+week|+month|+year] [+snippets]', "does": "One targeted Brave web search for a fact or quick discovery."},
    "news":      {"tool": "brave_search",   "fn": "news",                  "usage": '!news "topic" [count=10] [+day|+week|+month|+year]',          "does": "Brave news results (defaults to the past week)."},
    "videos":    {"tool": "brave_search",   "fn": "videos",                "usage": '!videos "topic" [count=10]',                                   "does": "Brave video results: links and metadata only, nothing downloaded."},
    "discuss":   {"tool": "brave_search",   "fn": "discussions",           "usage": '!discuss "topic" [count=10] [+week|+month|+year] [site="..."] [+anyforum]', "does": "Forum and discussion threads (Reddit, Quora, Substack and other discussion sites by default): leads and opinions, not verified fact."},
    "sweep":     {"tool": "brave_search",   "fn": "source_sweep",          "usage": '!sweep "what I want compiled" "query 1" "query 2" [... up to 6] [include="..."] [exclude="..."] [+sources]', "does": "Find-all / compiled lists: 2-6 planned searches in one bounded, de-duplicated sweep."},
    "topic":     {"tool": "brave_research", "fn": "topic",                 "usage": '!topic "question" [+quick|+deep] [+sources]',                  "does": "Source-grounded research answer to a general question."},
    "summarise": {"tool": "brave_research", "fn": "summarise",             "usage": '!summarise "subject" [focus="..."] [+quick|+deep] [+sources]', "does": "Plain-English summary built from gathered evidence."},
    "compare":   {"tool": "brave_research", "fn": "compare",               "usage": '!compare "A" "B" [...] [by="criteria"] [+deep] [+sources]',     "does": "Balanced side-by-side comparison of two or more subjects."},
    "claim":     {"tool": "brave_research", "fn": "check_claim",           "usage": '!claim "the exact claim" [context="who/when"] [+sources]',     "does": "Evidence that supports, contradicts or qualifies a claim."},
    "portfolio": {"tool": "brave_research", "fn": "research_portfolio",    "usage": '!portfolio "subject" [focus="..."] [+sources] [+nodiagrams]',  "does": "In-depth evidence dossier: background, mechanism, evidence, risks, status, disputes."},
    "brief":     {"tool": "brave_research", "fn": "public_interest_brief", "usage": '!brief "company or public figure" [angle="..."] [+sources]',   "does": "Public-interest brief on a company, organisation or genuinely public figure."},
    "profile":   {"tool": "brave_research", "fn": "professional_profile",  "usage": '!profile "public person" [org="organisation"] [focus="..."] [+sources]', "does": "A public person's professional relationship to an organisation (public LinkedIn + corroboration)."},
    "read":      {"tool": "brave_reader",   "fn": "read_url",              "usage": '!read "https://..." [+browser|+curl]',                         "does": "Read one public page in full via self-hosted Jina."},
    "save":      {"tool": "brave_reader",   "fn": "save_url",              "usage": '!save "https://..." [+browser]',                               "does": "Save a full page into this chat's Reader Library for later questions."},
    "wiki":      {"tool": "brave_reader",   "fn": "choose_wikipedia",      "usage": '!wiki "topic"',                                                "does": "Pick an English Wikipedia article from a popup and save it to this chat."},
    "library":   {"tool": "brave_reader",   "fn": "list_library",          "usage": "!library",                                                     "does": "List the documents saved in this chat."},
    "ask":       {"tool": "brave_reader",   "fn": "ask_document",          "usage": '!ask "question" [doc="id"]',                                   "does": "Answer a question from a saved document (latest by default)."},
    "overview":  {"tool": "brave_reader",   "fn": "overview_document",     "usage": '!overview ["focus"] [doc="id"]',                               "does": "General overview of a saved document."},
    "quote":     {"tool": "brave_reader",   "fn": "quote_document",        "usage": '!quote "exact phrase" [doc="id"] [lines=2]',                   "does": "Exact wording with line numbers from a saved document."},
    "help":      {"tool": "",               "fn": "",                      "usage": "!help",                                                        "does": "Show this command reference."},
}
ALIASES = {"summarize": "summarise", "discussions": "discuss", "web": "search", "check": "claim", "wikipedia": "wiki", "readurl": "read", "read-page": "read"}
# Liam's short names (12 Oct 2026), accepted typed (!search-forum) or as a brave-<name> skill chip if one is ever
# recreated. The menu currently has no Brave chips: the Command Guide's builder replaces them.
CHIPS = {"search-summary": "search", "search-news": "news", "search-forum": "discuss", "research-sweep": "sweep",
         "research-topic": "topic", "research-deepdive": "portfolio", "research-wiki": "wiki", "research-videos": "videos"}
ALIASES.update(CHIPS)
SKILL_PREFIX = "brave-"
BRAVE_TOOL_IDS = {"brave_search", "brave_research", "brave_reader"}
FRESHNESS_FLAGS = {"day": "pd", "week": "pw", "month": "pm", "year": "py"}
KNOWN_FLAGS = {"sources", "quick", "standard", "deep", "nodiagrams", "snippets", "browser", "curl", "keep", "uk", "ukgov", "anyforum"} | set(FRESHNESS_FLAGS)
TOOL_TAGS = {"brave_search": "SEARCH", "brave_research": "RESEARCH", "brave_reader": "READ", "": "HELP"}
UKGOV_SITES = ["gov.uk", "parliament.uk", "nhs.uk", "ac.uk", "police.uk"]
# !discuss searches these with a normal web search unless site=, +uk/+ukgov or +anyforum is given. Brave's own
# discussions lane returns nothing for many news topics (Gaza returned NO_RESULTS four times on 12 Oct 2026).
FORUM_SITES = ["reddit.com", "quora.com", "substack.com", "news.ycombinator.com", "stackexchange.com", "mumsnet.com", "medium.com"]
# Where a site filter is appended, per command: (argument key, is multi-line query list)
SITE_TARGET = {"search": "query", "news": "query", "videos": "query", "discuss": "query", "sweep": "queries",
               "topic": "question", "summarise": "subject", "compare": "subjects", "claim": "claim",
               "portfolio": "subject", "brief": "subject", "profile": "subject"}

_ALL_NAMES = sorted(set(COMMANDS) | set(ALIASES), key=len, reverse=True)
_CMD_RE = re.compile(r"!(" + "|".join(re.escape(n) for n in _ALL_NAMES) + r")(?=$|[\s\"';+])", re.IGNORECASE)
_SKILL_RE = re.compile(r"<(?:\$|/)" + re.escape(SKILL_PREFIX) + r"([a-z0-9_-]+)(?:\|[^>]*)?>", re.IGNORECASE)
# Other skills (e.g. diagram-*). OWUI resolves skills from <$id|label> tags AFTER filter inlets, so a command turn must
# keep these tags or the skill is lost; and plain pasted "$diagram-x" text is turned into a tag so it resolves too.
_OTHER_SKILL_TAG_RE = re.compile(r"<(?:\$|/)(?!" + re.escape(SKILL_PREFIX) + r")([a-z0-9_-]+)(?:\|[^>]*)?>", re.IGNORECASE)
_PLAIN_SKILL_RE = re.compile(r"(?<![<\w$])\$(diagram-[a-z0-9-]+)\b", re.IGNORECASE)
_TOKEN_RE = re.compile(r'(?P<kv>[A-Za-z_]+=(?:"[^"]*"|\S+))|(?P<q>"[^"]*")|(?P<flag>\+[A-Za-z]+)|(?P<word>[^\s"]+)')


def _canon(name: str) -> str:
    name = name.lower()
    return ALIASES.get(name, name)


def _split_outside_quotes(text: str, sep: str) -> list[str]:
    parts, buf, in_q = [], [], False
    for ch in text:
        if ch == '"':
            in_q = not in_q
        if ch == sep and not in_q:
            parts.append("".join(buf))
            buf = []
        else:
            buf.append(ch)
    parts.append("".join(buf))
    return parts


def _strip_quotes(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] == '"':
        value = value[1:-1]
    return value.strip()


def normalise(text: str) -> str:
    """Curly quotes -> straight; picked brave-* skill chips -> !command."""
    text = text.replace("“", '"').replace("”", '"').replace("‘", "'").replace("’", "'")
    return _SKILL_RE.sub(lambda m: "!" + m.group(1).lower() + " ", text)


def has_command(text: str) -> bool:
    return bool(_CMD_RE.search(normalise(text or "")))


def parse(text: str) -> dict[str, Any]:
    """Parse a command message into {commands, global_note, stray, errors}."""
    text = normalise(text or "")
    first = _CMD_RE.search(text)
    result: dict[str, Any] = {"commands": [], "global_note": "", "stray": "", "errors": []}
    if not first:
        return result
    result["stray"] = text[: first.start()].strip()
    notes_global: list[str] = []
    for segment in _split_outside_quotes(text[first.start():], ";"):
        segment = segment.strip()
        if not segment:
            continue
        match = _CMD_RE.match(segment)
        if not match:
            # A segment with no command is a whole-answer instruction ("-- compare both", or plain text).
            notes_global.append(_strip_quotes(segment[2:] if segment.startswith("--") else segment))
            continue
        name = _canon(match.group(1))
        body = segment[match.end():]
        note = ""
        # Find the first " --" that sits outside quotes: everything after it is this section's note.
        idx, in_q = -1, False
        for i in range(len(body) - 1):
            if body[i] == '"':
                in_q = not in_q
            if not in_q and body[i:i + 2] == "--" and (i == 0 or body[i - 1].isspace()):
                idx = i
                break
        if idx >= 0:
            note = _strip_quotes(body[idx + 2:])
            body = body[:idx]
        positional: list[str] = []
        keywords: dict[str, str] = {}
        flags: set[str] = set()
        words: list[str] = []

        def flush_words() -> None:
            if words:
                positional.append(" ".join(words))
                words.clear()

        for tok in _TOKEN_RE.finditer(body):
            if tok.group("kv"):
                flush_words()
                key, _, value = tok.group("kv").partition("=")
                keywords[key.lower()] = _strip_quotes(value)
            elif tok.group("q"):
                flush_words()
                positional.append(_strip_quotes(tok.group("q")))
            elif tok.group("flag"):
                flush_words()
                flag = tok.group("flag")[1:].lower()
                if flag in KNOWN_FLAGS:
                    flags.add(flag)
                else:
                    result["errors"].append(f"!{name}: unknown flag +{flag} ignored")
            else:
                words.append(tok.group("word"))
        flush_words()
        positional = [p for p in positional if p]
        result["commands"].append({"name": name, "args": positional, "kw": keywords, "flags": sorted(flags), "note": note, "raw": segment})
    result["global_note"] = " ".join(n for n in notes_global if n).strip()
    return result


def _freshness(flags: list[str], kw: dict[str, str]) -> str:
    since = kw.get("since", "")
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", since):
        return f"{since}to{_dt.date.today().isoformat()}"
    if kw.get("freshness"):
        return kw["freshness"]
    for flag in flags:
        if flag in FRESHNESS_FLAGS:
            return FRESHNESS_FLAGS[flag]
    return ""


def _split_list(value: str) -> list[str]:
    return [v.strip().lstrip("-").strip() for v in re.split(r"[,\s]+", value or "") if v.strip().lstrip("-").strip()]


def site_operators(cmd: dict[str, Any]) -> str:
    """Brave operators from +uk, +ukgov, site="a, b" and nosite="c, d" (verified live 25 Sep 2026)."""
    kw, flags = cmd["kw"], cmd["flags"]
    include = _split_list(kw.get("site", ""))
    if "ukgov" in flags:
        include += UKGOV_SITES
    elif "uk" in flags and not include:
        include = ["uk"]
    ops = []
    if len(include) == 1:
        ops.append(f"site:{include[0]}")
    elif include:
        ops.append("(" + " OR ".join(f"site:{d}" for d in dict.fromkeys(include)) + ")")
    ops += [f"-site:{d}" for d in _split_list(kw.get("nosite", ""))]
    return " ".join(ops)


def apply_site_filter(name: str, call: dict[str, Any], ops: str) -> None:
    key = SITE_TARGET.get(name)
    if not ops or not key or key not in call:
        return
    if key == "queries":
        call[key] = "\n".join(f"{line} {ops}" for line in str(call[key]).splitlines() if line.strip())
    else:
        call[key] = f"{call[key]} {ops}"


def build_call(cmd: dict[str, Any]) -> tuple[Optional[dict[str, Any]], str]:
    call, error = _build_call(cmd)
    if call is not None:
        apply_site_filter(cmd["name"], call, site_operators(cmd))
    return call, error


def _build_call(cmd: dict[str, Any]) -> tuple[Optional[dict[str, Any]], str]:
    """Return (kwargs, error). kwargs excludes dunder context arguments."""
    name, args, kw, flags = cmd["name"], cmd["args"], cmd["kw"], cmd["flags"]
    first = args[0] if args else ""
    sources = "sources" in flags
    depth = "quick" if "quick" in flags else "deep" if "deep" in flags else "standard"
    fresh = _freshness(flags, kw)
    engine = "browser" if "browser" in flags else "curl" if "curl" in flags else "auto"

    def need(label: str) -> str:
        return f'!{name} needs {label}. Usage: {COMMANDS[name]["usage"]}'

    def count(default: int) -> int:
        try:
            return int(kw.get("count", default))
        except ValueError:
            return default

    if name == "discuss" and "anyforum" not in flags:
        if not first:
            return None, need("a query")
        if not (kw.get("site") or "uk" in flags or "ukgov" in flags):
            kw["site"] = ", ".join(FORUM_SITES)
        return {"__fn__": "web", "query": first, "count": count(10), "freshness": fresh or "pm", "extra_snippets": True}, ""
    if name in {"search", "news", "videos", "discuss"}:
        if not first:
            return None, need("a query")
        call: dict[str, Any] = {"query": first, "count": count(8 if name == "search" else 10)}
        if fresh or name == "search":
            call["freshness"] = fresh
        if name == "search":
            call["extra_snippets"] = "snippets" in flags
        return call, ""
    if name == "sweep":
        if len(args) < 3:
            return None, need('the request plus at least two quoted queries')
        return {"request": args[0], "queries": "\n".join(args[1:7]), "inclusion_criteria": kw.get("include", ""),
                "exclusion_criteria": kw.get("exclude", ""), "include_sources": sources, "freshness": fresh}, ""
    if name == "topic":
        return ({"question": first, "depth": depth, "freshness": fresh, "include_sources": sources}, "") if first else (None, need("a question"))
    if name == "summarise":
        if not first:
            return None, need("a subject")
        return {"subject": first, "focus": kw.get("focus", "general overview"), "depth": depth, "freshness": fresh, "include_sources": sources}, ""
    if name == "compare":
        args = [a for a in args if a.lower() not in {"vs", "vs.", "versus", "and"}]
        first = args[0] if args else ""
        subjects = args if len(args) >= 2 else [a.strip() for a in re.split(r"\s+(?:vs\.?|versus)\s+", first, flags=re.I) if a.strip()]
        if len(subjects) < 2:
            return None, need('two or more quoted subjects')
        return {"subjects": " | ".join(subjects), "criteria": kw.get("by", kw.get("criteria", "all material differences")),
                "depth": depth, "freshness": fresh, "include_sources": sources}, ""
    if name == "claim":
        if not first:
            return None, need("the claim in quotes")
        return {"claim": first, "context": kw.get("context", ""), "depth": depth, "freshness": fresh, "include_sources": sources}, ""
    if name == "portfolio":
        if not first:
            return None, need("a subject")
        return {"subject": first, "focus": kw.get("focus", "all material aspects"), "include_sources": sources,
                "include_diagrams": "nodiagrams" not in flags, "freshness": fresh}, ""
    if name == "brief":
        if not first:
            return None, need("a public company, organisation or figure")
        return {"subject": first, "angle": kw.get("angle", "professional activity and public record"), "freshness": fresh, "include_sources": sources}, ""
    if name == "profile":
        if not first:
            return None, need("a genuinely public person")
        call = {"subject": first, "organisation": kw.get("org", kw.get("organisation", "")), "include_sources": sources}
        if kw.get("focus"):
            call["focus"] = kw["focus"]
        return call, ""
    if name in {"read", "save"}:
        if not re.match(r"https?://", first or ""):
            return None, need("a full http(s) URL")
        return {"url": first, "engine": engine}, ""
    if name == "wiki":
        return ({"topic": first}, "") if first else (None, need("a topic"))
    if name == "library":
        return {}, ""
    if name == "ask":
        return ({"question": first, "document_id": kw.get("doc", "")}, "") if first else (None, need("a question"))
    if name == "overview":
        return {"focus": first or "general idea", "document_id": kw.get("doc", "")}, ""
    if name == "quote":
        if not first:
            return None, need("a phrase to find")
        try:
            lines = int(kw.get("lines", 2))
        except ValueError:
            lines = 2
        return {"phrase": first, "document_id": kw.get("doc", ""), "context_lines": lines}, ""
    return None, f"!{name} is not a runnable command"


def help_text() -> str:
    rows = "\n".join(f"| `{c['usage']}` | {c['does']} |" for n, c in COMMANDS.items())
    return (
        "## Brave commands\n\n| Command | What it does |\n|---|---|\n" + rows + "\n\n"
        "**Rules:** put text in \"double quotes\" · `+sources` adds numbered citations · `;` separates commands · "
        "`-- note` after a command is an instruction for that section · a final `; -- note` applies to the whole answer · "
        "`since=YYYY-MM-DD` limits dates · `+uk` = .uk sites only · `+ukgov` = gov.uk/parliament/NHS/ac.uk/police.uk · "
        "`site=\"a.com, b.org\"` / `nosite=\"x.com\"` include/exclude domains · `+keep` saves the evidence to this chat's library for `!ask` · "
        "the 📖 Command Guide model explains every command and builds one for you (type `build brave command` there)."
    )


class Filter:
    class Valves(BaseModel):
        priority: int = Field(default=-10, description="Runs before other filters.")
        ENABLED: bool = Field(default=True, description="Master switch for !commands.")
        HIDE_BRAVE_TOOLS_ON_COMMAND_TURNS: bool = Field(default=True, description="On a command turn, remove the Brave tools from the model so it cannot re-run or loop; results are already supplied.")
        MAX_COMMANDS: int = Field(default=6, description="Maximum commands executed from one message.")
        EVIDENCE_SHARE: float = Field(default=0.55, description="Share of the model's context window given to tool evidence (rest: system prompt, instructions, answer).")
        CHARS_PER_TOKEN: float = Field(default=3.5, description="Conservative characters-per-token estimate used for budgeting.")
        DEFAULT_CONTEXT_TOKENS: int = Field(default=65536, description="Assumed window when the model has no num_ctx set (e.g. API models).")
        MAX_TOTAL_CHARS: int = Field(default=160000, description="Hard ceiling on evidence characters injected in one turn.")
        SKIP_MODEL_IDS: str = Field(default="q_command-guide:8b", description="Comma-separated model ids where !commands are never run (the Command Guide only explains them).")

    def __init__(self) -> None:
        self.valves = self.Valves()

    # ---------------------------------------------------------------- helpers
    @staticmethod
    def _last_user_index(messages: list[dict[str, Any]]) -> int:
        for i in range(len(messages) - 1, -1, -1):
            if messages[i].get("role") == "user":
                return i
        return -1

    @staticmethod
    def _get_text(message: dict[str, Any]) -> str:
        content = message.get("content", "")
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            return "\n".join(str(p.get("text", "")) for p in content if isinstance(p, dict) and p.get("type") in {"text", "input_text"})
        return ""

    @staticmethod
    def _set_text(message: dict[str, Any], text: str) -> None:
        content = message.get("content", "")
        if isinstance(content, list):
            others = [p for p in content if not (isinstance(p, dict) and p.get("type") in {"text", "input_text"})]
            message["content"] = [{"type": "text", "text": text}] + others
        else:
            message["content"] = text

    @staticmethod
    async def _status(emitter: Optional[Callable], text: str, done: bool = False) -> None:
        if emitter:
            try:
                await emitter({"type": "status", "data": {"description": text, "done": done}})
            except Exception:
                pass

    @staticmethod
    async def _load_tool(tool_id: str) -> Any:
        from open_webui.models.tools import Tools
        from open_webui.utils.plugin import load_tool_module_by_id

        tool = await Tools.get_tool_by_id(tool_id)
        if tool is None:
            raise RuntimeError(f"tool {tool_id} is not installed")
        # OWUI 0.11 returned (instance, frontmatter); 0.12 adds the module as a third value.
        instance = (await load_tool_module_by_id(tool_id, content=tool.content))[0]
        valves = await Tools.get_tool_valves_by_id(tool_id) or {}
        if hasattr(instance, "Valves"):
            instance.valves = instance.Valves(**valves)
        return instance

    async def _keep(self, cmd: dict[str, Any], output: str, ctx: dict[str, Any], cache: dict[str, Any]) -> str:
        """Save the full, untrimmed evidence to this chat's Reader Library; returns a one-line status."""
        if cmd["name"] in {"read", "save", "wiki", "library", "ask", "overview", "quote"}:
            return "not needed for Reader commands (use !save for pages)"
        try:
            if "brave_reader" not in cache:
                cache["brave_reader"] = await self._load_tool("brave_reader")
            reader = cache["brave_reader"]
            scope = reader._scope(ctx.get("__chat_id__"), ctx.get("__user__"))
            if not scope:
                return "not saved - no chat context (API or temporary chat)"
            import hashlib
            label = f'!{cmd["name"]} ' + " ".join(f'"{a}"' for a in cmd["args"])
            url = f'router://{cmd["name"]}/{hashlib.sha256(cmd["raw"].encode()).hexdigest()[:12]}'
            row = reader._save(scope, url, f"Title: Evidence for {label[:200]}\n\n{output}")
            return f'saved to this chat\'s Reader Library as `{row["id"]}` - follow up with !ask "question" doc="{row["id"]}"'
        except Exception as exc:
            return f"not saved ({type(exc).__name__})"

    async def _run(self, cmd: dict[str, Any], ctx: dict[str, Any], cache: dict[str, Any]) -> str:
        spec = COMMANDS[cmd["name"]]
        call, error = build_call(cmd)
        if error:
            return f"[ROUTER STATUS: INVALID_COMMAND]\n\n{error}"
        if spec["tool"] not in cache:
            cache[spec["tool"]] = await self._load_tool(spec["tool"])
        fn = getattr(cache[spec["tool"]], call.pop("__fn__", spec["fn"]))
        params = inspect.signature(fn).parameters
        for key, value in ctx.items():
            if key in params:
                call[key] = value
        try:
            return str(await fn(**call))
        except Exception as exc:  # typed, content-free failure; no fallback
            return f"[ROUTER STATUS: TOOL_ERROR]\n\n{spec['tool']}.{spec['fn']} raised {type(exc).__name__}. No fallback was used."

    _SOURCE_LINE = re.compile(r"^#{2,4} \[(\d+)\] (\[.*?\]\(https?://[^)\s]+\))", re.M)
    _URL_LINE = re.compile(r"^(\d+)\. .*?(https?://\S+)", re.M)

    def _budget(self, model: Optional[dict]) -> int:
        num_ctx = None
        try:
            params = ((model or {}).get("info") or {}).get("params") or {}
            num_ctx = int(params.get("num_ctx") or 0) or None
        except (TypeError, ValueError):
            num_ctx = None
        tokens = num_ctx or self.valves.DEFAULT_CONTEXT_TOKENS
        return max(8000, min(self.valves.MAX_TOTAL_CHARS, int(tokens * self.valves.CHARS_PER_TOKEN * self.valves.EVIDENCE_SHARE)))

    def _fit(self, output: str, limit: int) -> str:
        """Trim one tool result to its share, keeping a compact index of every source URL so citations stay real."""
        if len(output) <= limit:
            return output
        index = [f"[{n}] {link}" for n, link in self._SOURCE_LINE.findall(output)]
        index_text = ("\n\n[SOURCE INDEX - every citable URL from the full result]\n" + "\n".join(index)) if index else ""
        note = "\n\n[ROUTER: evidence trimmed to fit this model's context window]"
        keep = max(2000, limit - len(index_text) - len(note))
        return output[:keep].rstrip() + note + index_text

    # ------------------------------------------------------------------ inlet
    async def inlet(
        self,
        body: dict,
        __user__: Optional[dict] = None,
        __event_emitter__: Optional[Callable] = None,
        __event_call__: Optional[Callable] = None,
        __metadata__: Optional[dict] = None,
        __model__: Optional[dict] = None,
    ) -> dict:
        if not self.valves.ENABLED:
            return body
        model_id = str((__model__ or {}).get("id") or body.get("model") or "")
        if model_id and model_id in {m.strip() for m in self.valves.SKIP_MODEL_IDS.split(",") if m.strip()}:
            return body
        messages = body.get("messages") or []
        idx = self._last_user_index(messages)
        if idx < 0:
            return body
        original = self._get_text(messages[idx])
        tagged = _PLAIN_SKILL_RE.sub(lambda m: f"<${m.group(1).lower()}|{m.group(1).lower()}>", original)
        if tagged != original:
            self._set_text(messages[idx], tagged)
            original = tagged
        if not has_command(original):
            return body

        skill_tags = [m.group(0) for m in _OTHER_SKILL_TAG_RE.finditer(original)]
        parsed = parse(_OTHER_SKILL_TAG_RE.sub(" ", original))
        commands = parsed["commands"][: self.valves.MAX_COMMANDS]
        dropped = len(parsed["commands"]) - len(commands)
        chat_id = (__metadata__ or {}).get("chat_id")
        ctx = {"__user__": __user__ or {}, "__event_emitter__": __event_emitter__, "__event_call__": __event_call__, "__chat_id__": chat_id}

        # Help only: no tool call.
        if commands and all(c["name"] == "help" for c in commands):
            self._set_text(messages[idx], "[BRAVE COMMAND ROUTER]\nReproduce the following reference exactly, with no additions:\n\n" + help_text())
            if self.valves.HIDE_BRAVE_TOOLS_ON_COMMAND_TURNS and isinstance(body.get("tool_ids"), list):
                body["tool_ids"] = [t for t in body["tool_ids"] if t not in BRAVE_TOOL_IDS]
            return body

        cache: dict[str, Any] = {}
        sections: list[str] = []
        runnable = [c for c in commands if c["name"] != "help"] or commands
        budget = self._budget(__model__)
        per_section = max(4000, budget // max(1, len(runnable)))
        any_sources = False
        for number, cmd in enumerate(commands, 1):
            if cmd["name"] == "help":
                continue
            spec = dict(COMMANDS[cmd["name"]])
            if cmd["name"] == "discuss" and "anyforum" not in cmd["flags"]:
                spec["fn"] = "web (forum sites)"
            await self._status(__event_emitter__, f"⚡ Router {number}/{len(commands)}: {spec['tool']}.{spec['fn']}")
            full_output = await self._run(cmd, ctx, cache)
            kept = await self._keep(cmd, full_output, ctx, cache) if "keep" in cmd["flags"] else ""
            output = self._fit(full_output, per_section)
            ops = site_operators(cmd)
            wants_sources = "sources" in cmd["flags"]
            any_sources = any_sources or wants_sources
            args_view = ", ".join(f'"{a}"' for a in cmd["args"]) or "(none)"
            sections.append(
                f"### Section {number}: !{cmd['name']} {args_view}\n"
                f"- Tool already executed: `{spec['tool']}.{spec['fn']}`\n"
                f"- Flags: {', '.join('+' + f for f in cmd['flags']) or 'none'}"
                + (f"; options: {', '.join(k + '=' + repr(v) for k, v in cmd['kw'].items())}" if cmd["kw"] else "") + "\n"
                + (f"- Site filter applied: `{ops}`\n" if ops and cmd["name"] in SITE_TARGET else "")
                + (f"- Evidence {kept} (tell Liam this ID in one line)\n" if kept else "")
                + f"- Numbered sources: {'REQUIRED for this section' if wants_sources else 'not requested - do not add a Sources list'}\n"
                f"- Liam's instruction for this section: {cmd['note'] or 'none'}\n\n"
                f"<tool_result>\n{output}\n</tool_result>"
            )
        await self._status(__event_emitter__, f"⚡ Router ran {len(sections)} command(s)", done=True)

        notices = list(parsed["errors"])
        if parsed["stray"]:
            notices.append(f'stray text before the first command was ignored: "{parsed["stray"][:80]}"')
        if dropped > 0:
            notices.append(f"{dropped} command(s) beyond the limit of {self.valves.MAX_COMMANDS} were not run")

        prompt = (
            "[BRAVE COMMAND ROUTER - commands already executed]\n"
            "Liam sent explicit commands. The router has ALREADY run each Brave tool below over the protected route. "
            "Do not call any tool for these sections and do not ask to search again. Write one response with one section per command, "
            "in order, using only the supplied results and following each section's instruction. If a result shows a failure status, "
            "say so plainly for that section; do not fill the gap from memory.\n"
            + (f"\nInstruction for the whole answer: {parsed['global_note']}\n" if parsed["global_note"] else "")
            + ("\nRouter notices to mention briefly at the top: " + "; ".join(notices) + "\n" if notices else "")
            + ("\nWhere sources are REQUIRED, cite with numbered markers and end that section with its numbered Sources list; every Sources entry must give the title AND the full URL copied exactly from that section's tool result or SOURCE INDEX. Never invent, shorten or placeholder a URL; omit a source rather than guess.\n" if any_sources else "")
            + f"\nOriginal message: {original.strip()}\n\n" + "\n\n".join(sections)
            + "\n\n[ROUTER REMINDER] Write one section per command in order, from the tool results above only; follow each section's instruction"
            + (f" and the whole-answer instruction ({parsed['global_note']})" if parsed["global_note"] else "")
            + ("; copy source URLs exactly - never invent one" if any_sources else "; no Sources lists were requested")
            + "."
        )
        if skill_tags:  # keep e.g. <$diagram-timeline|...> so OWUI still applies that skill to this answer
            prompt = " ".join(skill_tags) + "\n" + prompt
        self._set_text(messages[idx], prompt)
        if self.valves.HIDE_BRAVE_TOOLS_ON_COMMAND_TURNS and isinstance(body.get("tool_ids"), list):
            body["tool_ids"] = [t for t in body["tool_ids"] if t not in BRAVE_TOOL_IDS]
        return body
