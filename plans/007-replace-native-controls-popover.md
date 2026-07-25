# 007 — Replace the native Controls popover

- **Status**: DONE
- **Commit**: eb27882
- **Severity**: HIGH
- **Category**: Physicality & origin
- **Estimated scope**: 1 file, about 70 lines changed

## Problem

The Controls dropdown is styled as a custom surface, but
`Sources/Unhog/FluidDropdown.swift:100` still presents it with SwiftUI's native
macOS popover:

```swift
.popover(
    isPresented: $isPresented,
    arrowEdge: .bottom
) {
    FluidDropdownPanel(width: width) {
        content
    }
    .presentationBackground(.clear)
}
```

That creates a separate macOS popover window and native placement/arrow
behavior. It cannot feel like the Fluid Functionalism select, which is a
spring-animated layer spatially attached to its trigger.

The panel also owns a second `appeared` state and starts an animation in
`onAppear`. The presentation state and visual state can drift, and closing
cannot smoothly reverse the entrance.

## Target

Render the panel as a SwiftUI overlay in the existing Unhog popover window:

- No `.popover`, `Menu`, `Picker`, `NSPopover`, or separate window.
- Right edge aligned to the trigger; panel begins 32 points below it.
- Panel transform origin is `.topTrailing`.
- Normal motion enters from `scale 0.96`, `y -4`, and opacity `0`, then reaches
  `scale 1`, `y 0`, and opacity `1`.
- Opening and closing use the existing spring:
  `.spring(response: 0.24, dampingFraction: 0.90)`.
- Reduced Motion removes scale/offset and keeps the existing 200ms opacity
  transition through `UnhogTheme.motionFade`.
- The trigger, an action, Settings, and Escape all close the same binding.
- The panel has a higher `zIndex` than the normal header/content.
- Keep the existing material, 12-point continuous radius, one-pixel subtle
  stroke, shadow, keyboard focus, and arrow-key behavior.
- Keep hover feedback quick and subtle. Do not animate layout size.

## Repo conventions to follow

- Shared motion tokens live in
  `Sources/Unhog/DesignSystem.swift:106-122`.
- `UnhogTheme.motionEnter` is the established 200ms strong ease-out curve.
- Reduce Motion is provided by `@Environment(\.unhogReduceMotion)`.
- `ProcessActivityRow.swift` uses asymmetric opacity/scale transitions without
  adding dependencies.

## Steps

1. In `Sources/Unhog/FluidDropdown.swift`, replace the trigger's `.popover`
   modifier with a local `ZStack(alignment: .topTrailing)` or
   `.overlay(alignment: .topTrailing)`.
2. Keep the trigger in normal layout. Conditionally insert
   `FluidDropdownPanel` at `offset(y: 32)` with `zIndex(100)`.
3. Wrap every `isPresented` mutation in one `setPresented(_:)` helper. Use the
   spring for normal motion and `UnhogTheme.motionFade` for Reduce Motion.
4. Apply an asymmetric transition to the inserted panel. Normal insertion and
   removal use opacity + top-trailing scale + a four-point vertical offset.
   Reduced Motion uses opacity only.
5. Remove `FluidDropdownPanel.appeared` and its entrance animation. Retain its
   focus setup and key handling.
6. Keep the environment dismiss action, but route it through
   `setPresented(false)` so actions and Escape animate out consistently.
7. Confirm that the local overlay is not clipped by the header and visually
   covers content instead of pushing it down.

## Boundaries

- Do NOT change the Controls menu actions or labels.
- Do NOT change the app's 372×500 popover size.
- Do NOT introduce a third-party menu library.
- Do NOT use AppKit `NSPopover`, `.popover`, `Menu`, or `Picker`.
- Do NOT touch unrelated process, storage, logo, or palette work in the dirty
  worktree.
- If the overlay is clipped by an ancestor, move only the presentation layer
  to the nearest existing root `ZStack`; do not create another window.

## Verification

- **Mechanical**:
  - `rg -n '\\.popover|NSPopover|Menu\\s*\\{|Picker\\s*\\{' Sources/Unhog/FluidDropdown.swift`
    returns no presentation primitive.
  - `swift build` succeeds.
  - `swift test` reports all suites passing.
- **Feel check**:
  - Click the sliders icon: the panel grows from its top-right trigger without
    an arrow or detached macOS window.
  - Rapidly click the trigger: the motion reverses cleanly from its current
    position.
  - Hover rows: feedback stays subtle and does not move surrounding rows.
  - Press Escape and choose an action: both animate the panel closed.
  - Enable Reduce Motion: opening/closing fades without scale or travel.
- **Done when**: Controls looks and behaves like an in-surface animated select,
  and no native macOS dropdown window appears.
