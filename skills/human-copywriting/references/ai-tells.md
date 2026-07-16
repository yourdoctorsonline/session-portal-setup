# AI Writing Tells — Full Catalog

Source: Wikipedia's "Signs of AI writing" (WP:AISIGNS), adapted for copywriting.
Use as a sweep checklist. Judge by **density** — one instance is human, repetition is the signature. Items marked **HARD BAN** should never appear in copy at all.

## 1. Vocabulary tells

Words LLMs use at far higher rates than human writers. **HARD BAN** in copy — if one appears in a draft, rewrite the sentence, don't synonym-swap.

| Cluster | Words |
|---|---|
| Fake-profound nouns | tapestry, testament, landscape (metaphorical), realm, journey (metaphorical), interplay, synergy, beacon, cornerstone, catalyst (metaphorical) |
| Inflated adjectives | pivotal, crucial, vital, robust, seamless, holistic, nuanced, multifaceted, vibrant, meticulous, intricate, enduring, comprehensive, invaluable, ever-evolving, cutting-edge, state-of-the-art, transformative, revolutionary, groundbreaking, unparalleled, renowned |
| Puffed-up verbs | delve, leverage, elevate, empower, unlock, unleash, harness, foster, cultivate, bolster, garner, underscore, streamline, revolutionize, navigate (metaphorical), embark, boast ("boasts a") |
| Hype compounds | game-changer, game-changing, deep dive, full potential, next level, best-in-class, world-class, top-notch |

Notes:
- "Delve", "tapestry", "testament", "boasts" are the strongest single-word signals — near-zero false-positive rate.
- Domain-legitimate uses are fine outside copy (a "robust" statistical method in a technical doc). In marketing copy, all uses are the tell.

## 2. Sentence-pattern tells

### Negative parallelism — **HARD BAN**
- "It's not just X, it's Y" / "This isn't about X — it's about Y"
- "Not only X but also Y"
- "It's not X. It's not Y. It's Z." / "No X, no Y, just Z"
- "X rather than Y" as a repeated crutch
Fix: state the positive claim directly. "Acme isn't just a scheduler — it's a growth engine" → "Acme fills your calendar."

### Rule of three — density check
Triplets as a reflex: "faster, smarter, and more reliable"; three-item lists everywhere; three-adjective stacks. One deliberate triplet per piece is fine. Three triplets is a signature.
Fix: use two items, or four, or one strong one. Break the symmetry.

### "-ing" trailer clauses — **HARD BAN**
Analysis glued to a sentence tail as a participle: "...— ensuring seamless collaboration", "...highlighting our commitment to quality", "...reflecting a broader shift", "...underscoring the importance of", "...contributing to", "...fostering", "...cementing its place".
Fix: if the clause says something real, give it its own sentence with a subject and evidence. If it doesn't, delete it. Usually delete it.

### Copula avoidance — density check
Dodging "is/are" with: "serves as", "stands as", "marks", "represents", "acts as", "functions as", "refers to", "offers", "features", "maintains".
Fix: "The dashboard serves as your single source of truth" → "The dashboard is where everything lives."

### Vague attribution / weasel claims — **HARD BAN**
"Experts agree", "studies show", "industry reports suggest", "observers have noted", "many users find", "widely regarded as".
Fix: name the study, cite the number, quote the customer — or cut the claim entirely.

### Significance inflation — **HARD BAN**
"Plays a vital/pivotal/crucial role", "stands as a testament to", "left an indelible mark", "rich cultural heritage", "cements its status", "a key turning point", "symbolizing", "reflects broader trends".
Fix: state what the thing actually did, with a date or number.

### Superficial both-sidesing / hedging — density check
"It's important to note that", "arguably", "one might argue", "while X, it's also true that Y", "can be seen as". Copy takes a position.
Fix: commit. If genuinely uncertain, say what you'd need to know.

### Elegant variation — density check
Unnaturally cycling synonyms to avoid repeating a word ("the platform... the solution... the tool... the system" in one paragraph). Humans repeat words. Repeat the word.

## 3. Structure & formatting tells

- **Bold-header bullet lists in prose** — **HARD BAN** in copy: "• **Speed:** Our platform is fast." This is slide formatting leaking into prose. Write sentences, or use a plain list.
- **Boldface overuse** — bolding every key term. Bold at most one phrase per screen of text, or nothing.
- **Em dash overuse** — density check: max ~1 per 150 words. (Em dashes are human; five per paragraph is not.)
- **Title Case Headings** — sentence case everywhere.
- **Emoji as section markers / in headings** — ban in copy unless the brand voice explicitly uses them.
- **Horizontal rules between sections** — ban in prose deliverables.
- **Skipped heading levels, "Overview"/"Conclusion" headings** — restructure.
- **Uniform paragraph shape** — four consecutive paragraphs of 3 sentences each reads machine-made. Vary block sizes.
- **Summary endings** — **HARD BAN**: "In summary", "In conclusion", "Ultimately", "At the end of the day", or a final paragraph that restates the piece. End on the strongest specific, the offer, or the CTA.
- **Cliché openers** — **HARD BAN**: "In today's fast-paced/digital world", "In the ever-evolving landscape of", "It's no secret that", "Have you ever wondered", "Picture this:".
- **Formulaic challenge sections** — "Despite these advantages, challenges remain... The future looks promising." Cut or replace with a named, specific limitation (naming a real limitation is one of the most human moves available).

## 4. Chatbot & artifact tells — **HARD BAN, always**

These should never survive any pass:
- Conversational residue: "Certainly!", "Great question", "I hope this helps", "Would you like me to...", "Let's explore", "We will examine"
- Knowledge-cutoff disclaimers: "As of my last update...", "I cannot access real-time information"
- Placeholders: "[Insert customer quote]", "[Company Name]", unfilled brackets of any kind — unless deliberately marked `[NEED: ...]` for the user
- Markup residue: markdown asterisks in rendered copy, `turn0search0`, `oaicite`, `contentReference`, `:::`, stray `**`
- Smart-quote inconsistency: mixed curly and straight quotes in one piece (pick one; match the destination platform)
- UTM parameters or tracking junk pasted into reference links

## 5. Tone tells

- **Relentless positivity** — every feature amazing, every outcome guaranteed. Humans qualify, admit tradeoffs, and get specific about who it's NOT for. One honest exclusion ("If you ship twice a year, you don't need this") makes everything else credible.
- **Promotional travel-brochure voice** — "nestled", "breathtaking", "a diverse array of", "something for everyone".
- **Fake enthusiasm via punctuation** — exclamation points doing the work the claim should do.
- **Addressing "audiences" instead of a person** — "businesses looking to scale" vs "you're doing payroll in a spreadsheet at 11pm".

## 6. What to do instead — the positive palette

The replacements that make copy read human (these are the point; the bans just clear space for them):

1. **Checkable specifics.** Numbers, names, dates, prices. "Trusted by thousands" → "4,200 clinics, including 40 of the 50 largest in Ontario."
2. **One reader.** Write to a single person with a single problem stated in their words.
3. **A stance.** Recommend. Exclude. Disagree with the industry default. Copy without an opinion is filler.
4. **Burst rhythm.** Short sentence. Then a longer one that takes its time getting where it's going, maybe with an aside. Then medium. Read it aloud.
5. **Concrete verbs, plain copulas.** "Is", "does", "costs", "breaks", "ships". The strongest sentences in most copy are the plainest.
6. **A real offer and a real risk-reversal.** "Ready to elevate your workflow?" → "Try it on one project. If it doesn't stick in 30 days, we'll export your data and cancel for you."
7. **Deliberate imperfection, sparingly.** Start a sentence with "And". Use a fragment. Repeat a word for effect. One or two fingerprints per piece — not a costume.

## Sweep procedure

1. Ctrl-F the hard-ban vocabulary (section 1) — any hit: rewrite the sentence.
2. Scan sentence patterns (section 2) — count instances; anything above the density notes: rewrite.
3. Check formatting (section 3) against the destination medium.
4. Grep-level scan for artifacts (section 4) — these are disqualifying.
5. Tone read (section 5): find one place to add an honest qualification or exclusion.
6. Rhythm pass: sentence-length variance, paragraph shape variety, cut 10%.
7. Final test per sentence: *"Would this sentence survive on a competitor's page unchanged?"* If yes, it's generic — replace it with something only this brand can say.
