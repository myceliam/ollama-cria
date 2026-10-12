"""Rewrite the "# DIAGRAM SKILLS" section of command_guide_system_prompt.md from diagram_skills.py (AICL-0179).

Each entry shows the skill's description, its template drawn as a live example, four example prompts, and a clean
block to copy. Run on the host from E:\\ai\\ollama\\owui-tools, then deploy with deploy_command_guide.py:
  python -I build_guide_diagram_section.py
"""

import importlib.util
import pathlib
import re

HERE = pathlib.Path(__file__).resolve().parent
PROMPT = HERE / "command_guide_system_prompt.md"
HEADING = "# DIAGRAM SKILLS"

spec = importlib.util.spec_from_file_location("diagram_skills", HERE / "diagram_skills.py")
skills = importlib.util.module_from_spec(spec)
spec.loader.exec_module(skills)

INTRO = (
    "These are skills, not router commands: each one tells the model how to draw one kind of reliable Mermaid diagram. "
    "To use one, paste its block (or type `$` and the skill name and pick it from the menu that pops up), then type what "
    "to draw after it. With nothing after the skill, it diagrams the latest topic in the chat. No tool needs ticking. "
    "Each entry below shows an example of what it draws, some example prompts, ways to stack it with a Brave command (the search runs first, then the skill draws from the results; it may not always work), and a clean block to copy."
)


def entry(skill: dict) -> str:
    example = re.search(r"```mermaid\n.*?\n```", skill["body"], re.S).group(0)
    uses = "; ".join(skill["uses"]).lower()
    prompts = "\n".join(f"- {p}" for p in skill["prompts"])
    stacks = "\n".join(f"- {p}" for p in skill.get("stacks", []))
    return (
        f"### {skill['id']}\n"
        f"{skill['summary']} Best for: {uses}.\n\n"
        f"**Example:**\n{example}\n\n"
        f"**Example prompts:**\n{prompts}\n\n"
        + (f"**Stack it with a Brave command (searches first, then draws):**\n{stacks}\n\n" if stacks else "")
        +
        f"**Copy this, then type what to draw after it:**\n```\n${skill['id']} \n```"
    )


section = HEADING + "\n\n" + INTRO + "\n\n" + "\n\n".join(entry(s) for s in skills.SKILLS) + "\n"
text = PROMPT.read_text(encoding="utf-8")
start = text.index(HEADING)
nxt = re.search(r"^# ", text[start + len(HEADING):], re.M)
end = start + len(HEADING) + nxt.start() if nxt else len(text)
PROMPT.write_text(text[:start] + section + ("\n" + text[end:] if nxt else ""), encoding="utf-8", newline="")
print(f"diagram section: {len(skills.SKILLS)} entries, {len(section)} chars")
