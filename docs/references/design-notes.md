# Design notes from reference apps

These notes record layout and feature ideas taken from a competitor (KeepFeather) for the owner's reference. The local
screenshots are in `docs/references/KeepFeather/`. They are gitignored because they show personal photos.

Rule (spec §9): we take ideas for **layout and features only**. We never copy the name, icon, wording or styling.

## Adopt (mapped to our plans)

| Idea | Where | Plan |
|---|---|---|
| First-run Overview: one-line promise, three short trust lines with SF Symbols (read-only until queued; copies keep date, place, albums; originals only to Recently Deleted when you choose), primary "Allow access to Photos…", secondary "Use local files instead" | Overview empty state | 3 (T3/T7) |
| Overview dashboard: a headline "can be about X smaller" with a now → after bar; a Videos card with rows by tier (4K and higher / 1080p and lower) showing count, size → after, Show, and Add all to queue…; an "Originals" segmented control (keep in a folder / don't keep) with a link to settings | Overview | 3 (T7) |
| Savings header shows a **range** ("about A–B") and how many items have been estimated so far, plus a live "Reading sizes · n of N" progress line with an info button | Savings header | 3 (T2/T3) |
| Preset choice as a bar with three stops, each showing High / Balanced / Smaller with its size underneath | Savings header (we use a segmented control today; consider) | 3 polish |
| Toolbar: Years / Months / All, tile zoom − / +, one filter menu whose options show **count and size**, a Select menu, inspector toggle, search | Grid toolbar | 3 (T7b) |
| Filter menu sections: "Can be compressed" (default), types, "Kept as is", "All", a Year submenu, "Hide finished" | Filters | 3 (T7b) |
| Grid / list toggle and a sort menu next to the header | Grid | later |
| Footer status line: "N items · size · k selected, size" | Grid footer (we have it) | done |
| Inspector: large preview with a Preview button; name, date · dimensions · format; badge chips; a Kept as is explanation with a link to the relevant setting; a Details disclosure; an "Original archive" example path; quality rows with keyboard shortcuts 1–4 (Original / High / Balanced / Smaller); "Add to queue · <preset>"; "Measure exactly" | Inspector | 3 polish (shortcuts 1–4), measure exactly later |
| Full-size preview mode with zoom and "Only in iCloud · original shown" status | Preview | 3 (streaming preview, no original download) |
| Sidebar counts on Photos / Videos; user albums listed under an Albums section | Sidebar | 3 (T3) |
| Empty Queue: "Nothing in the queue" plus a "Go to Videos" button; the queue's inspector says "Select a job to see its result" | Activity | Plan 2 fix pass |
| Insights ▸ Statistics (total saved over time) with an empty state until the first job finishes | Statistics | later (spec §9 "may come later") |

## Don't copy

- The name, feather icon, gradient accent text or any sentence of its copy.
- Its photo-compression features: photos are out of scope for v1 (spec §11 roadmap).
