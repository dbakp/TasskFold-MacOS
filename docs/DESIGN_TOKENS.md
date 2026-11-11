# Taskfold design tokens

The same spec lives in both app repos at `docs/DESIGN_TOKENS.md`. Each app implements it in `Taskfold/Views/DesignTokens.swift`, inside an `enum DS` namespace. The names are identical on both platforms. Values may differ only where this file says so.

## Rules
- Views use tokens, not numeric literals, for padding, spacing, corner radius, text styles and semantic colours.
  - A literal is fine for one-off geometry, such as chart sizes or calendar hour heights.
  - Leave a short comment explaining why.
- Text uses Dynamic Type text styles through `DS.Font` roles.
  - `.font(.system(size:))` is allowed only for SF Symbols that need an exact optical size.
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
| `screenTitle` | `.largeTitle.bold()` (iOS) / `.title2.weight(.semibold)` (Mac) |
| `sectionHeader` | `.subheadline.weight(.semibold)` |
| `taskTitle` | `.body` |
| `taskNote` | `.subheadline`, secondary text colour |
| `taskMeta` | `.footnote` |
| `chip` | `.caption.weight(.medium)` |
| `badge` | `.caption2.weight(.semibold).monospacedDigit()` |
| `inspectorLabel` | `.subheadline` (Mac) / `.body` (iOS) |

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

## Motion
Keep each platform's existing `Motion` values; Mac stays shorter and subtler on purpose. Add these aliases so code reads the same on both platforms:
- `DS.Motion.complete` = settle
- `DS.Motion.appear` = quick
- `DS.Motion.reorder` = layout
