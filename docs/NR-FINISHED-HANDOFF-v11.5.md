# NR finished-picture handoff: v11.5.1

## Source and preserved features

The integration descends from v11.4 (`17ba1461`) and merges the default
`dlss-neural-rendering` branch (`33c49d59`). It preserves v11.4's localized,
resizable menu, NR addon options, model-context metadata, existing backend
support and the `96bf1def` one-click installer lineage. The final binary is
not the earlier `e286277b` diagnostic base.

The two fixes share the capture/consumer contract but solve different failures.
There is no game-name branch, new option, frame wait or unconditional lag.

## Extent contract

`PrepareFinishedPicture` is used by both production admission and apply.
It requires a real single-sample picture with matching aspect ratio, bounded
guide regions, valid render/output extents and source motion-vector scale.
It returns a separate frame whose output is the actual finished picture.
It keeps the source capture/guide bounds intact and converts the MV scale
from the captured output extent to the finished-picture extent.

The same-size path keeps its original scale. Supported expansion and shrinking
use the existing NR preparation/composition shaders. Unsupported aspect, bounds,
sample or guide combinations remain refused. This is not a removed size check
or a fabricated capture extent.

## Application identity and lifetime

The earlier v11.5 release remains an unpublished draft, with its tag retained. A release-time production
regression exposed mutation of the original capture identity. v11.5.1 preserves
that source identity, derives a consumer identity only in returned admission facts,
and uses it consistently for claim, model epoch and output status. A queried but
unclaimed serial cannot be restamped forward into later consumer applications.

The Dawnwalker precedent used `9a1c81da` together with historical uncommitted
changes. Its successful `eab3ee53` binary does not prove that the patch commit
alone reproduces that binary.

v11.5.1 keeps exact application matches first. Only a unique, selectable capture
exactly one application behind may be learned, after three consecutive distinct
consumer applications. Duplicate queries do not advance learning. Query then
claim of the same real serial keeps that learned phase without altering the capture.

Learning belongs to the existing mutex-protected `LateContext`, never a
process-static variable. It resets on owner/consumer/generation changes,
`Cancel()`, the existing capture reset, backwards or skipped applications,
ambiguous candidates and a genuine exact match. Existing retirement calls
`Cancel()`, so a recreated feature cannot inherit the previous owner's phase.
The existing claimed-application/serial, readiness and fence checks still apply.

## Production tests and observed use

The CPU fixture compiles the actual production admission and apply bodies,
the actual `LateContext` member declaration and `Cancel()` body, and the actual
capture-reset statements. It invokes the real extent and phase helpers.
Twelve seeded defects must fail at their intended assertion: admission bypass,
MV scaling, source mutation, aspect/bounds bypass, unused prepared frame,
process-global learning, missing cancellation/capture reset, capture-identity mutation
and incorrect model consumer epoch.

Packaging reads committed blobs while preserving unchanged archive members.
All Windows BATs use CRLF. The extracted-package E2E checks that transport
before executing the actual installer, including fresh/no-op/upgrade/removal.

| Game / evidence | Earlier observed result | Unified v11.5.1 |
| --- | --- | --- |
| Black Flag Resynced, `43c9b3dd` | Owner confirmed visible NR; observed APPLY continued after feature recreation | Extent and identity CPU regressions passed; new integrated binary not game-tested |
| Dawnwalker, historical `eab3ee53` | Separate lag1 repair reported working | Scoped phase/claim/reset regressions passed; new integrated binary not game-tested |
| Crimson Desert | Owner reports prior NR success | Same-size admission/claim/apply regressions passed; no new game run |

No GPU test or new integrated gameplay acceptance is claimed. Ghosting, depth
and MV image quality remain separate runtime checks. Existing working game
installations were not replaced as part of publishing.

## 한국어 요약

v11.4 기능·메뉴·설치기를 유지하고 캡처/최종화면 크기 계약과 프레임 인계를
함께 고쳤습니다. 1프레임 보정은 관측으로 학습하며 owner·소비자·재생성·리셋
범위 밖으로 남기지 않습니다. 통합판의 생산 로직 CPU 회귀는 통과했지만,
블랙플래그와 던워커의 과거 성공을 이번 새 DLL의 실기 성공으로 취급하지 않습니다.
