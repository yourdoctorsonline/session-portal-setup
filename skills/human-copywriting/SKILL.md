---
name: human-copywriting
description: >
  Write copy that reads like a skilled human wrote it — zero AI tells. Built on
  Wikipedia's "Signs of AI writing" catalog (WP:AISIGNS): bans the vocabulary,
  sentence patterns, and formatting habits that make text pattern-match as
  AI-generated, and replaces them with the mechanics of strong human copy —
  specificity, stance, and varied rhythm. Use this whenever writing OR rewriting
  any reader-facing prose: marketing copy, landing pages, ads, emails, social
  posts, product descriptions, bios, About pages, newsletters, video scripts.
  Triggers: "write copy", "make this sound human", "humanize this", "de-AI this",
  "this sounds like ChatGPT", "won't be detectable as AI", "AI detector",
  "punch this up". Also run it as a silent final pass before delivering any
  customer-facing prose, even when the user didn't ask. Does NOT trigger for
  code, technical docs, or intentionally formal legal/academic text.
---

# Human Copywriting

Write copy a reader would never clock as AI. The method is not evasion — it's the observation that every "AI tell" is also just weak writing. Kill the tells by writing well: concrete facts, a real opinion, sentences that don't all march in step.

## Outcome

Reader-facing copy (new or rewritten) that:
- Contains zero patterns from the banned catalog (`references/ai-tells.md`)
- Makes specific, checkable claims instead of vague inflated ones
- Has deliberate rhythm variance — sentence lengths and paragraph shapes differ
- Takes a stance the way a human expert with skin in the game would

When rewriting, also return a short list of what was changed and why.

## Context Needs

All optional — the skill works standalone. Load only what exists in the current workspace:

| File (if present) | Purpose |
|---|---|
| `brand_context/voice-profile.md` (or any voice/tone guide) | Use the brand's actual vocabulary and rhythm as the replacement palette |
| `brand_context/icp.md` (or any audience doc) | Write to one specific reader, not "audiences" |
| `brand_context/positioning.md` | Source of the concrete differentiators Step 1 needs |

## Skill Relationships

- **`tool-humanizer`** (project-level, agentic-os): a post-processing cleaner that scores and scrubs finished text. This skill is the upstream fix — write it right the first time so there's less to scrub. For new copy, use this skill; for scoring an existing draft someone else wrote, either works.
- **`mkt-copywriting` / other content skills**: they own persuasion strategy (offer, angle, structure). This skill owns the prose layer. When both apply, follow their structure and write every sentence under this skill's rules.

## Why AI copy gets spotted

Three signals give it away, to both detectors and human readers:

1. **Stock patterns.** LLMs reuse the same constructions at density no human does: "isn't just X — it's Y", triplet lists, "-ing" analysis clauses, the same 40 words ("delve", "tapestry", "seamless", "elevate"). One instance is human. Five per page is a signature.
2. **Vagueness dressed as insight.** "Game-changing results", "industry experts agree", "unlock your full potential" — claims with no falsifiable content. Humans who know their subject write checkable specifics; models padding a word count write mist.
3. **Uniformity.** Same sentence length, same paragraph shape, same relentless positive tone, everything wrapped up with a summary. Human writing is bursty — short jabs, then a long winding sentence, an aside, an abrupt stop.

Fix those three and there is nothing left to detect. That's the whole method.

## Step 1: Gather substance

Before writing a word, collect the raw material vague copy is used to hide the absence of:

- Numbers: prices, timeframes, counts, percentages, dates
- Names: real customers, real competitors, real places, real features
- The one thing this product/offer does that the alternative doesn't
- A real objection the reader has, stated in their words
- The actual offer: what happens if they click, what it costs, what's guaranteed

Pull from the conversation, workspace files, and brand context. If a load-bearing specific is missing (e.g. no proof point exists), do not invent one and do not pad around it — write the copy with a clearly marked `[NEED: customer count]` placeholder and tell the user what's missing. Fabricated specifics are worse than vague ones.

## Step 2: Set the voice

Copy sounds human when it sounds like *a* human. Pick one:

- If a voice profile exists in the workspace, use it.
- Otherwise, define a one-line persona before drafting: *"A founder who's tired of competitors overpromising"*, *"a doctor explaining this to a friend at dinner"*. Write every sentence as that person.

Default register for marketing copy: one person talking to one person. Contractions on. Second person. Confident, a little opinionated, allowed to be wry. No exclamation points doing the enthusiasm's job.

## Step 3: Draft under the bans

Write the draft with the hard bans in force from the first sentence — don't plan to "clean it later". The full catalog is in `references/ai-tells.md`; read it before your first draft in a session. The bans that do the most work:

**Never use these words in copy:** delve, tapestry, testament, landscape (metaphorical), pivotal, crucial, vital, robust, seamless, leverage (verb), elevate, empower, unlock, unleash, foster, cultivate, holistic, nuanced, multifaceted, realm, journey (metaphorical), navigate (metaphorical), boasts, vibrant, meticulous, intricate, game-changer, transformative, revolutionary, cutting-edge, ever-evolving, dive/deep-dive.

**Never use these constructions:**
- Negative parallelism: "It's not just X, it's Y" / "This isn't X — it's Y" / "Not X. Not Y. Just Z."
- Rule of three as a reflex: "faster, smarter, and more reliable"
- "-ing" trailer clauses: "...— ensuring your team stays aligned", "...highlighting our commitment to quality"
- Copula avoidance: "serves as", "stands as", "represents", "acts as" — just say "is"
- Vague attribution: "experts agree", "studies show", "industry reports suggest" — name the source or cut the claim
- Significance inflation: "plays a vital role", "stands as a testament", "rich heritage"
- Cliché openers: "In today's fast-paced world", "In the ever-evolving landscape of", "It's no secret that"
- Summary endings: "In summary", "Ultimately", "At the end of the day" — end on the strongest specific or the offer instead

**Formatting bans:** no bold-header bullet lists ("**Speed:** our platform is fast") in prose copy; no Title Case Headings; no emoji as section markers; max one em dash per ~150 words; no horizontal rules between sections.

## Step 4: Tell-sweep

After drafting, sweep against `references/ai-tells.md` — it's organized as a checklist. Judge by **density**, not existence: one triplet or one "however" is human; the tell is the pattern repeating. Thresholds:

- Any hard-banned word or construction → rewrite the sentence (not synonym-swap; the *thought* was templated)
- Same sentence-opener twice in a paragraph → vary it
- Any claim you couldn't defend to a skeptic with a source or a number → sharpen it or cut it
- Any sentence that would survive being pasted into a competitor's page unchanged → it's generic; rewrite it with something only this brand can say

## Step 5: Rhythm pass

Read the draft aloud (literally simulate this — subvocalize the cadence):

- Sentence lengths should visibly vary. Aim for a mix like 4 words / 22 words / 11 words / 7 words — not a wall of 15-18s.
- Paragraph shapes should differ: a one-liner somewhere, one meatier block, not four identical 3-sentence bricks.
- At least one sentence should do something slightly irregular — start with "And", end abruptly, repeat a word on purpose. Human writing has fingerprints; leave one or two.
- Cut 10% by word count. AI drafts run fat; the fastest humanizer is deletion.

Do not overcorrect into fake quirkiness. Typos, slang stuffing, and random fragments are their own tell. The goal is a competent human, not a chaotic one.

## Step 6: Deliver

Present the copy clean. If this was a rewrite, add a brief change log (3-6 bullets: pattern found → what replaced it). If any `[NEED: ...]` placeholders remain, list them explicitly so they can't ship by accident.

Save output where the host workspace convention says (in agentic-os: `projects/human-copywriting/{YYYY-MM-DD}_{name}.md`); otherwise return it inline.

## Rules

*Direct corrections from user feedback. Read before every run. Format: `- YYYY-MM-DD: rule`*

## Self-Update

If the user flags an issue — a tell that slipped through, a ban that was too aggressive, a voice mismatch — add a dated rule to `## Rules` immediately and, if the fix is general, update `references/ai-tells.md` too. Fix the skill in the same session the feedback arrives.
