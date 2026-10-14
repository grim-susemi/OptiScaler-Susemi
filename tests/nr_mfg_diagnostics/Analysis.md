# Offline MFG capture analysis

Run `tests/run_nr_mfg_diagnostics.ps1 -Tier Analysis -EvidenceRoot <absolute-output-directory>` with the installed `pwsh.exe` (PowerShell 7 or later) available on PATH. The Analysis branch runs bounded, explicitly SYNTHETIC fixtures in fresh directories. Add `-AnalysisInputRoot <absolute-capture-session-directory>` to analyze an existing Task21 capture without changing its files. The fixture runner reads the retained Task5 native fact logs through its `HistoricalHostFactsRoot` parameter; this checkout defaults to the authoritative local Foundation evidence directory.

For a single offline report, run `pwsh.exe -NoProfile -File tests/nr_mfg_diagnostics/Analyze.ps1 -InputRoot <session-directory> -OutputPath <new-report-path>`. Output must be a new local file outside the input directory. The analyzer never loads a provider, executes a game, samples a GPU, follows module paths or writes input files. Unsafe/malformed/unbounded input returns native exit 2 and a named `T22_...` error; valid but incomplete or mismatched evidence returns exit 0 with `InsufficientData`.

The production inputs are `capture-session.json`, `frame-N/capture.json` schema 1, each available image's relative `role.raw`, and the relative `observerReference` with schema `nr-mfg-preflight-v1`. Reads are bounded to 64 frame directories, 8 images per frame, 256x256 ROIs, 1 MiB per raw ROI, 64 KiB per JSON/log, 512 elements per JSON array, depth 16, 580 input files, 5 MiB JSON reads and 256 MiB total retained input reads. Reparse paths, references escaping the session root, unsupported layouts, duplicate keys and invented pixel origin are rejected. Raw artifact hashes include padding; active-content hashes exclude row padding.

Current production capture metadata explicitly says `phaseKnown=false` and `displayTimingAvailable=false`; the observer records independent last values at worker time. Therefore current Task21 captures remain `InsufficientData`. Raw MultiFrameIndex, Streamline tokens, provider activity, success counters and callback spacing never become phase, pixel-origin or display-timing proof.

Only the separate fixture companion `analysis-synthetic.json` may exercise complete metadata today. Its schema is `nr-mfg-analysis-synthetic-v1`, with `synthetic=true`, `provenance="SYNTHETIC"`, and up to 64 application entries. Each entry binds its capture SHA256 and available image SHA256, declares `declaredPhase=real|generated`, a finite `displayTimeMs`, and explicit NR `enabled`/`signature`. These declarations stay separate from the production image's `owned_nr_surface` origin. They never qualify as captured provider/generated game pixels.

The exact outcome classes are:

| Outcome | Required observation |
| --- | --- |
| `InsufficientData` | Missing captures, comparable images, provenance, NR settings, declared phase/timing, observer, or a measured artifact mismatch. |
| `NotReproduced` | Complete bounded SYNTHETIC fixture observations show no reproduced contract failure or stable-input sample anomaly. |
| `ProviderHypothesisOnly` | Complete SYNTHETIC observations show changed NR samples with stable sampled input and NR/exposure settings, with no reproduced OptiScaler contract failure. This is descriptive, with no proprietary cause inferred. |
| `OptiScalerDefect` | A complete SYNTHETIC reconstruction binds retained historical Task5 native facts to an explicit nonneutral applied-final-copy contract; actual application pixels contradict the independently declared expected scratch value while composed/copyBack/executed/submitted/applied all report true. |

The Task5 fixture is historical proof of the already repaired final-output publication failure, not evidence of a current regression. A neutral expected copy or `applied=0` cannot trigger that defect. Candidate source paths are emitted only for this reproduced contract failure and route to existing Task5; no current product repair is requested without current failure evidence. Other observations create no speculative source path or unplanned product edit.

Reports keep raw content change, NR output change, raw/resolved exposure changes, declared NR-setting changes, declared phase, observed samples and available SYNTHETIC timing in separate fields. Every report sets `gameReproduced=false` and `qualityFixProven=false`. No foliage cure, Crimson Desert reproduction, proprietary optical-flow/occlusion cause or Blackwell parity is claimed.
