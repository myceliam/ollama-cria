"""Definitions for the ten diagram-* Open WebUI skills (AICL-0171).

Each skill fixes the diagram type so the model does not fall back to a flowchart, and carries
only the syntax rules for that type. Every template below renders in Open WebUI 0.12.0's bundled
Mermaid 11.15.0. deploy_diagram_skills.py creates or updates them through the skills API.
"prompts" and "stacks" (skill plus a Brave command) feed the Command Guide's diagram list (build_guide_diagram_section.py, AICL-0179); the skills ignore it.
"""

COMMON_RULES = (
    "## Rules that keep it rendering in Open WebUI\n"
    "1. Exactly one fenced ```mermaid block, with nothing but the diagram inside it.\n"
    "2. Copy the template's shape. Do not add `%%{init}%%` themes, HTML tags, emoji or styling; the renderer supplies the dark look.\n"
    "3. Keep every label on one line. Inside quoted labels use single quotes, never double quotes.\n"
    "4. Keep it readable: about 20 items at most.\n"
    "5. After the block, write 2 to 4 plain-English lines saying what the diagram shows.\n\n"
    "If the request is vague, draw the most useful interpretation rather than asking. "
    "If nothing follows the command, diagram the most recent topic in this conversation."
)

SKILLS = [
    {
        "id": "diagram-flowchart",
        "summary": "Steps, decisions and cause and effect as boxes and arrows.",
        "uses": ["Processes and how something works", "Cause and effect", "Decision paths (yes/no branches)"],
        "prompts": ["how a parcel gets from the warehouse to my door", "what to do if my boiler stops working", "how a bill becomes law in the UK", "how my home server reaches the internet through the VPS"],
        "stacks": ["$diagram-flowchart !topic \"how does a heat pump work\" -- draw the process step by step", "$diagram-flowchart !portfolio \"how a bill becomes law in the UK\" +nodiagrams -- show the stages", "$diagram-flowchart !search \"how to reset a Hive thermostat\" -- turn the steps into a flowchart"],
        "body": (
            "Draw a Mermaid **flowchart**. Do not switch to another diagram type.\n\n"
            "```mermaid\nflowchart TD\n    start[\"Feeling tired\"] --> check{\"Sleeping 7+ hours?\"}\n"
            "    check -->|\"No\"| sleep[\"Fix sleep first\"]\n    check -->|\"Yes\"| bloods[\"Ask GP for blood test\"]\n```\n\n"
            "- Use `flowchart TD` (top-down) or `flowchart LR` for wide pipelines; never the legacy `graph`.\n"
            "- Short IDs (`a`, `gp`, `vps`); every label in double quotes: `id[\"Label (detail)\"]`, decisions `id{\"Question?\"}`.\n"
            "- One edge per line: write `a --> c` and `b --> c`, never `a, b --> c`. Edge labels quoted: `-->|\"text\"|`.\n"
            "- Never use lowercase `end` as an ID. Group related nodes with `subgraph g1[\"Title\"]` ... `end` only when it helps."
        ),
    },
    {
        "id": "diagram-mindmap",
        "summary": "Ideas branching out from one central topic.",
        "uses": ["Brainstorms", "Topic overviews", "Pros and cons, or causes and fixes"],
        "prompts": ["ways to sleep better", "everything to think about before getting a dog", "the causes and fixes of slow Wi-Fi", "the main ideas in this conversation"],
        "stacks": ["$diagram-mindmap !discuss \"best home lab projects\" +year -- map the main ideas people suggest", "$diagram-mindmap !topic \"causes of the cost of living crisis\" -- map causes and effects", "$diagram-mindmap !sweep \"self-hosted AI tools\" \"open source AI self hosted\" \"local LLM apps\" -- group them by type"],
        "body": (
            "Draw a Mermaid **mindmap**. Do not switch to another diagram type.\n\n"
            "```mermaid\nmindmap\n  root((\"Better sleep\"))\n    Causes\n      Stress\n      Late caffeine\n"
            "    Fixes\n      Fixed bedtime\n      Dark, cool room\n```\n\n"
            "- Structure comes only from indentation: two spaces per level, consistently. No arrows.\n"
            "- The root is `root((\"Topic\"))`. Branches are short plain words with no brackets, colons or quotes.\n"
            "- 3 to 6 main branches, each with 2 to 5 leaves."
        ),
    },
    {
        "id": "diagram-timeline",
        "summary": "Events laid out in date order.",
        "uses": ["History and background", "A sequence of incidents", "Project milestones"],
        "prompts": ["the history of the Raspberry Pi", "the key events of the 2008 financial crash", "my home lab changes this year", "the main moments in the life of Alan Turing"],
        "stacks": ["$diagram-timeline !news \"Open WebUI\" +month -- draw the key events in date order", "$diagram-timeline !portfolio \"the history of the Raspberry Pi\" -- show the main releases", "$diagram-timeline !topic \"key events of the 2008 financial crash\" +sources -- lay them out by year"],
        "body": (
            "Draw a Mermaid **timeline**. Do not switch to another diagram type.\n\n"
            "```mermaid\ntimeline\n    title NHS dental changes\n    2006 : New dental contract\n"
            "    2020 : Practices close in lockdown\n    2024 : Recovery plan : New patient premium\n```\n\n"
            "- Every line is `period : event`, with ` : ` between extra events in the same period. Never use arrows (`→`, `->`).\n"
            "- The period must not contain a colon: write `14.30`, not `14:30`. No `#` or `;` in the period.\n"
            "- Optional `section Name` lines group periods. Keep events short."
        ),
    },
    {
        "id": "diagram-sequence",
        "summary": "Who says or sends what to whom, in order.",
        "uses": ["Conversations and negotiations", "Request and response between systems", "Hand-offs between people or teams"],
        "prompts": ["what happens when I log in to a website", "how a GP referral to a specialist works", "how my phone talks to Open WebUI through Tailscale", "ordering a takeaway from an app, step by step"],
        "stacks": ["$diagram-sequence !topic \"how HTTPS sets up a secure connection\" -- show who sends what", "$diagram-sequence !search \"how an NHS GP referral works\" -- show the steps between patient, GP and hospital", "$diagram-sequence !topic \"how Tailscale connects two devices\" -- draw the messages between them"],
        "body": (
            "Draw a Mermaid **sequenceDiagram**. Do not switch to another diagram type.\n\n"
            "```mermaid\nsequenceDiagram\n    participant P as Patient\n    participant G as GP\n    participant L as Lab\n"
            "    P->>G: Describes symptoms\n    G->>L: Requests blood test\n    L-->>G: Sends results\n    G-->>P: Explains results\n```\n\n"
            "- Declare each participant once at the top with a short ID: `participant G as GP`.\n"
            "- `->>` for a message, `-->>` for a reply. Message text after the colon, with no further colons.\n"
            "- Optional `Note over P,G: text`, and `alt` / `else` / `end` blocks for branches."
        ),
    },
    {
        "id": "diagram-chart",
        "summary": "Numbers as a bar and/or line chart.",
        "uses": ["Comparing amounts", "Trends over time", "Before and after figures"],
        "prompts": ["UK average house prices 2015 to 2025", "my monthly electricity use this year", "UK inflation over the last ten years", "rainfall by month in Manchester"],
        "stacks": ["$diagram-chart !search \"UK inflation rate by year 2015 to 2025\" +sources -- chart the yearly figures", "$diagram-chart !news \"UK house prices\" +month -- chart any figures mentioned", "$diagram-chart !topic \"global EV sales by year\" +sources -- bar chart of sales per year"],
        "body": (
            "Draw a Mermaid **xychart-beta**. Do not switch to another diagram type.\n\n"
            "```mermaid\nxychart-beta\n    title \"UK inflation (%)\"\n    x-axis [2021, 2022, 2023, 2024]\n"
            "    y-axis \"Percent\" 0 --> 12\n    bar [2.6, 9.1, 7.3, 2.5]\n    line [2.6, 9.1, 7.3, 2.5]\n```\n\n"
            "- Titles and axis names in double quotes. X-axis categories in square brackets, separated by commas.\n"
            "- The y-axis range must cover every value. Each `bar [...]` or `line [...]` has one number per category.\n"
            "- Numbers only in the data lists: no units, % signs or thousands commas. Use `bar` and/or `line`.\n"
            "- Only use figures from the conversation or sources; say in the explanation if any are estimates."
        ),
    },
    {
        "id": "diagram-pie",
        "summary": "Shares of a whole as a pie chart.",
        "uses": ["Budget or time breakdowns", "Market or vote shares", "Survey results"],
        "prompts": ["how a typical monthly budget splits", "where UK electricity comes from", "how I spend a normal weekday", "the vote share in the last general election"],
        "stacks": ["$diagram-pie !search \"UK electricity generation mix 2025\" +sources -- show the shares as a pie", "$diagram-pie !topic \"where UK income tax is spent\" -- pie of the main spending areas", "$diagram-pie !search \"smartphone market share UK\" -- pie of the brands"],
        "body": (
            "Draw a Mermaid **pie** chart. Do not switch to another diagram type.\n\n"
            "```mermaid\npie title Monthly budget\n    \"Rent\" : 900\n    \"Food\" : 400\n    \"Savings\" : 300\n```\n\n"
            "- Every slice is `\"Label\" : number`, label in double quotes, plain number with no units or % sign.\n"
            "- 2 to 8 slices. Combine small ones into \"Other\".\n"
            "- Only use figures from the conversation or sources; say in the explanation if any are estimates."
        ),
    },
    {
        "id": "diagram-quadrant",
        "summary": "Items placed on a two-by-two grid by two qualities.",
        "uses": ["Priorities (effort against impact)", "Risk (likelihood against severity)", "Comparing options on two measures"],
        "prompts": ["my home lab jobs by effort and impact", "household risks by likelihood and severity", "these laptops by price and performance", "my to-do list by urgency and importance"],
        "stacks": ["$diagram-quadrant !compare \"Proxmox\" \"Unraid\" \"TrueNAS\" -- place them by ease of use and power", "$diagram-quadrant !discuss \"home lab projects worth doing\" -- place them by effort and payoff", "$diagram-quadrant !topic \"main household fire risks\" -- place them by likelihood and severity"],
        "body": (
            "Draw a Mermaid **quadrantChart**. Do not switch to another diagram type.\n\n"
            "```mermaid\nquadrantChart\n    title Priorities\n    x-axis Low effort --> High effort\n"
            "    y-axis Low impact --> High impact\n    quadrant-1 Plan carefully\n    quadrant-2 Do now\n"
            "    quadrant-3 Drop\n    quadrant-4 Delegate\n    Fix boiler: [0.3, 0.9]\n    Paint shed: [0.6, 0.2]\n```\n\n"
            "- quadrant-1 is top right, 2 top left, 3 bottom left, 4 bottom right.\n"
            "- Each point is `Name: [x, y]` with both values between 0 and 1. Names in plain words with no colons or brackets.\n"
            "- Axis text is plain words joined by `-->`. 3 to 12 points."
        ),
    },
    {
        "id": "diagram-compare",
        "summary": "Several options scored across the same criteria, as a radar chart.",
        "uses": ["Product or option comparisons", "Strengths and weaknesses", "Scoring choices against criteria"],
        "prompts": ["three budget laptops on battery, screen, speed and price", "Proxmox, Unraid and TrueNAS for a home server", "the main VPN providers on privacy, speed and price", "two phones on camera, battery, value and size"],
        "stacks": ["$diagram-compare !compare \"iPhone 17\" \"Pixel 10\" \"Galaxy S26\" by=\"camera, battery, value, size\" -- score each out of 5", "$diagram-compare !compare \"Mullvad\" \"Proton VPN\" \"NordVPN\" by=\"privacy, speed, price\" -- radar of the scores", "$diagram-compare !discuss \"best budget laptop\" +year -- score the most recommended models"],
        "body": (
            "Draw a Mermaid **radar-beta** chart. Do not switch to another diagram type.\n\n"
            "```mermaid\nradar-beta\n    title Phones\n    axis cam[\"Camera\"], bat[\"Battery\"], price[\"Value\"], size[\"Size\"]\n"
            "    curve a[\"Phone A\"]{4, 3, 2, 4}\n    curve b[\"Phone B\"]{2, 5, 4, 3}\n    max 5\n    min 0\n```\n\n"
            "- `axis` lists every criterion once as `id[\"Label\"]`, separated by commas. 3 to 8 axes.\n"
            "- Each `curve id[\"Option\"]{...}` has exactly one score per axis, in the same order. 2 to 5 curves.\n"
            "- Use one scale (for example 0 to 5) and set `max` and `min` to it. Explain the scores below the block."
        ),
    },
    {
        "id": "diagram-sankey",
        "summary": "Amounts flowing from sources to destinations.",
        "uses": ["Where money goes", "Energy or resource flows", "Funnels and drop-off"],
        "prompts": ["where UK council tax money goes", "where my monthly salary goes", "how the UK's energy supply flows into homes, transport and industry", "a website funnel from visit to purchase"],
        "stacks": ["$diagram-sankey !search \"UK government spending breakdown 2025\" +sources -- show where the money goes", "$diagram-sankey !topic \"how UK energy flows from sources to homes, transport and industry\" -- sankey of the flows", "$diagram-sankey !search \"average UK household budget breakdown\" -- flow from income to spending"],
        "body": (
            "Draw a Mermaid **sankey-beta** diagram. Do not switch to another diagram type.\n\n"
            "```mermaid\nsankey-beta\nSalary,Rent,900\nSalary,Food,400\nSalary,Savings,300\nSavings,ISA,200\n```\n\n"
            "- After the first line, every line is `source,target,value`: three fields, no header row, no spaces after commas.\n"
            "- Values are plain numbers. Names must not contain commas; if one must, wrap it in double quotes.\n"
            "- Flows must not loop back to an earlier node."
        ),
    },
    {
        "id": "diagram-gantt",
        "summary": "Tasks on a calendar, showing order and overlap.",
        "uses": ["Project plans", "Schedules and deadlines", "Treatment or training plans over weeks"],
        "prompts": ["a six-week plan to move my server to the VPS", "a twelve-week couch to 5K plan", "planning a kitchen refit", "revision for three exams over a month"],
        "stacks": ["$diagram-gantt !search \"typical UK house move timeline\" -- turn it into a schedule", "$diagram-gantt !topic \"couch to 5K plan week by week\" -- gantt of the nine weeks", "$diagram-gantt !portfolio \"how long a kitchen refit takes\" +nodiagrams -- schedule the stages"],
        "body": (
            "Draw a Mermaid **gantt** chart. Do not switch to another diagram type.\n\n"
            "```mermaid\ngantt\n    title Kitchen refit\n    dateFormat YYYY-MM-DD\n    section Prepare\n"
            "    Quotes :q1, 2026-11-02, 7d\n    Order units :o1, after q1, 3d\n    section Build\n    Fit units :f1, after o1, 5d\n```\n\n"
            "- Keep `dateFormat YYYY-MM-DD`. Each task is `Name :id, start, duration` where start is a date or `after id`.\n"
            "- Durations like `3d` or `2w`. Task names without colons.\n"
            "- Group tasks with `section Name`."
        ),
    },
]


def description(skill: dict) -> str:
    """Short menu text, matching the existing `(TAG) command — purpose` style."""
    return f"(DIAGRAM) {skill['id']} <what to draw> — {skill['summary']} Best for: {'; '.join(skill['uses']).lower()}."


def content(skill: dict) -> str:
    uses = "\n".join(f"- {use}" for use in skill["uses"])
    return (
        f"# {skill['id']} — {skill['summary']}\n\n"
        f"Draw what the user describes after the command.\n\n## Best for\n{uses}\n\n"
        f"## Template\n{skill['body']}\n\n{COMMON_RULES}"
    )
