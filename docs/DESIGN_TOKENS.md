# Taskfold design tokens

The same spec lives in both app repos at `docs/DESIGN_TOKENS.md`. Each app implements it in `Taskfold/Views/DesignTokens.swift`, inside an `enum DS` namespace. The names are identical on both platforms. Values may differ only where this file says so.

## Rules
- Views use tokens, not numeric literals, for padding, spacing, corner radius, text styles and semantic colours.
  - A literal is fine for one-off geometry, such as chart sizes or calendar hour heights.
  - Leave a short comment explaining why.
- Text uses Dynamic Type text styles through `DS.Font` roles.
  - `.font(.system(size:))` is allowed only for SF Symbols that need an exact optical size.
  - The one custom face, Fraunces, is reached only through the title roles below, never with an ad-hoc `Font.custom`.
- Colours use semantic roles.
  - Raw `Color(red:)`, hex and system colours live only in `DesignTokens.swift` and the existing palette tables: accents, priority and project colours.
- Every animation goes through the existing `Motion` vocabulary and respects Reduce Motion.

## Spacing: `DS.Space` (4-pt grid)
| Token | pt | Use |
|---|---|---|
| `xxs` | 2 | icon and text hairline gaps |
| `xs` | 4 | between metadata items |
| `s` | 8 | default stack spacing, chip padding |
| `m` | 12 | row horizontal inset (Mac), group spacing |
| `l` | 16 | row horizontal inset (iOS), card padding |
| `xl` | 20 | section spacing |
| `xxl` | 24 | screen edge (iOS large screens), header spacing |
| `xxxl` | 32 | empty-state and onboarding spacing |

Odd legacy values snap to the nearest token when a view is touched: 5→4, 6→8 (or 4 if the gap is tight), 10→8 or 12, 14→12 or 16, 18→16 or 20.

## Corner radius: `DS.Radius`
| Token | pt | Use |
|---|---|---|
| `xs` | 4 | tiny badges |
| `s` | 6 | chips, tags, inline tokens |
| `m` | 10 | text fields, buttons, menus |
| `l` | 14 | cards, grouped rows, popovers |
| `xl` | 20 | sheets, capture panel, large cards |

Use `Capsule()` for pills.
Use `.continuous` style for every rounded rectangle.

## Typography: `DS.Font`
| Role | Style |
|---|---|
| `screenTitle` | Fraunces SemiBold: `Font.custom("Fraunces-SemiBold", size: 34, relativeTo: .largeTitle)` (iOS) / `Font.custom("Fraunces24pt-SemiBold", size: 17, relativeTo: .title2)` (Mac) |
| `displayTitle` (Mac only) | `Font.custom("Fraunces-SemiBold", size: 34, relativeTo: .largeTitle)`, the sign-in wordmark |
| `sectionHeader` | `.subheadline.weight(.semibold)` |
| `taskTitle` | `.body` |
| `taskNote` | `.subheadline`, secondary text colour |
| `taskMeta` | `.footnote` |
| `chip` | `.caption.weight(.medium)` |
| `badge` | `.caption2.weight(.semibold).monospacedDigit()` |
| `inspectorLabel` | `.subheadline` (Mac) / `.body` (iOS) |
| `heroTitle` (Mac only) | `Font.custom("Fraunces-SemiBold", size: 30, relativeTo: .largeTitle)`, Today's title beside the 72 pt day ring |
| `heroFigure` / `heroFigureRest` (Mac only) | `.title3.weight(.semibold)` / `.body`, both tabular: "**4h 30m** of 7h 30m" |
| `heroMeta` (Mac only) | `.callout`, tabular: "3h free · 1h 30m done", the overbooked suggestion and the empty day's teaching line |
| `rowEstimate` (Mac only) | `.footnote`, tabular: the "45m" at the end of a Today row and on Plan your day's rows |

### Screen-title face: Fraunces
- Screen titles use Fraunces, a display serif. Everything else, including task titles, buttons and controls, stays SF.
- The apps bundle two static instances cut from the Google Fonts variable font (`google/fonts`, `ofl/fraunces`) with fontTools. Both are wght 600, SOFT 0 and WONK 0 (wonk off).
  - `Fraunces-SemiBold.ttf` (PostScript `Fraunces-SemiBold`) is opsz 72. It is for large titles at 34pt and up.
  - `Fraunces24pt-SemiBold.ttf` (PostScript `Fraunces24pt-SemiBold`) is opsz 24. It is for the 17pt titles: the iOS inline navigation-bar title and the Mac `screenTitle`.
- The files live in `Taskfold/Resources/Fonts/`. iOS registers them with `UIAppFonts`. The Mac app registers them with `ATSApplicationFontsPath = .`.
- iOS navigation bars get the same faces through `BrandAppearance` in `TaskfoldApp.swift`, scaled with `UIFontMetrics`. The large title uses -0.3 kern.
- Every use scales with Dynamic Type through `relativeTo:`. If the font fails to load, the system face is used instead.
- Licence: SIL Open Font License 1.1, copyright 2018 The Fraunces Project Authors. The licence ships with the apps as `Fraunces-OFL.txt`. The OFL allows bundling in an app. The font must not be sold on its own, and any modified font must keep the OFL. The static instances are such a modified version, so they keep the OFL.

## Semantic colour: `DS.Palette`
| Role | Value |
|---|---|
| `textPrimary` / `textSecondary` / `textTertiary` | system label colours |
| `separator` | system separator |
| `surface` | window or system background |
| `surfaceRaised` | secondary grouped background (iOS) / control background (Mac) |
| `surfaceSunken` | tertiary fill |
| `danger` | system red |
| `success` | system green |
| `dateOverdue` | red, priority-1 red |
| `dateToday` | green |
| `dateTomorrow` | orange |
| `dateThisWeek` | purple |
| `dateLater` | `textSecondary` |
| `accentSecondary` | teal. Quick Add highlight for `#project` and `/section` |
| `label` | purple. Quick Add highlight for `@label` |
| `selectionFill` | accent at 0.14 opacity (light) / 0.22 opacity (dark). The selected row keeps primary text colour, never white on light grey. |
| `hoverFill` (Mac only) | ink at 0.05 / 0.06: a hovered Today row, while its ring segment lifts |
| `chipFill` (Mac only) | ink at 0.07 / 0.10: an inline chip such as the "30m" in the empty day's line |
| `tooltip` / `onTooltip` (Mac only) | ink / ground: the "Drop to plan" tooltip over the day ring |
| `tray` / `card` (Mac only) | ink at 0.045 / 0.04 over `surface` / `Brand.surface`: the Plan your day tray and its rows |

Priority, accent and project palettes keep their current values and stay where they are. `DS.Palette` gets `priority(_:)` and `accent` passthroughs.

## Sizes: `DS.Size`
| Token | Mac | iOS |
|---|---|---|
| `checkbox` | 18 | 22 |
| `iconS` / `iconM` / `iconL` | 12 / 14 / 18 | 13 / 16 / 20 |
| `rowMinHeight` | 32 | 44 |
| `rowVerticalPadding` roomy / compact | 8 / 4 | 10 / 6 |
| `rowHorizontalPadding` | `Space.m` | `Space.l` |
| `contentMaxWidth` | 860 | — |
| `planTrayWidth` | 290 | — |
| `estimatePip` | 3 × 16, 0.55 opacity while open, 1 when done (`estimatePipOpenOpacity`) | — |
| `ringDropScale` | 1.08: the day ring while a task is held over it | — |

## Motion
Keep each platform's existing `Motion` values; Mac stays shorter and subtler on purpose. Add these aliases so code reads the same on both platforms:
- `DS.Motion.complete` = settle
- `DS.Motion.appear` = quick
- `DS.Motion.reorder` = layout
