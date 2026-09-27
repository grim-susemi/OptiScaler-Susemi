# SUSEMI source provenance (v11.2 recovery, committed R snapshot)

Status: **COMMITTED product record** at `docs/SUSEMI-SOURCE-PROVENANCE.md` on
branch `susemi/v11.2-source-recovery-r2`, single-parent R commit
`chore(release): reconcile Susemi product source with shipped lineage`.
Machine source: refreshed T1/T16 `recovery-spec.json` (see §8 for its hash).

- R2 repair: the first R `e780e0f0` (branch `susemi/v11.2-source-recovery`)
  was REJECTED at independent gate for committing six compiled
  `tools/__pycache__/*.pyc` build outputs. It is preserved untouched as
  rejected history. This R2 commit repeats the reconciliation from the
  same v11.1 base with those six files reclassified to
  `exclude-local / generated-cache` per the refreshed T16 manifest
  (1124 recover / 77 remove / 9 retain / 4927 exclude); nothing else in
  the product set changed (1124/1124 per-path donor SHA re-verified).

## 0. What this snapshot is — and is NOT

- This commit restores the **reviewed Susemi product sources** from donor
  HEAD `a8eac0c4195bb5d2c93a08055c05b584d5c98953` onto the exact v11.1 base `8f387acad612e7ce8ea0b4811823d08f31e204db`
  as one ordinary single-parent child commit. The v11.1 tag and all of its
  assets are preserved untouched; no tag was rewritten and no false merge
  (`merge -s ours`) was used.
- **This is NOT an exact historical reconstruction of v11.1.**
  "v11.1을 그대로 재현"이라고 쓰지 않는다. The v11.1 ZIP was built from
  uncommitted donor state, not from the v11.1 tree: the two lineages are
  siblings (merge-base `65a5f6f9c5cec6e0a898bf7accc4bfcdfc807a02`, neither is the other's
  ancestor). Files that existed only in the v11.1 tree are either retained
  as reference (§5) or removed with record (§4); files below are pinned to
  donor worktree bytes (§3), which differ from both parents' blobs where
  the donor had 45 tracked modifications.
- Feature changes after this point go in later individual commits; the R
  commit itself is source reconciliation only.

## 1. Ancestry pins

- v11.1 base (sole parent of R): `8f387acad612e7ce8ea0b4811823d08f31e204db`
- Donor HEAD (reviewed source): `a8eac0c4195bb5d2c93a08055c05b584d5c98953`
- merge-base(v11.1, donor): `65a5f6f9c5cec6e0a898bf7accc4bfcdfc807a02` (plan-expected; neither is ancestor)
- Spec verdict: `PASS`, generated 2026-09-27T10:30:00+00:00
- Counts: recover=1124 remove_current=59 remove_old_tag=18 retain_old_tag=9 exclude=4927 unresolved=0

## 2. Shipped-lineage pins (why this source set, not the tag tree)

- release A ZIP: `04e23d830561be37c6fc293086d3ec4bcf97e8b02a52a9601827e35cc59e9522` — MATCH
- release B ZIP: `dab6c49e1835cf7d1d0b4387185f62536259ad460d6c000cc8dfaf198642c60c` — MATCH
- Six runtime-manifest comparisons (OptiScaler.asi, configs, logs): all MATCH per T1 seal.
- R12 end-of-run logs (failure 0 APPLY / success 1096 APPLY) and UAL inner-DLL pin: MATCH per T1 seal.

## 3. Recovered paths (donor worktree bytes, sha256-pinned)

**1124** paths copied byte-identical from the donor worktree into this
tree and re-hash-verified (0 missing, 0 mismatch at apply time).
`source` is always `donor-worktree:<donor_head>`; `class` is always
`recover-from-donor`. Full table (path / sha256 / donor git_kind / reason):

| path | sha256 | donor git_kind | reason |
| --- | --- | --- | --- |
| `.clang-format` | `fb29f5c7c5d705be923ba440bb002c5899f04f664f168989a97c799cc67f415c` | tracked | tracked-modified-product-source |
| `.gitattributes` | `c8469d80ec6210838fc250cf86cffd8096c436ff06aa5d037885aa77fed33671` | tracked | tracked-modified-product-source |
| `.github/ISSUE_TEMPLATE/crash-bug.md` | `cf2a7c03d5689a39bbe44b085bb0ee08f16a12b1c56a07003bd41de9c26762eb` | tracked | tracked-modified-product-source |
| `.github/workflows/build.yml` | `8516decc86566ce34ef8e2918bdde6be66b427afb22f434e922d4b89c218cbaf` | tracked | tracked-modified-product-source |
| `.github/workflows/clang-format.yml` | `e77cfe5894282cfc4703687bee24fec68489c3339675f6f8c6c2bcb705363d67` | tracked | tracked-modified-product-source |
| `.github/workflows/just_build.yml` | `a779c0b48c6618871bc369570731aae977f20b39d36e256fced0e8413e881686` | tracked | tracked-modified-product-source |
| `.github/workflows/just_build_no_signature.yml` | `7c82711d816410e7c3a8e2bb5e56fb65df4b1443bf9c4fdf8696ec7ce3b300ed` | tracked | tracked-modified-product-source |
| `.github/workflows/package_release.yml` | `f51d1d5069095f4726389a7678ca130b3c8238f3e1e5f703362989be0214679f` | tracked | tracked-modified-product-source |
| `.github/workflows/release_debug.yml` | `228e24bff7e3e5ef413ea0b0029ed37e1d71a555546cff0305357c28894e9613` | tracked | tracked-modified-product-source |
| `.github/workflows/test.yml` | `60280b281eef42e7590d50e5cf3a52fa7a0acf0db4d226903502f8f3f0a10463` | tracked | tracked-modified-product-source |
| `.gitignore` | `9d7f84bd6fce840dda7799bae6341073829ebbcc2086f63d73633431c882fde6` | tracked | tracked-modified-product-source |
| `.gitmodules` | `a51e5c46fa7be8af090f21b367f48804b092a4c2d1b6124e43a832458cc64f06` | tracked | tracked-modified-product-source |
| `CONTRIBUTING.md` | `a7d75e2836245571fc54a462689b4e26a64a57f97b8df903f988ea4413bb4fea` | tracked | tracked-modified-product-source |
| `Changelog.md` | `cf5de89bebfff00485f05fcc6c627a8fea04f81197d30cf450f77f5691c794b6` | tracked | tracked-modified-product-source |
| `Config.md` | `5addd4a48f963c923011b5daff26514f4aef7537562545e87cc13cd910c3fba1` | tracked | tracked-modified-product-source |
| `Features.md` | `2809121e847f3615ed73f5f71b13709f79964e4780591e8dc214a38d73301de8` | tracked | tracked-modified-product-source |
| `INSTALL-DLSSNR.md` | `194aafe4788ee4940cf7f4dcf72a8923164e9937d6d876d6365e7b720ad707e4` | tracked | required-product-input-untracked |
| `INSTALL-KO.md` | `301634d7bb24e7bc9f00ef52d347cb18521fa223beeceb3b014c3a10f432a1ef` | untracked | required-product-input-untracked |
| `Install_AsiLoader_windows.bat` | `2a375e09c258e7d5aedfab0828f10c4ce3b08551d59ca465329e55dece79a81c` | untracked | required-product-input-untracked |
| `Issues.md` | `e89fbd938aa83d52f3f7718a16edfd988af156e54805c1c350ac952a14102e18` | tracked | tracked-modified-product-source |
| `LICENSE` | `230184f60bae2feaf244f10a8bac053c8ff33a183bcc365b4d8b876d2b7f4809` | tracked | tracked-modified-product-source |
| `Licenses/MFGUnlock_LICENSE.txt` | `b3a057a22420584bb0e6867afd7a79a756518eb6f9a3b1fae66f2f762203fb10` | tracked | tracked-modified-product-source |
| `Licenses/RenoDX_ATTRIBUTION.txt` | `1d2f2b2f8cf5c9acfe2eaaa2d2c22face87bd19f7df85453079a28e7123ae727` | tracked | tracked-modified-product-source |
| `OptiScaler.ini` | `d8b0bbddd51fbd63a99e2226826796aa94fd159c51b551f64d4d35d59e3de54c` | tracked | tracked-config-reviewed-defaults-OFF |
| `OptiScaler.sln` | `9286e49706bb967f7a7e2338c418d127adc124d14352654a1d7399f3ecd240ca` | tracked | tracked-modified-product-source |
| `OptiScaler/BuildInfo.cpp` | `0d957fbd75eeb3d231cb1778ad60773013f7fabf73268dff02b3e8f2a7ad3ca9` | tracked | tracked-modified-product-source |
| `OptiScaler/BuildInfo.h` | `5aa70eac4b99364ccee3b7d45a702a5c93cea5a8aafbe3c8b3837b6098c3e282` | tracked | tracked-modified-product-source |
| `OptiScaler/Config.cpp` | `f7f2ca903681c937cdca8a64e9446cd7df40a59ad8bb92fc5417671882fa46e4` | tracked | tracked-modified-product-source |
| `OptiScaler/Config.h` | `e78c2c2033c45a2b684ad40e4c5d64a6296d5d26f66a8a03f095ec1049566d5a` | tracked | tracked-modified-product-source |
| `OptiScaler/DllNames.h` | `c6f358967aaff03dbcbc6d95f3fc2e6c5fe2c2a8710f62678f8175854a36c384` | tracked | tracked-modified-product-source |
| `OptiScaler/Logger.cpp` | `a8d6d20756734f6906d4830f3ac32630036064942a073a0a5b481806363c2148` | tracked | tracked-modified-product-source |
| `OptiScaler/Logger.h` | `4bea0d17f287da6d0e7f9bbb08f71f9d0c70fea3e3ba8beb3c6d65a8eb2ff1b8` | tracked | tracked-modified-product-source |
| `OptiScaler/MathUtils.h` | `9b4777c58747924c7b37165fbae4bbf2badd43bb7c87c227e989febf86e6e1a6` | tracked | tracked-modified-product-source |
| `OptiScaler/NVNGX_Parameter.cpp` | `6ad627897d9c3de9e13f42aa6c93dab3e1818429d40b1ded11d2f3e85fbba09e` | tracked | tracked-modified-product-source |
| `OptiScaler/NVNGX_Parameter.h` | `b0b69efd21d6c966748ed6484821695e4c1d0bbc94bbc0c130df581ff7f955e7` | tracked | tracked-modified-product-source |
| `OptiScaler/OptiScaler.rc` | `fc49b59f72282d1ca738bd375b2ba982d79134c77ebbbb8bfdc6a70c77cf4923` | tracked | tracked-modified-product-source |
| `OptiScaler/OptiScaler.vcxproj` | `016a9211271aa5dd8c13b232047e6e6aeb5dd22653b4d4588ca4751a54b7e969` | tracked | tracked-modified-product-source |
| `OptiScaler/OptiScaler.vcxproj.filters` | `28ca7cec024121a209345067587dc3e9f20e905d68e24b16e0940016224e273c` | tracked | tracked-modified-product-source |
| `OptiScaler/OptiTypes.cpp` | `2a685951dd7fae314a15ff8c597825b38f6dbf192ca1862640d043a0269f22d0` | tracked | tracked-modified-product-source |
| `OptiScaler/OptiTypes.h` | `9b45ebcd0a797d3baec21897552d28c868a48edb0b998119ef3be66619929ebd` | tracked | tracked-modified-product-source |
| `OptiScaler/OwnedMutex.h` | `d20e8766111d30858c547e5993c1ad683caea46d844412db4721d687d6e8b841` | tracked | tracked-modified-product-source |
| `OptiScaler/Source.def` | `bad88da47286c4c549b479c7384b54ad1f2b4eaac902a25b9f9d0d5fb0700b3e` | tracked | tracked-modified-product-source |
| `OptiScaler/State.h` | `23325ea495c114b233fe38908711879b0a87c35d24c1be5ce6ab8e38acf78653` | tracked | tracked-modified-product-source |
| `OptiScaler/SysUtils.h` | `91b8ac40bcfe5187bcee171a6bdc05787402e9e593e4a90ad9f2af0cc8a0ddf1` | tracked | tracked-modified-product-source |
| `OptiScaler/Util.cpp` | `9f1197192a6d4a6a226dd0334ad8df63d082afaa087a78d6459c419de33906cd` | tracked | tracked-modified-product-source |
| `OptiScaler/Util.h` | `c7d4d93c05b9b900257b3d80aff5b637a544498789aa0058f7e15faa70fea7a9` | tracked | tracked-modified-product-source |
| `OptiScaler/dllmain.cpp` | `395356e584dd8af055efedd52bd2319c1d222b4910873cc60994cabee6b6baa0` | tracked | tracked-modified-product-source |
| `OptiScaler/dllmain.h` | `14b4ac85d4a657d684689556787241075340a0e41977a5960a3c69f3b380e3af` | tracked | tracked-modified-product-source |
| `OptiScaler/dlssnr/DlssNr.h` | `f376c83ddf654f42b79784d4c48fe03a34e7907894c4fdde8056443895fa7f0a` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNrFeature_Dx12.h` | `7d1a4aab0dd87ebfe8f72490b644786267419b05cad172966db256f6f0e4d515` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNrFeature_Vk.cpp` | `a5b695395def6ac64ec838381966dc24f6a9d9e8d5c9e0b7e03ac5f3226d91e4` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNrFeature_Vk.h` | `4991628bcc743c48945e63f08f8af95131272019fd396480eb650ee9ba8a3548` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNrFeature_Vk_Internal.h` | `fa72c78628c67372854cd3a563af9e3d13c7fb3aa670d86b92b6d65df2034322` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNrFeature_Vk_Model.cpp` | `228ec3884fbd557f8ec98d1e94a22d3d12cdabcdf9b1597cb9db03bb5568286a` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNrFeature_Vk_Resources.cpp` | `dbe85da708060231d5af304eed120b45dc4adfab10c845693a4b65535a5ea3b3` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNrFinished_Vk.cpp` | `3cbecb9322814cb7bc97d0b5fa7d228a1437ed4cb78ada1d385037fccdff50ee` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNrFinished_Vk.h` | `17f678e8dee7747c3263857aef2c5d3385134e8edbaa92c07265b0f7ac65b380` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNrPipeline_Vk.h` | `80857e87ccca2eedbbbd9c07ad2aab05206ec48bceb4fee97956009bbe208e60` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_Capture.h` | `3bb5325ed9e58ca40403a08c3a939785a3b884d47f01e0848af88fac28c8c8c7` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_CompatibilityRuntime.cpp` | `116ab57daefe624a12ecba8c329582286a7cb240ac24fb883f8881214c43ee76` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_CompatibilityRuntime.h` | `8477af869a403223e38d3e7d82ab355357c48d49cdb65395d161b60a3a7721b8` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_CompatibilityRuntimePaths.cpp` | `394ff51d55691279fbc86c25ec4414db15e6247786647da491ae31092723a002` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_Exposure.h` | `f5859d885c4d052767d0e3a111122bc7d33f2f8ca24fd4b9dd7f6e98e6fe9ba1` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_FinishedConsumer.h` | `260ffde9ff9bfdf6ec3c03a15f6e34444783c6fab453bdc578aae9a15146af8f` | untracked | required-product-input-untracked |
| `OptiScaler/dlssnr/DlssNr_FinishedPictureBridge_Dx11.h` | `f4e586f9f46c76a8ea5ef062301725d65606274183c988dbba4eb2be17b167b7` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_FinishedReady.h` | `46264abe4ced132c663ca123443048e2e9f90e5dd7a162d35ba27782d94dfd7d` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_GpuLifetime.cpp` | `f861c0acf870a3462fc4bbff6fa9df00333a9a4f1fc1f548878cb055c5053201` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_GpuLifetime.h` | `1771635885bb79de9e54c4567f79f4801fa00eb3005da8ba43f63cf294c45f3a` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_HoldParameters_Dx12.h` | `3993a871e032c6057cabf0fc128ab61912e1cc1920d2d5239a29668dbddceddf` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_Image_Vk.h` | `e9a72253eb831c435dff391b7daacad6a6b40dce2eab0b875e790203f6680fdd` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_Menu.cpp` | `a26944e29da78b4f7252117049917c7d5eb5acbb2f83a4e4328e0473397016dc` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_MenuControls.cpp` | `f1b8f28feb51e7c1de7f5c67b0e5ca95dee562e9561bbf2fd9f963b375a4d52e` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_MenuOverlay.cpp` | `935cc5df3e3019684bd0b8b18c5251f61c89cbc69163b4c0106d14423e125936` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_MenuOverlay.h` | `3ea80379a9617282bc2683ad039982aab8dc6e16f9d60bc8a6cde9d170c83e82` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_MenuSections.h` | `526a6acf9a30eac3a2a24e127db793d616fe6397c5e5a91dbaa84d33a9f9eff5` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_ModelParameters.h` | `696bed1028d92dc129f1fbd25b98a54ffb3439bee9a53633be4b3d66570fdbe5` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_NgxDiagnostics.cpp` | `d2c51bed04a0b84c6c41ec26cbe9d976197e04484534a2ee8267e34afa954975` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_NgxDiagnostics.h` | `8561661bf25b35a806e21ec0a315f5d77cc54ae9a9f059af9d3a3528f5ed3d71` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_PipelineCapture.h` | `231d3b81f8d61f3f632714d147e503ace0dcb4cefc1d92ff210c33d6d6943cfe` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_PipelineUi.h` | `a046756cf5bb0c2ffbfb53ec5b0872f0a141c4e5a390821e3b7fbca39fc9b03b` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_Pipeline_Dx12.cpp` | `64981bfdaee288c183be5193b6af792bf410c84e1d89b01ba35040b70cf09714` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_Pipeline_Dx12.h` | `0fb54c9e28a58f658b0b5229c0d1fbb2463b10db7a00688a6fcf3af801041b91` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_Placement.h` | `7b3af2face186a646d5319e5e624b0358dcfff0972fe9a48c1b963c413e958b9` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_Proxy.cpp` | `55d77b654ab4848d2e41e14583ab3839f9bc1d0eacb8521872fe5effe04ee824` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_Proxy.h` | `37567b789f2cc87c06569ce25c4027bead3746391d4f76df57ca68289aa3ff49` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_Readback.h` | `348d6a781d8210a541f8e5924b021e56f3700efa23ed92e6a338422bf61cc7f3` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_RuntimeImports.h` | `b595a12cfc8b0ff53fbbc8666a66e477d431cd8b2ee642b280ff420fad490889` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_Status.cpp` | `140bfa72bcd92835def1cc2882b48b5b2e9900376d581e18c21261ab29b1f9a6` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_Status.h` | `80fba567068498f4c22d3cc24dc1772b3989df56dfc70f05a9f4a7fb43b9c4ef` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_StreamlinePicture.cpp` | `8185d5028c656e9815569011ae8531e0b8ba65358b38d885ff2265cf551f5237` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_StreamlinePicture.h` | `192afb44adda9296be0038ea89799c0f6bcc6726e44557ef36ec23b1f3850f52` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_Upscaler.h` | `df309722500ae745c04d8ca9e6af0b2aad140d95593e557b1594eadd3a2ee127` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_VkExtensions.h` | `00c206aaeeb7b8b8171e134edca4cb01793b6d2e0e8e79b16c626f08b7753874` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/DlssNr_XeFGHandoff.cpp` | `3015fbde0a85d7ac469cf8381aab1d666af9c31e9d3d24a614596b4a274c5123` | untracked | required-product-input-untracked |
| `OptiScaler/dlssnr/DlssNr_XeFGHandoff.h` | `c54be2e357695027982c8a14f0c4469b9e64dbd107a91d31cf0ae880e573e893` | untracked | required-product-input-untracked |
| `OptiScaler/dlssnr/PassProfiles.h` | `a085f80dd0075b34243fc949ffdb15dfc203e034c6468d84790b34186e026293` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/README.md` | `6ee5a206e1c3c38be6aed2e8f81c3f810842f3137acbb5670a5905d7d7c5e5de` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/design/frame-hold.md` | `8e87ff4c134d5ce129c649ac28de026602dbc27d3047ecf8ae08ecd791cae2ea` | tracked | product-area-untracked |
| `OptiScaler/dlssnr/design/pre-sr-multipass.md` | `28b5f6855238f0aee40edc074bef83da1ec5c6b63b44207fd0802c92bf428e95` | tracked | product-area-untracked |
| `OptiScaler/exports/d3d12.h` | `91e444dce5304dccdc0fb7de01b26eabc71aac30f4b0b25950fae49e4300ac77` | tracked | tracked-modified-product-source |
| `OptiScaler/exports/dbghelp.h` | `5b2b0c0f0917c29aadb13d29e3e31b9955bc967dcf3cd58ffde4f8d4b8aa8db1` | tracked | tracked-modified-product-source |
| `OptiScaler/exports/dxgi.h` | `8397b8ed653908780cd80164cd4d3cbffe9237dddfe263b89711e01b0a895d0b` | tracked | tracked-modified-product-source |
| `OptiScaler/exports/exports.h` | `8b6e1dd4d4eb127d79821f69fecbe247031d6c528cc1c8dd67a250e6a7ef6d9e` | tracked | tracked-modified-product-source |
| `OptiScaler/exports/shared.h` | `8adb75b90256e71023ade09726c19f9b104641ba6c353e289aaf6f38c6fa7b01` | tracked | tracked-modified-product-source |
| `OptiScaler/exports/version.h` | `c7508cc4823e3dc5d096c478c898a3c6fb02ac544598babc0db21c5a6a6bbac4` | tracked | tracked-modified-product-source |
| `OptiScaler/exports/winhttp.h` | `b84806df6afe7772dd2a4e6b090d6b1bd995042d724de14705f03b04022d80cc` | tracked | tracked-modified-product-source |
| `OptiScaler/exports/wininet.h` | `6ab050dab292c842d99d71fcb13ecfdd2303893e7392f8863e5fffe49debc2bd` | tracked | tracked-modified-product-source |
| `OptiScaler/exports/winmm.h` | `3b1282068b9f130fd567145713c9ee7042f25733301cde7a0e8f34e6b1a5dc94` | tracked | tracked-modified-product-source |
| `OptiScaler/framegen/IFGFeature.cpp` | `f801bbd4c68f39ac1f269803653c839be9db0608b54f3c016bec8192fc042565` | tracked | tracked-modified-product-source |
| `OptiScaler/framegen/IFGFeature.h` | `6c291cd30e4d3af4fe016b4c4aa97de90e4aad11d808e011a346e4eac12f737c` | tracked | tracked-modified-product-source |
| `OptiScaler/framegen/IFGFeature_Dx12.cpp` | `ea5fca0e1b168ed266a4ae3520d6007234e1b8e7e5517a52e9b60859fae39af5` | tracked | tracked-modified-product-source |
| `OptiScaler/framegen/IFGFeature_Dx12.h` | `fb923eb0d37350598e429702794b0cf9de1e6b197a7558c125c6e3007deebf14` | tracked | tracked-modified-product-source |
| `OptiScaler/framegen/dlssg/AmpereMfgLoader.cpp` | `17912d6df86077b174712e8c5387ce33e4f1ff600a6f4dbd2a435e2b3a5f458b` | untracked | rtx40mfg-flavour-source-vcxproj-OptiScalerRtx40Mfg-included-callsites-Arm-LastStatus |
| `OptiScaler/framegen/dlssg/AmpereMfgLoader.h` | `eea55c8eb1fe52eb07f7120ef900d6e09ab443a04a3edcf621f096ec2a749f69` | untracked | rtx40mfg-flavour-header-vcxproj-ClInclude-callsites-Arm-LastStatus |
| `OptiScaler/framegen/dlssg/DLSSG_Dx12.cpp` | `000ee9b800d297986f4c84a01a720b61502d7a064035ae887efd78af617a5fa6` | tracked | tracked-modified-product-source |
| `OptiScaler/framegen/dlssg/DLSSG_Dx12.h` | `0a21885351309a66d7f1b3d75715262f6712de27f27a97ffa470838ef17813e3` | tracked | tracked-modified-product-source |
| `OptiScaler/framegen/dlssg/Kcd2Hdr.cpp` | `e498dcf3c0f8ce40e4ebba73633913439127e0b95bc26d3ceacc3af0a94e54e2` | tracked | tracked-modified-product-source |
| `OptiScaler/framegen/dlssg/Kcd2Hdr.h` | `033721fd672f7fafb07a978667377ac25fceac47f4e64911ee1074841a3ea15b` | tracked | tracked-modified-product-source |
| `OptiScaler/framegen/dlssg/MfgUnlock.cpp` | `8d9b104b52b76a10db2c5be451fb9170f7876f709932c7be293fdb5730661287` | tracked | tracked-modified-product-source |
| `OptiScaler/framegen/dlssg/MfgUnlock.h` | `117a990ea2c071e0931bfd6078541dcf032f7e207ee306faf3e9c5b51ebedf3f` | tracked | tracked-modified-product-source |
| `OptiScaler/framegen/dlssg/MfgUnlockFlip.h` | `4ae9437444d639ac76ca027727f5654f84b7d79b25ffc51a62ad01aac830e021` | tracked | tracked-modified-product-source |
| `OptiScaler/framegen/dlssg/MfgUnlockMethod.h` | `3899a79831f974527b36c5cfb590ced78408551da4e88d94a792f58a0d0f0c57` | tracked | tracked-modified-product-source |
| `OptiScaler/framegen/dlssg/MfgUnlockPlugin.h` | `168ba982ddb5b75494e49aa9e375ffec446d8d7e0f6a2af1d99b8d59bcd5c537` | tracked | tracked-modified-product-source |
| `OptiScaler/framegen/dlssg/MfgUnlockProvider.h` | `be7e770e8264b2752d8a899ef6dc3447c276daa6b0832ce5c8bfe3adb7d1b2eb` | tracked | tracked-modified-product-source |
| `OptiScaler/framegen/dlssg/MfgUnlockPtx.h` | `69c1ec0785291b41d6a934600e98583f42040fd15fa17695aa03823c2b5b70e4` | tracked | tracked-modified-product-source |
| `OptiScaler/framegen/ffx/FSRFG_Dx12.cpp` | `078b57312ed4d373896b25121e0483d637e521481c6a18da8c43d1acb7c5e722` | tracked | tracked-modified-product-source |
| `OptiScaler/framegen/ffx/FSRFG_Dx12.h` | `00483694c34b3df5a1e71bc334a2751f683df4aae39fd596ee1488b980db3573` | tracked | tracked-modified-product-source |
| `OptiScaler/framegen/nvngx/IFGNvngx.h` | `f5543313c94786856021c09f0c85089d5d8c0ebd494e2a1e66d5a07d5fb1d3bf` | tracked | tracked-modified-product-source |
| `OptiScaler/framegen/nvngx/Nvngx_Arturs.cpp` | `081fb95f8d392f5728998f262c87ed8a2aa4e8248a8c5c85d4e230ca540777b8` | tracked | tracked-modified-product-source |
| `OptiScaler/framegen/nvngx/Nvngx_Arturs.h` | `d79e1661c49862f5a5a9c982130b7882c84b09956a135806399eab0501948fc0` | tracked | tracked-modified-product-source |
| `OptiScaler/framegen/nvngx/Nvngx_Combo.cpp` | `93359a5e2a47deaee40f2aedeecaab1464a779c8af746b14040f8d62de588870` | tracked | tracked-modified-product-source |
| `OptiScaler/framegen/nvngx/Nvngx_Combo.h` | `b320f1351db693a860ce4c885498b044e31c452539ca7c2e07874797c2d16da4` | tracked | tracked-modified-product-source |
| `OptiScaler/framegen/nvngx/Nvngx_DllProxy.cpp` | `8cc3c2f7ac4af928f1a290f56c59dbcfcf37960f770a2c73387682229b7e1a4c` | tracked | tracked-modified-product-source |
| `OptiScaler/framegen/nvngx/Nvngx_DllProxy.h` | `82bb19a9a2e5d4cd812c2839052a06d771b3f6c7a7088414d9dbc68ff83569d8` | tracked | tracked-modified-product-source |
| `OptiScaler/framegen/nvngx/Nvngx_FFX.cpp` | `5b808d45245682078c3ef9e8d78f0246d5f6e930a2ce47260f0166ea3cb0373d` | tracked | tracked-modified-product-source |
| `OptiScaler/framegen/nvngx/Nvngx_FFX.h` | `b5b563245d954696ad5675f73a1bcf5206155f46b008c2e0ab218eb14de613fd` | tracked | tracked-modified-product-source |
| `OptiScaler/framegen/nvngx/Nvngx_FG.cpp` | `012305bb7c61617cb699627ba9cb5a7e84e7f8392c11176ab043b4b84c8d09bd` | tracked | tracked-modified-product-source |
| `OptiScaler/framegen/nvngx/Nvngx_FG.h` | `7914984258d3b2d5dd6533b3c0cf69a11a1e6a7fca547c63011b7355e3032292` | tracked | tracked-modified-product-source |
| `OptiScaler/framegen/nvngx/Nvngx_Nukems.cpp` | `9a163f5f9457ece3712db04b9c8fc27b26beb1ac1ca3cc7a2c7a99d1b54e7e26` | tracked | tracked-modified-product-source |
| `OptiScaler/framegen/nvngx/Nvngx_Nukems.h` | `47ad5e998477ba25c960ea78fbc094a2a782332e1ecff2c84931b747b93a56e6` | tracked | tracked-modified-product-source |
| `OptiScaler/framegen/xefg/XeFG_Dx12.cpp` | `fbe724c351294a11a60ad1bd831d3c579e5f2d22884b0b1b019e117842c25a97` | tracked | tracked-modified-product-source |
| `OptiScaler/framegen/xefg/XeFG_Dx12.h` | `4fe402422d22b054bc83ecd1de0eefc8c46b1a9f4b31b9935682b06f5ba70b37` | tracked | tracked-modified-product-source |
| `OptiScaler/fsr4/FSR4ModelSelection.cpp` | `1979465ff9cdb0768cbf512ed018f23810461779d780f5daa74c8e0aa7744f33` | tracked | tracked-modified-product-source |
| `OptiScaler/fsr4/FSR4ModelSelection.h` | `3c89ac7317aac5ab37e91b4b2da73df54da90e3a9a2a1e4bf5f180ce552449f9` | tracked | tracked-modified-product-source |
| `OptiScaler/fsr4/FSR4Upgrade.cpp` | `505ab579c89f499404bb92dc304992d9dfadda0c145d5c9a4943225e152325b6` | tracked | tracked-modified-product-source |
| `OptiScaler/fsr4/FSR4Upgrade.h` | `e67097d633b4728ff353103a9f06fcad7760f6ffcc39f55294a382d1060c32e4` | tracked | tracked-modified-product-source |
| `OptiScaler/gpu_time/GpuTime_Dx11.cpp` | `e65a9d6cecd2ca833e0f47e8930de075c22af232b798d763f9ded0e3f92e9208` | tracked | tracked-modified-product-source |
| `OptiScaler/gpu_time/GpuTime_Dx11.h` | `23940da1902458c49deaf13de015e7e3121bfd71455e64bbaf40a1108103dda9` | tracked | tracked-modified-product-source |
| `OptiScaler/gpu_time/GpuTime_Dx12.cpp` | `d638478d8787ea2fcd14bb88578486838095b89242c3ca7d39ffbbf16c2e13eb` | tracked | tracked-modified-product-source |
| `OptiScaler/gpu_time/GpuTime_Dx12.h` | `0858997b4ee460af5d94a9b773f8ee83ae987e646583eed6bb9afeefee9f2ca9` | tracked | tracked-modified-product-source |
| `OptiScaler/gpu_time/Vitals.h` | `33a75462ebb2bd2d27bb3f14dbbbaf0f12a09ad3dd842175d88fbea50337b06e` | tracked | tracked-modified-product-source |
| `OptiScaler/hooks/Advapi32_Hooks.h` | `e89cb08be756eb70d23c219055c9c69b93b893270d7e2f116c1d3a2b81f9365e` | tracked | product-area-untracked |
| `OptiScaler/hooks/Amdxc64_Hooks.cpp` | `cef1f1fad68bada8bd78fc929449e095ac5dc7d0ad794e1c5bf1411e435056e8` | tracked | product-area-untracked |
| `OptiScaler/hooks/Amdxc64_Hooks.h` | `33e8ebd15dddc51166dff80977c66e5f10513761d8a47012c7a404aacf874d9a` | tracked | product-area-untracked |
| `OptiScaler/hooks/CommandBuffer_StateTracker.h` | `e3364e261ecab2d8173fa11ecb7f48ccd831b1d8365c04acb190c7f60b65caa0` | tracked | product-area-untracked |
| `OptiScaler/hooks/Crypt32_Hooks.h` | `c0cde2eb1dcac58eeb8d2d5014b46dd4fd0fddd1bc9959c50883ac30e9a6b3fa` | tracked | product-area-untracked |
| `OptiScaler/hooks/D3D11_Hooks.cpp` | `049d1458daa7448e59131dc7140d81215d1a723732e9c15fa03efa9491daa8d6` | tracked | product-area-untracked |
| `OptiScaler/hooks/D3D11_Hooks.h` | `2571e9757c38281928b671863321a3002512dd845f84a0fb7553c5aee6c83b01` | tracked | product-area-untracked |
| `OptiScaler/hooks/D3D12_Hooks.cpp` | `4979ae82037e8b01c96e3a5475abd7a37c07b97bdd0ad9574a2e44f1f96eb997` | tracked | product-area-untracked |
| `OptiScaler/hooks/D3D12_Hooks.h` | `06758a341aaf2744a2abf1cf43b72a605731c61c5eb396f7896d9fe966bb2f87` | tracked | product-area-untracked |
| `OptiScaler/hooks/DxgiFactory_Hooks.cpp` | `d7a88465fabe3d00399c4cc3144861da5a90c89dcd8ed8903d4ceddca9f45330` | tracked | product-area-untracked |
| `OptiScaler/hooks/DxgiFactory_Hooks.h` | `98464efd248d017a18efcea95da0f808edb2bee501b6eb042370051505668cc9` | tracked | product-area-untracked |
| `OptiScaler/hooks/DxgiFactory_WrappedCalls.cpp` | `1f85ae80f5cd88f87387eb66fd059e134acc03d90e19fbc4354b5214677c53c8` | tracked | product-area-untracked |
| `OptiScaler/hooks/DxgiFactory_WrappedCalls.h` | `f0c037b964e3d552e8390f9bed2bad96f3b7be35901119202e49a0d1c31441e4` | tracked | product-area-untracked |
| `OptiScaler/hooks/DxgiSwapchainSizing.h` | `b0ffb8ef40efed5c9834ba89f927eed2f47db0449f1500971c2b153376b6e7f5` | tracked | product-area-untracked |
| `OptiScaler/hooks/Dxgi_Hooks.cpp` | `9c1ccf0e5c668518c5b7dd9ec9f5c7c9fd44e507bb144abf98a5857e15e3c86c` | tracked | product-area-untracked |
| `OptiScaler/hooks/Dxgi_Hooks.h` | `583b189ac6bd0b61c87d828ec3f8cb31770bd6becffa5246f8d8d9a09907e184` | tracked | product-area-untracked |
| `OptiScaler/hooks/FG_Hooks.cpp` | `38312e9d434102d4a93a4e08b5d25dab33a310fa09ac2ed8eab42432d0b09db3` | tracked | product-area-untracked |
| `OptiScaler/hooks/FG_Hooks.h` | `f908f65711d94b8cd445358127ee626fa6c9923cfdf3c978bdfa4c218dbcb56e` | tracked | product-area-untracked |
| `OptiScaler/hooks/Gdi32_Hooks.h` | `39b126bc54f452a97989a823f1b3912351ef5d1738a5995bfe6b07e9c19a09ae` | tracked | product-area-untracked |
| `OptiScaler/hooks/Hook_Utils.h` | `4ffb2600828b1ddc3fc82d80d8dfc23bac19e156079c310b215efbb0351174a5` | tracked | product-area-untracked |
| `OptiScaler/hooks/Kernel_Hooks.cpp` | `fe82a7ba3aab05f6112e6fa80df481a1485d45f6ee50d750462edfe9b1ed820b` | tracked | product-area-untracked |
| `OptiScaler/hooks/Kernel_Hooks.h` | `a68f1187208d011f01b32cb39e8a5072c1b6c5e5eb6dceb11cbddb92a5a352d7` | tracked | product-area-untracked |
| `OptiScaler/hooks/LibraryLoad_Hooks.cpp` | `4ea977110ee4704fb422e8ac0fa3a52ac1537db6e9a794c7363f91c0446d0781` | tracked | product-area-untracked |
| `OptiScaler/hooks/LibraryLoad_Hooks.h` | `3475a9429b63375d306be008f435a2767a65c22aa2bb5f2adecb10d91e8fab5c` | tracked | product-area-untracked |
| `OptiScaler/hooks/Ntdll_Hooks.h` | `c8ddbd39cd2c3e4a7eee16c4b6bed590ad95a3c7fe9dc02fa49ad1d6b0d43a59` | tracked | product-area-untracked |
| `OptiScaler/hooks/Reflex_Hooks.cpp` | `30fe48def9777a0423051fa67244e66c193b44027cf3e9e04f3165809fa6dc00` | tracked | product-area-untracked |
| `OptiScaler/hooks/Reflex_Hooks.h` | `51a96a73879ec04d2ed2eca3085fe3e8a51066cbe12a27265cb37d2c878807e9` | tracked | product-area-untracked |
| `OptiScaler/hooks/SlPairDetours.h` | `3632d5900dbd6e82e96dfc931a669c3777bc25e797e1cbdf55eab83feb416aa5` | untracked | required-product-input-untracked |
| `OptiScaler/hooks/Streamline_Hooks.cpp` | `9c75933554b7066bc751c5b66cd5ae1e368f19a3931af48380a26c0ccd773bab` | tracked | product-area-untracked |
| `OptiScaler/hooks/Streamline_Hooks.h` | `8d76f13fc3552ee551079f30a6b791c4c4c763b6fd5b1c4f4968320017f3bda3` | tracked | product-area-untracked |
| `OptiScaler/hooks/Vulkan_Hooks.cpp` | `123438d52f5d30b56880ebc0511befd543125894fba85dc7aaedeea68a89c5be` | tracked | product-area-untracked |
| `OptiScaler/hooks/Vulkan_Hooks.h` | `fa1e1a8dfacb7ee1d8d68124180f6773fa7da79c8d8a310e14b0d7455ed3ea56` | tracked | product-area-untracked |
| `OptiScaler/hooks/VulkanwDx12_Hooks.cpp` | `643f6990906a85ae9004bc706f8690242fb2a6d57a73eb2b88e532e303ebe8fe` | tracked | product-area-untracked |
| `OptiScaler/hooks/VulkanwDx12_Hooks.h` | `8d53696280a4b080a42562bd4be5a8280f25f4415dffe7ec9bd156cf17a883ad` | tracked | product-area-untracked |
| `OptiScaler/hooks/Wintrust_Hooks.h` | `3c71e9f673d45656431811ebb1e67c12f69a4511b5286a96ca2dc942f6c55f38` | tracked | product-area-untracked |
| `OptiScaler/hooks/Xell_Hooks.cpp` | `beccf9739e069b108b640650084431e489ea664a74aaa732e30e02a27321af95` | tracked | product-area-untracked |
| `OptiScaler/hooks/Xell_Hooks.h` | `1c9a7c1b4d2f4d4346ccd8716a701b0fed3b1dc9378a2b53f70389979738d949` | tracked | product-area-untracked |
| `OptiScaler/hudfix/Hudfix_Dx11.cpp` | `ff1d02bf2e351777abeaad23ffb89377d62ed39749eea402700a5f05311b2871` | tracked | tracked-modified-product-source |
| `OptiScaler/hudfix/Hudfix_Dx11.h` | `5ef5b3842581ff40945455b79f283d97144122324fe01dbccf52b13e7f6dada6` | tracked | tracked-modified-product-source |
| `OptiScaler/hudfix/Hudfix_Dx12.cpp` | `888f9b7566c1312003b77a403b103985aacbcbd0c257678da35b6ccbfbb4022e` | tracked | tracked-modified-product-source |
| `OptiScaler/hudfix/Hudfix_Dx12.h` | `e8c827ace5aa453386b317c12938d8e7b4a8ea363208f5b2733598233d94a05b` | tracked | tracked-modified-product-source |
| `OptiScaler/include/d3dx/D3DX11.h` | `187e39e025297a6e74d5e1b4fb4884203d40c18e68c3c244cf34ff461ba3bc59` | tracked | tracked-modified-product-source |
| `OptiScaler/include/d3dx/D3DX11async.h` | `cc9da11454cd86d0235d02e3f35bd9cd03c582f21cd13e20fb1397c0b0e262c1` | tracked | tracked-modified-product-source |
| `OptiScaler/include/d3dx/D3DX11core.h` | `356921cd7c423e3450aa5b666c0fd9535b309bfb6bb75dd8dea750c4fe471c11` | tracked | tracked-modified-product-source |
| `OptiScaler/include/d3dx/D3DX11tex.h` | `2e282b3a7a9daf8db6df6b4afe864b109bbf2c24eea2244277e16b499bb5aecb` | tracked | tracked-modified-product-source |
| `OptiScaler/include/d3dx/d3dx12.h` | `6d6dd341ee7e1ea38074a50e37ace24c5bab5a4aa0981e3ff5f76a17519c8f1b` | tracked | tracked-modified-product-source |
| `OptiScaler/include/detours/detours.h` | `4aaa48661bf48c5ffb9433d38b654bc228e5378edc314d3931a7ee7411a213b9` | tracked | tracked-modified-product-source |
| `OptiScaler/include/detours/detver.h` | `23262b7ec42d5a1dc17576c86da532dc478f464694bec6e32c1d1b112d4a3f45` | tracked | tracked-modified-product-source |
| `OptiScaler/include/device_info/device_info.cpp` | `b774e419301f924e4a796d842e8ac0d0d32d20a665b6d53c08f51960570ec795` | tracked | tracked-modified-product-source |
| `OptiScaler/include/device_info/device_info.hpp` | `28cb93c0544cc68eefd98abbd2f46d5e98afb7537112ef641a23058d6b78516f` | tracked | tracked-modified-product-source |
| `OptiScaler/include/flag-set-cpp/flag_set.hpp` | `c9957ea2d6d098181a657cad654333102b41cc332d5e3ac1f946d262128c1157` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr2/dx11/ffx_fsr2_dx11.h` | `6ba3930f663f961d6cb1b4904debe61486ada14053b0fee592197a6e4c55f94e` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr2/dx11/shaders/ffx_fsr2_shaders_dx11.h` | `f5d3717221956fee07dc81d54c1bcfb2b606c7f8af15e209c706a9b713c8c791` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr2/dx12/ffx_fsr2_dx12.h` | `97f7bebab507f8dec0614654b1e9c3077ed76c8b790c6a6bc72ca03e9ef54023` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr2/dx12/shaders/ffx_fsr2_shaders_dx12.h` | `80d2f18dd88eedb9337145811db79eb731db1c928e4fc2989d5eb768c5fc4bc8` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr2/ffx_assert.h` | `06fe1c23fb1a4412e18b56f547c973a93aa428d9fd55021055cc353b33775219` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr2/ffx_error.h` | `27c12280f75ca6ffc23904c92d630b4c7baec340f3c05c50e8dca885b58752f8` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr2/ffx_fsr2.h` | `de5b82d009eaf5028be34e55b809358e0dedb789a74ab39da71d3cedd6b596dd` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr2/ffx_fsr2_interface.h` | `322ea5425470ba18766d1dec8b2e475fb6c12eabe50b432c353ecb940046b769` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr2/ffx_types.h` | `e85c0f803d3e4d250e90f7551aaebbc4ef0e5e015ec927405cb9570c33eb4123` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr2/ffx_util.h` | `caf49e186794cf7bedb1edc93b1de47d52911b45896b27f1433475b0aa4b3456` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr2/shaders/ffx_fsr2_common.h` | `5f4ada0de77add19225a3dee7581557f26347a5b1e77ede8e230cd9c7acacf1c` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr2/shaders/ffx_fsr2_resources.h` | `6516e71b817a6a1ef597110883e7115233542b89ff78f2a736835ab3d61c7edc` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr2/vk/ffx_fsr2_vk.h` | `4e5e289f4954da1ec75395e867dc0391feba6086abfa28f2bafe34166a4a7ae8` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr2/vk/shaders/ffx_fsr2_shaders_vk.h` | `7ff52024424ac1935d71396de628cdcb7ea998aee94be4b234886832603a4327` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr2_212/dx12/ffx_fsr2_dx12.h` | `a2abd2480cab8b74963686475df58a38fac4cf7a6b0d5a3c5d0165fac8641014` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr2_212/dx12/shaders/ffx_fsr2_shaders_dx12.h` | `ec97174b96b196208c8a75c6c251036f86607fda92fe522db3c41bfcad4a82c1` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr2_212/ffx_assert.h` | `af694c269b9efd58119648866ac0819a183472bd5b1dbdd705547e32948ada17` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr2_212/ffx_error.h` | `90e435d63b1cbfa2ff1ed5b900b9d9b44a99f48f6fe4359141a2065e80dd1cf4` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr2_212/ffx_fsr2.h` | `1d3edac4de3f2960381bb6c05ea622ee26f68d3b1b2a20be31f5541295af13dc` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr2_212/ffx_fsr2_interface.h` | `11e8858200995fd7e3194d116af2b46c9c590da364b48f64495e53650dacc3fe` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr2_212/ffx_types.h` | `e94915086b66210af336283bc4e6d2bf96c947ed3fcb55f9ebe262e5e50ead6d` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr2_212/ffx_util.h` | `7914b38726bf69a3922618cfca24df80ec02fffb53552ec16b7143f2ec9176e2` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr2_212/shaders/ffx_fsr2_common.h` | `901aa495e9ae2467f6695f1e53fc0b94cb4f18fdd16c9620faa7b68d6f1a81a6` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr2_212/shaders/ffx_fsr2_resources.h` | `38afc68507fdae3c3769aec4edb471fd8ba57f530350ccd313cfce244a70116d` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr2_212/vk/ffx_fsr2_vk.h` | `0649d65fc335bc6ba4f4f1741c8c6477b4cc0b691fd64ecadab95a11c3f35b65` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr2_212/vk/shaders/ffx_fsr2_shaders_vk.h` | `3ec47824ba6e3c83e0028e45bec85c1db5ce0b6886b279d4f6f794cae7ec269d` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr3/dx12/ffx_dx12.h` | `e7151b54b0fdd21c67b46927859caf7e93114f112e8b7293d4cc3ab831b7fce9` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr3/ffx_assert.h` | `fff88fc8fffeb5ab1dc023f80cf90453c96aec755c27231b41f6173529c45e83` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr3/ffx_error.h` | `f779766b3c497ddf42cff9a1d1313b4e286cf4cc2bf29fceb62434218250cf80` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr3/ffx_frameinterpolation.h` | `586737dbf963084d8aec3a5a325fe8f673fdbaa89280de0d98a0dad3a39c9210` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr3/ffx_fsr3.h` | `a5bc3e695565cf112ead62877876f1c6e1b73e2c2449e57e67e2d27927d3b122` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr3/ffx_fsr3upscaler.h` | `e28c91a6ea8e9a5e5fd35c2c230586ee4a5b0f00737cd5937a20e06d58232270` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr3/ffx_fsr3upscaler_resources.h` | `0948d59c7986339c79a1d7084dd41f8b09d3556128b114f8fa41a18e3547090c` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr3/ffx_interface.h` | `3285d0146896285ff896f5e467302b916779248610c2f32c46e07f0a363493d1` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr3/ffx_opticalflow.h` | `f521a1f71eddcf43e8f99a5854d9e9e96d7c14643096621edf16b79fdddb6e51` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr3/ffx_types.h` | `db2fbeb9f9c8ab12666dd134030358d36a42d6e921aee2d00a8f810c7c8d91d8` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr3/ffx_util.h` | `6f358ca7cf8814d5957b605ea056e8dabedec4995c0cf166a76c2dbc2f7e98f4` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr31/dx11/ffx_dx11.h` | `f954e51c5449566c19d6e8e8a9ae82dd7cae5a183f24a17773af1c0c78390dfe` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr31/ffx_assert.h` | `d6a65489d4348ede57efee01ad66328d86ba29fbbad057b78ed848861f4b964d` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr31/ffx_error.h` | `269ccd0e08bb3bacf1f6a46bdd71e4534657013fea60d563374b7c0dc2afabc3` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr31/ffx_frameinterpolation.h` | `f0d58b244eeaea8398825c0ccbbb01bc587e729d17f69a645b9cd84074566e4d` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr31/ffx_fsr3.h` | `40dcfdaa4e9c79a293d39c650c27cdc8a0b13557be9d5cb565f54613128eb5b4` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr31/ffx_fsr3upscaler.h` | `677a1b288be3780c26de67b38eecc1f08d8aea2fef08dc397688d445cafc4b16` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr31/ffx_interface.h` | `d539627227d60fa446770ef99a087f0f9614c0b5a6fe44741b96babb3115fdc6` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr31/ffx_opticalflow.h` | `df6786147b56c6d797fcd715170d9daf0b1a5ba7f5e0b8db6c8d81b81b3fb228` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr31/ffx_types.h` | `3874d5fc328f5b8b924b3451fec3521493736978e08b0115e4bc5d050aee1557` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr31/ffx_util.h` | `929689f264e279f75ad4d362c626b8e0693630c689bbea018eab518eb46424ac` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr31/shaders/ffx_fsr3upscaler_common.h` | `d6c320dd0c6cd329636adec8ac5b1cb94493c4ac348da7d4b15b60e4b075fbbe` | tracked | tracked-modified-product-source |
| `OptiScaler/include/fsr31/shaders/ffx_fsr3upscaler_resources.h` | `d172e0f265660163aec6702c7a277aa2084067a37e12528f4ed7345761edd40f` | tracked | tracked-modified-product-source |
| `OptiScaler/include/imgui/ImGuiNotify.hpp` | `00e38751b054bcdcf71047005d5a29b05f5584b13969cc7c9e2dbd83a867c5dd` | tracked | tracked-modified-product-source |
| `OptiScaler/include/imgui/LICENSE.txt` | `55e058cc5899e6077a819ad1005d6d1f4528f65ae100795c9692f9fa6525a8ce` | tracked | tracked-modified-product-source |
| `OptiScaler/include/imgui/imconfig.h` | `5767ee654b661e77e72cb059a8d341c9741f1be2488f3eef4fa48d2529c0f297` | tracked | tracked-modified-product-source |
| `OptiScaler/include/imgui/imgui.cpp` | `321015cca583a4b5c13cfc88f852b721b33d14528fc95dba4fbead5af6d2ecd9` | tracked | tracked-modified-product-source |
| `OptiScaler/include/imgui/imgui.h` | `9d442811967f8d6c6b7066c5d47076821c25cebd1d481466daa15b490d35fb51` | tracked | tracked-modified-product-source |
| `OptiScaler/include/imgui/imgui_demo.cpp` | `d2b97a2d307ee1d6770ef259821a6c78a0ae2582b24e2da43f6d65fb69bca0f2` | tracked | tracked-modified-product-source |
| `OptiScaler/include/imgui/imgui_draw.cpp` | `6668f6fd00022d109d7c46f3d3ef071325105b789e5b780379647f8d10506330` | tracked | tracked-modified-product-source |
| `OptiScaler/include/imgui/imgui_impl_dx11.cpp` | `234fe1990c02f09bc64ca00cdcc18c37e489bc6e1fd0e44c8d1160c58fc48b3b` | tracked | tracked-modified-product-source |
| `OptiScaler/include/imgui/imgui_impl_dx11.h` | `49d19cec3c2d7ad91ad81043f5e864b46631c5008dd35841bdb7b302dfc2f4bb` | tracked | tracked-modified-product-source |
| `OptiScaler/include/imgui/imgui_impl_dx12.cpp` | `af8ae2a024650604a7bf47c635747a96b500a5926e44a3a33b1741564835bafd` | tracked | tracked-modified-product-source |
| `OptiScaler/include/imgui/imgui_impl_dx12.h` | `134a80081790a69f425a675c35439c61c77ffe7da89da1225ebf9b5032577c2f` | tracked | tracked-modified-product-source |
| `OptiScaler/include/imgui/imgui_impl_uwp.cpp` | `3003246b4f7a5fb75558569d7fe123161961b4735a628f3b7487a9c13717234f` | tracked | tracked-modified-product-source |
| `OptiScaler/include/imgui/imgui_impl_uwp.h` | `dbd8482e437fb34b0b18d3398c3781d64e27e99ca210c979b0ff16940ab614c7` | tracked | tracked-modified-product-source |
| `OptiScaler/include/imgui/imgui_impl_vulkan.cpp` | `bdf408a905f237d2de586cfa2b7931154f7d15e28d839fc0ebebf774a2b51125` | tracked | tracked-modified-product-source |
| `OptiScaler/include/imgui/imgui_impl_vulkan.h` | `5ee5597f9ea9c7fa7e0557f9cf69516a183d28c0c82683537476f6be296b2e18` | tracked | tracked-modified-product-source |
| `OptiScaler/include/imgui/imgui_impl_win32.cpp` | `dcd904ed3b346fc76b0cc3aa5cbd182511b63809d76f6fcf0013917263c5f8b0` | tracked | tracked-modified-product-source |
| `OptiScaler/include/imgui/imgui_impl_win32.h` | `d71cfdba658c65eadf90c47cd2b73f023674a57e4adb577636d35002fe00aa9a` | tracked | tracked-modified-product-source |
| `OptiScaler/include/imgui/imgui_internal.h` | `536b9cc34b06da4db70ab2fa4e193cee8a05d0e980306b685f00216ad54239d4` | tracked | tracked-modified-product-source |
| `OptiScaler/include/imgui/imgui_tables.cpp` | `4e6412ac81f962406cb1fef7bdb0e7221e5f24b84ae9aa2f6c9b3ac97e138f11` | tracked | tracked-modified-product-source |
| `OptiScaler/include/imgui/imgui_widgets.cpp` | `e69dd2c655c006eed7bd1050191920c87747adad3c171253dca44be55e03edc2` | tracked | tracked-modified-product-source |
| `OptiScaler/include/imgui/imstb_rectpack.h` | `bb53504995e983d54b1ae06ea727f0b39647e5e205b4bf7da01343953974951c` | tracked | tracked-modified-product-source |
| `OptiScaler/include/imgui/imstb_textedit.h` | `f6ef71b6c94225d8ec554eb63ea6ae60551377a9b9328df0bc522a215b8523ea` | tracked | tracked-modified-product-source |
| `OptiScaler/include/imgui/imstb_truetype.h` | `941a95c9f36771aab45062e977596785aa9cfaa508a523f6c34ace84b5916780` | tracked | tracked-modified-product-source |
| `OptiScaler/include/imgui/misc/freetype/imgui_freetype.cpp` | `21fced20aa04e3cd35626fdc9718971bafa9fcf973e19faa80d004e88341544a` | tracked | tracked-modified-product-source |
| `OptiScaler/include/imgui/misc/freetype/imgui_freetype.h` | `5adef13011fc366a4a41786e793b4f26e356c8b3cbefd8827a26521a5675a445` | tracked | tracked-modified-product-source |
| `OptiScaler/include/sha1/sha1.hpp` | `f7f644d6dc6ba5d211fc113f89471ecda1649cf0c3b5fde9efde8d15a786bdb8` | tracked | tracked-modified-product-source |
| `OptiScaler/include/sl.param/parameters.cpp` | `4d1b1462b7aac6fd8d34c550967b70027cf43a942fb90875d6c8ced6b2d551a2` | tracked | tracked-modified-product-source |
| `OptiScaler/include/sl.param/parameters.h` | `3dbb66cb7cdce2de5044e21f09e99885131ec0c80c61c9af3b5adca067476c1c` | tracked | tracked-modified-product-source |
| `OptiScaler/include/spdlog_sink/debug_sink.h` | `fa65c630947a69ca567ed929151c0f199cb5d3e94a14898ed263aa6824d38f84` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/FG/FSR3_Dx12_FG.cpp` | `8ed2f1471775b5ca47af70726b4c103424326577053157101b6e50c0941c0113` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/FG/FSR3_Dx12_FG.h` | `b16cd75bba11e23449ae455fa14e533f3da27c2959381ce124b86257820347a0` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/FG/FfxApi_Dx12_FG.cpp` | `d96d36ebc0453f07382e0ec0db9000bc0c0c61f7dcb9b452fafe788c4d3f5b55` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/FG/FfxApi_Dx12_FG.h` | `7a60c9c3ca70a451af05f2846b3c276d960b1ded8f707ea67e6ea12d7a3f3482` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/FG/Streamline_Inputs_Dx12.cpp` | `d80da613d80496eec1674ee779ab428ad6562228513b22f007bfd9ee1b9bd06f` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/FG/Streamline_Inputs_Dx12.h` | `28fe78d072f63b662e62386517d239b56c4a79065c0982e97af8a485556d5d5a` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/FG/Streamline_Inputs_Sl1_Dx12.cpp` | `66e83694ea5f1a77e1ecef194196bb86d263154114780ea5b41da9c1f0433fcf` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/FG/Streamline_Inputs_Sl1_Dx12.h` | `1c5544331650d9422974f5c7c6728588344a5646b8c72b36db09af8eeb47642b` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/FG/Upscaler_Inputs_Dx11wDx12.cpp` | `f5602c5c8005f6c6d433923d556cdeb4a573edb54a50d7f19dd5212b796b20ec` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/FG/Upscaler_Inputs_Dx11wDx12.h` | `5ea822ce0a2d9ebc154a1f34cecf86f661f9735a9111f2739ca56b91df94cd61` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/FG/Upscaler_Inputs_Dx12.cpp` | `6048bd8a5ef458a07a79bace62b30d31deca5d810de6f25bb845b557c2049463` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/FG/Upscaler_Inputs_Dx12.h` | `48198603444e6e74bd6419ffb9443b15bc0143e11c7311e1e99f457958c44a2e` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/FSR2_Dx11.cpp` | `b440f7fa8c7f422466294172825f423d8c1e002b75e5824f795a69748c78ad18` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/FSR2_Dx11.h` | `2f99b14d61c01566f75aa8e6d50a8428d5b168e6f1f681f7e6e5c2c038d40f0e` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/FSR2_Dx12.cpp` | `246c4ae1c4ee757a43d792296b4feb95eb90758b1927356749bf578cbd6adf53` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/FSR2_Dx12.h` | `c46c86e99b162bc91fba19258fa792bcfe8df16cac7c256217b165aa04b42bf5` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/FSR2_Vk.cpp` | `1ec9f2b70326e32b3948d0b7955ea391335436437aa85e38e0806f8f8a07f91b` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/FSR2_Vk.h` | `a0d1c111e1e66f738096475f72c52acebfaeabd846c44096579360ec87e0589d` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/FSR3_Dx12.cpp` | `50f9af119cd4027757e2ecc2436ce5e0e1abf07a32bdef7eb838c4d0a7053047` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/FSR3_Dx12.h` | `af9dccd70bce656d5ef714c9b078699cd096ddac9226f7ec1e94aaef4e7312ba` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/FfxApiExe_Dx12.cpp` | `cfe71b53df94120b89eb6e3f70c613336127d1914d76598f8bae266eee487a75` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/FfxApiExe_Dx12.h` | `ddb1ccfebfa63bd375ccd7e16bdd304946aae01555de3128f9310f5fe3d65494` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/FfxApi_Dx12.cpp` | `554b8cfcb3416d60c221b7b09a859b6a0d7e38d47c1e7eb4238f1451303d4e86` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/FfxApi_Dx12.h` | `959ecb43dd27221bc8e0cf125e00f72f59ada458aefbdd6cc8fc94bed8331852` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/FfxApi_Vk.cpp` | `70143403afc0b79edb8fa93082d10e262bbe6bf2a0a524673124a509d73a3e1c` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/FfxApi_Vk.h` | `62984fd7fe1a698a65f217961e6ef28772e4f8bf86a2855155fa10a4e6dcef47` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/NVNGX.cpp` | `623bd21c2af762d129e709ca3341ad93a3833beb643be65b72e66b8fd8ed8f38` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/NVNGX_DLSS.h` | `53a19cd71dce2024ea5baef69c5b8b75dc1a0b94c2dd191ccdd7d8d72e76d2f9` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/NVNGX_DLSS_Dx11.cpp` | `4b994ef2d81c6249e16ca7d0d47d6d9a9291736bd540c51ac1458ba5a7c6114a` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/NVNGX_DLSS_Dx12.cpp` | `0bb08d504c1e8c5300015693bc3a7578630622f35d9e7dc480d0d04569ff6d88` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/NVNGX_DLSS_Vk.cpp` | `4a9cced0622e062d0e7a9fa4d9740788eac6998b3aea237008f5cdbb3cb1b6ca` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/NgxFeatureRegistry.h` | `0d970f0b5ba38783895b794cd9dad941996a9509ee8856c1881670f4a8753c38` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/XeSS_Base.cpp` | `00a93e714519de431ced4016425a72c26147de06d1dbbc34ca6eece6c801243c` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/XeSS_Base.h` | `745ed7e06b6f01ecffd7a3206cfc0f9e12426b5b23d05c1abd5d3b3a1e1b347b` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/XeSS_Common.cpp` | `dea24b3b5fcf619861551c814f520117c70eaa0975c4fe19f93d39a56f537fe4` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/XeSS_Common.h` | `e782b6097202bd138ebe0ca52e977ad115728bed133af5491e710ffc7a40bedc` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/XeSS_Dbg.cpp` | `b4ce42935a2bad82a7b70c4c1e5eb8a5fd127adff1dc603384a5bbd96cb8ecf8` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/XeSS_Dbg.h` | `d5924fb962524902f9e26b1994474802cb2a49c9074d00e985061484f17d3c5b` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/XeSS_Debug.cpp` | `d414a8924cd9723352f34ce2c2cf3e80f26d7bd6b8969bbec358b6d039ddc566` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/XeSS_Dx11.cpp` | `e864526265f0ed9bf6a9d0877a1de50a19d7eda0754a2052474379961bcce340` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/XeSS_Dx11.h` | `a6e80f2fb838931aa990f1c259c51f1246e07da34a2b65f71425902716f04b15` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/XeSS_Dx12.cpp` | `2677e21c69687933d6a3f0708b3853b4b76c19b8d7d226ba41a9bfeadf2129cf` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/XeSS_Dx12.h` | `5d779a1f74f8bc9a53790ec9bbb783576e7e97848955bb98632e82d384d711f9` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/XeSS_Vulkan.cpp` | `9384dd4c890df9b17b5b4e9645a6490d611e1aadeb9e60aaa21e45b9d538ac6d` | tracked | tracked-modified-product-source |
| `OptiScaler/inputs/XeSS_Vulkan.h` | `d5a06a1d8928a7157e0e4abc4cc70ad7b753dda646daeca9cd8a3b3e1cc3803d` | tracked | tracked-modified-product-source |
| `OptiScaler/library/d3dx/d3dx11.lib` | `77268ebef609be985ce7882011ae549f8cf592e058ff8ea0cb27840f967de9a1` | tracked | vendored-link-lib-vcxproj-AdditionalDependencies-LibraryPath |
| `OptiScaler/library/detours/detours.lib` | `4f5d6f5b8a82c6609e45758d60bbdf29bfcb7956de1fd4454187a1b4a430b2f9` | tracked | vendored-link-lib-vcxproj-AdditionalDependencies-LibraryPath |
| `OptiScaler/library/fsr2/ffx_fsr2_api_dx11_x64.lib` | `09bae432b40540fd129e20b5a50ffdbc181eb66b3d35e0b2a581455ab739efc7` | tracked | vendored-link-lib-vcxproj-AdditionalDependencies-LibraryPath |
| `OptiScaler/library/fsr2/ffx_fsr2_api_dx11_x64d.lib` | `96f716e91ae45dfd9d398bd004deceb95345b4631dcce5320d70063203ed21de` | tracked | vendored-link-lib-vcxproj-AdditionalDependencies-LibraryPath |
| `OptiScaler/library/fsr2/ffx_fsr2_api_dx12_x64.lib` | `0af49bc7c5a660cc2fdbdd969c83b9337e66cfe87f76b8654e3e8e9694200026` | tracked | vendored-link-lib-vcxproj-AdditionalDependencies-LibraryPath |
| `OptiScaler/library/fsr2/ffx_fsr2_api_dx12_x64d.lib` | `fc75e44b90b49791f749a54c8fce0a850d340b4eb3338fc0b2eef7db0799d59f` | tracked | vendored-link-lib-vcxproj-AdditionalDependencies-LibraryPath |
| `OptiScaler/library/fsr2/ffx_fsr2_api_vk_x64.lib` | `e410a0e6ab0ad4bb1a1e1638cc723ad4087768777947129d6991ab05a3d1c094` | tracked | vendored-link-lib-vcxproj-AdditionalDependencies-LibraryPath |
| `OptiScaler/library/fsr2/ffx_fsr2_api_vk_x64d.lib` | `1f0a5bd06bc445cfdd2cd13bbac5b84a98131527fb63b1762c844312997dd1b2` | tracked | vendored-link-lib-vcxproj-AdditionalDependencies-LibraryPath |
| `OptiScaler/library/fsr2/ffx_fsr2_api_x64.lib` | `2755e4847ad9a648b305e3391abded44138588f30748ac36b63665740a6c855e` | tracked | vendored-link-lib-vcxproj-AdditionalDependencies-LibraryPath |
| `OptiScaler/library/fsr2/ffx_fsr2_api_x64d.lib` | `090df95a90a1030a34c693d17634b959e2639edd714643f924a4ac3af0fd62d4` | tracked | vendored-link-lib-vcxproj-AdditionalDependencies-LibraryPath |
| `OptiScaler/library/fsr2_212/ffx_fsr2_212_api_dx12_x64.lib` | `f6af216970b392656fa617e220059dc35863e6ee08b16494950415a89273925a` | tracked | vendored-link-lib-vcxproj-AdditionalDependencies-LibraryPath |
| `OptiScaler/library/fsr2_212/ffx_fsr2_212_api_dx12_x64d.lib` | `dcb25f748bc404225c04d8d6514f48971306a65e51e2aa8d8969512e059c68ec` | tracked | vendored-link-lib-vcxproj-AdditionalDependencies-LibraryPath |
| `OptiScaler/library/fsr2_212/ffx_fsr2_212_api_vk_x64.lib` | `0f993f9f34a686c64aaead36cae79d5ff3962f4079bcb9e01c64c691d0930175` | tracked | vendored-link-lib-vcxproj-AdditionalDependencies-LibraryPath |
| `OptiScaler/library/fsr2_212/ffx_fsr2_212_api_vk_x64d.lib` | `21453f5d4bec1ac31dbe609bd700bcfa0ce62b6cc8198e5c1c296f4a0661a813` | tracked | vendored-link-lib-vcxproj-AdditionalDependencies-LibraryPath |
| `OptiScaler/library/fsr2_212/ffx_fsr2_212_api_x64.lib` | `14803a9de847d103183f75e5ddd30d51fd159ae8f640fe62abfc6135b4aa4f76` | tracked | vendored-link-lib-vcxproj-AdditionalDependencies-LibraryPath |
| `OptiScaler/library/fsr2_212/ffx_fsr2_212_api_x64d.lib` | `7977ea82de834b57723827c60b6290a94aad234a9a76a018f66406c1513c626c` | tracked | vendored-link-lib-vcxproj-AdditionalDependencies-LibraryPath |
| `OptiScaler/library/fsr31/ffx_backend_dx11_x64.lib` | `cacb63cf1b9c7160cc0828cbfaa82b355de044f7671e2cc0590331919e98a3ff` | tracked | vendored-link-lib-vcxproj-AdditionalDependencies-LibraryPath |
| `OptiScaler/library/fsr31/ffx_backend_dx11_x64d.lib` | `67b169582cb73781d80ebb1201f425709cb6af92ce3073ba53fd2340ceaccde8` | tracked | vendored-link-lib-vcxproj-AdditionalDependencies-LibraryPath |
| `OptiScaler/library/fsr31/ffx_frameinterpolation_x64.lib` | `fa4e93e97ba920b2a14ca115398144dba6aad516ee13370f61b65fc4452d001b` | tracked | vendored-link-lib-vcxproj-AdditionalDependencies-LibraryPath |
| `OptiScaler/library/fsr31/ffx_frameinterpolation_x64d.lib` | `cee45571588790d209a9a3ef65205260327769290f9ded0095b444ee5b3ce394` | tracked | vendored-link-lib-vcxproj-AdditionalDependencies-LibraryPath |
| `OptiScaler/library/fsr31/ffx_fsr3_x64.lib` | `81545ea10df42c2ee0a72b993c95b97b247af6f0eb4eef76a0d67506a37a262b` | tracked | vendored-link-lib-vcxproj-AdditionalDependencies-LibraryPath |
| `OptiScaler/library/fsr31/ffx_fsr3_x64d.lib` | `f8390a825a2d38b13d8ddcfcef68cd727a8d9ef6ae44147c68208b1ba9f07a31` | tracked | vendored-link-lib-vcxproj-AdditionalDependencies-LibraryPath |
| `OptiScaler/library/fsr31/ffx_fsr3upscaler_x64.lib` | `db29ffce9372ddaf1174ea401a09cfe25e21e4ef8f4f05e268b5786d86c831cf` | tracked | vendored-link-lib-vcxproj-AdditionalDependencies-LibraryPath |
| `OptiScaler/library/fsr31/ffx_fsr3upscaler_x64d.lib` | `d5c9c34431aa06f9b1ad839131f0cdc085125cc34cf3d87fc57aefd051d2486c` | tracked | vendored-link-lib-vcxproj-AdditionalDependencies-LibraryPath |
| `OptiScaler/library/fsr31/ffx_opticalflow_x64.lib` | `80e6559f162c63d2d6cc2702b3a71fdcef7243a57d46b3ddd43bb5f290011360` | tracked | vendored-link-lib-vcxproj-AdditionalDependencies-LibraryPath |
| `OptiScaler/library/fsr31/ffx_opticalflow_x64d.lib` | `39f9e1dadfa58be7ce8e92c03a068dc6fb62e323f5ed730638efb46b9b24d1a5` | tracked | vendored-link-lib-vcxproj-AdditionalDependencies-LibraryPath |
| `OptiScaler/library/vulkan/vulkan-1.lib` | `974ca389f1ab5cbbd39b5a757dfe9935e903d85dca253f847ef0a9c785c9eb5d` | tracked | vendored-link-lib-vcxproj-AdditionalDependencies-LibraryPath |
| `OptiScaler/low_latency/input/input_antilag2.cpp` | `eb05c3b155938fc346759cdc78d199761345b70c4cca9d55758ee6aaebea217e` | tracked | tracked-modified-product-source |
| `OptiScaler/low_latency/input/input_antilag2.h` | `aff694c0946c9844c599879c2f3e9b89ff76a713f90435ebeb3897533e132124` | tracked | tracked-modified-product-source |
| `OptiScaler/low_latency/input/input_common.cpp` | `2284eea1d2680d87537d9050d4be981228141a927509c49424a05bcb61c230a6` | tracked | tracked-modified-product-source |
| `OptiScaler/low_latency/input/input_common.h` | `a79c9abd23fc5bd844b19601c147000ae970697dab9f64ff1aef2ad44be7b876` | tracked | tracked-modified-product-source |
| `OptiScaler/low_latency/input/input_reflex.cpp` | `534a11c1d726794056000f9655a0b0fc4968c1fe7bd1c340549f5d858c0aadfc` | tracked | tracked-modified-product-source |
| `OptiScaler/low_latency/input/input_reflex.h` | `c1453a072a9a3a7a6553bf9e61bb1e90b9b574832bafa038066b33091ee451d6` | tracked | tracked-modified-product-source |
| `OptiScaler/low_latency/input/input_uell.cpp` | `2cabf99b48d007c1dbede8e4811ece29d9671086d959ac02b046cbf8cac8fb9f` | tracked | tracked-modified-product-source |
| `OptiScaler/low_latency/input/input_uell.h` | `1c226a3d4bb0cf46d7f77a1592385ad6ef00dcf7996d322dd7ab7b2481ae67e5` | tracked | tracked-modified-product-source |
| `OptiScaler/low_latency/input/input_xell.cpp` | `7205ddaec6711b79500536374ec6d9a9b0fce48578d21b8c26e831dd40c9f741` | tracked | tracked-modified-product-source |
| `OptiScaler/low_latency/input/input_xell.h` | `81b449b625b776a5331f58c68374bb034ddd3e22d9458d348c530ce671fe84c4` | tracked | tracked-modified-product-source |
| `OptiScaler/low_latency/ll_util.cpp` | `ec3c6f94c4988fc8cfce55214a08b06b33905d8c63083e167e2e8bf535ca62fc` | tracked | tracked-modified-product-source |
| `OptiScaler/low_latency/ll_util.h` | `9ff6473fe162952c0585e7bf7e66db4b175a7d72a14ab9cb8fcb8ba205f79e67` | tracked | tracked-modified-product-source |
| `OptiScaler/low_latency/low_latency_tech/ll_antilag2.cpp` | `00a7b6f9ae26301027a6d84c8b292f898ca17f71439232aa0e8ba5f054e39078` | tracked | tracked-modified-product-source |
| `OptiScaler/low_latency/low_latency_tech/ll_antilag2.h` | `a66aa2c7d7f31d681365ad4c88b2f9a6b018c25190dac6dd54658133b5ed7364` | tracked | tracked-modified-product-source |
| `OptiScaler/low_latency/low_latency_tech/ll_antilag_vk.cpp` | `ef127189bb1c0ee9433377df98edba2ac9255d6845f115ed8d3022c426b9d44c` | tracked | tracked-modified-product-source |
| `OptiScaler/low_latency/low_latency_tech/ll_antilag_vk.h` | `e6a682237ed1380f249ad27997f5b4606ff5411f02ac60cca6a9def4e238aed0` | tracked | tracked-modified-product-source |
| `OptiScaler/low_latency/low_latency_tech/ll_latencyflex.cpp` | `6717b37bfb13dafcc92026db88798d491af95426b3319d15e7b0eb12429bab9f` | tracked | tracked-modified-product-source |
| `OptiScaler/low_latency/low_latency_tech/ll_latencyflex.h` | `bb669cae7f91f4a5602574d3ec7c72daa82a7369b64a0d2698f4df42f5527d09` | tracked | tracked-modified-product-source |
| `OptiScaler/low_latency/low_latency_tech/ll_xell.cpp` | `1536e79d048fdb55eee94d0d41e41223076249fb54f03b6346809de62a98b2ad` | tracked | tracked-modified-product-source |
| `OptiScaler/low_latency/low_latency_tech/ll_xell.h` | `de492a09580d5f2d326fb23e48d6ac268d2a619e467e0dcf2c75c3c9058ffddc` | tracked | tracked-modified-product-source |
| `OptiScaler/low_latency/low_latency_tech/low_latency_tech.h` | `7d7cc90ac2e1431a4db4ac33f3ee5de19169dc9018f1918fc65cad99680f0797` | tracked | tracked-modified-product-source |
| `OptiScaler/menu/Localization.cpp` | `83f83b73f26ce12f890cde52874a814c5486e6cc88752fbce040606e40724630` | untracked | required-product-input-untracked |
| `OptiScaler/menu/Localization.h` | `c742ffd4bd9fe6d24a96f26941e7798fa16e84500c88f7d4a9aeec87ae6d41c5` | untracked | required-product-input-untracked |
| `OptiScaler/menu/font/Hack-Regular.ttf` | `15f55cc0c85a2988d2b4b3a8cdb5d77fdfbaf319e1bb5309d725db9818fb7125` | tracked | tracked-modified-product-source |
| `OptiScaler/menu/font/Hack.h` | `a2d89d0f390dafd387dd2251e005e38017ee7550ea7e303c1d9d35a7ab50c67d` | tracked | tracked-modified-product-source |
| `OptiScaler/menu/font/Hack_Compressed.h` | `8bb0bc1d4ae6f4d73b5ba338ac35a49c09f408de62b5f653359c7e68c62b6b02` | tracked | tracked-modified-product-source |
| `OptiScaler/menu/input/input_system.cpp` | `9c1d17385b5df5aabe32fe66e933b9a5e126d847c024ccc69ed7b57debbffc93` | tracked | tracked-modified-product-source |
| `OptiScaler/menu/input/input_system.h` | `70b8825088261d92cfae8cf1989af715ba43762022ef274d01d6c4fb14555645` | tracked | tracked-modified-product-source |
| `OptiScaler/menu/input/input_system_cursor.cpp` | `de4fee32372cec693f7e143349da72eef7525ebc33478af16abf99749644c86d` | tracked | tracked-modified-product-source |
| `OptiScaler/menu/input/input_system_detours.cpp` | `87e6af26e43f3c2a5f8296dddfb129ffe100233eadba2b83af77750f071cd2f6` | tracked | tracked-modified-product-source |
| `OptiScaler/menu/input/input_system_directinput.cpp` | `06ad6012678489daa63b0851db03f1174f1095654bc8f3c365a232e945f82b3f` | tracked | tracked-modified-product-source |
| `OptiScaler/menu/input/input_system_gameinput.cpp` | `ef2f0cc0d4b2c7c89c522d7d20ed8a9c0259a4bfbd3ec7c75718a298c61e6095` | tracked | tracked-modified-product-source |
| `OptiScaler/menu/input/input_system_hid.cpp` | `64a827c33daf1f33367d44a0003251cdd6ced02ef80c3c534d02897c3b6e1675` | tracked | tracked-modified-product-source |
| `OptiScaler/menu/input/input_system_internal.h` | `cb6c3105a358daafee0896117bd809e5abaa8609bccb1eefae57879de62ef32d` | tracked | tracked-modified-product-source |
| `OptiScaler/menu/input/input_system_messages.cpp` | `bbe3389a1463e8ca19bdf7f27f11a0bcca73ec5bdd269fd36510b20128737ba8` | tracked | tracked-modified-product-source |
| `OptiScaler/menu/input/input_system_raw.cpp` | `74929a31e05c2f80c02690068e9f7cddd99399d0174b9c10f83c881ba34f3bd6` | tracked | tracked-modified-product-source |
| `OptiScaler/menu/input/input_system_window.cpp` | `637cfc7c16912b31d652c8482d8cfca5d268cbb4c2ddb1fcbb996fb219fae77c` | tracked | tracked-modified-product-source |
| `OptiScaler/menu/input/input_system_windows_hooks.cpp` | `e45b9ce476689bc8a5d6e209405fdbb9faf8976bc2dadae65161f39d31b6c2a7` | tracked | tracked-modified-product-source |
| `OptiScaler/menu/input/input_system_xinput.cpp` | `9035fb663666c7e25d197112ded3984b9c4db6bbbdb751204cff3436aebe34a4` | tracked | tracked-modified-product-source |
| `OptiScaler/menu/locales/ko.json` | `6130c0f58f5560a4a51e80d5feeec9a077a71c6282c10ec42eb32dc4c01b35bc` | untracked | product-area-untracked |
| `OptiScaler/menu/locales/ko_catalog.inc` | `df441e7a43c0e9ace8610088670bc5f8ff2721d6e3b7aa333880cdccb07f3cfd` | untracked | product-area-untracked |
| `OptiScaler/menu/menu_common.cpp` | `74884e586a0bbeabfecd9eda224363a99b4b158ce2e277f451b5c930feffabd2` | tracked | tracked-modified-product-source |
| `OptiScaler/menu/menu_common.h` | `c319192b1c1d2cedfc854db0b2bb2a817424edf26f9e01519abdab891c294e11` | tracked | tracked-modified-product-source |
| `OptiScaler/menu/menu_dx11.cpp` | `4ca6587579dbfb03142f70bd144ccc8f226735f94cdba41f5aec4b3fa2e622b4` | tracked | tracked-modified-product-source |
| `OptiScaler/menu/menu_dx11.h` | `5bd2da04c80e990fec84d84381f91560145ae40ab59c0897c6c28253b542a875` | tracked | tracked-modified-product-source |
| `OptiScaler/menu/menu_dx12.cpp` | `ec5e45e9e2abfda5655f62894d036159f94ab1fda51d1dd0268b9f4dc62bba36` | tracked | tracked-modified-product-source |
| `OptiScaler/menu/menu_dx12.h` | `3eedb67616cf5794335f027d5191304c46fcbaeaf4c4705cba5a4176ea0df640` | tracked | tracked-modified-product-source |
| `OptiScaler/menu/menu_dx_base.cpp` | `719bed4184857411e35eb317375f8ed7a927c280b95d4febe107caa7f21d8ca6` | tracked | tracked-modified-product-source |
| `OptiScaler/menu/menu_dx_base.h` | `f8466d4adbda1a5a893d32fe981c1fd3713de66ab95f90abfc96f0d8fbd09f94` | tracked | tracked-modified-product-source |
| `OptiScaler/menu/menu_overlay_base.cpp` | `114241c7267799235ee48a1aa0511c1712a1056687df47495efc84ac279a0677` | tracked | tracked-modified-product-source |
| `OptiScaler/menu/menu_overlay_base.h` | `07278a27aff5dd3fb654798df3662e9aa2db882a3a1b5497a98c058cc772c095` | tracked | tracked-modified-product-source |
| `OptiScaler/menu/menu_overlay_dx.cpp` | `4c51eb353a077ea6f51da3fc7ad00f2128c12cb2da014ed472403424d6247220` | tracked | tracked-modified-product-source |
| `OptiScaler/menu/menu_overlay_dx.h` | `eb47c3031e50cc7a55f3a2144e45deb83785fc65aa0abee5857b0be69b3da076` | tracked | tracked-modified-product-source |
| `OptiScaler/menu/menu_overlay_vk.cpp` | `0515e08f9e2617c9e953f777e42770ce7dd122bf40859afece50f2cdf8a1a58a` | tracked | tracked-modified-product-source |
| `OptiScaler/menu/menu_overlay_vk.h` | `f316e923a8f17470c5749d8b5a827a3e690db84b1607305bbf0c15d0ebe3cb11` | tracked | tracked-modified-product-source |
| `OptiScaler/misc/FrameLimit.cpp` | `4c5c31f30bd06d589f1911a37e6e7b61fd4ae585c65ddc5e0d152b19687643ca` | tracked | tracked-modified-product-source |
| `OptiScaler/misc/FrameLimit.h` | `5ed2fa7119bcf4b84c3292df1e456b84b6ef6170a4e0389b16cd666645b3955a` | tracked | tracked-modified-product-source |
| `OptiScaler/misc/HiddenWindow.h` | `13d0847a34c2e48fc910a5dc2d41d0a678fb301cf76a03b679821f1255e96da9` | tracked | tracked-modified-product-source |
| `OptiScaler/misc/IdentifyGpu.cpp` | `ba4cda09d53ca4821091346477061e706c37f4aa39b305cf9e2d4dad7d2bd89d` | tracked | tracked-modified-product-source |
| `OptiScaler/misc/IdentifyGpu.h` | `1d9db85c8842b95ab4f0d23431b109e3a5d71aabbeccaaf92133bf170e3d738e` | tracked | tracked-modified-product-source |
| `OptiScaler/misc/Quirks.h` | `44b178ed32a001e615f48797b3f9247327994bb1af695adf2ff535330724132a` | tracked | tracked-modified-product-source |
| `OptiScaler/misc/SkipSpoof.cpp` | `ef61804637997219dc5c9769848dbb0d40f02cbcfad3869e05e22e72ad3382ba` | tracked | tracked-modified-product-source |
| `OptiScaler/misc/SkipSpoof.h` | `985d5265251b3fb1d481319632059b8c4d2f4055c91003c9ebd97f3ab28d21c9` | tracked | tracked-modified-product-source |
| `OptiScaler/nvapi/NvApiHooks.cpp` | `5481bea05fc8f56db5fe229ae3e70f4fd0558ad28564dd6f988356606a77b117` | tracked | tracked-modified-product-source |
| `OptiScaler/nvapi/NvApiHooks.h` | `3f9274329670ff877079b0ede13bf5ec979758cc3b4e757a3ec2102117da5a39` | tracked | tracked-modified-product-source |
| `OptiScaler/nvapi/NvApiTypes.cpp` | `e1f6f71ca5f296077fcf0a2652435fe9bafb0de5ecf8ca4f39e3e2d971bb9626` | tracked | tracked-modified-product-source |
| `OptiScaler/nvapi/NvApiTypes.h` | `f5a7210988d7089357d8a8a87f447c185b9c08d621c7a891c696e483c5458596` | tracked | tracked-modified-product-source |
| `OptiScaler/nvapi/fakenvapi.cpp` | `46844b0c4bb9615c1b902e715adec2d0a78d2142d388636991ed7e193fa71ad8` | tracked | tracked-modified-product-source |
| `OptiScaler/nvapi/fakenvapi.h` | `359792cc76e19d2d8279b5152da9a469b6d453381ceecbf9a4e3cc93ba832754` | tracked | tracked-modified-product-source |
| `OptiScaler/nvapi/fakenvapi/log.cpp` | `c156204e9269f719b9de17964f06acf5b37d691dffac3e80fbb13782cff2104d` | tracked | tracked-modified-product-source |
| `OptiScaler/nvapi/fakenvapi/log.h` | `7421a4e9fb3b214fa906792eb7fbd8e9d68cf0e71c06a8c0aa937c6b3ba95ae6` | tracked | tracked-modified-product-source |
| `OptiScaler/nvapi/fakenvapi/low_latency.cpp` | `c922529a58ba4462a53103b62e580c58d8be2ea7e94887ffccea8ddabf1c74b2` | tracked | tracked-modified-product-source |
| `OptiScaler/nvapi/fakenvapi/low_latency.h` | `dcadd637b3d943e2532d9dc254da529a8b8bced8410fa29963f023996edb5294` | tracked | tracked-modified-product-source |
| `OptiScaler/nvapi/fakenvapi/low_latency_d3d.cpp` | `2925f50239f404c6e0a8e93f09f4c1cadbf4051d716b8a56ccf4f5e272fe3d67` | tracked | tracked-modified-product-source |
| `OptiScaler/nvapi/fakenvapi/low_latency_vk.cpp` | `043bb71475e2033a193e423b35ab562a4d71b71cd810ed4f7b8d2ff4f22fa8b4` | tracked | tracked-modified-product-source |
| `OptiScaler/nvapi/fakenvapi/nvapi_calls.cpp` | `6b9aa47a31415465d5c2fe552e37289ac17efded57f9900bbab39e48cb1d7a50` | tracked | tracked-modified-product-source |
| `OptiScaler/nvapi/fakenvapi/nvapi_calls.h` | `90bebd26b1d03720beb442c8802064c80bdb6f8f8ccdc6c7d672c92049a8ab88` | tracked | tracked-modified-product-source |
| `OptiScaler/pch.cpp` | `767c147b79a2d6c6488f245d364e406bf927d83e92475247ce92792f71f0bb2d` | tracked | tracked-modified-product-source |
| `OptiScaler/pch.h` | `24f0a3e167b1a4a363adc44adf7127e9173f9641ad9fc56b807f184114e6ebc1` | tracked | tracked-modified-product-source |
| `OptiScaler/proxies/D3D12_Proxy.h` | `a0d78100f93311fa8dda052c39cf3d77e659db272eeafb637ae17e5bfa4eb2d5` | tracked | product-area-untracked |
| `OptiScaler/proxies/Dxgi_Proxy.h` | `d0657a88b2b88d7904d30734e947662e01479c716cf22ce43912406b18f86878` | tracked | product-area-untracked |
| `OptiScaler/proxies/FfxApi_Proxy.h` | `04b1cb1107b7c9c275844bbb03c5116db5b29e69930dd2fc4862eade34dede0f` | tracked | product-area-untracked |
| `OptiScaler/proxies/IGDExt_Proxy.h` | `076df97ea45819e0f2860324c83f378478cf8a77fdcca5749c81307e04d620ac` | tracked | product-area-untracked |
| `OptiScaler/proxies/Kernel32_Proxy.h` | `123f4cadfeb811ae4e64101effe1f3d4d92bbf4b286596562ec5410aea82b455` | tracked | product-area-untracked |
| `OptiScaler/proxies/KernelBase_Proxy.h` | `6de941de72002a1734e2e16d406199a5557e323b801842f6f16cc26e8dfdac49` | tracked | product-area-untracked |
| `OptiScaler/proxies/NVNGX_Proxy.h` | `93a970dff6590d633b875ca46bbe84dd994f6cc4c2de394323466052ddde20d4` | tracked | product-area-untracked |
| `OptiScaler/proxies/Ntdll_Proxy.h` | `efa31fc339f595a3da9dca82222da7f5d430817997f0948a4a53c2bee157ad1d` | tracked | product-area-untracked |
| `OptiScaler/proxies/Streamline_Proxy.h` | `af9e1f9b4887ffd7aa173df2e484b0b673aafc20f7a3b8346e8b155c79e41c78` | tracked | product-area-untracked |
| `OptiScaler/proxies/XeFGPacing.h` | `453270a4cd3f7944b4f1259f54727f76d5d256c81675b92d1059ab14cc92a507` | untracked | required-product-input-untracked |
| `OptiScaler/proxies/XeFGUnlock.h` | `e6de23a98d7ee34b241b88612581f3aad7f173f8687387dd449398b96c7a80c6` | untracked | required-product-input-untracked |
| `OptiScaler/proxies/XeFG_Proxy.h` | `d608826e19249ab4b182e7f246190cc6203888282f4b5157da362f52a38ba96b` | tracked | product-area-untracked |
| `OptiScaler/proxies/XeLL_Proxy.h` | `8b8a43bef3a380ccebdc366cacb2babede2ee64136df0d43f34d899cda9d61de` | tracked | product-area-untracked |
| `OptiScaler/proxies/XeSS_Proxy.h` | `2e2fb2b0454fe6c0258375ec8247457fb067782af237a1d7e073dde8255235bd` | tracked | product-area-untracked |
| `OptiScaler/resource.h` | `b3ed5e11b98165b16e5b5f67d0a9a15fdbdff6c1bca7dd038e7389df65de0bce` | tracked | tracked-modified-product-source |
| `OptiScaler/resource_tracking/ResTrack_dx11.cpp` | `cac9976f8af8eeeb45e0f596ba56b1eb909b03064b9ae05177510283df60cd94` | tracked | tracked-modified-product-source |
| `OptiScaler/resource_tracking/ResTrack_dx11.h` | `3aceff7deeace005063163104002f70408a6865d256d09aacdf2db1e4fe38c94` | tracked | tracked-modified-product-source |
| `OptiScaler/resource_tracking/ResTrack_dx12.cpp` | `50f1fc026b851814e540d9b350e27dd35621c2e9d710e171c546cdf53a8948e4` | tracked | tracked-modified-product-source |
| `OptiScaler/resource_tracking/ResTrack_dx12.h` | `e409afe2906c34f9cdc775bdb697fc7c53b5d7e90e285eb94c1ebad444e35d4b` | tracked | tracked-modified-product-source |
| `OptiScaler/scanner/scanner.cpp` | `e51eb26d89015c876af34b26e7487f346328173f707a7f3bd8daa2040694acdb` | tracked | tracked-modified-product-source |
| `OptiScaler/scanner/scanner.h` | `a26cf4c99bac9abd285e61ba401af8eaff40d12e1a63257fc2afb81cdd5e30a9` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/Shader_Common.cpp` | `6900850329523977e4093f1e0bce996346a5c1aa230ca9a9b4baafc76fb7c1b3` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/Shader_Common.h` | `0b747d6f71e21a0e64cf277d1691cf6492d1516236264cd2dd8bea1d6d584299` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/Shader_Dx11.cpp` | `23a065689f17145e0f0da714440de83519130c11080277c4da9545b7a851d9ed` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/Shader_Dx11.h` | `e73c0f78c52ff467346ebd74594eb519407c4d6360a20499c89f4afe6bb5d844` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/Shader_Dx12.cpp` | `9b899e3439e0fb0c361cff0389a11b9ccd88025026eddc319c526d14dca95ec7` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/Shader_Dx12.h` | `716985862dc3ce7cfec03a2c05257a377e138ae99eda52e21086ba5584c830f5` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/Shader_Dx12Utils.h` | `3b3357ed146681528646afcc5be04b60590ed737fa91670a8e1062e5a1d635ae` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/Shader_Vk.cpp` | `0f3165a85202a18c3e8bbd796ad06074785d541fb28851f68f3c9ac710462494` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/Shader_Vk.h` | `d4ec22eacb55edb823429acb5b6b2544cc035c27aa8505e9e39b7188e5a14904` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/Shader_VkUtils.h` | `6cc76e8943ec5416923badabe20bba1715204fead6406c9ea4b3b172de84863a` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/bias/Bias_Common.h` | `894df40e8b0293d643e51e8bcd7b164e620cf0d79795f7abb8f72a354dc99aea` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/bias/Bias_Dx11.cpp` | `f482af9bb05a8f9398510e87008a8940d0f2586d59a76d82d0a8c3313f895928` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/bias/Bias_Dx11.h` | `5b40a86f39cddc566250f22bd1c8bd39089c0b8f7f2506644b3b201d13e3aa5d` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/bias/Bias_Dx12.cpp` | `07c05bfec35f00e44596098dfa6c4728ee4472a35240775048f9799208bcdc1c` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/bias/Bias_Dx12.h` | `8000b4b8be96278c249bedf8a97e0a5716ffeaa57a6a41cb955209e33c21fdca` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/bias/precompile/Bias_Shader.cso` | `b81dc2c3262d8b543ce98f68455ce0616edfb1a4daf8416298b82af152e25dd2` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/bias/precompile/Bias_Shader.h` | `0c28567794909a1fb2dca51d85d6fe72865a3cf801ffc7634c6a53987e119141` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/bias/precompile/Bias_Shader_Dx11.cso` | `59343e2a08a70bd740a1b857290762985057da0d1faac41edc556018c30bcde5` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/bias/precompile/Bias_Shader_Dx11.h` | `8691466bf10f72e8e8e0e78b0543d38577e046da19c1e613089e26f66347ded7` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/bias/precompile/bias.hlsl` | `61f1fa400aec340944702453dc5b1dc007c2730f8bb55f214d3b101d46b002e4` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/depth_invert/DI_Common.h` | `55049d73aa092431aec2fdce3b4ea21d00740285c3cf108d6c6cd47a851cabaa` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/depth_invert/DI_Dx12.cpp` | `4c6956a7e6f7b244292a476f07228bd12b9e0f014fe3a1653984074f18d94d94` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/depth_invert/DI_Dx12.h` | `60dd3c87e891ca6aff637abbf8ae1d1d4d0185c2bd372cba8d5c6e4616339f2c` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/depth_invert/precompiled/DI.hlsl` | `4378a7322110fa3ce5f8e6fa9d1d70ef7d8fc5dc601869f94eb44aa6d4439107` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/depth_invert/precompiled/DI_Shader.cso` | `d3dabc1dd4a5accfc2cd0c1f32661e23ce0b072a5fddb084f296216d7645056c` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/depth_invert/precompiled/DI_Shader.h` | `c7f09c97a1eb73718b16db9e41b2357e4289f898c618c871d12fb035e0a2fa2f` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/depth_scale/DS_Common.h` | `9ec81a1befbbaeabcd6f44d67913174b40578d91e7680316b80cd1b1ddb7b001` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/depth_scale/DS_Dx12.cpp` | `83854c0145622a320764406f272b5ecee4ac590fd18e76c9c6b3a9e381c06bfd` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/depth_scale/DS_Dx12.h` | `8b77badcef4348fd4925b7efef7b6312c6e082f1549d350c188437412f8e507c` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/depth_scale/precompiled/DS.hlsl` | `58b045dcdb4be3a333b0043a999c38bc7af704fb1b0372e4ba6110be5a89e70b` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/depth_scale/precompiled/DS_Shader.cso` | `7f21e18044aefdff0f049528357b9f7406d9a2676368809a67ad749d4eb606d3` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/depth_scale/precompiled/DS_Shader.h` | `82bdb1b377558819f4c6fd3883588506b21a1103f7ba1c25773035acf5e32b90` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/depth_transfer/DT_Common.h` | `0c18f132646c8eef13c74732c044cdfe0e3a923b8fc77f18a6ef67a2d8894ffc` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/depth_transfer/DT_Dx11.cpp` | `7c30ce53dc1d2c383472675ab6a964a43650cc051e511d0096df8b682fc59a06` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/depth_transfer/DT_Dx11.h` | `06f73ef1c527b0bc72dae6615987afea9adb00222ac3a51bb137ad89560dac01` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/depth_transfer/DT_Vk.cpp` | `c84df420f5083aa314e85098db2d695f4b11ed68898f76ffe625904e1681ce32` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/depth_transfer/DT_Vk.h` | `8efac4f27adeeaa3a9a5f9d0f8e4006df7afb7a2b245eedebcb9ace1b1ad4825` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/depth_transfer/precompile/dt.hlsl` | `f2d23bae24139707142ea00b33b3f5c88ddc2b1e6ad4a256eff986bfe516520e` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/depth_transfer/precompile/dt_Shader_Dx11.cso` | `21d5014741190d7228414e580b586b0bacf1c57514102faea6b88663b6499011` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/depth_transfer/precompile/dt_Shader_Dx11.h` | `13358445b9429fad3cff55cf0f217418a7137cc92903490d40100b769754d073` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/depth_transfer/precompile/dt_Shader_Vk.h` | `c3236bc7ccbf91bada996bb8e62da6a95aeaf0c84cc0605afbcb0dbddcb248ae` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/depth_transfer/precompile/dt_Shader_Vk.spv` | `f873271af1b5f2ba56e163d6a0d37ed13b689876401ba2fe637a8620fd54bc2c` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/depth_transfer/precompile/dt_dx11.hlsl` | `b38307ced15caaf969dfe221f0139aea779d650b9d687a1068072e1c87ffcb3e` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/depth_transfer/precompile/dt_dx11_Shader_Dx11.cso` | `011356acff435a0c73f0b1d591f21c005dbeec66fd9c9c2e15155dca75101f54` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/depth_transfer/precompile/dt_dx11_Shader_Dx11.h` | `d3a198ce5a4ce9f6a185accb78cd05a7a877a04ccf3c5f2339ff6a53f4531de5` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/depth_transfer/precompile/dt_int.hlsl` | `f1963577c38614d1bbbc1ab768b627a85e519ed0d2c7d4395851dfb61ff9262f` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/depth_transfer/precompile/dt_int_Shader_Vk.h` | `a92649aabfc1ff6f257c7d7fa380427ec05af4352118f08babe4cfcbf2635e06` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/depth_transfer/precompile/dt_int_Shader_Vk.spv` | `a05aaadd725f260e0bbf90c5c3391368777258ad2fd45eb4dbd8d1a9a38f68ab` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/dlssnr/DlssNr_ActiveColor.h` | `f30f23f2f986fe5ee046b5339fe0da735e32a495fdc5792957965554fdfb5d90` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/DlssNr_Common.h` | `7488755404a65150bba08e69febe17e2ec2b7f42ae1159d76ee7aaf09f96f45b` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/DlssNr_Dx12.cpp` | `d3c1a8511a6de575c38272491a8d8762d80656081efdd8ff000e37b3e43f69a8` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/DlssNr_Dx12.h` | `d4786aaaa728ed53b1a480d20cb85fc99835bd81c268fcafc907d1ebe6868ca7` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/DlssNr_Dx12_DeferredSr.cpp` | `bb14d734877a41aad5a60a552696daa1eb043adc11782d28275301dc95a1dea7` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/DlssNr_Dx12_Encode.cpp` | `6191e4ba2a6f5e5b3e920c12ea3922f1a5b63f4ad6fb009563e44265994dcd4d` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/DlssNr_Dx12_Enlarge.cpp` | `c5e6c82842d4839958bae2e52b0a3b1269945908f48080a2522f02f19e4b9590` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/DlssNr_Dx12_Evaluate.cpp` | `10c8e59e36bdd9297667c8a0c24fada5690a38fd832914a9dfc8449d5647eae6` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/DlssNr_Dx12_FinishedCompose.cpp` | `54326948e72b25fd8d7f20911f2fa2db4d5b14d01ec3d4ed2cec423a5fba6593` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/DlssNr_Dx12_FinishedQueue.cpp` | `410bb4f4e9a65cfd28a84262a13ba6a15e7700ecbdb4309c38471ca4743c5238` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/DlssNr_Dx12_Hold.cpp` | `e32ee4f9a777e1a20b55569c90d81af805f5a2d9c89b2aba59fe818a9f24494e` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/DlssNr_Dx12_Late.cpp` | `fec380bda29c8fff881d7ed87824f38d6af4d2999f515889b09c6218cd055bf6` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/DlssNr_Dx12_ModelState.h` | `d32e01debaf788d7c8b9c7dc039fcc41a49abee9bb3bdf519adb708561330b37` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/DlssNr_Dx12_Models.cpp` | `472690a0424fa0ea01bf9c64dff8ff596c12909fd8b200f8680844c374f0e2c4` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/DlssNr_Dx12_Resources.cpp` | `b573e9ae9434e671b9aebe1d95f112319a8c9ebf8471a8854acbfa67a5827ea8` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/DlssNr_Dx12_Run.cpp` | `00e6bc00a3187f4f0189507ed8f313775dded914a4b8aa7e46298c9593cf43e8` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/DlssNr_Dx12_State.h` | `009cfed0f576535b89ef458ccc48e497c063a758e141a45cda1738a299150d44` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/DlssNr_Dx12_Status.cpp` | `9e3210921853e26a677d00b53229a8091f22b7900f631993c225f9549e292be4` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/DlssNr_GpuTime.h` | `fdb5672ec41d5bba82055fff8c477892bd99294ef3dc683e92ed44f75c2dab11` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/DlssNr_Guides.h` | `2a4f7677d7f51610cfc5fd75b8c568da66d92f06733b8a4c824007cecefbae44` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/DlssNr_LateSlot.h` | `442758e03a78a4e0d8a16a1e96fecd6182740b966e620ba8dfa82c8d8b7247ba` | untracked | required-product-input-untracked |
| `OptiScaler/shaders/dlssnr/DlssNr_NativeProbe.h` | `b15ce7e322e1dbc2fd6d3b0919c486f2d01c7aebe9a73c665e0a8fdcd8aac145` | untracked | required-product-input-untracked |
| `OptiScaler/shaders/dlssnr/DlssNr_ResidualPair.h` | `4fb9640580163c2d693f7267d7d6ed0e44e57ea2dd305f49ff11095cc7585d49` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/DlssNr_SeamClock.h` | `baf738a48d6cada970abf1859c4c8784055cb6512a9025d1e7e61ac833bc7462` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/DlssNr_Upscaler_Dx12.cpp` | `d1f1200a7f1469276a90a527fb6b555b5fe2713b828570a024b752e8703eee82` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/DlssNr_Upscaler_Dx12.h` | `6d13573079dd3569cee5928b9f8a1c4005475f110585c3731cdea8a7a11c432f` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/DlssNr_Vk.cpp` | `6d64c97f88c6d81171ce155737902b80985111dc315a3a4022c2401935800096` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/DlssNr_Vk.h` | `ade21cdfde57ac79ad051085e88065833406a2eb822fc0cee6b41db70f40e2f7` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/precompile/DlssNr_Shader.cso` | `ba5df863b33fee2918bf5bec630aa393b351125a777f729a7eb44af09aa8964d` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/precompile/DlssNr_Shader.h` | `f3c71f5693a85fd6904ae173bca120be2d82811a59385ccf28386faf54e1225d` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/precompile/DlssNr_Shader_Vk.h` | `ed87b63e91da1ab9741773211713d3826511937137c74eda5f30051be6ff9e8e` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/precompile/DlssNr_Shader_Vk.spv` | `51fb224233338db6ef304dd238df1feed2be75f4c481172bcc920050f45f3f4d` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/precompile/dlssnr.hlsl` | `f97fb3dffc2e305a4edbd83d00942849d222a2f21547d880788a897fdfdd80b5` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/precompile/dlssnr_finished_color.hlsl` | `78ccaf5a9e90784f8a36074117a4ae491841ac5fc0b3af0146a7265fb223efc0` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/precompile/dlssnr_finished_color_Shader.cso` | `9210525ff17ded7b1d928b1cd1fce6c2ac0c9ca857b6532f99d05244a58574d4` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/precompile/dlssnr_finished_color_Shader.h` | `49be9f6cd81ee133073594fc3dc183a342db35e5f1f9ce1ce7752263788a9923` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/precompile/dlssnr_finished_color_Shader_Vk.h` | `e29ed783befff7233e301130d6bffcbcb5492113071071eccbfac085aedb8f33` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/precompile/dlssnr_finished_color_Shader_Vk.spv` | `946347601791ba1709b695482a131e17ff67b2a4507db1778e02c7fdd469f8d4` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/precompile/dlssnr_residual.hlsl` | `91f12d5de68b42e8692536fdf460cf96b4faec76c8f28c6ec82aac74d1578e23` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/precompile/dlssnr_residual_Shader.cso` | `d939e5567fbe4ede5fabb41e975a4a7e49975feb11024a41ff9402bf09000d10` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/precompile/dlssnr_residual_Shader.h` | `7ed85b07dac198c450df11f6861b237836737afed93edd75055876572d50a618` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/precompile/dlssnr_residual_Shader_Vk.h` | `4da2015ab32c316842385b9701918267b4e3354dae1c18f4eba196ed364dce29` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/precompile/dlssnr_residual_Shader_Vk.spv` | `4b4cefbf99eb40b8b29d7b5c3bdf6c2bfce4fc5aab384c804a223068851216e0` | tracked | product-area-untracked |
| `OptiScaler/shaders/dlssnr/precompile/dlssnr_resize.hlsli` | `d47efc0a8eb04611799227f2fbddf6be42b03771546d1259be34f364f5459a83` | untracked | required-product-input-untracked |
| `OptiScaler/shaders/format_transfer/FT_Common.h` | `ce8e42f432fd9056f5174e8eff7c12514950e8c66b99cd76183217833ccff398` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/format_transfer/FT_Dx12.cpp` | `464642a4bc3d289a8ba0058643d518760bd87297bc1078744a21fffc42619820` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/format_transfer/FT_Dx12.h` | `9968e7e64fb98213015a66d766e38ff0673e348000704c0fb48a60652b55b445` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/format_transfer/precompile/FT.hlsl` | `0a86f4002816bc4575cea06b06a418fba6c745db58be9f50596b349b34a5d031` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/format_transfer/precompile/FT_Shader.cso` | `5d708d451360d7b1186975434ce1d18b9861768b76d5eaa942648b19f644d313` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/format_transfer/precompile/FT_Shader.h` | `acb639ec7dbb3d33c0bc926182a2e5198af81c641126b37d512aa56c9f884897` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/hud_copy/HudCopy_Common.h` | `de84fc39bc0df82c0e5effb3daa66b55faaf2c3247d69809b4e5dc27261ce593` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/hud_copy/HudCopy_Dx12.cpp` | `4af7e0252155df776ba20e797460ff80eb95eac7125771e69bc810618e89a4c3` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/hud_copy/HudCopy_Dx12.h` | `067ff109a158aaf5903cda0d3ed5012b0eb72c5c99738fb2b3d4057f58af9a76` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/hud_copy/HudCopy_Vk.cpp` | `0b5bb8c271810bae7ee4e5de1d2f3809d5da6cd1643890378aacc09ac7571138` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/hud_copy/HudCopy_Vk.h` | `543383de0dd29bb1fa72837ee94bdd51b0bdf6b613de0f03da584168359c08d0` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/hud_copy/precompile/HudCopy.hlsl` | `cf7c1cf4c8f0ef3844a8e22742180781de8b0dc85a6daad6f87ce5fdcb6c4ba1` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/hud_copy/precompile/HudCopy_Shader.cso` | `34e589dceb2f539c704277d161f07f258194a226d0254167591f47714acc7ed4` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/hud_copy/precompile/HudCopy_Shader.h` | `8347e430eef51c6728a37a13f937704422313ea4364faf2a29e353c9f404581b` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/hud_copy/precompile/HudCopy_Shader_Vk.h` | `f8b56f027bcb7a128568a463267e924dc13cbaf161d659cbff6e2a6e188c3140` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/hud_copy/precompile/HudCopy_Shader_Vk.spv` | `48ab1b06b8266b173055a05b89687212a2890209521e668a92d031e29a616cc0` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/hudless_compare/HC_Common.h` | `685ef0fbbb89f663f91b31e0493ed12690534a6eb6b0146ccfdeefd58ee162b1` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/hudless_compare/HC_Dx12.cpp` | `bf4592e45da71f5e5c038134ff1e54a528393f60286d5378c189d7d9681a5276` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/hudless_compare/HC_Dx12.h` | `9cc13545dfc61052c3ee1d0f1bc085806fd9d071c31508e57aafce4e3391c26c` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/hudless_compare/precompile/hudless_compare.hlsl` | `4455b90150e57d74691778a0e2b7aff4f1b98a6bcfcca4cf9b81f901e204f57b` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/hudless_compare/precompile/hudless_compare_PShader.cso` | `12add7d8bea2ac7fcce9495a4114f73c03b6d53bb6aba3bd47aa73d00aae5a35` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/hudless_compare/precompile/hudless_compare_PShader.h` | `26bc4805f6ff87c8cd9312abb351e1815d4d988ec3881cb1a282174873ae5da4` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/hudless_compare/precompile/hudless_compare_VShader.cso` | `317768180743cdd6a26d776c322b17fe016f991cc18ed653014877ea05130784` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/hudless_compare/precompile/hudless_compare_VShader.h` | `2f7ba5f0448dd20a0acb566a659a64dc7834c6467aca9f294bd6c82fbc980f39` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/hudless_compare_compute/HCC_Common.h` | `c4026cdb6677187eeb57c5833f94c15c6b2117cda430fc26ff024d34cf6c702a` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/hudless_compare_compute/HCC_Dx12.cpp` | `0b53bd0009cf702494c0f966131715766fd6d6ca502966177022db44385f3b50` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/hudless_compare_compute/HCC_Dx12.h` | `f2ae86d68a5f2c6688fe12e85fdfff1e56c38746282d0a5cb6d4f91e34bf1925` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/hudless_compare_compute/precompile/HCC.hlsl` | `20adc75b2eb71112ab1d48ea7e0a6baff1b037dbb75fb51d3e30665c440b8d4a` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/hudless_compare_compute/precompile/HCC_Shader.cso` | `899b8ec79b4b008e43d05e84cc9f0c4700b299af8598eb59563d011aeda4bc9a` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/hudless_compare_compute/precompile/HCC_Shader.h` | `b249e3dfc5a9ffaeb5bf5c2345195b1d9e6d210814de9c8581d6797ee99b0a34` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/magnifier/Magnifier_Common.cpp` | `343fdfb0d4eef8f4eda463eda0424b19c96d945c3db0f0ae8a9503249266e9a0` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/magnifier/Magnifier_Common.h` | `472666a67a39db9a85dc7ee7a981f9620d288f32b3065587c8ebb689b7effd38` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/magnifier/Magnifier_Dx11.cpp` | `d635b3cdf688fce5f6a04ed4b7feb1201fba9d3e87104b737fe9987ee6343629` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/magnifier/Magnifier_Dx11.h` | `a9bfe2375fa11842b02d2203c6635c163ef53bd4bcf5936e996169d22e7b752d` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/magnifier/Magnifier_Dx12.cpp` | `7efb562c24925dfc2c42f21b73852469d96d8ec1c2c00810571b922c8c3b42ff` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/magnifier/Magnifier_Dx12.h` | `9a59cff0d809c8be29b9fdf308f3be564b091b1515a3fcf158ac6f9f9ead0058` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/magnifier/Magnifier_Vk.cpp` | `4d0296b78dfba5816ca1af05e67b6c6b55f3f6fb39e5accffe9f4367a2fa5055` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/magnifier/Magnifier_Vk.h` | `561438fff90386fbb299488dbe0bcc249a1a8ad87420450e1f3a405f3da9fce5` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/magnifier/precompile/Magnifier.hlsl` | `a96ab3c8aa6a42371b4525be5497a4edd20b4eced2682c47d0f7658f213f3f92` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/magnifier/precompile/Magnifier_Shader.cso` | `cf40d593a68ba9e36915fed91f87c70ac40de565855dee2946c9a6cf6e86ba9c` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/magnifier/precompile/Magnifier_Shader.h` | `24090d42ca2b9589a9d270b162052882a0fe34ae2ae23d35073dc8a8703b7036` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/magnifier/precompile/Magnifier_Shader_Dx11.cso` | `79bd8c89bd884485389fe740f039e3ff15f9fec6b5f11943ab7a527af5f1353e` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/magnifier/precompile/Magnifier_Shader_Dx11.h` | `15713215c9ba3d456bbeb66e63721d6025cf3176605897e1d41b99c5dbd6cd09` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/magnifier/precompile/Magnifier_Shader_Vk.h` | `037a2c6515e59af9f143fdbd730c0c8a10d821c7ffcb0b1b1aeeae1314fb07a1` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/magnifier/precompile/Magnifier_Shader_Vk.spv` | `91445639f44d083d5310aa19c1e302dddfee420cc7fab0e6653bfe4f324a04ce` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/OS_Common.h` | `63e4de3a06bdc38f81f3c7aeffdb3759471f1bb329509f7b3006130bcfbdc342` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/OS_Dx11.cpp` | `9a22aa9c8c7804d29f3a1b04f91e3791449868011e257d0da625db9863a0b953` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/OS_Dx11.h` | `2d4ed38258f92e0955d0f4b7cb334d533db90365793c5e7852826d0e05a1b2ca` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/OS_Dx12.cpp` | `ebee8713e9bc98e2d598349ec347a4bf2fca2877418d6ab5719344db90e4faeb` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/OS_Dx12.h` | `5a1cbf0728c7ee93017c18507ce0f4f44974e49a8a59a5a54bf7b5e4b4aa01ca` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/OS_Vk.cpp` | `925d7f6b4977e501d6558e50e59a2e84d397d5370966d41e7c6705ec967926fc` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/OS_Vk.h` | `f24f58e27986bd50338a43fb67ffed7c9a796d0c7a7aa282d661478b586f704d` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/fsr1/FSR_EASU_Shader.cso` | `a5c89c900c44882ba202bf65328315793c3d2c7bb821524bb249fef964e4dedd` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/fsr1/FSR_EASU_Shader.h` | `d9a074d7621d979d114fe58fd6311f178515ddc010ed4663c5e62eb8aeef986b` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/fsr1/FSR_EASU_Shader_Dx11.cso` | `a5c89c900c44882ba202bf65328315793c3d2c7bb821524bb249fef964e4dedd` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/fsr1/FSR_EASU_Shader_Dx11.h` | `d9a074d7621d979d114fe58fd6311f178515ddc010ed4663c5e62eb8aeef986b` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/fsr1/FSR_EASU_Shader_Vk.h` | `23a776f1f61f0bd10f280670e7929671e4c7a1eab76afcdb3a9b1f48cea10cef` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/fsr1/FSR_EASU_Shader_Vk.spv` | `58b6ea4e5fb1d39229e0f84f84c8e8e26fc9cc813e1a9f54f7471d28872a0e9b` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/fsr1/FSR_RCAS_Shader.cso` | `bdcd389e2985b63665d9671f7fca439153b5c58da98097038d018e71f969515d` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/fsr1/FSR_RCAS_Shader.h` | `168707be544e586690fe78140febaa28bb119a159af42fc2c52f9712caa8a287` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/fsr1/ffx_a.h` | `1b161667a5b3bf8ce0d08a3662202c94e7c736ca3697b184ffc9f0c9692d2058` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/fsr1/ffx_fsr1.h` | `7bb0829548d7b5fb212557f1a3c3082e34adb24af9b304e71361a5423102f132` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/fsr1/fsr_easu.hlsl` | `5e47ef4f791cbf593b00a3e85d78ef4e289e157b5bca9cded25b235ab072ffb1` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/fsr1/fsr_rcas.hlsl` | `89f4b664d32d304e48671907bddc0c8f1afc4e51df067a1c8cc1f42d773e3667` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/BCUS_Shader.cso` | `e7a64857368c36f9abbc22fe6ba0fc5f46a1d1abb6c420609d436151d5dc6da6` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/BCUS_Shader.h` | `331409425bb5765d7fd4e9c3ebca5c8ae4270821b694308dde17ea2b3fceb63a` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/BCUS_Shader_Dx11.cso` | `e7a64857368c36f9abbc22fe6ba0fc5f46a1d1abb6c420609d436151d5dc6da6` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/BCUS_Shader_Dx11.h` | `331409425bb5765d7fd4e9c3ebca5c8ae4270821b694308dde17ea2b3fceb63a` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_bicubic.hlsl` | `203f787ae4105fa8476c9f34f352b5291f4a5090839ff3e3e5cd34885540d15e` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_bicubic_Shader.cso` | `5e3190943ad79cab04c2b16a4cfa436791a00cabb4341240e4a9beee76aefabc` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_bicubic_Shader.h` | `9dbb06835896a52ba74487d867e2e6b6e13251ca92afd08694c9ac944ebdd469` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_bicubic_Shader_Dx11.cso` | `5e3190943ad79cab04c2b16a4cfa436791a00cabb4341240e4a9beee76aefabc` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_bicubic_Shader_Dx11.h` | `9dbb06835896a52ba74487d867e2e6b6e13251ca92afd08694c9ac944ebdd469` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_bicubic_Shader_Vk.h` | `959eca76953f08944974e71550473180e6d2de5743b2d9138f74450bd5efd6d6` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_bicubic_Shader_Vk.spv` | `4ac02bc2c0195e7bb3534b429802d7755536f0fff1abfa9f93690bf890623a78` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_catmull.hlsl` | `3a172728ba2271ccce93eb11939c01cb4bf83ce1bf920a37cc934ec410b0b853` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_catmull_Shader.cso` | `d9805122f1ad3e78272c01366bcb28a77a2186b437393a8d8af1ab5afcbf592d` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_catmull_Shader.h` | `3733eeacf7b39658830de0b34936120ba08b4574b894b6c727602da8046d3071` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_catmull_Shader_Dx11.cso` | `d9805122f1ad3e78272c01366bcb28a77a2186b437393a8d8af1ab5afcbf592d` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_catmull_Shader_Dx11.h` | `3733eeacf7b39658830de0b34936120ba08b4574b894b6c727602da8046d3071` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_catmull_Shader_Vk.h` | `ab4f244e07aa6b1b7240db945bf93ef21b166aadb6c3a1b5770bbbbc8bced4d6` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_catmull_Shader_Vk.spv` | `5de62230c9fd7fdb3d72295d851eb623bab9a2601af3838b15499d93164b7bed` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_kaiser2.hlsl` | `570b060c4ec45f2545c624920bebc865f305eaaf801ee8f497d5fccce4387540` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_kaiser2_Shader.cso` | `4362fdbc19f94da3f27e6099b83829d99e5973cad7d0d1dce5550cb3369b6c07` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_kaiser2_Shader.h` | `c2654af4a6c7c3438738e43bbe3013a1aadbb24f2740975ff751124870692647` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_kaiser2_Shader_Dx11.cso` | `4362fdbc19f94da3f27e6099b83829d99e5973cad7d0d1dce5550cb3369b6c07` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_kaiser2_Shader_Dx11.h` | `c2654af4a6c7c3438738e43bbe3013a1aadbb24f2740975ff751124870692647` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_kaiser2_Shader_Vk.h` | `be8b99b0b9f10f33259c86624bd03c24bc4e16f5df6070763cb80f1a9ee1b4c1` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_kaiser2_Shader_Vk.spv` | `5117ebca23f97ddacbb04abbe2a11fc433cc7a1dc99f198707b3e6ca31607cc8` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_kaiser3.hlsl` | `79379639d606524fb38e995a3c942bd1d1c44c476171272e34cdfd76868caad6` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_kaiser3_Shader.cso` | `1ee4ac3c118a48ba4c21ab0c63f69adf5b0944b3b3116ae0a863fa00a4cb3a5c` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_kaiser3_Shader.h` | `a35e93637a4302b4f34101766883e386bf7dc924ad0a9181e4854611a0912766` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_kaiser3_Shader_Dx11.cso` | `1ee4ac3c118a48ba4c21ab0c63f69adf5b0944b3b3116ae0a863fa00a4cb3a5c` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_kaiser3_Shader_Dx11.h` | `a35e93637a4302b4f34101766883e386bf7dc924ad0a9181e4854611a0912766` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_kaiser3_Shader_Vk.h` | `15fdc94d3fc2b7262b10433690c1d6d267636c2b582043f22ecccb71c17ccce8` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_kaiser3_Shader_Vk.spv` | `5f6a2ca0abac100eee754d032d0cb99120473cb5f139e77abc351fc7faafc6d5` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_lanczos2.hlsl` | `6c543aa4f5736cdfa508faa83c26c39aa033479e045d9423194de09ff3820fa8` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_lanczos2_Shader.cso` | `3ab260cf94265c267541669b730b210e83ea52b354472b72c593a45944ab5c80` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_lanczos2_Shader.h` | `3238c761ee6efd3b855fc4a223bd71d174a1f5cfa205b49728b5aa9c9ee00bef` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_lanczos2_Shader_Dx11.cso` | `3ab260cf94265c267541669b730b210e83ea52b354472b72c593a45944ab5c80` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_lanczos2_Shader_Dx11.h` | `3238c761ee6efd3b855fc4a223bd71d174a1f5cfa205b49728b5aa9c9ee00bef` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_lanczos2_Shader_Vk.h` | `7447b436b41994bf43abfe826a012134fa4540f10394932d212cc912573c1e58` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_lanczos2_Shader_Vk.spv` | `ee9ebbdc0e833309cebe42bf80e4acf05dceec8b1fa6aab7320a61edecc5f859` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_lanczos3.hlsl` | `f63b269279b702388cf257f01f869a5fbb722eb11dd91f33c807d8e5acb252cc` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_lanczos3_Shader.cso` | `dd1d6ac1a28a2f7a4cc538f7bedefc449f694bbf3d1586f43f467a43c942eab8` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_lanczos3_Shader.h` | `8c89b56c772ac359366aa7f9033272bae00bbecad342b7f62cbe0fa35938f763` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_lanczos3_Shader_Dx11.cso` | `dd1d6ac1a28a2f7a4cc538f7bedefc449f694bbf3d1586f43f467a43c942eab8` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_lanczos3_Shader_Dx11.h` | `8c89b56c772ac359366aa7f9033272bae00bbecad342b7f62cbe0fa35938f763` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_lanczos3_Shader_Vk.h` | `75237aeb094decb21d9a99f9a29fb162907f890f314891a20f30d16c5e222144` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_lanczos3_Shader_Vk.spv` | `5dcf95eb63a86c0d7fd3ac5e38ce46f1fb6e4de78ba7ad8c3272fbaf4f78f550` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_magc.hlsl` | `07a6a007fcaa4239be67dceb5f87e43fa837f5d3c21a6a5be995913d287b558b` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_magc_Shader.cso` | `8373823c5f7257347ccb3a7674cd7431f33daf32d17a07f16789688c706b9d8b` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_magc_Shader.h` | `d164680bf4a3e7d737952005be4623b68c610b8b6e3cef2ee7d0c91f15710abc` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_magc_Shader_Dx11.cso` | `8373823c5f7257347ccb3a7674cd7431f33daf32d17a07f16789688c706b9d8b` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_magc_Shader_Dx11.h` | `d164680bf4a3e7d737952005be4623b68c610b8b6e3cef2ee7d0c91f15710abc` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_magc_Shader_Vk.h` | `47700f08be6309cc677f7fa34acece980c4c07e0b0d5969864db6f0af2d56e22` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcds_magc_Shader_Vk.spv` | `7a144ff7c067c4e4d9002e997f8a4f93407e3a4f36b2afc80ff6ba3b7c780f19` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcus.hlsl` | `3fce17be66d62d669c3c6196772e306852907bb3deb29f4d329841828b21747c` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcus_Shader_Vk.h` | `277e0dcb40cf45a3545e3bfb672e49165fa4f4b8ecaa6f73a3f1b458676e6b68` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/output_scaling/precompile/bcus_Shader_Vk.spv` | `f1317d2ebc422a4d2cc1f4cbf248463b344e0797dcd421777942af3cf6d9e8fa` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/rcas/RCAS_Common.cpp` | `37fa31d1d99f699892af771e716adfb49e58708dfb12657302aa878a82ecb8f5` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/rcas/RCAS_Common.h` | `72b0deec20071f6ef87bd8751217142a751cd67d55ce66edeebb812e45b5b81f` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/rcas/RCAS_Dx11.cpp` | `ed696409faccf5392383cd255816059a199927f81408d480b4eabb3d7104e714` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/rcas/RCAS_Dx11.h` | `b8c40a23572baa9c9d113d5d4962b26769dd14157d81e1a17031a827657123d5` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/rcas/RCAS_Dx12.cpp` | `8577d21d3ee859c8f8923b6b9b59d70e5251227b455b41c9a17c7a01be28a97e` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/rcas/RCAS_Dx12.h` | `842eb1705e155b4d6cd6b30f44817f982378466e0fd3aed79164853d275511e3` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/rcas/RCAS_Vk.cpp` | `255e50fb9f25543212cc6f7b3dce07d6a98446995c03956f5d8d223e9fec3856` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/rcas/RCAS_Vk.h` | `12f2ca1119e6b8b38945d1c727f171607451751ea1ef7144f0d7d35b1b62b65d` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/rcas/precompile/RCAS_Shader.cso` | `ecfde2eb465a012274a1b3cb7fa342ae4c17b419da44043249eaa3926c484460` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/rcas/precompile/RCAS_Shader.h` | `211135577aa8bc82c3817564ddc9b30435990ef4e0555ac95911b77bc0833b19` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/rcas/precompile/RCAS_Shader_Dx11.cso` | `1e3851f92284949ce2fc26e66ff6cd41b74dc33017c83930202dac50781c4772` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/rcas/precompile/RCAS_Shader_Dx11.h` | `7ae559ca7860da3e090dfb5b62209c80b4d3ed1d9a53ba063699a53bde4bebe7` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/rcas/precompile/RCAS_Shader_Vk.h` | `f5761f9a5972920edfed920e39929e114d4d57470fa59da0c0cd63c8ec2a5e1b` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/rcas/precompile/RCAS_Shader_Vk.spv` | `be29681bc2f1824dade6fbebb508499bcf8ba951938fbd5e172bff1a12f92465` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/rcas/precompile/da_das_sharpen.hlsl` | `491423794ba9c5b5b29d92b9f411a5d03aac87a8e4817638e33fab2cfa520681` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/rcas/precompile/da_das_sharpen_Shader.cso` | `4ed77bf9ffdb537be5add44b4fe720c292c6769be3ca0d8c899e67772d8a5c65` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/rcas/precompile/da_das_sharpen_Shader.h` | `1c45318bed2d6b1e81baf34a8b35c03b5e45a1dea6ce94f345e4919f9bfc986d` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/rcas/precompile/da_das_sharpen_Shader_Dx11.cso` | `4ed77bf9ffdb537be5add44b4fe720c292c6769be3ca0d8c899e67772d8a5c65` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/rcas/precompile/da_das_sharpen_Shader_Dx11.h` | `1c45318bed2d6b1e81baf34a8b35c03b5e45a1dea6ce94f345e4919f9bfc986d` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/rcas/precompile/da_das_sharpen_Shader_Vk.h` | `3896eb4ca10b7fbf752ceb6ca5473f909826ec6666d1e72c87ef5fbb0261eea1` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/rcas/precompile/da_das_sharpen_Shader_Vk.spv` | `281f6736acd58f24b8d5597c11f4559b872151b13a8ca400fda06d2413fe3e92` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/rcas/precompile/da_rcas_sharpen.hlsl` | `60fb9ec1d18b9b0f3fac6a3e224fc5d5dcc7f2ec3d82b8201f256333eaabfbcb` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/rcas/precompile/da_rcas_sharpen_Shader.cso` | `0fc255576dda515623b8a4b221cdbed01846d308abe807a16f9fb27818a57655` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/rcas/precompile/da_rcas_sharpen_Shader.h` | `ee35680da1290cc9291ef88c4fd28cbde5d9bcf097cb18acaf372c9eb9445ee0` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/rcas/precompile/da_rcas_sharpen_Shader_Dx11.cso` | `0fc255576dda515623b8a4b221cdbed01846d308abe807a16f9fb27818a57655` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/rcas/precompile/da_rcas_sharpen_Shader_Dx11.h` | `ee35680da1290cc9291ef88c4fd28cbde5d9bcf097cb18acaf372c9eb9445ee0` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/rcas/precompile/da_rcas_sharpen_Shader_Vk.h` | `ee5d8bb102d667984e84ccf4cbbf5aa302d4c76e7be65f330d3d2fb8134efb31` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/rcas/precompile/da_rcas_sharpen_Shader_Vk.spv` | `c7b6e61db51bfb5bfbfd73997375f193c854d53794227dbf4a4ed3dd931ea16a` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/rcas/precompile/rcas.hlsl` | `ace1f2cf5611f2925a8475be440e43581499ad00cf4100fa47155a4681c306be` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/rcas/shaders/DA_DAS_Shader.h` | `3e8478654913b7806e746af9dee80aefcc711e95dd8ce2bbe922334b365d82d4` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/rcas/shaders/DA_RCAS_Shader.h` | `b8a071154dd58afa52c755d0aefcb74e7d2008bffc5b1a7f0f73d146b92eb008` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/rcas/shaders/RCAS_Shader.h` | `682a1b844d871a1bb1880983532c486cd2cafc8170648db4805391e0461257c8` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/render_ui/RUI_Common.h` | `aee1765016ce60eec7dadb736514a294c25f5eee1ede59db550ef878d3826a9d` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/render_ui/RUI_Dx12.cpp` | `d7560af21708d2354569e9057e2108beb2ce9229fc14ef6d0a269ae239001a7b` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/render_ui/RUI_Dx12.h` | `1943177f8757ca94d6a6ca25fb0ac3a06c9f80eacf9a1cc0953e341de098adf1` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/render_ui/precompile/render_ui.hlsl` | `5f82d6acd88c5cee2edce90346d2efb4488b3b22ee11a97b38b2684acc29f9ab` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/render_ui/precompile/render_ui_PShader.cso` | `b3541ceb929c84c8e1358545afaf7a61872093236df7b7641790c87200f55630` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/render_ui/precompile/render_ui_PShader.h` | `2fea90a5c757087dcfdd3680010dd2327f58701487873583f80e1c8d9c8a9206` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/render_ui/precompile/render_ui_VShader.cso` | `6b38788b9f6f3167b724eae2d66a5a2a84ccf783cbc9f804e56c441e606f3213` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/render_ui/precompile/render_ui_VShader.h` | `28996cdbf3492495d33889b95a768bd40bc22d03c4526a92b3e706ca7a418be3` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/render_ui/precompile/render_ui_pm.hlsl` | `0befe63e8b057fecf64666e299123415eaed05c7a8682307ed9d44acf58c12f3` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/render_ui/precompile/render_ui_pm_PShader.cso` | `a9914a7eea42817d8bdcab1b0388538012dcbae9062d35c085580187dde708ba` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/render_ui/precompile/render_ui_pm_PShader.h` | `b01a85ccacfbaec9f16369936ba50ef2667253566d250a51682446b66d032c92` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/render_ui/precompile/render_ui_pm_VShader.cso` | `6b38788b9f6f3167b724eae2d66a5a2a84ccf783cbc9f804e56c441e606f3213` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/render_ui/precompile/render_ui_pm_VShader.h` | `05634ad4f32c18a6dd54d0479ec599606740523b9ab3af1267f5b6408ac8c85c` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/resource_copy/RC_Vk.cpp` | `769bf458a42172f258065d6725c5e86b0eb2a526b4a923deb6050e40980c617c` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/resource_copy/RC_Vk.h` | `36c14b13f20e3f77986bf9943906f0d6e7e127360cf8433d6e75a29eef46836b` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/resource_copy/precompile/rc.hlsl` | `a4e97e4129e222d2b32397e8a305dad11720429047dd95f667c18c0b08be5797` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/resource_copy/precompile/rc_Shader_Vk.h` | `e5701da6f3eda9acbc3f9477e3f53e1f5228713017d645a7d52499adf1e84a80` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/resource_copy/precompile/rc_Shader_Vk.spv` | `03495301263a0373ff444ea888f045450b53673df4455e05e1002b2942e82932` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/resource_flip/RF_Common.h` | `4de88048860d556cb3fdee3f98019c20267573c8a3c27c36b42a6414fdab7fef` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/resource_flip/RF_Dx12.cpp` | `024c4dc75a717f10f95b2e8a725e398f8edcc0220f603b67cc8fc2372b7ab2d5` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/resource_flip/RF_Dx12.h` | `f349bb187547de1ff7f6aae0f56d2005a1567b5febcd72c23dbc18e7908486a5` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/resource_flip/precompiled/RF.hlsl` | `aae96592ff08dc0438703b4b165aeb04f37dc42f30f4fdf8935d17c8d598ec38` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/resource_flip/precompiled/RF_Shader.cso` | `03677a360b9c0e403f1bb311232a5b9fff8c9c1276bcdd03b38d32e322edb2c3` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/resource_flip/precompiled/RF_Shader.h` | `745ed8f3d6152478539b8a75e75c880451023230048451a080daca754398ce76` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/shader_tools/build_precompiled_pixelshader.bat` | `724297525022e325e997987a5f703bb0306001e43795d29b5a2ba057d9414653` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/shader_tools/build_precompiled_shader.bat` | `bf1d79a86c1464669e50f5d7d7270bb458ef3c43227ef8a2263ae1ef1abb6d6e` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/shader_tools/build_precompiled_shader_fxc.bat` | `5e18e3f28d397cf6b1b2c48330088dcc99aadc090db4e6bd5482adcd6cc2cb21` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/shader_tools/build_precompiled_shader_vk.bat` | `647b49a08189859c041d3009b1b1a3627c1dbce8db63d8ae582e335201e67945` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/shader_tools/create_header.py` | `edb11fecb6769d0843811bdbf40db42f67ff707a436704239a5635f1426f0f8c` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/shader_tools/dxc.exe` | `b9cff94181248e080804b385da8964b6319fd07760721baa9053a891cf7a727f` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/shader_tools/dxv.exe` | `91c1d4a6e0efb6ff1d89f648ac0621b9b1f91230d4d74ace00907e0e0794b7c3` | tracked | tracked-modified-product-source |
| `OptiScaler/shaders/shader_tools/fxc.exe` | `31fa10504b1551337de4d06ec2194143885a76a8b5a81177999e2faa34729183` | tracked | tracked-modified-product-source |
| `OptiScaler/spoofing/Dxgi_Spoofing.cpp` | `b962fe469100b5de86c8facf58ae5c0f7e4856e661980f36c9bf3120a145e1e4` | tracked | tracked-modified-product-source |
| `OptiScaler/spoofing/Dxgi_Spoofing.h` | `f70ef78057777933a925757eb2959aafb3d869984b00a1538ce82f8ec4094e4c` | tracked | tracked-modified-product-source |
| `OptiScaler/spoofing/User32_Spoofing.cpp` | `bc6092fee4d1926525870fd7738a3771dbe77bb68b89958b6939c252ecfd8b86` | tracked | tracked-modified-product-source |
| `OptiScaler/spoofing/User32_Spoofing.h` | `c9d4cc72e08862e0edbfe32d37e856308949326cd175e268c577f29aa50d7598` | tracked | tracked-modified-product-source |
| `OptiScaler/spoofing/Vulkan_Spoofing.cpp` | `c46e2ed8fd6a114c262d72025058314913129bd32264446778da4fef519ac41c` | tracked | tracked-modified-product-source |
| `OptiScaler/spoofing/Vulkan_Spoofing.h` | `760b2a80a312fa1a24982f7c2596dbbfd94b6df58eccaedff7dc41a692948200` | tracked | tracked-modified-product-source |
| `OptiScaler/upscaler_time/UpscalerTime_Vk.cpp` | `194730f2f820ec7ea8384cf53d726c5d51f8862a0cf0476cd23625f45cb954e4` | tracked | tracked-modified-product-source |
| `OptiScaler/upscaler_time/UpscalerTime_Vk.h` | `6bdf06baf1e6ec93c651bd8a7c1d72a4eabb889c8004a4c032b4dbd19c498790` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/FeatureProvider_Dx11.cpp` | `90189669fd3b59c3b1cfb50c1816ef29bd4efa84b2197d665a2e0ae5a2079d53` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/FeatureProvider_Dx11.h` | `5f411f0626972b3cd75c7e0b3ca3040d5a55c01b826bc27805420db34e457d37` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/FeatureProvider_Dx12.cpp` | `aa28a2c9a3e66e838dcccf2e2018ab95eac3aed6a75265c3679563cf4863aa1b` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/FeatureProvider_Dx12.h` | `44aa07ecf433b0aa88e1911469e6d2263e03c49f83c221edb9e3481626fd2bd7` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/FeatureProvider_Vk.cpp` | `f2a84fe9149dc271b96ed545d0ce9e4eaec4b1236b65628d30a5b11761ba2f8a` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/FeatureProvider_Vk.h` | `258b87f71ad8c3a5c6a8904e4ef2a64b0a826b8413aeb895fa035687746552c9` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/IFeature.cpp` | `8535fd73136711b4ab3780e44f8886ec508d0a3dc028fdaecf9e7213c88f742e` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/IFeature.h` | `88a0a48c4d911883bc0f07f31c386e95919e7a93d1ba8c43835da0ce7fbb0ee5` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/IFeature_Dx11.cpp` | `a6dea74d723ebf2c8018480f989910ef97b6df5a092cf3ccdff5e651dfffa57c` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/IFeature_Dx11.h` | `1a84360157197718abcd4df8bee90dcfe1cf48e8c171c3d151b6324c8275d3b6` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/IFeature_Dx11wDx12.cpp` | `2ad9ed8974f2bdfbb4af7ac3a4ec3d8dac723eea509f81a63b762607522ca86d` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/IFeature_Dx11wDx12.h` | `37bec1c8ac452aa07b68f4035710a42abd6d9fd615cff5f2ca102c35eade5ac0` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/IFeature_Dx12.cpp` | `356066be59a59f8f16d5c6c1f5a5b9df1991b78546bf7c68c7898eaa5e5396b8` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/IFeature_Dx12.h` | `ba53f1bcfc79c3ec89e05bd747033ffb3b6a4abdb8843cd2cf1472c5dc104f66` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/IFeature_Vk.cpp` | `9f9c167d62489dcac8f847ba1f873c694cbeea5f1f8685521c8a2640e1902260` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/IFeature_Vk.h` | `a11e97d5281465e28db3386d13af4dcaaca699df732c48a2972539380b61a463` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/IFeature_VkwDx12.cpp` | `a7b2803eb3228e5f94fdbd1b8a8cb87c2d4596adbf46ad2c10ac93ba88726ede` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/IFeature_VkwDx12.h` | `f9bd41ca2b0eb681440082227cf9145262e3bf7e53fafc0702ff9f276fd89574` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/NgxOptionalDx12Inputs.h` | `c26b778d23e2544c3a03536fa191b68395006eb94610e3c461cfec7a07bb19e9` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/ShaderPipeline_Dx12.h` | `411a3d99ab1fd1c7c9392606482199c49baf4985a7d468abfafc60843ffe8d68` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/ShaderPipeline_Vk.h` | `d57604f501273821f5a270489daeec880841cda5ef3e4f6bd248c9d9e306900f` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/dlss/DLSSFeature.cpp` | `22c971539111b04bf07e74c1cdf4506aafcec5d65d1613290b0284f666fb1a44` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/dlss/DLSSFeature.h` | `8346cf02e824c8ff9438113f9d5a0a7fb7d9586ff82bcb1972496fbee451bc88` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/dlss/DLSSFeature_Dx11.cpp` | `05b50dade6bd8d50611ad715a9c9f7ea249ba9215cfa78f3d5494a9a0bebbf88` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/dlss/DLSSFeature_Dx11.h` | `971a0b7897a880489a1ecd3462a545b3eb255d4e6e91e6a804706f3dfe20c2f3` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/dlss/DLSSFeature_Dx11On12.cpp` | `b51dc6ab3f94341b3860340939fde7bbbcb513d55f4b9b8656a2da5daba66751` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/dlss/DLSSFeature_Dx11On12.h` | `4dab12eadcf67add9cc684861b59da533b610991adb775afdfa48879eb0ca66a` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/dlss/DLSSFeature_Dx12.cpp` | `6f1c86435436068cb169e209de5e9b78bba7e827bf34844bb03e31093c74a6e0` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/dlss/DLSSFeature_Dx12.h` | `38a8ddab9d2c782f9f1e04549b4868173a13fc64916953a75e3c75dfb9984a3a` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/dlss/DLSSFeature_Vk.cpp` | `18db7fe474c709e34c5fda7728e5d0294d926db67cb96cfcb504672db2d81897` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/dlss/DLSSFeature_Vk.h` | `2d6cb1c6c7bcadcca5e180c55dfd6230d69d1599119a83dbe31b4e5a2bbeb34d` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/dlss/DLSSFeature_VkOn12.cpp` | `574598eb457999253718a1a4bdb4106f9d77ffe67fa5e2f59defb9c307bcab74` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/dlss/DLSSFeature_VkOn12.h` | `965878127431acda845370d39164307f4050d2ad085b0a46610e2b9e34fcda76` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/dlssd/DLSSDFeature.cpp` | `ae6704faed913159c521226f6733cb42adb7b4b8318f6651ee9e0671e3535ed1` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/dlssd/DLSSDFeature.h` | `e073ee16ef08e232cbe05640d7e755c5cb6a5388dee22702ae7592ead1cf23d2` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/dlssd/DLSSDFeature_Dx11.cpp` | `8ec076446b5629e98b66562cc4ff4a42c7aee36f8491c3e0226e81276670a295` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/dlssd/DLSSDFeature_Dx11.h` | `dc1da380d2464151e7ae16aee7ffb308860964b12fdd42d2b0ce7deee297eb1a` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/dlssd/DLSSDFeature_Dx12.cpp` | `72fc486676e2b8351e428758429e1238670f54932a148318ba59d883f3ee848e` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/dlssd/DLSSDFeature_Dx12.h` | `2a69ddcb69b06282366ef2699ee4abfa145b12ab8bc47a59395d5aac6bd912b7` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/dlssd/DLSSDFeature_Vk.cpp` | `39b542a80ee103c2072051a945470450877bdd44c5045035bcce5eddd2500660` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/dlssd/DLSSDFeature_Vk.h` | `d1cf580534eea22975db76ead5eabea09512b2f4496fe71955c0c4d1c3991661` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/ffx/FFXFeature.cpp` | `6f2858e118148db1975201224b0a1f60ac04cba6895a618d7e96ccafa641f856` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/ffx/FFXFeature.h` | `6cafcfeaad616b00f72d60740369c297071de9f18980ea3d9f73dec3edfacb4d` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/ffx/FFXFeature_Dx11On12.cpp` | `51854522ffa2fde34f76f2af5862ff8d4fffc3347ac582f7a4fc79d6eb5768da` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/ffx/FFXFeature_Dx11On12.h` | `4480092aa3f904947e392a76fd1101476121c4c82a763b1f9f607cfb76fe50b3` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/ffx/FFXFeature_Dx12.cpp` | `7b80053b9995f9ab47da3616f368b3fe84413c79c32963a3f677bcdd26157aa1` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/ffx/FFXFeature_Dx12.h` | `b29f8a0aefbe1c84d88610ec3725375a01da4dc10142766832b57cf12c44af0f` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/ffx/FFXFeature_Vk.cpp` | `4f225dda039c18d17e6c2c98840f6e834b017263008a3acc5a45951812bd5e75` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/ffx/FFXFeature_Vk.h` | `3c79b5ac103dbd3f5465641cc18c81cb9d9c655dee5c48bd46eade9fc9ca3c8e` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/ffx/FFXFeature_VkOn12.cpp` | `909b129b1a66e7055291826835995d90182d9ab8d59f3186594d79c0716e27d1` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/ffx/FFXFeature_VkOn12.h` | `cc44d086830beb1063204ad8bcd862da847728ce9ba0ff0c4f9bb9c9123681d6` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/fsr2/FSR2Feature.cpp` | `5132425e49f0a38ecb9cfe12e001603bdb5997918b984f6809334c27e09dbdd8` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/fsr2/FSR2Feature.h` | `5ccac91be0da208852db0a5803b64136c108df2dbcf469e1b84916c3ddb7f21d` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/fsr2/FSR2Feature_Dx11.cpp` | `75eb6b1289c0ba54ed94600aa4f6e213035daf9647b8c6268935ab26e12692da` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/fsr2/FSR2Feature_Dx11.h` | `3c501f7a63885bd12682efa7e1cedb7daba0be8fab786fa301600b8df57ad52e` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/fsr2/FSR2Feature_Dx11On12.cpp` | `745b7765d62173c100c340bef919150ee8715469bd694a6f4f65cb712dbd76fe` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/fsr2/FSR2Feature_Dx11On12.h` | `d3dbb84fb6d5d383673f0af46edb1e3517ec610c0e5d5b5f61d5698006078607` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/fsr2/FSR2Feature_Dx12.cpp` | `7f606e49d996493c5dabe45bdcd53eda8d7d36834f9797a969d7bc7efe7803e5` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/fsr2/FSR2Feature_Dx12.h` | `158fa445a575a4d0558661ff6f016e53074ff52958addfcfef631e9db91fea85` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/fsr2/FSR2Feature_Vk.cpp` | `a18f337f8169f48bc7f23e2735b85e0fc1f7355518ecfa713920712a6d95c9c0` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/fsr2/FSR2Feature_Vk.h` | `659bd75e4c23462ffd2770d61ccafa616339f943f2b11cb968ead2eac2f73a72` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/fsr2_212/FSR2Feature_212.cpp` | `bf6b4388d33d192be28eb525fda80631d11f1b8ab8282bc872a6783c06f29350` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/fsr2_212/FSR2Feature_212.h` | `3ea7e68dce22eb89a782b4230acb0d3fd23acb872999571f14824ca250bbcad0` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/fsr2_212/FSR2Feature_Dx11On12_212.cpp` | `30a295f1fe857c5f2b3b8f76cb4a63048d299e1a7c3defe98659ceb09220188b` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/fsr2_212/FSR2Feature_Dx11On12_212.h` | `328fc1bff76ad67b230cd7ff8c4ce52494998826e0119d7b418691882b5bcc24` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/fsr2_212/FSR2Feature_Dx12_212.cpp` | `b08ebe86ee10248bda39cefb3a52f122abc61491ef03c3088a3aa27d58f27d74` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/fsr2_212/FSR2Feature_Dx12_212.h` | `d54b5176a7c733227096acdc5f78fcd3aed0e0b250c237aa45f030674840eaa5` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/fsr2_212/FSR2Feature_VkOnDx12_212.cpp` | `68a1efdb10b6666b17d05a0df028983b8960a2384ff7939574f6583ddcfcad80` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/fsr2_212/FSR2Feature_VkOnDx12_212.h` | `4182be1d1be68ed9b80a704c20d1d64d2619755f7858c8c09c992dc23a49ab76` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/fsr2_212/FSR2Feature_Vk_212.cpp` | `c7bd1b08dc1930f39d63e44caa8d657498b6060da0878509f29bc6f30a3cdc7b` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/fsr2_212/FSR2Feature_Vk_212.h` | `0b0dce5beea085bbcfe05da0f2a44df602ccdabab09c7b28e4c32369de876520` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/fsr31/FSR31Feature.cpp` | `8119a273b1bc2eb5804070bee317620f3023d9f0782d5e145ba8bb4b1f2f4d68` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/fsr31/FSR31Feature.h` | `d5aaf9e12a03718f5147c4e4d431033d3ca3e41b87fcdec2c07370bae289d2d4` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/fsr31/FSR31Feature_Dx11.cpp` | `3268aa23b2625af2bf156e68645b31c818925ad2a919fea7ddbe617e0563256f` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/fsr31/FSR31Feature_Dx11.h` | `cbd0cf7226617cf665f27fd136dcd811b586abf57e1474f8ede0324c93f0e25c` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/xess/XeSSFeature.cpp` | `79fe1ef2cd8c6ee27a48490247b3445bff2eaed148d764db9b2a01a9e8c1a98b` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/xess/XeSSFeature.h` | `322173b60690d9d97085b33001c0e453e76a220836f60b3ef6a3256702674214` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/xess/XeSSFeature_Dx11.cpp` | `4e7d709c7b8d24ad0eb86afe9b931787c51f8a425593995a5e7b112c3ac1521c` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/xess/XeSSFeature_Dx11.h` | `a47d101850310f095bb63339840eb97e8b8617c125bf55994ac721326bfd2b22` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/xess/XeSSFeature_Dx11on12.cpp` | `62f60eecfdda98a7579863837a0f1176748ee573f34b1736dffb4560f67a9092` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/xess/XeSSFeature_Dx11on12.h` | `c8551f4faa7f6eed96ca1873cb4fd1217f5cd91fddbd48c9c94460d8295bba5c` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/xess/XeSSFeature_Dx12.cpp` | `d9c390f69ea51defd11709edfa7e56e3622d03aab1e7e87fb83ac85b696741f0` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/xess/XeSSFeature_Dx12.h` | `1e275679807fec81c8f8ed39847173d60a8af1e591176a48be43119ae62c10a7` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/xess/XeSSFeature_Vk.cpp` | `21eee75fa1f6a75b0d4a8716ded4083537c2f989cc02dfa7a47c23e133757a91` | tracked | tracked-modified-product-source |
| `OptiScaler/upscalers/xess/XeSSFeature_Vk.h` | `eabc3bec268549af77be96598501a90ba58435e8fbecb47495b2a4da5de8a9cb` | tracked | tracked-modified-product-source |
| `OptiScaler/version_check.cpp` | `a9ccaf7c93a80832cc1cdfdb3d271d9d5d063168229af318c1ac8907814011ae` | tracked | tracked-modified-product-source |
| `OptiScaler/version_check.h` | `ff8391b0272bbccec7fcaede82e21135fe163ecad2ba8b313de6ec4c24e0333f` | tracked | tracked-modified-product-source |
| `OptiScaler/with_dx12/dx11_with_dx12.cpp` | `744573440adf0026d945af14dff20de122abd0222789d5ad40831dce0adf8da6` | tracked | tracked-modified-product-source |
| `OptiScaler/with_dx12/dx11_with_dx12.h` | `ecfd56a763a9c3eb6e7b919c88a1e1d5c098d4e938fe8ff2b968fcd621e9c4ad` | tracked | tracked-modified-product-source |
| `OptiScaler/with_dx12/dx11_with_dx12_sc.cpp` | `870e06bcd283dbca4888bd21c12d01b1497d1a0b42e5ca22a4730b5026dedac3` | tracked | tracked-modified-product-source |
| `OptiScaler/with_dx12/dx11_with_dx12_sc.h` | `0f620bfeccaac59c668897ca919393728f8e7abff2af9133c08add78e473bedf` | tracked | tracked-modified-product-source |
| `OptiScaler/with_dx12/dx11_with_dx12_sync.h` | `361197e4333a9992b1eddc8d01be44e8c7b2135a81a8118e28afdb43c90331f2` | tracked | tracked-modified-product-source |
| `OptiScaler/with_dx12/with_dx12.cpp` | `73cafdb9bd1816456974e067bb82d09ad93138fb58c6062560971c62eb3a4a78` | tracked | tracked-modified-product-source |
| `OptiScaler/with_dx12/with_dx12.h` | `6144105f5da736b48c001403a2a1f52cc57355fd8694eb355de6d58e9c6eb3a1` | tracked | tracked-modified-product-source |
| `OptiScaler/wrapped/wrapped_factory.cpp` | `17e5eca7b6ba71691ddde8b4ab5584503c60e248f8059b734b776a268c5d37d5` | tracked | tracked-modified-product-source |
| `OptiScaler/wrapped/wrapped_factory.h` | `6c38571c45009dca802c844df7e4d8769f5e142e5ffc0b772e0532ce1465b8c9` | tracked | tracked-modified-product-source |
| `OptiScaler/wrapped/wrapped_swapchain.cpp` | `0fe906ff931daef3c16abc6bd8a2e5cd04252d4aa7202a53e95107375688fa3c` | tracked | tracked-modified-product-source |
| `OptiScaler/wrapped/wrapped_swapchain.h` | `7b992ad9ef8307eb6affb35e55e15b728a888b60a09ba2f10e097272da3db935` | tracked | tracked-modified-product-source |
| `README.md` | `538d5fe6be96122bf577e3c313afddb8527c0d63d9c3aa1d67b389abe77cd6a8` | tracked | tracked-modified-product-source |
| `Spoofing.md` | `a4ade7d18bd8a257526d5b79bd8e81de3f97725dcebbbd91ec16f9cbcb8bec63` | tracked | tracked-modified-product-source |
| `Streamline_fetcher_windows.bat` | `3b0b0f9dbabe95ab42ab79c1990796f4eb75d364a2d7b5869b2e305468e45702` | untracked | required-product-input-untracked |
| `Streamlined_fetcher_windows.bat` | `4052e172f464235c9b33bcefd63965250a592f11129d0dee032942db3453cae3` | tracked | tracked-modified-product-source |
| `docs/COMPATIBILITY-CHANGES.md` | `2b72a950d790dd1a8dc994f70e644283ee55e27aef1cf07da7299929e6e91ff2` | tracked | product-area-untracked |
| `docs/CREDITS.md` | `700318091df65fb10ebde069a8229bfabea5fec0daa1d755ce7e171f7e5bf236` | tracked | product-area-untracked |
| `docs/DEFERRED-NR-DLSS.md` | `8b9002ff7a85519c55bd4148f60922d6fb57e37f6f4b934d2f1d9ed43685ea6c` | tracked | product-area-untracked |
| `docs/NR-COMPATIBILITY.md` | `554d9068f10bede9dbe0511cf4e862de980a533bac6e7fc14e003d3062f7ccd2` | tracked | product-area-untracked |
| `docs/NR-DIRECT-RUNTIME.md` | `128d5a9e3a920c326d81a960870613cf9c211d77c30a58e541906badbd55489a` | tracked | product-area-untracked |
| `docs/NR-DLSS-ENLARGEMENT.md` | `fee366effad9a1bf2c53bebfc3ebd9200313548e354b399ceb3f5bbf8b05fc3e` | tracked | product-area-untracked |
| `docs/NR-FINISHED-BRIDGES.md` | `2b7219c306a41e5619adb95338585160704e0370d9e392fee899562bea999e25` | tracked | product-area-untracked |
| `docs/NR-GPU-RETIREMENT.md` | `ac4bad7cff55c9ac90f9e18efd5ca3ce2edaaeb5a0320c6863f474edfbaaa9ba` | tracked | product-area-untracked |
| `docs/NR-INITIALIZATION-DIAGNOSTICS.md` | `fba1d130e1d14a4cd322c66bc905e61e760f63019a6406ee8c53668745347930` | tracked | product-area-untracked |
| `docs/NR-MOTION-METADATA.md` | `e098580599ad09208d763ab1c9967dd6138f1d5034e918e0c5bc2fcda7443a52` | tracked | product-area-untracked |
| `docs/NR-NATIVE-STREAMLINE-PRESENT.md` | `8670d2eb32a54627fa297f81d0a39c92df95cbd2f4bcc726f73eb3b2ab548ba4` | tracked | product-area-untracked |
| `docs/NR-PHOTO-DIAGNOSTIC.md` | `07caea8f8a722056c2c35524240635b5015b9617c1b8c05929fa168f0ee42082` | tracked | product-area-untracked |
| `docs/NR-PIPELINE-UI.md` | `a62953203e8ff07a9056a49e96437bda9c6d5f9a9d2eec0ca11195e12aa80d1e` | tracked | product-area-untracked |
| `docs/NR-PRIVATE-RR.md` | `1279c21c0bbc8d88c5ee0add7bdf37fe75d2ec3afd5347c809b6fb3ca030188b` | tracked | product-area-untracked |
| `docs/NR-RESTRICTION-AUDIT.md` | `60faf68917e8135ed1714ea8ab4469ed41a7d54c343a8329d082c14eddfe3742` | tracked | product-area-untracked |
| `docs/NR-UPSTREAM-DIFF-INVENTORY.md` | `8ed01990deb4e9002521cef356b7bb61a3fdac6ed3aaceeb21b925581e61a97b` | tracked | product-area-untracked |
| `docs/NR-UPSTREAM-REVIEW.md` | `b1f2e177db3f27e6cf58fe3ff376f857df456d8192c8def9ce80e6d4672baf87` | tracked | product-area-untracked |
| `docs/NR-VULKAN.md` | `1492144611632197057a4d49bd08d15fc9fe3abb92dd7dc116fd819a0a38adb5` | tracked | product-area-untracked |
| `docs/PADDED-PRESR.md` | `39de8ff85b9c7be331c83b85f0551873a5280f481b025149e36baa82efac202f` | tracked | product-area-untracked |
| `docs/PR-REWRITE-REVIEW-v0.8.5.md` | `b8033fa602bd6706f2b489dae29cce5657c45ea3e43e960d91a7d2ec5f86e777` | tracked | product-area-untracked |
| `docs/README-XeFG-MFG-Unlock.md` | `6d8ee50847bb2aba8c691190b35c137b20fe384083325f6dd3ad02bd37a3eabe` | untracked | product-area-untracked |
| `docs/README-XeFG-Pacing.md` | `281dd66afaa739bdba680f8d2f180606f6025ddec5aece014ced984930a40700` | untracked | product-area-untracked |
| `docs/RELEASE-NOTES-r3-KO.md` | `9c282cbbd53cd9003bf50a169c448a55241dc7bced017693c1e0fbd28d95cc13` | untracked | product-area-untracked |
| `docs/RELEASE-v0.8.4.md` | `dfde0104fc4116a05e2bafeb72af8a4b18d0e12f9e4066b846795d2ab67dbe29` | tracked | product-area-untracked |
| `docs/RELEASE-v0.8.5.md` | `91551eec5c210b01f344cdd152dca69a980ae48e6db823d4df8ff7e4a0698c6a` | tracked | product-area-untracked |
| `docs/RELEASE-v0.8.6.md` | `930b1e5de9d688d3d1e7cb83d022af62ef3d9119071f2fe39a30fe1e6a9e40f0` | tracked | product-area-untracked |
| `docs/RELEASE-v0.8.7.md` | `8419b2d1a0082d36029c2a2129a3b139bb5753a04f166e57951f2447fffa9d8c` | tracked | product-area-untracked |
| `docs/RELEASE-v0.8.8.md` | `17121b6ef57df89feec2a79b5fdc725b71209fd9372e6597bb574acb7da26318` | untracked | product-area-untracked |
| `docs/RESIDUAL-ACROSS-RR.md` | `3628986920cc60b0f0c0bd534f890dd12fa9778b0eb6b1a61482f225a3324040` | tracked | product-area-untracked |
| `docs/RTX40-MFG.md` | `1feea9ee2840da6f9401d26ddec959131c8fcb61c0f828b48a799fd1853e6fb6` | tracked | product-area-untracked |
| `docs/in-game-ko-check.md` | `a836f4de17cad1dc430eeaf577cdba4aafab94e553ca7424584cd4cf8e40602c` | untracked | product-area-untracked |
| `docs/ko-friction-backlog.md` | `41d5c0c7fbf044280003f5eb75bac18a3e1144d975aaf9374c89bf856ef914a6` | untracked | product-area-untracked |
| `docs/rtx2030-payload-contract.md` | `0fc1c74a02698b352161aefbc8071c28e6c63c58dfd641f58e3a2f1853bda62b` | untracked | product-area-untracked |
| `external/AntiLag2-SDK/ffx_antilag2_dx11.h` | `1b095ef2480810b838cc5920d0d784fd5c72163a7c68d7817a8afee6e31ec0a4` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/AntiLag2-SDK/ffx_antilag2_dx12.h` | `fd9b60453738bb5d6edc31c947ff927ff8f36c24475ce33f4705ed7aebe1b923` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/directx_agility_sdk/LICENSE.txt` | `5239850894610071566f7ecee0b751fde43c862032d92b99d7d0f596b3433ebd` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/directx_agility_sdk/lib/D3D12Core.dll` | `07d286c306f8117321422affd9e6388c12d0fb4be1c7fc689d9e899324feeb24` | tracked | vendored-runtime-dll-explicitly-tracked-gitignore-exception |
| `external/freetype/freetype.lib` | `74856e22714bf99f2f04e59cfe77d7c85729e5aa3570030b939048115ef528ad` | tracked | vendored-link-lib-vcxproj-AdditionalDependencies |
| `external/freetype/freetype/config/ftconfig.h` | `f3c2f1d7a3321edf770584838a18d97e2129d1a4ed95bbb1777949b7165e2310` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/config/ftheader.h` | `3efd94b282ed139bb430cd92215fc471eac98e1dd30cfaba08412385649f52e3` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/config/ftmodule.h` | `afa757297aab082ae0d76acf71b0165a7496443c8b14dd3cea32dc98949c4083` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/config/ftoption.h` | `bec19e825412e87d5e8c34babcde911e517778a2f0581edbabf48c0ba1e10870` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/config/ftstdlib.h` | `fc29f7c491959d81431cf742bf4cc44ac8244880af42a12f302b87df02c2ab75` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/config/integer-types.h` | `7599e076216cf4213ac7dbf4372a6d8a01a2073399573004b1703dc1d2c4952d` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/config/mac-support.h` | `a2b33bd43c1fe77dd7c358b076cf50f7ad41fa0d7b48d698e3baef131c71f0c4` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/config/public-macros.h` | `987e8ebc633f222bf07b8531efbf7bffc097e5db9272b4b5f60a1a2cfd4e29b8` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/freetype.h` | `4a184feb875793a7ace74b6c685ab561d96ffcf4a8f4bb0c7587a0a7f915bd53` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftadvanc.h` | `7a73f6a0d398ad2b60c7de3bbb3170e1ef12c5cfcee8793d3215265f9d76b5ef` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftbbox.h` | `0212027b8281154eeee4dfb1aa8c87d6fdf4988ed38e93db5941e8043629660b` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftbdf.h` | `e5ed115b667f535343eab0d7b724d3d2dfa935e912b62e1c486a5453b655462d` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftbitmap.h` | `91699933a299d66aab1045bd87fdaa172918a2c61cc5d3ceb6af73dc5c9f0e81` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftbzip2.h` | `ac4d7749c9add3d6430ec232c0a23c10f06f3533f4c8d675f01baf46dc399e1f` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftcache.h` | `18ee0e817f9d6d99b851d7aa42506d0e80287d6352eceb05c13f81be071eb3b0` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftchapters.h` | `a2dcf4a39c8ff508dd93427f909b66530ad416c653e70a09802feb1ca4568055` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftcid.h` | `243ad80a69ac3a723622a808a5c269ff5a2db86c9669950ee40d183879736270` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftcolor.h` | `7d6beb96943a7a0b49d41e0836ea8ce5a4c1cfb1e51f1afaf2ad703c3067c3fa` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftdriver.h` | `f7ccb4bb490c63c5d00f2b6b170d6311f269a62247108ebad2476ff4eaf4b6f6` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/fterrdef.h` | `d26dffdd159eac4559bf5efe802872a9cc3b7dc9fa9b34cd9f3acd597fc6055c` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/fterrors.h` | `531719a2b5c59f64c0af8f72cd35a62f48a8580127507c6500356660255fed5e` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftfntfmt.h` | `5fec5432efa3d8ad5956543467cf14d66dd8e4552f7bfd21bf6369d1750973fb` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftgasp.h` | `53c3c60b8fd828e37c3c16d5a53ce4e958792f68d4d38e9e1e2aac0df0e3fd84` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftglyph.h` | `d3bfa77167ef098cd1a798bcba47e86f03d6550a6756c02f6aa5d87d944017c2` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftgxval.h` | `58a75418889ef78222abf99f2a5232f5ae962db25cc2ef711fd236335e9935be` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftgzip.h` | `49d59411a2605988952ace592e2f15588d1aa78458c4de8c261f5963f91210d1` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftimage.h` | `d489af13bc24d832467abeece86138b5c057eff0d9957d7284ccaa8786522b6e` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftincrem.h` | `2a65f892c6f46496591f432df18707dc4f6bc8767215dada6195384309843796` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftlcdfil.h` | `f6cc6321b96f41ac249b5910041337fab223e3301151d2ab20ab29f4ccf3e55e` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftlist.h` | `5d6752f1d396e2d4464b04a85a9811e673c6ae756a7f12842544accbf7a6b206` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftlogging.h` | `cdd2ee99ab9525543694fd3273977809df6efc7ddaecd26881b0d46df00a970c` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftlzw.h` | `d5bf497f6a6dd74f9a62fc279c374dec2e72bda3e09a3aa4b69f62aff8b1a02d` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftmac.h` | `0649156f262fac5b8813dbc879c8af1319d1768a7da9f294980306d475176f60` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftmm.h` | `e50321a96c8dff9ea4585c90765ab7d899ba720d7592b607334d940718f65cf6` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftmodapi.h` | `af342d1dc284a055734a39351fe672f562292441026e2ec17f4ec292cf625205` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftmoderr.h` | `8c94da098a841940525092e150e548aaa73bfb82c10dd3f65a6b0950716e5b3e` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftotval.h` | `f0fb41b550f30c65867fb8a9587c77f18d5128cfb6b6a5b18398b8923e362df9` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftoutln.h` | `3a7029233fa90ffd5fa3b251607706da89a1c9ea7c9b9b472c9c81931d0dd99c` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftparams.h` | `210759012deff2061f01e8d8bc883162ff9ed8bd52398926ea48419591a1f0ba` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftpfr.h` | `d19bff9476aec81a3c9cbfd6dc8e043b24720e36cc8b77a8033e7802208bd1e6` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftrender.h` | `35b8fa0eb39d4d77524b390509e748b976fa0ba72612e15f72efdedb30274719` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftsizes.h` | `b062ac1cd28d4488e2664744cfb3bd7ecd17088675239b0b20a900eaf9a2e801` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftsnames.h` | `25da2196da623ae5e0778285b0cfd36c551ee5a8c8932f856e862fd50b4aec1c` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftstroke.h` | `0808071fddecf3d116ff47f75bd1d571c63ccfce82f74cb76d16bcf87f565e8c` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftsynth.h` | `49418b39ac7be11490d80e686e0ebcbedd32ee65f3b84dd70016d92fe1da3717` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftsystem.h` | `60e147b41f05e2590463fa6cfac98bf1f3f4a186eec6d68f9dc16f6aa8ab9e10` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/fttrigon.h` | `8e4f6643033ac93c920cc6321044962bff4b701bfe8e70d296e197193b0fed65` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/fttypes.h` | `5341c315ae76e6d0047cd04416c7a39d5352dfb118a7ac3c5635c8964f4eaf31` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ftwinfnt.h` | `2c0152bd050879f9b1e2a5662a825d8cc1294d5de0e6019c346acef36cebf443` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/otsvg.h` | `253d31105b8d9587235c1d4b581e89a39c23e05907ffaeef61af58eb91f9b1f7` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/t1tables.h` | `8018f8c786ad04fa052bcbf0c450e88cc0e17e033ae3f23784bd6bdef87cd5ac` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/ttnameid.h` | `6cdb9b6ed1faff7ecbbbb3a55dcc87318ff3bc2d60af23174c36f5c40db0bb98` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/tttables.h` | `a0d513fa8652bd8a3d55c86e77e365d3804b2b7b0565df3cae832637ec36a203` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/freetype/tttags.h` | `3c6d7734cd047c57f97ca1b04a369adfdf96ca654ed90abc85b987ba17a5d879` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/freetype/ft2build.h` | `1d1760ea6a00a05ad0f8e825a5cba9825466fd1f864707cfac76cb4b57579de7` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/latencyflex/latencyflex.h` | `1126bece30413700478eb1fe55d49797fc57af40c1e18f2a845d4e9b5e1a45da` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/nlohmann/json.hpp` | `5f09d1eebe9b3557f21df155869af13bcde79b74a0748f82ca946e8cc088aaa0` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/nvngx_dlss_sdk/nvsdk_ngx.h` | `b3867e9381c458fa0e407b127de71ef7f16a05e043360d4bead20b5ca5a04938` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/nvngx_dlss_sdk/nvsdk_ngx_defs.h` | `bf4f5e7f89eb98bf116b539c408a3b03a59cd413070b7fd859de1a3c4adf1f07` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/nvngx_dlss_sdk/nvsdk_ngx_helpers_vk.h` | `505e9c12a14b0bd40303ab9a0a5b63180fa42a8fddc1ec62a92b8192a8386f08` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/nvngx_dlss_sdk/nvsdk_ngx_params.h` | `dd9ef57ac264256ddd63b3c75b2894f519c72a1a9c9c23814fb433aa71478ada` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/nvngx_dlss_sdk/nvsdk_ngx_vk.h` | `2b355039fc19e42a81e6a40703c904a961ff2b7027ea39348c6b76110fc8d4f5` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/nvngx_dlss_sdk/regs/DisableSignatureOverride.reg` | `727d77828f6c6c4c8a1ece80b1f7cd3f5df12f92d8e60d20b3d0558ad6229316` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/nvngx_dlss_sdk/regs/EnableSignatureOverride.reg` | `434c9b9fd5b495333e36ec2228ff1f7dfb39a00255e5cb0f2cfaa8212d64b276` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/streamline/sl.h` | `e1e81a7428d15b30db37587e9469bd68a56d630d820a4accec0aee3b17e157dd` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/streamline/sl_appidentity.h` | `1337385ac9867d66fa6beb34c750e79aaf25a74a156a47e83f24937299dade87` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/streamline/sl_consts.h` | `69a9f35aeecd7fbf68a997872ba2e29f27af7da4675f76b94628393d14474abf` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/streamline/sl_core_api.h` | `328dc3a2c1dee579c200ca97e2d5b1ec38c893be4ba2745ef5ad506af7172e81` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/streamline/sl_core_types.h` | `4096734a92c16e95a6d9051040dc4da93bb1e3e3715e34eb2cb1b1740bb05b15` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/streamline/sl_device_wrappers.h` | `af7741305b1a468c3a83efaa2005ecd53d2ffd7aadb8ec6868c9dcb4a8a8e3a1` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/streamline/sl_dlss.h` | `d2c8c61fa71794c8ba424cebce5b3079ebfab8e47ed98b4b00cf8b257ecfd6b5` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/streamline/sl_dlss_g.h` | `1fc18cbe004e280df1f787276d08a1b28b8a8c4c65856fbaa659f56dff6a915d` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/streamline/sl_helpers.h` | `b495f1e1dc88674474b49bc74b8f2d3ba8f19bab089e5127194bc44cf1e68df1` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/streamline/sl_hooks.h` | `cfeff70a52e1cc012cf4c955a15cc9d0b290f7e084dcb3c0168a9af06ff8f122` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/streamline/sl_matrix_helpers.h` | `a65758d85abba1e12845d266d7d5e36aaefa952383cdf093f3143cd6d8653341` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/streamline/sl_pcl.h` | `f43c5135fc8d5349ccd345e424f8cf1f61953a9f17e9897204b0741a3ab7b0fb` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/streamline/sl_reflex.h` | `3b623a1189e04a686384d224a58c4ad9974c4e6e3204077676f6ec529475164c` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/streamline/sl_result.h` | `2a0f6c12863bdc00b38910a5ec85d1f083c5671ee817a920afe626ac2a9100f7` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/streamline/sl_security.h` | `a36b1c20394402bee7ce738089a5a1305ff6e9dd9dd517566154ce834f7c32b4` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/streamline/sl_struct.h` | `5c5fcdb6b8386e81c8e003a7b45a730c83aa96b8d6e03692a54521c94d4825a5` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/streamline/sl_template.h` | `af2d4a61361f2603872dcb6edc86cc9e18912762a5c03e6a782ff39a8c3b871b` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/streamline/sl_version.h` | `c07ea4433db72800a0d60f8e17fff3adf09a195c3dfb8f70edf0b359a1ecea12` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/streamline1/sl1.h` | `9dc8c15cfa7dfc34bc35421b913b0aad26302b4927ff38ce0fc3755d678bc18b` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/streamline1/sl1_consts.h` | `5a608e4f425944afd08de835a26269788653d4209339ab9e6afbbf8e4a051aec` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `external/streamline1/sl1_reflex.h` | `7d9fc4afb2a9459be85766023eb9facf0699bc1341eea5232fac3fe189cae04e` | tracked | vendored-build-dependency-vcxproj-IncludePath |
| `images/Dx11wDx12.png` | `c5259cd29332b3a16db1b7ba43199a3fc4b58802c196933c736db7d286832926` | tracked | tracked-modified-product-source |
| `images/Upscalers.png` | `15886065c6685f6aa33a469474316e6f557980cc1ff07fba7edd0d19c2dad2f8` | tracked | tracked-modified-product-source |
| `images/banishers.png` | `1c5630a031ed9513abc1040c2b0d817f6c87a4b922d6718934081eeeba162840` | tracked | tracked-modified-product-source |
| `images/bmac.png` | `cb402c2e63da90268445e3db1194b4f69936782b0ee179dbba302c3e3322a460` | tracked | tracked-modified-product-source |
| `images/cas.png` | `36aa2815712d10791d255f18ffd5be37dab1c71d9be40fb0eedb67ed02e36319` | tracked | tracked-modified-product-source |
| `images/christmas.png` | `eef40dbb2f96f5b8c886b279f2b6dae7ddab0df8701da2d44df4769d64d519d9` | tracked | tracked-modified-product-source |
| `images/cs.png` | `74915ff461ba8f6abf992df8473d96f7c462da9bcf48b0d1faa8cad8552c438b` | tracked | tracked-modified-product-source |
| `images/dx11sync.png` | `ba383f473b923a26071403f02c9ec6eccf013a5da0dc06cd2149823af085cca0` | tracked | tracked-modified-product-source |
| `images/dx11wdx12menu.png` | `72b6a3bf39a25d3041a947c0619722c541a300e7ea3e7bcb8ad68421bfe41613` | tracked | tracked-modified-product-source |
| `images/exposure.png` | `2322fafc384ae3c350a5509365ef89e5c427a349fc4e54b4df1da91efd202bcc` | tracked | tracked-modified-product-source |
| `images/fsr.png` | `60c203b57c05a4cb6278592e1c88fb78096dfad89d7f1521a1bcf1129cb4905f` | tracked | tracked-modified-product-source |
| `images/gh-sponsor-red.png` | `c994eef9b6650f19b403b9a92b2a7979609b0849701e85dbe06163dd960fa6be` | tracked | tracked-modified-product-source |
| `images/init_flags.png` | `15aadaabf2a8364694d3150d4d3bca54ff71b3d90482723774e18b82194ee8c7` | tracked | tracked-modified-product-source |
| `images/logging.png` | `616d1002e20aa4360fde3316da40197152c388a6027a4bceb34728d5ad4947c2` | tracked | tracked-modified-product-source |
| `images/menu.png` | `c3437dffb289573d43666be176c2d64ab4910c57ba4dc080e17cc36f4be8d6b5` | tracked | tracked-modified-product-source |
| `images/menu043.png` | `4cadbdf466a9d40e6804e2403a6230477ef5b100ca898355ad3b2e0eb4ca8595` | tracked | tracked-modified-product-source |
| `images/mipmap.png` | `9fafe2796a8d5fcefed7a39bde69e7831dd56d660aebc302eadec91f9170e23a` | tracked | tracked-modified-product-source |
| `images/mv_wrong.png` | `2236496678743fba67d425ed25cebe1f73faf4aaf4b6d1bc022817924338b4fc` | tracked | tracked-modified-product-source |
| `images/optiscaler.png` | `3bbf65b3230e609c18840805401b3de4658cbe398a889d575b26592913112973` | tracked | tracked-modified-product-source |
| `images/pss.png` | `52a6fadebeefe0021dd5978dbf635aa296675e2bae1e3e55c883cd16c610449d` | tracked | tracked-modified-product-source |
| `images/pss_config.png` | `aeccda744c9e025d4cc54a7b113a4d5487e10ee252277772bdb4f29a9e57f913` | tracked | tracked-modified-product-source |
| `images/q_ratio.png` | `da0b0280eb67c163b627ed12001e5978d47939443f6e8ea2c1e216a017efb565` | tracked | tracked-modified-product-source |
| `images/rb.png` | `624773ea1906e3bdf8822a88db999f643198574f277fda59c10de7018737d713` | tracked | tracked-modified-product-source |
| `images/sharpness.png` | `d533999fec29bfcd5dfbba6bc969472ccff37c30ce4a3d08058581de9b1fbfa0` | tracked | tracked-modified-product-source |
| `images/talos.png` | `8b1afa3a311f875f65c9c61b4b07bf7f6bab7eb7f78e0c6f55496caddf828165` | tracked | tracked-modified-product-source |
| `images/ui_scale.png` | `70909844b44f50aaf750dcf55320b75a4d37b0b0a4d5c3d8d1e666b0fbd80a36` | tracked | tracked-modified-product-source |
| `images/upsidedown.png` | `030966954f484de560de1b74ab29889d3f302214ca81a3a2ed13c99760604823` | tracked | tracked-modified-product-source |
| `images/us_ratio.png` | `9d4e32ff61816035ac64bdf05216421de8e47b36f60735298833e14601b680a3` | tracked | tracked-modified-product-source |
| `images/xess.png` | `6c7affde271bd59f88fd8879786cbb5c69df43b2a6097c5c8e087473e0ba26e6` | tracked | tracked-modified-product-source |
| `package_release.ps1` | `64113265a6fd38c6eed6023498f12d9dddf2f364a848082acd024426821f474c` | tracked | tracked-modified-product-source |
| `setup_linux.sh` | `0571b0ae077d985616acf9f4101e8338fc225b1b22aa7b339100c7ea3f3022be` | tracked | tracked-modified-product-source |
| `setup_windows.bat` | `0ff1d2628990775e599442b1c2f8f2cfc6ce3aa3d16de945a9c9d2f3c3397c6a` | tracked | tracked-modified-product-source |
| `tests/Run-AmpereMfgIniSmoke.cmd` | `23b6e5cc30fb06ffacaca68c6558b3b6678bd34747e5c6f11237202f4bcab4b5` | untracked | product-area-untracked |
| `tests/Run-AmpereMfgLoader.cmd` | `ecfddfcfaac8ab62e8e564e913af463dc4279fb172e2f63be3ca21efc3cd397d` | untracked | product-area-untracked |
| `tests/Run-AmpereMfgSidecarHarness.cmd` | `b2b6d4476caca3522cfad4b9eb4f7bf547f8fef52367f237ad69e4516efaf298` | untracked | product-area-untracked |
| `tests/Run-I18nFonts.cmd` | `12ab7866edb1e2276b2f6ad4d288b1be118206632315716140ce261d9b746dd3` | untracked | product-area-untracked |
| `tests/Run-I18nSeam.cmd` | `033ff133464a39357785588ab7964cfbbf6fae2bbb3e6a0553a121f620c6aaf1` | untracked | product-area-untracked |
| `tests/ampere_mfg_config_smoke.cpp` | `e5c2503010787ab5cbc20e686ae2e21ffdfa3928ede22a8f2b800257348f195f` | untracked | product-area-untracked |
| `tests/ampere_mfg_eligibility_mocks.h` | `6f0ed199ccb3b01a67148503420fba146b29836af57e20d084b65ec5c44ac375` | untracked | product-area-untracked |
| `tests/ampere_mfg_eligibility_seams/Config.h` | `b506b3ee62f98fbd270cfbf80cf7ee945f6837efd0704b4b6fde508abb6d29a5` | untracked | product-area-untracked |
| `tests/ampere_mfg_eligibility_seams/State.h` | `b506b3ee62f98fbd270cfbf80cf7ee945f6837efd0704b4b6fde508abb6d29a5` | untracked | product-area-untracked |
| `tests/ampere_mfg_eligibility_seams/Util.h` | `b506b3ee62f98fbd270cfbf80cf7ee945f6837efd0704b4b6fde508abb6d29a5` | untracked | product-area-untracked |
| `tests/ampere_mfg_eligibility_seams/framegen/dlssg/MfgUnlock.h` | `b506b3ee62f98fbd270cfbf80cf7ee945f6837efd0704b4b6fde508abb6d29a5` | untracked | product-area-untracked |
| `tests/ampere_mfg_eligibility_seams/misc/IdentifyGpu.h` | `b506b3ee62f98fbd270cfbf80cf7ee945f6837efd0704b4b6fde508abb6d29a5` | untracked | product-area-untracked |
| `tests/ampere_mfg_eligibility_seams/pch.h` | `b506b3ee62f98fbd270cfbf80cf7ee945f6837efd0704b4b6fde508abb6d29a5` | untracked | product-area-untracked |
| `tests/ampere_mfg_eligibility_smoke.cpp` | `2b6ad226cb471e0be9933d706a9e9708312c11f23498835bb87f19015600d0ea` | untracked | product-area-untracked |
| `tests/ampere_mfg_failure_matrix_smoke.cpp` | `d9ae5fde2c1c2d2ba13391dcef5ea01493105b0e6dc4ad2e6bee63d490aa53b1` | untracked | product-area-untracked |
| `tests/ampere_mfg_ini_smoke.cpp` | `4cbd5c4a7e83b3062ea8bc845ba73a6ff73e94b52260422de16affd47fc937ab` | untracked | product-area-untracked |
| `tests/ampere_mfg_payload_pin_seam.h` | `b92f3e33646d42904c69b687b30e3b0cd3ed76a6dd5b2beefa827f8590679ddf` | untracked | product-area-untracked |
| `tests/ampere_mfg_sidecar_harness.cpp` | `04a291ffb55fc29679516771387d4b16d3a08aa199284739cb53de839b93ad48` | untracked | product-area-untracked |
| `tests/ampere_mfg_stub_payload.cpp` | `ca0c02e4b0d4d6b871635c1686fc60613d4aa12aa1d1783ed27b57caffa0b771` | untracked | product-area-untracked |
| `tests/ampere_mfg_stub_payload_standby.cpp` | `a50c9b7d5e2b82a584005ca60095f69312be2a356184b3cd22454ebef48c25ac` | untracked | product-area-untracked |
| `tests/dlssnr_proxy/MockNgx.h` | `bf221b6f36141aebd2716b7133ca09c09c4b708b4231bfb7afc78c81b7827083` | tracked | product-area-untracked |
| `tests/dlssnr_proxy/ProxyTests.cpp` | `64c6d971024734454a1fb7856bdc0565dd28679e8008608d3d4cb0fe7c5cb541` | tracked | product-area-untracked |
| `tests/dlssnr_proxy/run.ps1` | `4d0bd9881d22c33dd68094358afbc6544dbda2438abe230e57935a7ac2239000` | tracked | product-area-untracked |
| `tests/dxgi_window_size_smoke.cpp` | `02f15625cc0541ea5155621b6bd0d35c764f42063ee4cb3f836f1f018fc11c9c` | tracked | product-area-untracked |
| `tests/fixtures/ko/duplicate-key/candidates.json` | `6446c47928ef6cb5b1259cd7a33fbe332bf91aaca6ecf281c7423cfc2393010d` | untracked | product-area-untracked |
| `tests/fixtures/ko/duplicate-key/case.json` | `19775a2307080f112a1cd052cd696545ce757f4093c193892d9cf37c83c1737d` | untracked | product-area-untracked |
| `tests/fixtures/ko/duplicate-key/ko.json` | `0b0356457388fdfc4de73b910ba07bc1f5c0cb1fef64d60f13618541997d6523` | untracked | product-area-untracked |
| `tests/fixtures/ko/empty-value/candidates.json` | `01fd36a7f7fc4542ccf4d8f35d938afd344154f0a7746c3de092f742403c62f9` | untracked | product-area-untracked |
| `tests/fixtures/ko/empty-value/case.json` | `ae1a549bde8f67394448b6f777c3e8f7260079f5247b8fe64dc718c6bd6dc637` | untracked | product-area-untracked |
| `tests/fixtures/ko/empty-value/ko.json` | `614b85d2d482557856d74e17bda178a277dd09d489da2478a0d05935095e3c13` | untracked | product-area-untracked |
| `tests/fixtures/ko/glossary-term-dropped/candidates.json` | `1b6da8355e4e1c8a5c9f3995eff5f9502c8274475f0e0c02e8e66b53be196a20` | untracked | product-area-untracked |
| `tests/fixtures/ko/glossary-term-dropped/case.json` | `dbd01efc25cb0cf4c7b5e1b385ac26e870be5abdf549491e809e3549b5713ac3` | untracked | product-area-untracked |
| `tests/fixtures/ko/glossary-term-dropped/ko.json` | `c6b73aefbd5a4b1712fb8f636850650034ff39227d690e3665dd9c728f44ff98` | untracked | product-area-untracked |
| `tests/fixtures/ko/inc-non-ascii/candidates.json` | `58230e7535f54aa5d52519e59167f86f3800a71d9840e788a0d48b3a99a1c640` | untracked | product-area-untracked |
| `tests/fixtures/ko/inc-non-ascii/case.json` | `7bf3263402217085ea178712aade86f442fe77e8f6e1a9d9cea1273c41b22fc8` | untracked | product-area-untracked |
| `tests/fixtures/ko/inc-non-ascii/ko.json` | `d749357584f316fcc5ba4c7a66047100a3afd133df902f345ee4685d5008eb1e` | untracked | product-area-untracked |
| `tests/fixtures/ko/inc-non-ascii/ko_catalog.inc` | `a47f18682ca13d49de671b4449fa10869f4c10f9166724b9e632e26251058edc` | untracked | product-area-untracked |
| `tests/fixtures/ko/missing-key/candidates.json` | `2d5223348872b7888fc2d8b8d008b217c58ed40890f004d09281c2d32e4aca7c` | untracked | product-area-untracked |
| `tests/fixtures/ko/missing-key/case.json` | `e4eec5781440457bec3ee812c991d3d0be6b3a29c107ad35d93c1e18c42a1d95` | untracked | product-area-untracked |
| `tests/fixtures/ko/missing-key/ko.json` | `d749357584f316fcc5ba4c7a66047100a3afd133df902f345ee4685d5008eb1e` | untracked | product-area-untracked |
| `tests/fixtures/ko/newline-mismatch/candidates.json` | `27ad2d1dc8052955d3fcad7445697a5e397c2c353b6399eee04c787da4b49693` | untracked | product-area-untracked |
| `tests/fixtures/ko/newline-mismatch/case.json` | `0e0eacfc6b2fd771fb3fba6fad3ffbf0b5dc74da6d208b089b8ab9af2736741b` | untracked | product-area-untracked |
| `tests/fixtures/ko/newline-mismatch/ko.json` | `3476b35a424ccc3765af4c08f56b7b971ac9b6c3aaf942880c8875e1127113c3` | untracked | product-area-untracked |
| `tests/fixtures/ko/token-dropped/candidates.json` | `dc5a4fe04d87e980665ac84f3554d7e376696a39333f9d615430a9fc58e1b90d` | untracked | product-area-untracked |
| `tests/fixtures/ko/token-dropped/case.json` | `c36206ccfda7f7c216909c771b27057b4ae49de683027966ecb67853f47f48dd` | untracked | product-area-untracked |
| `tests/fixtures/ko/token-dropped/ko.json` | `93c773bd09d517b01c3ce7e1d9e39ef6bb638444f83f77231c4acf4df412e0df` | untracked | product-area-untracked |
| `tests/fixtures/ko/token-reordered/candidates.json` | `099fff7a57d71c4190a482240d911452091234f71049ffc1c91c840c2981f514` | untracked | product-area-untracked |
| `tests/fixtures/ko/token-reordered/case.json` | `0d6663ac6facb34660fe0aab2729c0a826302202f7cf69806ea73da463126929` | untracked | product-area-untracked |
| `tests/fixtures/ko/token-reordered/ko.json` | `0f8793749cfd8745ec6848d3eb2bd6a676764227d4effb939c7e50fea1fb3f58` | untracked | product-area-untracked |
| `tests/fixtures/ko/url-mismatch/candidates.json` | `f17e22727b6442551b464d730e4527583b20224a77686d2917e2a7d7a7610d54` | untracked | product-area-untracked |
| `tests/fixtures/ko/url-mismatch/case.json` | `081b09aae4e2f8558fc2d687159ddc36b96c6276e9e243ca8d14c53099c800d6` | untracked | product-area-untracked |
| `tests/fixtures/ko/url-mismatch/ko.json` | `fe49dba4916717f4b726365c462fc64db1f35d9a5fa830499f7ee40711e8d715` | untracked | product-area-untracked |
| `tests/i18n_font_smoke.cpp` | `44c8e2e663dad3aa7bb9ab8ea4f992a061609bbb20c835b091b00aa23113092a` | untracked | product-area-untracked |
| `tests/i18n_seam_smoke.cpp` | `27c54f38f557970b6b14806937424d20618e4e56af984ff35d363c9757ef9035` | untracked | product-area-untracked |
| `tests/kcd2_hdr/CallbackTests.cpp` | `e06af695e6c9f53942fb34723d700edb8096e1f8b5d2d032726e8ac1f3f0a2e5` | tracked | product-area-untracked |
| `tests/kcd2_hdr/README.md` | `c51024b9bd5cc4217e9b5c232d76251518c7aa0c2cfa2a76c45a419fa9172425` | tracked | product-area-untracked |
| `tests/kcd2_hdr/run.ps1` | `fc47aae820434c483519c618b31ee2ef87a896f895cf5b7b426217cb514ff358` | tracked | product-area-untracked |
| `tests/mfg_ceiling_smoke.cpp` | `a178ed571400827048f708d35386317c5fe0d86eda1aa3779e3142c0df8d0626` | tracked | product-area-untracked |
| `tests/mfg_flipmeter_smoke.cpp` | `26d5c28320bd8bff37af9b4558d4ecb4a4c2dc49d715185470bfc94d9f405248` | tracked | product-area-untracked |
| `tests/mfg_method_smoke.cpp` | `ce96cb3b67a7aad8e591f7ce8f3cbf60c33849af18491f80e9a31a9a513bc17e` | tracked | product-area-untracked |
| `tests/mfg_provider_smoke.cpp` | `833593fecb45065845a68a9a2947d9ac23af2a7080572e8fee82d0bd2913317e` | tracked | product-area-untracked |
| `tests/mfg_ptx_smoke.cpp` | `52c8aa6be9df761c92b2c8f7232c0c46c52b0bd8d7e3ab52e747f58159888c53` | tracked | product-area-untracked |
| `tests/mfg_real_module_check.cpp` | `df9e942f46e6de9755e6315d6ed22f5af27e9915667042b717cb1cf7692d32e5` | tracked | product-area-untracked |
| `tests/mfg_unlock/Mocks.h` | `4f8296e7ea9d5199a7567b3f98b0d72a0e9a7209db9b1642ff49c687e6992839` | tracked | product-area-untracked |
| `tests/mfg_unlock/PatchTests.cpp` | `43920c1167c4a69d1789370dc31a13f9248ceb04858aad677fef7b4f15b50059` | tracked | product-area-untracked |
| `tests/mfg_unlock/run.ps1` | `5aa7063cba51c8f8f307694567d3622dd302a2943e329a6c8256e91a2238d062` | tracked | product-area-untracked |
| `tests/nr_active_color_smoke.cpp` | `b84b9c84d441b0965caeca115996f5a7d03162a0a7475ace27380b557826e8b6` | tracked | product-area-untracked |
| `tests/nr_compatibility/Adapter.h` | `e6b4d92d3c7b347c6fea6667e0f4e1d53c24e81d38e3657e341f1f38b92a019e` | tracked | product-area-untracked |
| `tests/nr_compatibility/HardwareSmoke.cpp` | `02297a79f48304252ba0cd68be0c18847219986f241d204707c59fd8917d4f94` | tracked | product-area-untracked |
| `tests/nr_compatibility/ImportTests.cpp` | `baa4950c155c3cff5e310c8de025eedf4624e9729ff2faf96ce35b3e5b6eb2a6` | tracked | product-area-untracked |
| `tests/nr_compatibility/run.ps1` | `c5d0bc13e4842181b4fb819c384c30c2e24dafb8d78cf892fc97526ab7044840` | tracked | product-area-untracked |
| `tests/nr_diagnostics/Adapter.h` | `477d02a4332dba90878079ab4635b79893314463179657d2b861af4a1088fff0` | tracked | product-area-untracked |
| `tests/nr_diagnostics/CallbackTests.cpp` | `df49820b3b110340baeb64d69983d42d6da118bfebf0fbac8b4c010520f58ab0` | tracked | product-area-untracked |
| `tests/nr_diagnostics/run.ps1` | `91f9ab4aefc114e7c48ef5316c8b957e773e23dfcd0734e659987f517a9c95b9` | tracked | product-area-untracked |
| `tests/nr_dx11_finished_bridge_smoke.cpp` | `c2b12ce0e882156b0aef7fccd7c30f425a5539cf4fad0d0d33bf19e6693196e7` | tracked | product-area-untracked |
| `tests/nr_exposure_shader_smoke.cpp` | `0845df94d1d97222217ef8b29b386530cbec9ba6176b4f510f57e5a54c64f07b` | tracked | product-area-untracked |
| `tests/nr_finished_color_smoke.cpp` | `6e5c4adde3770db3c59519cbd8c7e86dbb8d938313278d355fd1726bfa71d24a` | tracked | product-area-untracked |
| `tests/nr_finished_queue_smoke.cpp` | `45b69cad6abb1b948c6f4453ace13a8ec3bf8046584f37f4a1a62178fdd604d6` | tracked | product-area-untracked |
| `tests/nr_gpu_lifetime_smoke.cpp` | `bafd77569aa214fb9fceb663486c84a133c8621cee02b096b1c642ced0539778` | tracked | product-area-untracked |
| `tests/nr_gpu_time_smoke.cpp` | `28152779f8d8d2cfb57f6136ed04a77ae72ee53d9730452eda3c5464057dc393` | tracked | product-area-untracked |
| `tests/nr_guides_smoke.cpp` | `271fd31971a4c8cc8cb058a6c1c326c4143d259c1d6a126891d53d32ce763693` | tracked | product-area-untracked |
| `tests/nr_late_slot_pool_smoke.cpp` | `57b6f77449b6320ecefd8b06f284b803bde1f210cee1c4516eadd97dd1fed4a4` | untracked | product-area-untracked |
| `tests/nr_native_probe_budget_smoke.cpp` | `7554240404c51fec7c34f9a98a3dc2166255737ba102ccec6016993cd40a02ad` | untracked | product-area-untracked |
| `tests/nr_ngx_routing_smoke.cpp` | `87727be4ba79a1fdbd23663b3abb3cb16df76d4bb12fe38fb16962be485560f8` | tracked | product-area-untracked |
| `tests/nr_pipeline_capture_smoke.cpp` | `8584576f4f7f3f63011c17be29fb69229effe3090f17f37a5e75ace74c76236f` | tracked | product-area-untracked |
| `tests/nr_private_upscaler_smoke.cpp` | `9fe153bfd3d19b3173e1f6e3b38accf440eb489be192c8df73ed2069ec25d321` | tracked | product-area-untracked |
| `tests/nr_private_upscaler_smoke.md` | `bc1bb3342ced59d588e87cb2485b5813c24df3556251f7955aaaab99cd3d1c4a` | tracked | product-area-untracked |
| `tests/nr_promise_hook_order_smoke.cpp` | `90a09c293f9f386a99e9fd59a6ee33fa51ee6d3fda11f7ed33ef7ac917d9ab53` | untracked | product-area-untracked |
| `tests/nr_replace_detail_smoke.cpp` | `dc816ffc25d1283d86f8de95c7202b84c50f1f91c2c5836de95375a3dbccb236` | tracked | product-area-untracked |
| `tests/nr_residual_dlss_smoke.cpp` | `ff0280ab3a975d9e5a1da9439dfd06ca5a8491dc8bd80014f223ba048c93062b` | tracked | product-area-untracked |
| `tests/nr_residual_rr_smoke.cpp` | `56a524555034ae5fcef131f7f82ca77cfcf7686de8cdecc5fb26d02f72457243` | tracked | product-area-untracked |
| `tests/nr_resize_shader_smoke.cpp` | `f26b2fa2f323cbe6d5c247d121aa506b4b62b2b2ea2903aafb5d191b46f95563` | untracked | product-area-untracked |
| `tests/nr_seam_clock_smoke.cpp` | `30c5c7b090d72c7abb1c74216048f90976ce1612cf30525cab8a67ecf18cdf84` | tracked | product-area-untracked |
| `tests/nr_shutdown_smoke.cpp` | `8dc2a3c3972d3d602c4892b96daf68c0bdb07d9b327aef69d7fc04f622de3adc` | tracked | product-area-untracked |
| `tests/nr_skin_shader_smoke.cpp` | `b8d6ea49e66b308c640b784d8a164fbfe715226ac0b50b72a24af10144405a63` | tracked | product-area-untracked |
| `tests/nr_streamline_hooks.cpp` | `f6fb375d93ab3636e3d26570b7f82ae4387414f65f4f336d1f742def57011a64` | tracked | product-area-untracked |
| `tests/nr_streamline_picture_smoke.cpp` | `581b896c43535786f9778c940726801daccbbe6dbec227329f7569cb24829e76` | tracked | product-area-untracked |
| `tests/nr_vulkan_shader_smoke.cpp` | `a086e43e0dc87738d6641d6ed4a97ebd14d456300f2ba56d3c01136232be0028` | tracked | product-area-untracked |
| `tests/run_flavour_gate_negative.ps1` | `5df4bf8aae86f3056c70bb63b976f6d35ccde30942bdaea72ae672c56d9edda6` | untracked | product-area-untracked |
| `tests/run_nr_gpu_lifetime.ps1` | `706dcce9bb7bc0d05b1ab00bbe8354db0e5cb1f13226526372052a3195205ecd` | tracked | product-area-untracked |
| `tests/run_nr_late_slot_pool.ps1` | `025a10ec50408b4ef1a13c1e7e1b6842a5a086d53cc191252e5c3c8c6c4caccf` | untracked | product-area-untracked |
| `tests/run_nr_native_probe_budget.ps1` | `c33106c55eda8a276c0d77be63c3f0afaceba87f7faca41a1f2134e9a293d2e0` | untracked | product-area-untracked |
| `tests/run_nr_pipeline_capture.ps1` | `f320c07207ed6e7bd2c57eff0a497cb02498f6fb5f661c014ef5187cb8efc854` | tracked | product-area-untracked |
| `tests/run_nr_prerelease.ps1` | `0e104cbfc6aba25d6420dfc8b05d0d403fb914d2586fbe55110499660ff49bb6` | tracked | product-area-untracked |
| `tests/run_nr_private_upscaler_smoke.ps1` | `53b67ffb7a611a0aed29562b9f5f294fc19dd1e3cbf034182cfa969735ae91f1` | tracked | product-area-untracked |
| `tests/run_nr_shutdown.ps1` | `845a732b04f4eef7000cd42787b785bbb6864959c98d7a468068a266cb9d739f` | tracked | product-area-untracked |
| `tests/run_nr_streamline_hooks.ps1` | `9e530bbf7b56463a782441a51e459af118431919b6b3c161800479ba621d3f26` | tracked | product-area-untracked |
| `tests/run_sl_pair_detours_smoke.ps1` | `4505379c841a87fa4f2801c9357f69ea9f7f97aa5d8ab32de17fe1253b8d11a2` | untracked | product-area-untracked |
| `tests/run_xefg_handoff_smoke.ps1` | `f36f06905d9f83aeacbd43b78aa7eb1f62faa5af18f85d0782d2c5f9bebc1184` | untracked | product-area-untracked |
| `tests/sl_pair_detours_smoke.cpp` | `df39668e959d3a2c8b40afa1d213f4b455eb4e6da4a30a0f88e3b107344040d0` | untracked | product-area-untracked |
| `tests/xefg_handoff_smoke.cpp` | `1b0e70b5e8a52ddadb98cf7e996e4b8dac07efedae03313ffe627a9f0efe9abc` | untracked | product-area-untracked |
| `tests/xefg_wiring_regression.cpp` | `2eff9979fac2eee95fc76e9880a97bf5e748a5aa7b56d8fef867559f8a9533e1` | untracked | product-area-untracked |
| `tools/Get-StreamlineRuntime.ps1` | `6e47de765a2f54133d49a99e9bf2d1eabfcc48035764bd959ebd807541f31e58` | untracked | product-area-untracked |
| `tools/Verify-InstallerUntouched.ps1` | `81d99a371b882c338cb4b681cdd600c6c38c51175da5b4c99001bd79a188bd31` | untracked | product-area-untracked |
| `tools/Verify-Rtx2030Delta.ps1` | `876d9861ab855b03e241c6f1e151816e38cc3503735bccfe48d0601689b3ffc9` | untracked | product-area-untracked |
| `tools/Verify-ZipParity.ps1` | `28a7f32b217fc4ace29402d6d2ce905ad91f8382e8363bb18bef0223cc189ee7` | untracked | product-area-untracked |
| `tools/asi-loader/LICENSE_Ultimate_ASI_Loader.txt` | `ceca73c504e39084b0b80d2a437aea9988313d1915418d3c629c3e4a8313f5a1` | untracked | product-area-untracked |
| `tools/asi_loader_install.ps1` | `830050b2bde7d4a5647a489ebb0d47f55bb198853956d475ef106b1fbad56e1a` | untracked | required-product-input-untracked |
| `tools/check_ampere_arming_seam.py` | `b9ea2694a07f7bcc918baf4015f39dd67d1f004a96c3ac6a2b809ead2707c882` | untracked | product-area-untracked |
| `tools/check_payload_pin.py` | `8ac8053639e09642d219a505bfe0d61d4b959bbc0eb4c1fd4d644371c70ea7c4` | untracked | product-area-untracked |
| `tools/check_rtx2030_docs.py` | `8822dc2173931d1bebdf523bf3076169c7ff8a3eb32a2ec9f5e21b8dfe6efd23` | untracked | product-area-untracked |
| `tools/extract_menu_strings.py` | `2cfb93a35aa8f28a499eac3d42ff84625e292f24dd3e55f3ae3dd93b698a1169` | untracked | product-area-untracked |
| `tools/extract_mfg_config_seam.py` | `c8e1e927447f414accc6f5de9246445d45acc8db7caff9f0ce1156ccadfb96ff` | untracked | product-area-untracked |
| `tools/gen_ko_catalog.py` | `e981fa07b88688d0d639dd674dab660c8cdbc5aaf6fcbebc2f31cd28485a347f` | untracked | product-area-untracked |
| `tools/i18n_extract_fonts.py` | `7235249268720e0fe659fd5277dae06aff444510cc58ff40c6755792d6426c6c` | untracked | product-area-untracked |
| `tools/i18n_extract_seam.py` | `c0b43b3302fffd82b86d2777892fd1fa0ad10fba02f5c73778271c67345a222f` | untracked | product-area-untracked |
| `tools/verify_backlog.py` | `707c5389633c647c8b010ad81986d4856bb0952a73ccaa9479446afcae76e81b` | untracked | product-area-untracked |
| `tools/verify_ko_catalog.py` | `fa7dcbf94b8916c05e4079fb7fb7ecd7358a1d79eff43e23bcceb3f11fb61557` | untracked | product-area-untracked |
| `tools/verify_visual_protocol.py` | `fc8be7212de270efd444994d3ad3d5dbad7d1106e23667e940294a5eff42fcf0` | untracked | product-area-untracked |
| `vendor/dlssg_sm86/PIN.json` | `60471a781ee0da49cf3936bd5aa7ae258579ed441700bcf09d705baff62ef1da` | untracked | required-product-input-untracked |
| `vendor/dlssg_sm86/THIRD_PARTY_NOTICES.txt` | `ac3b44ab30a4235edd18feca1ab4f802d57c8d3d0ee4878dc77b81a6b127155f` | untracked | required-product-input-untracked |

### 3a. Notable inclusions inside §3

- `OptiScaler/framegen/dlssg/AmpereMfgLoader.cpp/.h`: RTX40-MFG flavour
  sources, compiled by the `OptiScalerRtx40Mfg` vcxproj configuration
  (`ClInclude` unconditional, `ClCompile` unless Rtx40Mfg != true) and
  consumed under `OPTISCALER_RTX40_MFG` by `Streamline_Hooks.cpp` and
  `menu_common.cpp`. These are *sources* for the plan's A-core MFG
  configuration (defaults OFF); no SM86 DLL / NVIDIA runtime / derived
  kernel binary is included anywhere in this commit (§6).
- 88 external vendored build inputs (`vendored-build-dependency-…`), 28
  tracked link libs, and tracked `external/directx_agility_sdk/lib/D3D12Core.dll`
  (explicit gitignore exception) — the link/load inputs the vcxproj needs.
- 106 previously-untracked product inputs (NR/XeFG handoff, unlock/pacing
  headers, late-slot/native-probe headers, resize hlsl, Localization +
  `menu/locales/`, `INSTALL-KO.md`, ASI-loader installer, streamline
  fetcher, `tools/` install/verify scripts, tests, docs).
- `tools/__pycache__/*.pyc` (6 compiled caches) are NOT shipped: T16
  reclassified them from the root draft's recover list to
  `exclude-local / generated-cache` (§6b). Their `tools/*.py` sources
  ARE recovered; the caches rebuild locally and never enter Git.

## 4. Old-tag-only removals (18, recorded — not resurrected)

Present in the v11.1 tree, absent from donor disk (`sha256: null`,
addressable only via the v11.1 tag object), deleted in this commit:

| path | reason |
| --- | --- |
| `OptiScaler/dlssnr/DlssNr_ExposureScan.cpp` | old-tag-only-superseded-absent-from-shipped-donor-set-do-not-resurrect |
| `OptiScaler/dlssnr/DlssNr_ExposureScan.h` | old-tag-only-superseded-absent-from-shipped-donor-set-do-not-resurrect |
| `OptiScaler/dlssnr/forwarder/CMakeLists.txt` | old-tag-only-dropped-experiment-not-in-donor-shipped-set |
| `OptiScaler/dlssnr/forwarder/dlssnr_forwarder.cpp` | old-tag-only-dropped-experiment-not-in-donor-shipped-set |
| `OptiScaler/dlssnr/forwarder/dlssnr_forwarder.vcxproj` | old-tag-only-dropped-experiment-not-in-donor-shipped-set |
| `dist/nvngx/nvngx_dlss.dll` | old-tag-only-third-party-runtime-binary-not-for-new-git-zip |
| `dist/nvngx/nvngx_dlssd.dll` | old-tag-only-third-party-runtime-binary-not-for-new-git-zip |
| `dist/nvngx/nvngx_dlssg.dll` | old-tag-only-third-party-runtime-binary-not-for-new-git-zip |
| `dist/streamline/sl.common.dll` | old-tag-only-third-party-runtime-binary-not-for-new-git-zip |
| `dist/streamline/sl.deepdvc.dll` | old-tag-only-third-party-runtime-binary-not-for-new-git-zip |
| `dist/streamline/sl.dlss.dll` | old-tag-only-third-party-runtime-binary-not-for-new-git-zip |
| `dist/streamline/sl.dlss_d.dll` | old-tag-only-third-party-runtime-binary-not-for-new-git-zip |
| `dist/streamline/sl.dlss_g.dll` | old-tag-only-third-party-runtime-binary-not-for-new-git-zip |
| `dist/streamline/sl.dlss_nr.dll` | old-tag-only-third-party-runtime-binary-not-for-new-git-zip |
| `dist/streamline/sl.interposer.dll` | old-tag-only-third-party-runtime-binary-not-for-new-git-zip |
| `dist/streamline/sl.nis.dll` | old-tag-only-third-party-runtime-binary-not-for-new-git-zip |
| `dist/streamline/sl.pcl.dll` | old-tag-only-third-party-runtime-binary-not-for-new-git-zip |
| `dist/streamline/sl.reflex.dll` | old-tag-only-third-party-runtime-binary-not-for-new-git-zip |

- 13 third-party runtime binaries (`dist/nvngx/*.dll`, `dist/streamline/sl.*.dll`):
  never enter new Git/ZIP per the B/rights gate; streamline inputs come via fetcher pins.
- 3 dropped forwarder build files + 2 superseded `DlssNr_ExposureScan.*`:
  unreferenced by donor vcxproj/sources (grep 0 hits per T1).

## 5. Old-tag-only retains (9, carried over untouched from v11.1)

| path | reason |
| --- | --- |
| `.github/workflows/just_build_fast.yml` | old-tag-only-ci-workflow |
| `OptiScaler/dlssnr/FORWARDER_INVESTIGATION.md` | old-tag-only-design-doc |
| `OptiScaler/dlssnr/design/multi-point-anchoring.md` | old-tag-only-design-doc |
| `OptiScaler/dlssnr/forwarder/README.md` | old-tag-only-component-doc |
| `dist/README.md` | old-tag-only-component-doc |
| `dist/streamline/nis.license.txt` | old-tag-only-rights-reference |
| `dist/streamline/nvngx_dlss.license.txt` | old-tag-only-rights-reference |
| `dist/streamline/reflex.license.txt` | old-tag-only-rights-reference |
| `images/susemi-title.svg` | old-tag-only-branding-asset |

Reference docs/workflows/license texts/brand asset only; no code or binary.

## 6. Intentionally excluded — never staged in R (59 current-donor B payload + others)

### 6a. Current-donor B payload (59, hashes kept for history/diagnosis only)

| path | sha256 (donor bytes, NOT in this tree) |
| --- | --- |
| `release/susemi-next-ko-r2-with-sm86-mfg/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `c3934a09399f022504227c72df0bf8c0de55f9a08880dddde898c5262cefa838` |
| `release/susemi-next-ko-r3-with-sm86-mfg/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `c3934a09399f022504227c72df0bf8c0de55f9a08880dddde898c5262cefa838` |
| `vendor/dlssg_sm86/dlssg_sm86.dll` | `c3934a09399f022504227c72df0bf8c0de55f9a08880dddde898c5262cefa838` |
| `vendor/dlssg_sm86/dlssg_sm86.ini` | `2616857ee29ec61e33c8b52e1b50f4c93cb5339adbb13b73f0ae71a722427a43` |
| `x64/ampere-mfg-eligibility/scratch-red/arm-conflict-ada/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `828477ce7867ac9cafb950cc48a78bedff2c534961d8c936030fde1068d341ce` |
| `x64/ampere-mfg-eligibility/scratch-red/arm-conflict-external-off/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `828477ce7867ac9cafb950cc48a78bedff2c534961d8c936030fde1068d341ce` |
| `x64/ampere-mfg-eligibility/scratch-red/arm-conflict-optifg/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `828477ce7867ac9cafb950cc48a78bedff2c534961d8c936030fde1068d341ce` |
| `x64/ampere-mfg-eligibility/scratch-red/arm-conflict-other-owner/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `828477ce7867ac9cafb950cc48a78bedff2c534961d8c936030fde1068d341ce` |
| `x64/ampere-mfg-eligibility/scratch-red/arm-eligible-sm75/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `828477ce7867ac9cafb950cc48a78bedff2c534961d8c936030fde1068d341ce` |
| `x64/ampere-mfg-eligibility/scratch-red/arm-eligible-sm86/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `828477ce7867ac9cafb950cc48a78bedff2c534961d8c936030fde1068d341ce` |
| `x64/ampere-mfg-eligibility/scratch-red/arm-ineligible-ada/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `828477ce7867ac9cafb950cc48a78bedff2c534961d8c936030fde1068d341ce` |
| `x64/ampere-mfg-eligibility/scratch-red/arm-ineligible-gtx16/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `828477ce7867ac9cafb950cc48a78bedff2c534961d8c936030fde1068d341ce` |
| `x64/ampere-mfg-eligibility/scratch-red/arm-ineligible-mixed/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `828477ce7867ac9cafb950cc48a78bedff2c534961d8c936030fde1068d341ce` |
| `x64/ampere-mfg-eligibility/scratch-red/arm-ineligible-sm80/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `828477ce7867ac9cafb950cc48a78bedff2c534961d8c936030fde1068d341ce` |
| `x64/ampere-mfg-eligibility/scratch-red/arm-ineligible-software-adapter/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `828477ce7867ac9cafb950cc48a78bedff2c534961d8c936030fde1068d341ce` |
| `x64/ampere-mfg-eligibility/scratch-red/arm-latch/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `828477ce7867ac9cafb950cc48a78bedff2c534961d8c936030fde1068d341ce` |
| `x64/ampere-mfg-eligibility/scratch/arm-conflict-ada/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `bbe7cae45c830c0f0c34bd0a3d6562d941341a7b38098e4e7ffb77ff058a03df` |
| `x64/ampere-mfg-eligibility/scratch/arm-conflict-external-off/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `bbe7cae45c830c0f0c34bd0a3d6562d941341a7b38098e4e7ffb77ff058a03df` |
| `x64/ampere-mfg-eligibility/scratch/arm-conflict-optifg/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `bbe7cae45c830c0f0c34bd0a3d6562d941341a7b38098e4e7ffb77ff058a03df` |
| `x64/ampere-mfg-eligibility/scratch/arm-conflict-other-owner/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `bbe7cae45c830c0f0c34bd0a3d6562d941341a7b38098e4e7ffb77ff058a03df` |
| `x64/ampere-mfg-eligibility/scratch/arm-eligible-sm75/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `bbe7cae45c830c0f0c34bd0a3d6562d941341a7b38098e4e7ffb77ff058a03df` |
| `x64/ampere-mfg-eligibility/scratch/arm-eligible-sm86/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `bbe7cae45c830c0f0c34bd0a3d6562d941341a7b38098e4e7ffb77ff058a03df` |
| `x64/ampere-mfg-eligibility/scratch/arm-ineligible-ada/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `bbe7cae45c830c0f0c34bd0a3d6562d941341a7b38098e4e7ffb77ff058a03df` |
| `x64/ampere-mfg-eligibility/scratch/arm-ineligible-gtx16/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `bbe7cae45c830c0f0c34bd0a3d6562d941341a7b38098e4e7ffb77ff058a03df` |
| `x64/ampere-mfg-eligibility/scratch/arm-ineligible-mixed/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `bbe7cae45c830c0f0c34bd0a3d6562d941341a7b38098e4e7ffb77ff058a03df` |
| `x64/ampere-mfg-eligibility/scratch/arm-ineligible-sm80/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `bbe7cae45c830c0f0c34bd0a3d6562d941341a7b38098e4e7ffb77ff058a03df` |
| `x64/ampere-mfg-eligibility/scratch/arm-ineligible-software-adapter/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `bbe7cae45c830c0f0c34bd0a3d6562d941341a7b38098e4e7ffb77ff058a03df` |
| `x64/ampere-mfg-eligibility/scratch/arm-latch/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `bbe7cae45c830c0f0c34bd0a3d6562d941341a7b38098e4e7ffb77ff058a03df` |
| `x64/ampere-mfg-eligibility/stub/dlssg_sm86.dll` | `bbe7cae45c830c0f0c34bd0a3d6562d941341a7b38098e4e7ffb77ff058a03df` |
| `x64/ampere-mfg-matrix/fixtures/dlssg_sm86.dll` | `d407168be3dc86536260babb63e66ee9150e8406ad20f29e3bd5ee132409889e` |
| `x64/ampere-mfg-matrix/fixtures/dlssg_sm86_standby.dll` | `1c5cf057d068f686f2a1ef6e123ee0be0d697f7164edc15bcc42fd823fd4acbd` |
| `x64/ampere-mfg-matrix/pin-check/wrong-hash/dlssg_sm86.dll` | `19456107a1e7575c2336e7e9d967c2e32df20abe8d6f994dcb84856232d36df1` |
| `x64/ampere-mfg-matrix/pin-check/wrong-size/dlssg_sm86.dll` | `25896bd83d77da39fe73bf1d790cc75167a31a702da1aa1de588aa79c3e5a3a8` |
| `x64/ampere-mfg-matrix/scratch/c01-conflict-ada-unlock/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `d407168be3dc86536260babb63e66ee9150e8406ad20f29e3bd5ee132409889e` |
| `x64/ampere-mfg-matrix/scratch/c02-conflict-other-owner/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `d407168be3dc86536260babb63e66ee9150e8406ad20f29e3bd5ee132409889e` |
| `x64/ampere-mfg-matrix/scratch/c03-conflict-external-off/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `d407168be3dc86536260babb63e66ee9150e8406ad20f29e3bd5ee132409889e` |
| `x64/ampere-mfg-matrix/scratch/c04-conflict-optiscaler-dlssg/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `d407168be3dc86536260babb63e66ee9150e8406ad20f29e3bd5ee132409889e` |
| `x64/ampere-mfg-matrix/scratch/i01-repeat-init-idempotent/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `d407168be3dc86536260babb63e66ee9150e8406ad20f29e3bd5ee132409889e` |
| `x64/ampere-mfg-matrix/scratch/i02-restart-latch-options/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `d407168be3dc86536260babb63e66ee9150e8406ad20f29e3bd5ee132409889e` |
| `x64/ampere-mfg-matrix/scratch/k01-kernel-auto/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `d407168be3dc86536260babb63e66ee9150e8406ad20f29e3bd5ee132409889e` |
| `x64/ampere-mfg-matrix/scratch/k02-kernel-ptx/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `d407168be3dc86536260babb63e66ee9150e8406ad20f29e3bd5ee132409889e` |
| `x64/ampere-mfg-matrix/scratch/k03-kernel-cubin/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `d407168be3dc86536260babb63e66ee9150e8406ad20f29e3bd5ee132409889e` |
| `x64/ampere-mfg-matrix/scratch/k04-kernel-foreign-value/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `d407168be3dc86536260babb63e66ee9150e8406ad20f29e3bd5ee132409889e` |
| `x64/ampere-mfg-matrix/scratch/k05-kernel-lowercase/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `d407168be3dc86536260babb63e66ee9150e8406ad20f29e3bd5ee132409889e` |
| `x64/ampere-mfg-matrix/scratch/m02-tiny-module/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `08f271887ce94707da822d5263bae19d5519cb3614e0daedc4c7ce5dab7473f1` |
| `x64/ampere-mfg-matrix/scratch/m03-not-a-pe/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `497199d1602b705d252695cda7b7a3f1c1e6417c21ccdcd59ba1a9908be44d22` |
| `x64/ampere-mfg-matrix/scratch/m04-wrong-size-truncated/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `25896bd83d77da39fe73bf1d790cc75167a31a702da1aa1de588aa79c3e5a3a8` |
| `x64/ampere-mfg-matrix/scratch/m05-wrong-hash-same-size/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `19456107a1e7575c2336e7e9d967c2e32df20abe8d6f994dcb84856232d36df1` |
| `x64/ampere-mfg-matrix/scratch/m06-standby-role/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `1c5cf057d068f686f2a1ef6e123ee0be0d697f7164edc15bcc42fd823fd4acbd` |
| `x64/ampere-mfg-matrix/scratch/m07-flat-layout/dlssg_sm86/dlssg_sm86.dll` | `d407168be3dc86536260babb63e66ee9150e8406ad20f29e3bd5ee132409889e` |
| `x64/ampere-mfg-matrix/scratch/m08-ini-unwritable/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `d407168be3dc86536260babb63e66ee9150e8406ad20f29e3bd5ee132409889e` |
| `x64/ampere-mfg-matrix/scratch/m09-ini-truncated-preexisting/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `d407168be3dc86536260babb63e66ee9150e8406ad20f29e3bd5ee132409889e` |
| `x64/ampere-mfg-matrix/scratch/m10-ini-foreign-schema/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `d407168be3dc86536260babb63e66ee9150e8406ad20f29e3bd5ee132409889e` |
| `x64/ampere-mfg-matrix/scratch/m11-valid-control/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `497199d1602b705d252695cda7b7a3f1c1e6417c21ccdcd59ba1a9908be44d22` |
| `x64/ampere-mfg-matrix/scratch/u01-ineligible-sm80/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `d407168be3dc86536260babb63e66ee9150e8406ad20f29e3bd5ee132409889e` |
| `x64/ampere-mfg-matrix/scratch/u02-ineligible-gtx16/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `d407168be3dc86536260babb63e66ee9150e8406ad20f29e3bd5ee132409889e` |
| `x64/ampere-mfg-matrix/scratch/u03-ineligible-arch-missing/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `d407168be3dc86536260babb63e66ee9150e8406ad20f29e3bd5ee132409889e` |
| `x64/ampere-mfg-matrix/scratch/u04-ineligible-mixed/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `d407168be3dc86536260babb63e66ee9150e8406ad20f29e3bd5ee132409889e` |
| `x64/ampere-mfg-matrix/scratch/u05-ineligible-unknown-arch/OptiScaler/dlssg_sm86/dlssg_sm86.dll` | `d407168be3dc86536260babb63e66ee9150e8406ad20f29e3bd5ee132409889e` |

All `B-payload-no-redistribution`: SM86 DLL / NVIDIA runtime / derived
kernels stay out of new Git, ZIP, and auto-download per the rights gate.
`vendor/dlssg_sm86/PIN.json` + `THIRD_PARTY_NOTICES.txt` ARE recovered (§3)
as history/pin reference only.

### 6b. Other explicit exclusions (verified absent from this tree)

- `OptiScaler/shaders/shader_tools/dxcompiler.dll`
  (`b86a738e…07b4d75`) and `dxil.dll` (`058f2f52…992de`): T1
  `exclude-local / binary-artifact`. Present in both lineages' checkouts,
  deliberately not carried into the new history; sibling tools
  (`dxc.exe`, `fxc.exe`, `dxv.exe`, all four `.bat`, `create_header.py`)
  are recovered (§3).
- 9 submodule gitlinks: uninitialized at commit time, pins unchanged from
  v11.1 (donor pins identical); initialized from exact pins at build time,
  never rewritten.
- 6 `tools/__pycache__/*.pyc` (`exclude-local / generated-cache` per T16):
  `tools/__pycache__/check_payload_pin.cpython-312.pyc` (`6616ea68c59c…`, exclude-local/generated-cache).
  `tools/__pycache__/check_rtx2030_docs.cpython-312.pyc` (`5f8c34f02555…`, exclude-local/generated-cache).
  `tools/__pycache__/extract_menu_strings.cpython-312.pyc` (`2b212e2dc5da…`, exclude-local/generated-cache).
  `tools/__pycache__/gen_ko_catalog.cpython-312.pyc` (`fe3c6c6261e0…`, exclude-local/generated-cache).
  `tools/__pycache__/verify_backlog.cpython-312.pyc` (`98551d18d38d…`, exclude-local/generated-cache).
  `tools/__pycache__/verify_ko_catalog.cpython-312.pyc` (`0f92b1fec5d1…`, exclude-local/generated-cache).
  Regenerable local bytecode of the recovered `tools/*.py` sources;
  the rejected R `e780e0f0` wrongly committed them, R2 does not.
- `.omo/` evidence (3844), `TEST-NOT-RELEASE/` local logs, game-path
  `winmm.ini` / personal `OptiScaler.ini` / raw logs, `x64/` + `release/`
  build outputs, gapscan scratch, `OptiScaler.pch`: none enter the tree.

## 7. Product boundaries carried by this source set

- NR / `UnlockMFG` / Ampere defaults: OFF in the recovered `OptiScaler.ini`
  (`tracked-config-reviewed-defaults-OFF`).
- UI/NR/MFG/A-lineage features come from the donor set (§3); the dropped
  forwarder experiment and `ExposureScan` pair do not come back (§4).
- B-variant (RTX20/30) outputs are fail-closed: sources/pins for history
  and diagnosis only; no redistributable B binary in this commit or in
  any future ZIP until explicit redistribution permission exists.
- Future amendments: feature work, installer hardening, packaging pins,
  and release notes land as separate follow-up commits on this branch —
  this R commit is the immutable reconciliation base.

## 9. T9 upstream-main (T6/T7) correspondence — reviewed main port vs this tree

Upstream pins (read-only `susemi-upstream-main-integration-r3`):
T6 `a369d6b4` `fix(xefg): port owned finished-picture NR handoff to main`,
T7 `5d6f3d46` `feat(xefg): port opt-in native unlock and pacing`.
Every row below names the Susemi location or one explicit exception. No
upstream wholesale merge, no duplicated features: only one real parity gap
was corrected (row 6); the rest is proven-equivalent by ported tests.

| # | T6/T7 behaviour | Susemi location / exception |
| --- | --- | --- |
| 1 | Handoff decision core: apply once per (generation, frameId); refuse duplicate/stale/unsubmitted/not-ready/cancelled/ambiguous; reset starts a new generation | `OptiScaler/dlssnr/DlssNr_XeFGHandoff.h` (donor lineage, contract-identical to T6; same `Tracker`/`Identity`/`Outcome`/`SkipReason` API). Pinned by existing `tests/xefg_handoff_smoke.cpp` + ported `tests/xefg_handoff_wiring_pin.cpp` §A |
| 2 | `XeFG_Dx12::Present` publishes `PublishFinishedConsumerState(consumes)` then calls `OwnedNrHandoff()` under `if (consumes)`; `consumes = dispatched && active && !paused` | `OptiScaler/framegen/xefg/XeFG_Dx12.cpp:1559-1563` (present since donor; untouched by T9). Pinned §D; removal seed fails `PIN_XEFG_CALLSITE` |
| 3 | `FGHooks::FGPresent` bypasses generic `ApplyToFinishedPicture` on the owned route and reports `NR_XEFG_PRESENT` via `XeFGHandoffSince` | `OptiScaler/hooks/FG_Hooks.cpp:1290-1304,1368-1375` (present since donor; untouched). Pinned §E; removal seed fails `PIN_FG_BYPASS` |
| 4 | Queue/device identity: never run NR on stale or cross-queue input | EXCEPTION — Susemi has no `DlssNr_QueueIdentity.h` / `DlssNr_Late.inl` unwrap helper. Equivalent protection: `FinishedInputReady` same-queue rule (`OptiScaler/dlssnr/DlssNr_FinishedReady.h`) + `LateContext::Acquire` device-identity refusal (`OptiScaler/shaders/dlssnr/DlssNr_Dx12_Late.cpp:67`) + capture admission gate (`FinishedConsumerAdmitsCapture`, same file `:142,:212`). Pinned §B/§F; device-gate removal seed fails `PIN_LATE_DEVICE` |
| 5 | Reset / swapchain recreation drops identity+interval state, closes stale captures | `XeFG_Dx12::ResetNrHandoff` (`XeFG_Dx12.cpp:1584`) + `Tracker::Reset` (present since donor; untouched). Pinned §A `PIN_TRACKER_STALE` |
| 6 | Native unlock: default OFF; unrecognised provider build refuses BEFORE any byte write and without pacing (fail-closed T7 adaptation vs warn-and-continue) | **T9 parity fix**: `OptiScaler/proxies/XeFGUnlock.h` previously warned and kept patching on per-byte checks (donor behaviour); now refuses with `unrecognised provider build ..., refusing to patch` and returns before any write/pacing. Same `KnownBuildStamp 0x69CB0F4D` / `KnownSizeOfImage 0x015ED000` as T7. Pinned `tests/xefg_unlock/UnlockPacingTests.cpp` F1 (OFF) + F4 (bad stamp) |
| 7 | Pacing: `ExtraPacing` switch, thunk rewrite with rollback, `Dispatch` feeds `RenderTimeMs` / reports `NoteFedFrameTime` | `OptiScaler/proxies/XeFGPacing.h` + `XeFG_Dx12.cpp:1065,1087` (present since donor; untouched). Pinned F6-F8 + §C; Install/feed removal seeds fail named |
| 8 | `XeFGProxy::HookXeFG` calls `XeFGUnlock::Apply` before any export lookup | `OptiScaler/proxies/XeFG_Proxy.h:176` (present since donor; untouched). Pinned §C; removal seed fails `PIN_APPLY_ORDER` |
| 9 | Ownership: only the registered app-facing proxy publishes consumer state; aborted/non-owner release publishes nothing; default route admits captures | `OptiScaler/dlssnr/DlssNr_FinishedConsumer.h:68-95` (equivalent, donor lineage; untouched). Pinned §C |
| 10 | Defaults/limits: `UnlockMFG` OFF, `MaxInterpolatedFrames` 5 (bound 31), ini ships `auto`, menu offers both checkboxes | `OptiScaler/Config.h:696,705-707`, `OptiScaler.ini:250-258`, `OptiScaler/menu/menu_common.cpp:4541,4554` (untouched). Pinned §D literals |
| 11 | Diagnostic markers `NR_XEFG_APPLY` / `NR_XEFG_SKIP` / `NR_XEFG_PRESENT` (+ device gate) preserved at default log level | Present in `XeFG_Dx12.cpp` / `FG_Hooks.cpp` (donor diagnostic set kept; no new per-frame spam added by T9) |

Ported production-bound tests (adapted, not wholesale):
`tests/xefg_handoff_wiring_pin.cpp`, `tests/run_xefg_production_route_smoke.ps1`,
`tests/xefg_unlock/UnlockPacingTests.cpp`, `tests/xefg_unlock/run.ps1`,
`tests/xefg_unlock/stubs/{Config,Logger,SysUtils}.h`.
Adaptations vs T6/T7 originals: Late path is `DlssNr_Dx12_Late.cpp` (no `.inl`);
§B drops COM-doubles for the absent QueueIdentity helper (row 4 exception);
§D derivation check matches Susemi's `Dispatch()`/`IsActive()`/`IsPaused()` locals;
§F pins the device-identity refusal + admission gates instead of unwrap sites.
Each file header names its adaptation.

T9 verification (this commit): clean `Rebuild Release x64` after the last
source edit, `tests/run_xefg_production_route_smoke.ps1` exit 0,
`tests/xefg_unlock/run.ps1` exit 0, full `tests/run_nr_prerelease.ps1` exit 0 —
raw exits captured in the task-9 receipt; every removal seed exits nonzero
with its named marker. Source→object→DLL hash binding recorded there.

## 8. How to re-verify

- T1 seal inputs (donor-local evidence, not committed here):
  `recovery-spec.json` (350577 B) sha256 `3f6401b72feb75c4d2af9bfd6cbe378b13a3beb1858685bad36aaf86efdab614`.
  `donor-inventory.json` (2443502 B) sha256 `b064b259946467f2ca45edc4e82719917944578c2379223e0904dae672f87da9`.
- Path/class/hash comparison: every §3 row was copied byte-identical from
  donor worktree bytes (reconcile-time rehash: 1124/1124 match, 0 missing).
  Git stores text files LF-normalized under the committed `.gitattributes`,
  so `git cat-file -p HEAD:<path> | sha256sum` equals the row hash for
  binary/uneol files, and equals `sha256(worktree bytes with CRLF→LF)` for
  text files. Every §4 row must satisfy `git cat-file -e HEAD:<path>` exit
  1, with `git rev-parse HEAD^` == v11.1 SHA and exactly one parent.
- Build/test gates run before the R commit (see task-2 receipt): clean
  `Rebuild Release x64` with exact pinned submodules,
  `tests/run_xefg_handoff_smoke.ps1` and `tests/run_nr_prerelease.ps1`
  each exit 0 in one run, `git diff --check` exit 0, negative manifest
  seed (missing file / added output) rejected.

