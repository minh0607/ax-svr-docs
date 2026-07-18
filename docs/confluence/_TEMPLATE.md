# Confluence page template & style guide (AX Svr)

**Every page follows this shape.** English, for an internal technical audience.

## Structure
1. `# AX Svr — <Component>` (H1)
2. **One-paragraph intro:** what this component is and *why it's built this way* (the decision, not just the fact).
3. **`> Info callout`** line near the top with: source repo doc path + one-line status.
4. Body sections (`##`) with real detail pulled from the source doc:
   - Config/parameter **tables** (name | value | note).
   - **Code blocks** for the actual commands / config snippets — keep comments English.
   - A **"Key decisions"** subsection where the design made a deliberate, non-obvious choice (say what was chosen AND what was rejected + why).
5. **"Related pages"** list at the bottom linking sibling components.
6. If a diagram exists/created for this page, embed it near the top: `![...](../images/en/<name>.png)` and note operators upload it as a Confluence attachment.

## Rules
- **Do not invent values.** Use what the source doc states. Where the doc leaves something to the engineer (e.g. NIC name, exact IP), keep it as a clearly-marked placeholder `<...>`, don't fabricate.
- Translate faithfully; don't drop the safety warnings the Vietnamese docs carry (e.g. backup Plan B risk, "create tables as owner").
- Prefer tables and short code blocks over walls of prose. This is a reference page.
- Network convention: WAN `107.118.210.<n>`, LAN `10.1.1.<n>`, same last octet on both NICs.
- PostgreSQL 17; Ubuntu Server 24.04 (Linux hosts); Windows Server 2025 (web).
- Confluence upload note at the very bottom: "Paste as Markdown; upload any referenced PNG as a page attachment."
