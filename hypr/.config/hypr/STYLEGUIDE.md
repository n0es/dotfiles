# Hyprland Workspace Style Guide

Minimal black + orange. Update this as the setup evolves.

---

## Color Palette

### Base

| Role             | Hex       | RGBA                       | Usage                          |
|------------------|-----------|----------------------------|--------------------------------|
| Background       | `#0a0a0a` | `rgba(10, 10, 10, 0.9)`   | Bars, panels, overlays         |
| Surface          | -         | `rgba(255, 255, 255, 0.04)` | Module backgrounds           |
| Text Primary     | `#d4d4d4` | -                          | Default foreground             |
| Text Muted       | `#666666` | -                          | Inactive/disabled elements     |
| Text Dark        | `#333333` | -                          | Animation endpoints, deep mute |
| Inactive Border  | `#333333` | `rgba(333333aa)`           | Unfocused window borders       |

### Accent

| Role             | Hex       | Usage                                  |
|------------------|-----------|----------------------------------------|
| Orange (primary) | `#ffa032` | Active borders, highlights, indicators |
| Green (status)   | `#88bb88` | Positive states (battery ok, charging) |
| Red (critical)   | `#cc4444` | Error/critical (disconnected, battery critical) |

### Accent Opacity Scale

Derived from `#ffa032` / `rgba(255, 160, 50, ...)`:

| Level   | Value  | Usage                    |
|---------|--------|--------------------------|
| Border  | `0.30` | Divider lines            |
| Active  | `0.20` | Active element bg        |
| Hover   | `0.15` | Taskbar active           |
| Subtle  | `0.10` | Hover states             |

---

## Typography

| Context      | Font                         | Size   | Weight |
|--------------|------------------------------|--------|--------|
| All UI       | CaskaydiaCove Nerd Font      | 13px   | Normal |
| UI emphasis  | CaskaydiaCove Nerd Font      | 13px   | Bold   |
| Terminal     | CaskaydiaCove Nerd Font Mono | 12pt   | Normal |
| Icons        | CaskaydiaCove Nerd Font (built-in Nerd Font glyphs) | - | - |

No Font Awesome. No JetBrains Mono. CaskaydiaCove everywhere.

---

## Spacing & Geometry

| Property         | Value    | Usage                        |
|------------------|----------|------------------------------|
| Border radius    | `4px`   | All UI elements              |
| Window rounding  | `4`      | Hyprland window corners      |
| Border size      | `1px`    | Window borders, bar dividers |
| Gaps inner       | `4`      | Between tiled windows        |
| Gaps outer       | `4`      | Window to screen edge        |
| Bar height       | `30px`   | Waybar                       |
| Module padding   | `0 10px` | Waybar status modules        |
| Module margin    | `3px 1px`| Between modules              |
| Bar spacing      | `4px`    | Between module groups        |

---

## Design Principles

1. **Minimal** - Tight spacing, thin borders, low-profile bar. No excess chrome.
2. **Black base** - Near-black backgrounds at `0.9` opacity. Dark, not transparent.
3. **Orange as the sole accent** - All active/selected states use `#ffa032` at varying opacity. No other accent colors except for semantic status.
4. **Three status colors only** - Orange = warning, green = good, red = error. That's it.
5. **One font family** - CaskaydiaCove Nerd Font for everything. Icons are built-in Nerd Font glyphs (󰤨 󰂯 󰁹 etc.), not a separate icon font.
6. **4px rounding** - Subtle rounding. Not rounded rectangles, just softened corners.
7. **1px borders** - Thin, understated. The bar bottom border is the only divider.

---

## State Mapping

| State        | Background                          | Text Color  |
|--------------|-------------------------------------|-------------|
| Default      | `transparent`                       | `#666666`   |
| Hover        | `rgba(255, 160, 50, 0.10)`         | -           |
| Active       | `rgba(255, 160, 50, 0.20)`         | `#d4d4d4`   |
| Disabled     | `transparent`                       | `#666666`   |

---

## Window Border

```
col.active_border = rgba(ffa032ee)
col.inactive_border = rgba(333333aa)
```

Single color. No gradients. The `ee` alpha keeps borders slightly transparent.

---

## Applying to New Elements

When adding a new config (rofi, dunst, lockscreen, etc.):

1. Background: `#0a0a0a` / `rgba(10, 10, 10, 0.9)`
2. Surface: `rgba(255, 255, 255, 0.04)` for grouped items
3. Selection/focus: `rgba(255, 160, 50, 0.20)`
4. Text: `#d4d4d4` primary, `#666666` muted
5. Radius: `4px`
6. Borders: `1px`, `rgba(255, 160, 50, 0.3)` if visible
7. Font: `CaskaydiaCove Nerd Font` at 13px
8. Icons: Nerd Font glyphs only
9. No gradients, no shadows, no blur effects in UI chrome
