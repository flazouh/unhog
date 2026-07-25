# Unhog motion plans

| Plan | Title | Severity | Status |
| --- | --- | --- | --- |
| 001 | Build the visual drain signature | HIGH | DONE |
| 002 | Animate verified state changes | HIGH | TODO |
| 003 | Unify motion and Reduce Motion behavior | MEDIUM | DONE |
| 004 | Add branch-scoped stopping | HIGH | DONE |
| 005 | Redesign the menu bar signal | HIGH | DONE |
| 006 | Build the preferences system | HIGH | DONE |
| 007 | Replace the native Controls popover | HIGH | DONE |

## Recommended execution order

1. Execute `001` to establish the visual component and its public data seam.
2. Execute `004` to add safe branch control before phase animation is wired.
3. Execute `003` to create shared motion tokens and remove continuous sampling
   motion.
4. Execute `006` to establish typed preferences and policy derivation.
5. Execute `005`; its presenter depends on the preferences display mode.
6. Execute `002` last; it depends on the signature, branch model, motion
   tokens, and final menu bar phase behavior.
7. Execute `007` independently; it only changes the Controls presentation
   layer and should be verified in the compact popover.

Each plan is based on commit `dc191bd`. If source files have changed, the
executor must stop and report drift instead of guessing.
