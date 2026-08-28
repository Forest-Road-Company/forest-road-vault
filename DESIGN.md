---
name: Forest Road Vault
description: Institutional credit made legible on-chain — navy placed as material on a white editorial field, with a sans-set Operate surface for the app.
colors:
  bg: "#ffffff"
  surface: "#f4f6f9"
  card: "#f9fafc"
  raised: "#ffffff"
  app-toolbar: "#eef1f6"
  line: "#dde3ec"
  line-strong: "#c3ccdb"
  row: "#e8ecf3"
  ink: "#14213a"
  ink-muted: "#33405c"
  ink-value: "#46536e"
  ink-faint: "#5f6b85"
  accent: "#2e4e6f"
  accent-strong: "#1c2d48"
  accent-light: "#9db0d4"
  accent-deep: "#14213a"
  accent-faint: "rgba(46, 78, 111, 0.07)"
  navy: "#1c2d48"
  navy-deep: "#16233c"
  navy-alt: "#1a2744"
  navy-deepest: "#0f1a2e"
  navy-raised: "#24365a"
  navy-border: "rgba(255, 255, 255, 0.14)"
  on-navy: "#ffffff"
  on-navy-muted: "#c7d0e0"
  on-navy-faint: "#93a0b8"
  on-navy-accent: "#9db0d4"
  on-navy-line: "rgba(255, 255, 255, 0.14)"
  series-1: "#1c2d48"
  series-2: "#3e547e"
  series-3: "#7c8db0"
  series-4: "#9db0d4"
  series-5: "#c9d0dc"
  ok: "#1c6b4c"
  ok-faint: "rgba(28, 107, 76, 0.1)"
  warn: "#96621a"
  warn-faint: "rgba(183, 121, 31, 0.1)"
  warn-on-navy: "#e8b055"
  warn-on-navy-faint: "rgba(232, 176, 85, 0.14)"
  danger: "#a23b3b"
  danger-faint: "rgba(162, 59, 59, 0.09)"
  danger-on-navy: "#f0918b"
  danger-on-navy-faint: "rgba(240, 145, 139, 0.16)"
typography:
  hero:
    fontFamily: "Merriweather, Georgia, serif"
    fontSize: "clamp(2.6rem, 7vw, 4.6rem)"
    fontWeight: 600
    lineHeight: 1.04
    letterSpacing: "-0.004em"
  display:
    fontFamily: "Merriweather, Georgia, serif"
    fontSize: "clamp(1.9375rem, 4vw, 2.875rem)"
    fontWeight: 600
    lineHeight: 1.12
    letterSpacing: "-0.004em"
  headline:
    fontFamily: "Merriweather, Georgia, serif"
    fontSize: "25px"
    fontWeight: 600
    lineHeight: 1.22
    letterSpacing: "-0.004em"
  title:
    fontFamily: "Merriweather, Georgia, serif"
    fontSize: "19px"
    fontWeight: 600
    lineHeight: 1.32
  figure:
    fontFamily: "Merriweather, Georgia, serif"
    fontSize: "clamp(2rem, 4vw, 3.375rem)"
    fontWeight: 600
    lineHeight: 1
    fontFeature: "\"tnum\" on"
  figure-band:
    fontFamily: "Merriweather, Georgia, serif"
    fontSize: "32px"
    fontWeight: 600
    lineHeight: 1
    fontFeature: "\"tnum\" on"
  figure-band-lg:
    fontFamily: "Merriweather, Georgia, serif"
    fontSize: "38px"
    fontWeight: 600
    lineHeight: 1
    fontFeature: "\"tnum\" on"
  operate:
    fontFamily: "Inter Tight, system-ui, sans-serif"
    fontSize: "16px"
    fontWeight: 600
    lineHeight: 1.2
    letterSpacing: "-0.012em"
  lede:
    fontFamily: "Inter Tight, system-ui, sans-serif"
    fontSize: "17px"
    fontWeight: 400
    lineHeight: 1.625
  body:
    fontFamily: "Inter Tight, system-ui, sans-serif"
    fontSize: "15.5px"
    fontWeight: 400
    lineHeight: 1.65
  body-card:
    fontFamily: "Inter Tight, system-ui, sans-serif"
    fontSize: "15px"
    fontWeight: 400
    lineHeight: 1.6
  body-dense:
    fontFamily: "Inter Tight, system-ui, sans-serif"
    fontSize: "14.5px"
    fontWeight: 400
    lineHeight: 1.55
  body-compact:
    fontFamily: "Inter Tight, system-ui, sans-serif"
    fontSize: "14px"
    fontWeight: 400
    lineHeight: 1.5
  caption:
    fontFamily: "Inter Tight, system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.625
  caption-sm:
    fontFamily: "Inter Tight, system-ui, sans-serif"
    fontSize: "12px"
    fontWeight: 400
    lineHeight: 1.55
  label:
    fontFamily: "Inter Tight, system-ui, sans-serif"
    fontSize: "11px"
    fontWeight: 600
    lineHeight: 1.4
    letterSpacing: "0.14em"
  mono:
    fontFamily: "Azeret Mono, ui-monospace, monospace"
    fontSize: "0.9em"
    fontWeight: 400
    letterSpacing: "-0.02em"
rounded:
  card: "10px"
  pill: "999px"
  inline: "4px"
  focus: "3px"
spacing:
  gutter: "20px"
  tight: "12px"
  stack: "24px"
  block: "56px"
  band: "80px"
  band-lg: "112px"
components:
  button-primary:
    backgroundColor: "{colors.navy}"
    textColor: "{colors.on-navy}"
    rounded: "{rounded.pill}"
    padding: "12px 28px"
    typography: "{typography.label}"
  button-primary-hover:
    backgroundColor: "{colors.navy-raised}"
    textColor: "{colors.on-navy}"
  button-on-navy:
    backgroundColor: "{colors.raised}"
    textColor: "{colors.navy}"
    rounded: "{rounded.pill}"
    padding: "12px 28px"
  button-on-navy-hover:
    backgroundColor: "{colors.on-navy-accent}"
    textColor: "{colors.navy}"
  button-ghost-on-navy:
    backgroundColor: "transparent"
    textColor: "{colors.on-navy}"
    rounded: "{rounded.pill}"
    padding: "12px 28px"
  button-ghost-on-navy-hover:
    textColor: "{colors.on-navy-accent}"
  button-micro:
    backgroundColor: "transparent"
    textColor: "{colors.ink-muted}"
    rounded: "{rounded.pill}"
    padding: "6px 14px"
  op-action:
    backgroundColor: "{colors.navy}"
    textColor: "{colors.on-navy}"
    rounded: "{rounded.pill}"
    padding: "10px 20px"
    width: "100%"
  op-action-hover:
    backgroundColor: "{colors.navy-raised}"
  op-action-active:
    backgroundColor: "{colors.accent-deep}"
  op-action-disabled:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink-faint}"
  op-field:
    backgroundColor: "{colors.raised}"
    textColor: "{colors.ink}"
    rounded: "{rounded.card}"
    padding: "12px 16px"
    typography: "{typography.mono}"
  op-toolbar:
    backgroundColor: "{colors.app-toolbar}"
    textColor: "{colors.ink-muted}"
    rounded: "{rounded.card}"
    padding: "16px 20px"
  panel:
    backgroundColor: "{colors.raised}"
    textColor: "{colors.ink-muted}"
    rounded: "{rounded.card}"
    padding: "28px"
  panel-navy:
    backgroundColor: "{colors.navy-deepest}"
    textColor: "{colors.on-navy-muted}"
    rounded: "{rounded.card}"
    padding: "32px 36px"
  highlight-box:
    backgroundColor: "{colors.accent-faint}"
    textColor: "{colors.ink-muted}"
    rounded: "{rounded.card}"
    padding: "24px 28px"
  kpi-band:
    backgroundColor: "{colors.navy-deepest}"
    textColor: "{colors.on-navy}"
    rounded: "{rounded.card}"
    padding: "32px 8px"
  table-head:
    backgroundColor: "{colors.navy}"
    textColor: "{colors.on-navy}"
    padding: "12px 20px"
  pill-severity-high:
    backgroundColor: "{colors.navy}"
    textColor: "{colors.on-navy}"
    rounded: "{rounded.pill}"
    padding: "3px 8px"
  pill-severity-low:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.ink-value}"
    rounded: "{rounded.pill}"
    padding: "3px 8px"
  nav-link:
    backgroundColor: "transparent"
    textColor: "{colors.ink-muted}"
    padding: "4px 0"
  nav-link-active:
    textColor: "{colors.ink}"
---

# Design System: Forest Road Vault

## Overview

**Creative North Star: "The Underwriting Memo, Set in Navy"**

This is what a speciality-finance credit committee's memo looks like when it becomes a
website: white paper, one serif voice for every claim, hairlines instead of boxes, and
numbers that line up down a column because somebody is going to compare them. The
category standard executed straight — the arrangement an allocator already expects from
an on-chain credit protocol, at full craft, with no ironic distance and no smuggled
novelty. Density is editorial rather than dashboard: generous bands (80–112px vertical),
a 62-character measure on every lede, and long unbroken passages of body copy that
assume a reader who reads.

The organizing move is material, not chromatic. The field is white (`#ffffff`) with one
alternating near-white band (`#f4f6f9`); navy is a solid object *placed on* that field —
the nav mark, the primary action, the figure band, table headers, the hero, the cascade
diagram, the closing anchor, the footer. Nothing fades between the two. The hero ends on
a hard horizontal edge against white, not a gradient dissolve, because a navy block on a
white page is the parent brand's own arrangement and a wash would soften it into generic
on-chain marketing.

The system runs in **two modes**. Everything published is *editorial*: serif headings,
banded rhythm, one authored motion moment. The wallet-connected `/app` surface is
*Operate*: one sans family, a fixed scale, full state coverage on every control, and
motion that only ever reports state. Operate is a class-scoped subtree (`.operate`), not a
separate stylesheet — the same tokens, deliberately different rules — and the boundary is
documented under Components.

The refusals are as load-bearing as the tokens. No eyebrow above a heading, anywhere. No
keyline above a card title. No scroll-reveal system — one authored entrance, on the hero,
and after that the page is simply present. No hue-coded data: severity, allocation and
rank all run down a five-step navy tint ladder, and the only chromatic exceptions
(`ok`, `warn`, `danger`) are functional status that always ships with a text label. The
parent brand's link blue `#1f8aff` is deliberately unadopted; a bright blue accent on
navy is the generic look this system is trying not to be.

**Key Characteristics:**
- White field, navy material — navy is an element, never a page background
- Merriweather 600 for every editorial heading, its italic reserved for a turn in the sentence
- Monochrome navy data; hue only for functional status, and never alone
- Hairlines and tonal bands instead of shadows and borders-as-decoration
- Two modes: editorial (serif, banded, one authored moment) and Operate (sans, fixed, state-only motion)
- Mono reserved strictly for on-chain strings — addresses, hashes, calldata
- Tabular figures wherever a reader compares down a column

## Colors

A monochrome navy palette on a white editorial ground: one hue family carries brand,
accent, data ranking and elevation, and the three functional status colours are
desaturated until they sit with it.

### Primary
- **Field Navy** (`#1c2d48`, token `navy`): the material itself. Full-width bands, the
  primary pill action, table header rows, the highest severity pill, the closing anchor,
  and the Operate action at rest.
- **Deepest Navy** (`#0f1a2e`, token `navy-deepest`): reserved for the surfaces that must
  read as the strongest thing on the page — the hero grade's anchor, the figure band, the
  loss-cascade section, the footer, the app's yield panel. One step below `navy`, and the
  step is the point.
- **Lifted Navy** (`#24365a`, token `navy-raised`): hover state on a navy fill only.
- **Pressed Navy** (`#14213a`, token `accent-deep`): fills only — the `:active` state of
  the Operate action. Never used for text.
- **Memo Navy** (`#2e4e6f`, token `accent`): the accent on the white field — italic
  emphasis in headings, inline links, active nav underline, list markers, caret, focus
  ring and focus glow. Never used as a fill behind text.
- **Pale Navy** (`#9db0d4`, tokens `accent-light` / `on-navy-accent`): the accent's
  on-navy counterpart. Used *only* where the ground underneath is navy — figure-band
  labels, on-navy links, footer column heads.

### Secondary
- **Series Ladder** (`#1c2d48` → `#3e547e` → `#7c8db0` → `#9db0d4` → `#c9d0dc`, tokens
  `series-1..5`): the only encoding for ranked or categorical data. Audit severities,
  allocation splits, ranked series. Solid navy demands attention; tints recede.

### Tertiary — functional status
Three hues, each with a faint wash for fills and a lifted on-navy value where one exists.
None of them is decoration and none of them ever carries meaning alone.
- **Confirmed Green** (`#1c6b4c`, token `ok`, wash `ok-faint` at 10%): a settled
  transaction. It exists because navy cannot distinguish pending from confirmed, and on a
  transaction surface that distinction is the whole point — the same exemption `warn` and
  `danger` hold, for the same reason: it reports state, not taste.
- **Ledger Amber** (`#96621a`, token `warn`, wash at 10%; **`#e8b055`** on navy, wash at
  14%): testnet banner, wrong network, an open finding, a queued exit.
- **Reverted Red** (`#a23b3b`, token `danger`, wash at 9%; **`#f0918b`** on navy, wash at
  16%): a reverted transaction, a failed write, an invalid field, a hard blocker.

### Neutral
- **Paper White** (`#ffffff`, tokens `bg` / `raised`): the page ground and the elevated
  panel are the same white; separation comes from hairlines, not from tone.
- **Band Grey** (`#f4f6f9`, token `surface`): the alternating section band, the resting
  fill of low-severity pills and disabled fields, and the recessed disabled action.
- **Chrome Grey** (`#eef1f6`, token `app-toolbar`): a second neutral layer, cooler than
  the white content panels, used only for Operate chrome — the connect row and toolbars —
  so chrome reads as chrome rather than as content.
- **Panel Grey** (`#f9fafc`, token `card`): the faintest fill, for nested cells.
- **Hairline** (`#dde3ec`, token `line`) / **Structural Hairline** (`#c3ccdb`, token
  `line-strong`) / **Row Divider** (`#e8ecf3`, token `row`): the three weights of rule
  this system draws with. `line` divides within a component, `line-strong` opens a page,
  encloses a table, or bounds an Operate field, `row` separates repeated rows.
- **Committee Ink** (`#14213a`, token `ink`): headings and any value a reader stops on.
- **Reading Ink** (`#33405c`, token `ink-muted`): body copy — 10:1 on white.
- **Value Ink** (`#46536e`, token `ink-value`): table values and secondary body.
- **Footnote Ink** (`#5f6b85`, token `ink-faint`): captions, sources, labels, and the
  label of a disabled control — 4.9:1 on white, the floor of this palette. Nothing
  lighter carries text.
- **On-Navy set** (`on-navy` `#ffffff`, `on-navy-muted` `#c7d0e0`, `on-navy-faint`
  `#93a0b8`, `on-navy-line` at 14% white): the inverted ink stack. Set once on
  `.navy-band` / `.navy-band-deep` so routes never re-specify on-navy colours per element.

### Named Rules

**The Material Rule.** Navy is an element placed on the white field, never the field
itself. If a navy area has no edge — no hard boundary against white, no hairline, no
radius — it has become a background and is wrong.

**The Monochrome Data Rule.** Ranked and categorical data is encoded in the navy tint
ladder. No green, no gold, no red-amber-green severity scale. Weight carries ranking.

**The Labelled Status Rule.** `ok`, `warn` and `danger` are exempt from the monochrome
rule because they are not decoration — but hue is never the only signal. A status colour
always appears with a text label beside it, and an invalid field always carries its
reason in words rather than leaving a red border to imply one.

**The Status-On-Navy Rule.** The editorial status values are tuned for the white ground
and fall through 4.5:1 on navy (`warn` measured 3.36:1 on the app's yield panel), so the
*variables themselves* are re-declared inside every navy subtree — `.navy-band`,
`.navy-band-deep`, `.hero-frame`, `.kpi-band`, and the `bg-navy*` utilities. Because
Tailwind resolves `text-warn`, `border-warn` and `bg-warn-faint` to `var(--color-warn)`
at use time, lifting the variable lifts text, border and wash together, and a status
colour cannot silently fail by being placed on the dark material. Never hard-code a
lifted status hex at the call site; extend the re-declaration block instead.

**The Two-Band Seam Rule.** When two navy bands meet (the closing anchor above the
footer), the lower one drops one tonal step (`navy` → `navy-deepest`) *and* carries a
visible `1px` rule at 20% white. Without both, the two bands read as a single dark mass.

**The Semantic Naming Rule.** Tokens are named for role, not for value: `ink` is text,
`raised` is an elevated surface, `bg` is the ground, `navy`/`on-navy` are the element and
the ink that sits on it. This is why the field was retuned from a dark first pass to
white/navy inside `globals.css` alone, and it is the same mechanism the Status-On-Navy
Rule uses — role naming applied to state. Never introduce a literal colour name.

## Typography

**Display Font:** Merriweather (with Georgia, serif) — 600 weight, normal and italic
**Body / UI Font:** Inter Tight (with system-ui, sans-serif)
**Mono Font:** Azeret Mono (with ui-monospace, monospace)

**Character:** Both faces are inherited from Forest Road Asset Management and are binding.
Merriweather at 600 with tight leading and near-zero tracking (`-0.004em`) is an
institutional serif that reads as a printed memo rather than a fintech headline; Inter
Tight underneath is neutral, slightly condensed, and stays out of the argument's way. The
pairing's whole personality sits in one gesture: Merriweather's italic — spent sparingly.

### Hierarchy
- **Hero** (600, `clamp(2.6rem, 7vw, 4.6rem)`, 1.04): the landing h1 only, bottom-anchored
  over the graded photograph, measure capped at 19 characters.
- **Display** (600, 31px → 46px, 1.12): every section h2 and interior page h1. Capped at
  a 7-of-12-column/`26ch` measure so it breaks into two or three lines, never one wide bar.
- **Figure** (600, 32–38px in the band, 42–54px as a bare statistic, 1.0, tabular): the
  number a reader should leave with. Always paired with a label and, where one is owed, a
  source note.
- **Headline** (600, 25px, 1.22): rendered-doc h2 — set above a `1px` top rule with
  2.6rem clearance, which is how long-form documentation gets its structure.
- **Title** (600, 19px, snug): card and row headings. 24–25px is the same face used for a
  panel's one-sentence claim.
- **Operate** (Inter Tight 600, `-0.012em`, 1.2): inside `.operate`, every heading, label,
  figure and control label. Fixed sizes, no fluid clamps.
- **Lede** (400, 17px, 1.625, `62ch` max — `54ch` in the interior page opener's right
  column): the paragraph beside or under a heading.
- **Body** (400, 15.5px, 1.65): default. 15px inside cards and rows; `72ch` maximum in
  rendered documentation at 1.72 leading.
- **Caption** (400, 13px / 12.5px): notes, sources, disclosure lines, figure provenance.
- **Label** (600, 11px, uppercase, `0.14em`, `.running-head`): wayfinding, breadcrumb
  trails, column heads, `<dt>`, figure legends, opt-in ordinals. Nothing else.
- **Mono** (400, `0.9em` of context, `-0.02em`): on-chain strings only. Also the amount
  input, where digit alignment is a correctness requirement.

### Named Rules

**The Turn-In-The-Sentence Rule.** Emphasis inside a heading is Merriweather italic in
`accent` (`.display-accent`), inverting to `on-navy-accent` on navy — and it marks a turn
in the sentence, not a section heading. At most one per page-scroll, never a section's
default voice. It survives on the landing where the sentence actually turns (the brand
line's "working credit", the cascade's "Depositors are last", the audit claim's
"accepted") and on other routes at most once. Never a weight change, never a tint
gradient, never an underline, never a highlight.

**The Label-As-Wayfinding Rule.** An uppercase label may tell a reader where they are,
head a column, define a term, or legend a figure. It may never sit above a heading as a
kicker. This holds on every route: where a category, round or date was doing wayfinding
work, it moved into a real breadcrumb `<ol>` with `aria-current="page"` on a `.rule-head`
hairline. If the label were deleted and the heading still worked, the label was
decoration.

**The One Family Per Mode Rule.** The serif is the brand's voice, not a UI face. Inside
`.operate` both `.display` and the `font-display` utility resolve to Inter Tight, so no
label, button, or figure a user is comparing in a task is ever set in the serif.

**The Mono Is Evidence Rule.** Mono means "this string is verifiable on-chain": addresses,
hashes, calldata, transaction amounts. It is never a technical costume for body copy.

**The Tabular Column Rule.** Anything compared down a column gets tabular figures.
Applied globally to `table`, `.tnum`, and `[data-figure]`.

## Layout

One measure runs the whole site: a `max-w-6xl` (1152px) centred container with a 20px
gutter, widened to `max-w-7xl` (1280px) only when a grid needs the extra column
(the five-vertical deck). Rendered documentation narrows to `max-w-3xl`.

Vertical rhythm is banded, not gridded. Full-bleed `Section` elements alternate tone
(`light` → `surface` → `light` → `navy-deep` → `surface` → `navy`) with `80px` of padding
rising to `112px` above the medium breakpoint. Inside a band: the section head, then
`56–64px` of clearance, then the content.

The interior page opener is a **document header on a twelve-column grid**: breadcrumb,
hairline, `40px`, then the h1 in seven columns with the lede beside it in five
(`max-w-[54ch]`, optically nudged down `8px`), collapsing to stacked below `lg`. Stacked
in a single column it left the right third of the measure empty on every interior page,
and the larger display size made that more conspicuous rather than less.

Grids are compositional rather than uniform. Card decks take an explicit column count
(2/3/4/5) and collapse to a single column below `sm`. The landing's book section runs two
wide cards over three narrow ones in a six-column grid so five items fill it exactly with
nothing stranded. Two-column argument layouts use deliberate ratios
(`1.25fr 1fr`, `2/5 + 3/5`, `7/12 + 5/12`) rather than halves. Fixed inch-based columns
(`3.2in`, `2.6in`, `2.5in`) hold the left rail of numbered rows and register lists.

Responsive behaviour: the nav collapses to a full-width overlay panel below `lg` (which
locks body scroll while open); every multi-column arrangement stacks; editorial type steps
down at the `md` boundary only, and Operate type does not step at all. No horizontal
overflow at 375px — wide data tables scroll inside their own container rather than pushing
the page.

**The Varied Opening Rule.** Consecutive sections must not open the same way. Stacked
headline-and-lede, two-column argument, and a cold statistic row are all in the
vocabulary; using one three times in a row turns the page into a slide deck, which is the
thing this system was built against.

## Elevation & Depth

Flat, with tonal layering doing all the work. There is no shadow scale. Depth is
communicated by the field a surface sits on (white ground → grey band → chrome grey →
navy element), by three weights of hairline, and by the 10px radius that makes a panel
legible as an object. The elevated panel (`raised`) is the *same white* as the page
ground — its edge is a `1px` `line` border, nothing more.

### Shadow Vocabulary
- **Panel lift on hover** (`box-shadow: 0 14px 34px -20px rgba(20, 33, 58, 0.28)`): on
  `.panel-hover` over `360ms`, alongside a border step from `line` to `line-strong`. A
  shadow is a response to the pointer, not a resting state.
- **Focus glow** (`box-shadow: 0 0 0 3px rgba(46, 78, 111, 0.14)`): the Operate field's
  `:focus-within` ring, with the border moving to `accent`. Its danger counterpart is the
  same 3px ring at `rgba(162, 59, 59, 0.12)` on `[data-invalid="true"]`.
- **Recessed control** (`box-shadow: inset 0 0 0 1px var(--color-line-strong)`): the
  disabled Operate action. An inset ring, not a drop shadow — the control sinks into the
  field rather than lifting off it.

### Named Rules

**The Hairline Rule.** Separation is a `1px` rule, not a shadow and not a gap. `line`
divides inside a component, `line-strong` opens a page or encloses a table, `row`
separates repeated rows, `on-navy-line` does all three on navy.

**The Flat-At-Rest Rule.** No surface carries a shadow at rest. If depth is needed,
change the field the surface sits on. Every shadow in the system is a state — hover,
focus, invalid, or disabled.

## Shapes

Two radii and nothing between them. Panels, callouts, tables, inputs, toolbars and the
figure band all take `10px` (`radius-card`) — enough to read as a card, too little to read
as an app tile. Every button, tag, and status pill is a full `999px` pill
(`radius-pill`); this is the system's one soft gesture and it is consistently applied,
from the 28px-tall severity pill to the 48px primary action. Inline code and the loading
skeleton take `4px`, the focus ring `3px`.

Everything else is orthogonal. Bands are full-bleed rectangles with hard horizontal
edges; the hero terminates on one rather than fading. Tables clip their children with
`overflow: hidden` so the header row's navy fill takes the container's corners. The only
non-geometric texture is a 5%-opacity fractal-noise overlay (`.grain`) on the hero, and
the cascade diagram's stroked SVG connectors.

## Components

### Operate Mode — the `/app` surface

**The app surface plays by different rules, and the boundary is a class.**
`AppSurface`'s root carries `className="operate mt-10"`, and every difference is declared
once as an `.operate` scope in `globals.css` rather than argued per component. Four rules
define the mode:

1. **One family.** `.operate .display` and `.operate .font-display` both resolve to Inter
   Tight 600 at `-0.012em`/1.2. Both selectors are required — the write cards reach for
   the `font-display` utility directly — and the rule deliberately sits *outside*
   `@layer` so it outranks Tailwind's utilities layer on specificity.
2. **Fixed scale.** No fluid clamps. A user sits at one DPI while doing a task.
3. **Full state coverage.** Every control declares hover, focus, active and disabled.
4. **Motion reports state.** `150ms`, colour and ring only, and never a transform for
   flavour. The hero's `.stage`/`.rule-draw` entrance never applies here; there is no
   orchestrated page-load on the app surface at all.

**The Mode-Not-Drift Rule.** `TransparencyDashboard` and `PointsDashboard` render on both
public routes and inside `/app`. On `/transparency` they keep Merriweather figures,
because there they are a document; inside `.operate` the same components render sans,
because there they are an instrument. That is the mode changing, not an inconsistency —
and it is precisely why the scope is a class on a subtree rather than a route-level
stylesheet: a shared component has to be able to read its context. Verified in the
render: public `/transparency` has no `.operate` ancestor and keeps its serif; `/app` has
zero serif leaks.

- **`.op-toolbar`** — the connect row and other chrome. `app-toolbar` (`#eef1f6`) fill, a
  `line` hairline, `10px` radius. The cooler grey is what separates chrome from the white
  content panels above and below it.
- **`.op-action`** — the one primary action shape on the surface. `navy` at rest, hover
  `navy-raised`, active `accent-deep`, `999px`, full width, 600 weight, `150ms` colour
  transition. **Disabled is deliberately recessed rather than dimmed**: `surface` fill,
  `inset 0 0 0 1px line-strong`, `ink-faint` label, `not-allowed`. The previous
  white-on-grey disabled measured 1.62:1 — a user needs to *read what the control would
  do* before working out why they cannot press it. The earlier `1.01` hover scale was
  removed as decoration on a control whose only job is to report pressability. Sets
  `aria-busy` while a write is in flight and carries a phase-accurate label —
  Simulating…, Confirm in wallet…, Pending… — never a generic spinner.
- **`.op-field`** — amount and text controls. `raised` fill, `line-strong` border, `10px`.
  `:focus-within` moves the border to `accent` with a 3px accent glow;
  `[data-invalid="true"]` moves it to `danger` with a 3px danger glow;
  `[data-disabled="true"]` drops to a `surface` fill and a `line` border. `AmountInput`
  takes an `invalid` prop and sets `aria-invalid`, but the message itself stays with the
  caller — a red border must never be the only statement of what is wrong.
- **`.op-skeleton`** — the loading placeholder. A `4px`-radius inline block carrying a
  three-stop `row → surface → row` gradient at 220% width, shimmering over `1.4s` linear
  infinite, flattened to a static `row` fill under `prefers-reduced-motion`. It shows the
  *shape of the value being fetched* rather than a spinner floating in content; wired to
  the in-flight balance read in `MintCard`.

**Operate state and copy conventions**, consistent across all three write cards:
an absent value and a loading value are different states, so a balance with no wallet says
`wallet not connected` in words while an in-flight read shows the skeleton; `StatusLine`
carries `role="status"` and `aria-live="polite"` because write phases resolve
asynchronously after the click that caused them, and "Confirmed" is set in `ok`;
`AppSurface`'s empty state teaches (what is already readable, what a wallet unlocks, what
the KYC gate does and does not cover) instead of saying "connect a wallet"; and no panel
renders a lone em dash at display scale — at 52–64px a dash reads as a redaction bar, so
an empty slot explains itself in words.

### Buttons (editorial)
- **Shape:** full pill (`999px`), no border on filled variants.
- **Primary (on white):** navy fill, white text, `12px 28px`, 14px/600. Hover steps to
  `navy-raised`. Used once per surface — the nav's "Enter App", "Open the audit register".
- **Primary (on navy):** inverted — white fill, navy text; hover fills with
  `on-navy-accent`. The hero's "Enter App" and the closing anchor's action.
- **Ghost (on navy):** `on-navy-line` border, `on-navy` text; hover moves border *and*
  text to `on-navy-accent`. The hero's secondary "How it works".
- **Micro:** `line-strong` hairline pill, 10–10.5px uppercase `0.12em` label, hover moves
  border to `accent/60` and text to `accent`. "max", the testnet faucet.
- **Text link:** `accent`, 13px/600, often with `.u-link` — a `1px` underline that wipes in
  from the right over `380ms` and out to the left. Arrow glyphs are `aria-hidden` and
  translate `2px` on group hover.

### Chips
- **Style:** `999px` pill, `1px` border, 10px uppercase `0.12em` 600 label, `3px 8px`.
- **State:** severity and disposition are the same four-step navy ramp — solid `navy` with
  white text for High/Open, `accent-strong` at 12% with `accent-strong` text for
  Medium/Accepted/Deferred, `surface` with `ink-value` for Low, `surface` with `ink-faint`
  for Informational. The word is always present; the tint only reinforces it.
- A `line-strong`-bordered variant with `accent` text is used as a collateral-model tag on
  vertical cards.

### Cards / Containers
- **Corner Style:** `10px`.
- **Background:** `raised` white on the light field, `navy-deepest` with a `navy-border`
  hairline when the card is the navy member of a pair.
- **Shadow Strategy:** none at rest; `.panel-hover` adds the single hover shadow to
  linked cards.
- **Border:** `1px` `line`, stepping to `line-strong` on hover.
- **Internal Padding:** `28px`, rising to `32–36px` for the two-token panels.
- **Behaviour:** a linked card moves its `title` to `accent` on group hover (to
  `on-navy-accent` on navy). Matched-height cards must fill: pin a closing hairline plus a
  claim and a reconciliation link to the foot rather than leaving a hollow panel, but
  never pin short metadata — that opens a hole mid-row.

### Navigation
- **Style:** sticky 64px header, `bg/88` with `backdrop-blur-xl`, `line` bottom border.
  Brand mark (navy, 28px tall) + "Forest Road" 15.5px/600 `ink` + "Vault" 10.5px uppercase
  `0.16em` `accent`.
- **Links:** 13.5px, `ink-muted` → `ink` on hover; the active route is `ink` at 500 with a
  `1.5px` `accent` underline `3px` below the baseline, and carries `aria-current="page"`.
- **Mobile:** a 36px hairline icon button (inline SVG, 1.5px stroke, hamburger ↔ close)
  opens a full-width panel of `row`-divided 15px rows; the active row is marked by a 6px
  `accent` dot. Opening locks body scroll; navigating closes it.
- **Breadcrumb:** every interior page and every document detail page opens with a real
  two-level trail set in `.running-head` — "Forest Road Vault / Section", "Docs /
  Category", "Audit register / Round · Date" — as an `<ol>` with the leaf in `accent` and
  `aria-current="page"`, on a `line-strong` hairline, with the h1 `40px` below. This
  replaced the kicker on every route; it is navigation, which is why it is allowed to be a
  label above a heading.

### Figure Band
The signature editorial component. A `navy-deepest` panel at `10px` radius, `1px` `line`
border, containing flex cells that each hold a `display` figure at 32–38px with `1.0`
leading, a `.running-head` label in `on-navy-accent`, and a 12.5px `on-navy-faint` note
naming the figure's source. Cells are divided by an inset `1px` rule (6px shy of top and
bottom) and each has a `150px` minimum, so the band re-flows to two rows on mobile instead
of compressing. Every value is a live read or a published figure, and every cell says
which.

### Card Deck
A gap-`32/44` grid at an explicit 2/3/4/5 columns. Ordinals are **opt-in** (`ordered`):
a zero-padded `.running-head` number in `accent` above the title, used only where the
sequence is information the reader needs — process steps, cascade layers, the risk
register. Never applied to an unordered set.

### Numbered Rows
Subhead and supporting copy in a fixed `3.2in` left rail, hairline-separated rows on the
right, each row a zero-padded ordinal + a `display` label in a `2.5in` column + body.
These are always sequential, so the numbers are unconditional here. The left rail is tall
next to a five-row list — the supporting copy is required, not optional, or the column
reads as unfinished.

### Data Table
`line-strong` border, `10px` radius, `overflow: hidden`; caption row filled `navy` with
white 600 text; body rows divided by `row`; label column `display` at 30% width, value
column `ink-value`. Tabular figures throughout. Wide tables scroll inside their own
container.

### Callout
A tinted panel, never a thick coloured edge: `accent-faint` fill with a `navy-border`
hairline at `10px` radius on the light field; `white/[0.06]` with `on-navy-line` on navy.
Title in `display` at 16px.

### Motion

**The One Authored Moment Rule (editorial).** The published site animates on entrance
exactly once, on the hero: `.stage` children rise 18px out of a 6px blur on a shared
`cubic-bezier(0.16, 1, 0.3, 1)` over `900ms` at 120/260/380/480/560ms delays, and the
figure strip's rule draws across (`scaleX`, `820ms`, `640ms` delay) after the last line
lands. The photograph settles from `1.11` to `1.06` scale over `2.4s`. Nothing else
animates on entrance; there is no scroll-reveal system and content is visible by default.
State transitions (`360ms`/`380ms` on the two soft eases) are the only other motion.

**The State-Only Motion Rule (Operate).** Inside `.operate` motion is `150ms`, colour and
ring only, and there is no orchestrated page-load whatsoever. The single exception is the
loading skeleton's shimmer, which is a status indicator rather than an entrance.

Under `prefers-reduced-motion: reduce` the hero entrance is removed outright, the skeleton
flattens to a static fill, and all animation and transition durations collapse to
`0.01ms`. The infinite cascade-flow stroke stops with it.

## Do's and Don'ts

### Do:
- **Do** place navy as a bounded element on the white field — band, panel, pill, table
  head, hero block — and give it a hard edge against the white.
- **Do** reach for a hairline before a shadow, a border, or a gap. Three weights exist:
  `line` (`#dde3ec`) within, `line-strong` (`#c3ccdb`) around, `row` (`#e8ecf3`) between.
- **Do** set every editorial heading in Merriweather 600, and spend its italic only where
  the sentence turns — at most once per page-scroll.
- **Do** put the app surface's headings, labels, figures and controls in Inter Tight by
  keeping them inside the `.operate` scope.
- **Do** encode severity, rank and allocation in the five-step navy series ladder.
- **Do** pair every functional status colour with a text label, always, and state an
  invalid field's reason in words next to it.
- **Do** re-declare a status *variable* on new dark material rather than hard-coding a
  lifted hex at the call site.
- **Do** cap ledes and body at `62ch` (`54ch` in the page opener's right column, `72ch` in
  rendered documentation) and let display headings break over two or three lines.
- **Do** open every interior and document page with a real breadcrumb `<ol>` carrying
  `aria-current="page"` on a `.rule-head` hairline.
- **Do** give every figure a label and, where one is owed, a note naming its source.
- **Do** apply tabular figures via `[data-figure]` or `.tnum` to anything compared down a
  column.
- **Do** vary how consecutive sections open — stacked head, two-column argument, cold
  statistic row.
- **Do** drop one tonal step and add a visible rule wherever two navy bands meet.
- **Do** declare hover, focus, active *and* disabled on every Operate control, and keep
  the disabled label readable (`ink-faint` on `surface`, recessed by an inset ring).
- **Do** distinguish absent from loading: words for "wallet not connected", a skeleton for
  an in-flight read.
- **Do** announce asynchronous outcomes with `role="status"` / `aria-live="polite"` and
  `aria-busy` on the control that caused them.
- **Do** keep the `:focus-visible` ring intact: 2px `accent`, 3px offset, 3px radius.
- **Do** state a page's absent data plainly and link where it can be verified, rather than
  rendering a plausible placeholder.

### Don't:
- **Don't** set a label above a heading. No eyebrows, no kickers. Labels are wayfinding,
  breadcrumb leaves, column heads, `<dt>`, or figure legends.
- **Don't** draw a keyline or accent bar above a card title. `.col-bar` and `.keyline`
  were both deleted from this system; a rule above every heading is the eyebrow wearing a
  different name.
- **Don't** use the italic as a section heading's default voice. Three per landing page is
  the ceiling, and each one has to be a turn in the sentence.
- **Don't** let the serif into the app surface — no `font-display` utility inside
  `.operate` expecting Merriweather, and no display face on a label, button, or figure a
  user is comparing in a task.
- **Don't** add a scroll-reveal or per-section entrance animation, and don't give the app
  surface a page-load animation at all. The hero's entrance is the whole entrance budget.
- **Don't** animate a transform to signal pressability. Operate motion is colour and ring,
  `150ms`.
- **Don't** dim a disabled control into illegibility. Recess it and keep its label
  readable.
- **Don't** number an unordered set. Ordinals are opt-in and mean "sequence matters".
- **Don't** use a gradient wash as a surface. The one gradient in the system grades navy
  across the hero photograph so type has solid ground; it is not a decorative device.
- **Don't** use mono for anything that is not an on-chain string, a hash, or an amount
  whose digits must align.
- **Don't** introduce a hue outside the navy family and the three status values.
  Specifically not `#1f8aff` — the parent brand's link blue is deliberately unadopted,
  because a bright blue accent on navy is the generic on-chain look.
- **Don't** carry text in anything lighter than `ink-faint` (`#5f6b85`) on white or
  `on-navy-faint` (`#93a0b8`) on navy; those are the contrast floor.
- **Don't** let hue be the only carrier of meaning anywhere.
- **Don't** render a lone em dash as a display-scale value. At 52–64px it reads as a
  redaction bar; write the absence out.
- **Don't** introduce a literal colour token name. Extend the semantic set
  (`ink`/`raised`/`bg`/`navy`/`on-navy`/`app-toolbar`) so the field and its states can be
  retuned in one file.
- **Don't** add a resting shadow, a second radius between 10px and the pill, or a third
  typeface.
- **Don't** ship an assurance row of identical tiles, or one section per idea in a uniform
  card grid — the deck-ported-to-web pattern this system exists to refuse.

## Open items

Recorded as open. The system is not closed on these.

1. **Live parameters on `/verticals/[slug]`.** The route deliberately does not restate
   CollateralRegistry class parameters — hardcoding them is forbidden and no reads are
   wired there. The page states the absence and links to `/transparency`. The designed
   pattern for surfacing those reads is unresolved.
2. **`ok` has no on-navy value.** `warn` and `danger` are re-declared inside navy subtrees
   per the Status-On-Navy Rule; `ok` (`#1c6b4c`) is not. It currently renders only in
   `StatusLine`, whose callers all sit on white panels, so nothing fails today — but
   `#1c6b4c` measures roughly 2.7:1 on `navy-deepest`, and `YieldPositionPanel` is a navy
   subtree. The first "Confirmed" placed on navy will fail. Add `ok` to the re-declaration
   block before using it on dark material; do not read its current absence as a decision.
3. **Two test suites cannot start.** `npm run test:logic` and `npm run test:sync` fail to
   launch because `node` cannot load their `.mts` files without a TypeScript loader. Both
   files are untouched by the design work and the failure is pre-existing, but the suite
   must not be read as green: `tsc --noEmit`, `npm run build` (42 routes), the render suite
   (25/25), the contrast audits on `/app` and `/transparency`, and the 375px overflow
   check all pass.

**Closed since the previous revision, verified in source:** the live kicker and orphan
`.keyline` on `/docs/[slug]` and `/docs/audit/[slug]` (both now render the standard
breadcrumb; the word "keyline" survives only in the direction contract's list of
refusals); the empty right third of the interior page opener (now a twelve-column document
header); and the unbroken italic in section headings (now governed by the
Turn-In-The-Sentence Rule — three on the landing, at most one elsewhere).
