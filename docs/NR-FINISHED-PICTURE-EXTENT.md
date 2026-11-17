# Finished-picture NR extent repair

## Cause and resource contract

A capture can contain SR-output metadata for 2048x1152 while the actual finished
picture is 2560x1440. The old admission predicate required these sizes to be equal
and returned `producer_not_ready` before considering an otherwise ready capture.

`PrepareFinishedPicture` is shared by admission/claim and application. It validates
actual colour/depth/motion resource descriptions and active guide regions. The
original SR output dimensions and guide offsets remain unchanged. The local
evaluation frame converts motion-vector scale by `picture / SR output`; the
existing Run path subsequently converts by `work / picture`. The composition is
`work / SR output`, not a second change to the guide region.

The actual picture still determines colour/output size. Same-size frames retain
their motion-vector scale. Uniform up/down scaling preserves source metadata and
does not accumulate conversion across frames. Different aspect ratios, unknown
active guide metadata during resizing, clipped guides, MSAA/arrays/multiple mips,
zero dimensions and nonfinite/zero converted motion scale are refused.

There is no game-name branch, new option, frame wait, lag compensation, shader,
framework or allocation path. Existing owner/consumer/application identity and
queue/fence requirements remain. Colour encoding and the existing independent
guide-region path are unchanged.

## Source lineage and limits

This feature branch starts from `e286277b`, the already-published source checkpoint
used for the verified extent repair. It is a preservation branch, not a claim
that the default branch or every v11.4 feature has been updated.

| Reference | Actual relationship |
| --- | --- |
| `e286277b` | Published NR options checkpoint; selected source base |
| `9a1c81da` on `susemi/nr-present-addon-options` | Separate Dawnwalker lag1 repair on that checkpoint |
| `17ba1461`, tag `v11.4`, `susemi/nr-ui-feedback-r3` | Separate newer UI/diagnostics/installer lineage; its other changes are not imported here |
| `33c49d59`, default `dlss-neural-rendering` when inspected | Older production lineage plus issue-template change; not changed by this branch |

The v11.4 compose diff also adds model-fact validation and output-status metadata.
Other GPU lifetime, pipeline, UI and installer differences exist. Referencing
that release is not equivalent to porting those features.

### Why the Dawnwalker policy remains separate

The actual `9a1c81da` patch changes identity selection: after an exact-match miss,
it learns a unique same-owner/consumer slot one application behind across at
least three observations, then restamps it. The second claim call preserves the
learned state for the restamped serial. It uses process-static learning state.

That fixes a different contract from resource extents. The extent repair begins
after exact identity selection and does not restamp a frame. Both share the
requirements that admission, claim and application use one coherent identity and
valid resources. Sharing that boundary does not justify enabling a lag policy
globally, nor does a historical Dawnwalker success validate a new combined build.

This branch deliberately does not merge the automatic lag policy. A future
combination needs an explicit policy choice about learning scope/reset across
owners and consumers plus runtime evidence. No decision is required to preserve
the already-verified extent repair separately.

## Verification matrix

| Game/surface | Evidence | Limits |
| --- | --- | --- |
| Black Flag Resynced | Instrumented extent build `43c9b3ddf58f333b79185e87ebff0b5d2ee8cb746070717a5fa0db4462ab887e`: SR 2048x1152, picture 2560x1440, MV scale 1 to 1.25; after feature 1000003 recreation, frames 470-804 gave 335 consecutive handoff APPLY records; owner confirmed the picture now applies | About 4.87 seconds of that post-recreation log interval; individual NR pass return codes were not logged; complete ghosting/depth/MV image-quality review was not claimed |
| Crimson Desert / same-size contract | CPU production-logic regression at 2048x1152 and 2560x1440, unchanged MV scale, up/down/return transitions and stale owner/generation/application refusal | CPU coverage, not a new Crimson Desert in-game test |
| Dawnwalker | Historical lag1 diagnostic counterpart: 6605 APPLY records; clean LAG1FIX build `eab3ee53e9c974c1eef4dc152503bd188befb43af94713545a639597d2d68b29` was reported working by the owner | Historical case. The clean historical run had no fresh matching log. This extent branch and any new combined build have not been run in Dawnwalker |

The source helper here is byte-identical to the helper in the observed Black Flag
build. This preservation source removes the installation-only `NR_BF_READY` and
`NR_BF_EXTENT` diagnostics and keeps normal build metadata. Its newly linked DLL
is not the byte-identical in-game-tested artifact and is not installed.

## CPU regression and sensitivity

From a Visual Studio x64 developer shell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/run_nr_finished_extent.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File tests/run_xefg_production_route_smoke.ps1
```

The extent runner compiles the real preparation header, the verbatim production
admission/claim body and the actual application preparation/frame-selection
statements. Only resource/device access is represented by POD test adapters.
There is no D3D device creation, WARP, GPU or NGX execution.

Coverage includes high/low-resolution vectors, two same-size cases, up/down/return
transitions, guide offsets, unchanged source metadata, stale identities and six
resource/metadata refusal cases. Seven disposable mutations must fail by name:
old equality-only admission, absent MV conversion, forged source dimensions,
removed aspect refusal, discarded preparation, discarded prepared frame at Run,
and removed guide-width protection. The real source is never mutated.

The existing handoff 11-case/wiring 4-case results from the observed candidate
remain historical evidence; they are not relabelled as fresh executions here.
Final-source validation is recorded below after the delta checks.

### Final source checks on 2026-11-17

- Production extent CPU regression passed, including both native sizes,
  up/down/return transitions and stale owner/generation/application identities.
- All seven disposable mutations failed at the intended named assertions.
- The actual production-route pin passed; its four existing sensitivity seeds
  failed as expected. The unchanged handoff/wiring suites were not rerun.
- One Release x64 build completed: MSBuild `/m:1`, compiler `/MP2`, fresh
  intermediate/output directories, external existing SDK dependencies and
  pre/post-build events disabled. No GPU execution or game operation.
- Build exit 0, errors 0, elapsed 2:33.62. There were 65 inherited warnings in six
  warning classes: C4244, C4250, C4267, C4018, C4744 and LNK4098. Those warning
  classes also occur in the earlier baseline build; no warning was emitted
  against the changed production header/compose or new regression source.
  Warnings remain in the raw local build record; no suppression was added.
- The new uninstalled source-validation DLL is 26,691,072 bytes, exports 947 names,
  SHA-256 `00db2a9f194ed347f5c7974f95713dfa288823db9a1ec1471ff0da51e6abefdd`.
  It is not the installed in-game artifact.
- The tested preparation header has SHA-256
  `a85bd3154d6171f36c42b756a0e02cdb9a20a697a29ea8c3098bc872907e7b1e`,
  identical to the observed Black Flag candidate's header.

Only production source, executable CPU regression source/runner and this
sanitized change/evidence document belong to the preservation commit. No SDK,
DLL, raw log, installation-only diagnostic or machine-specific build script is
added. The previously working installed ASI and all game settings stay untouched.

## Korean summary

캡처 크기와 실제 완성 화면 크기가 달라도 안전한 같은 화면비 변환을 허용한다.
원본 guide 영역은 보존하고 평가용 MV 단위만 맞춘다. 게임별 분기는 없다.
블랙플래그는 계측판 실사용 성공, 붉은사막 동일 크기는 CPU 회귀,
던워커는 과거 lag1 성공 사례이며 새 통합판 실사용 완료로 표시하지 않는다.
던워커 자동 lag 정책은 이번 공통 크기 수리에 합치지 않았다.
