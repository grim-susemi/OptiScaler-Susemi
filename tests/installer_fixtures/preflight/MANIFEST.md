# preflight fixtures manifest

Pinned sources:
- zip sha256 42bac65ff8d9c2ada98cbcfa9c24753f3fe5253d08f7c956a9df977c0e21cc2a
- OptiScaler.dll (core) sha256 0eab8e59446d126fb25e35f83c87ffdf0fe6a3abb1084e6b480ad18234741c60
- Ultimate-ASI-Loader-x64.dll (UAL) sha256 fa266e3513d02c08a1b808f28c10538a489eaffaa4b0707f7cc1066e71b5afd7
- GameA.exe = COPY of C:\Windows\System32\notepad.exe (original untouched)
- ReShade.asi F1/F2/F4/F5 = 1024B minimal x64 PE stub (seed 0xF101 for payload; MZ+lfanew@0x3C=128+PE\0\0@128+mach 0x8664);
  F3 = 1024B pure random bytes (seed 0xF303, no MZ); F3 dxgi.dll = seed 0xF304

## F1-ready
- F1-ready/GameA/bin64/GameA.exe  360448B  sha256=db1131b5060bcfad80fc21d7bd333d9a7de3eee5190c5586d0a3a096fd563b87
- F1-ready/GameA/bin64/OptiScaler.asi  26667008B  sha256=0eab8e59446d126fb25e35f83c87ffdf0fe6a3abb1084e6b480ad18234741c60
- F1-ready/GameA/bin64/ReShade.asi  1024B  sha256=602642dbab0fbb1225ac19d0551dfc62f064c67757c66ef5f7c835ea600b8b85
- F1-ready/GameA/bin64/ReShade.ini  43B  sha256=a1917414307630abee5ea7c688de46fbfe1d005f5411159fb36b053b3b0a082f
- F1-ready/GameA/bin64/winmm.dll  3615928B  sha256=fa266e3513d02c08a1b808f28c10538a489eaffaa4b0707f7cc1066e71b5afd7
- F1-ready/GameA/bin64/winmm.ini  59B  sha256=ff35d4c4657d2e08f2524f497d66ddb1ec4cf9e8de4dcdd2e78864d1cdf25a89

## F2-renamed
- F2-renamed/GameA/bin64/dinput8.dll  3615928B  sha256=fa266e3513d02c08a1b808f28c10538a489eaffaa4b0707f7cc1066e71b5afd7
- F2-renamed/GameA/bin64/dinput8.ini  44B  sha256=1855e7917d530e0498f27875bf57e99a3d270979072527bfe8a70b04d7c9d82d
- F2-renamed/GameA/bin64/GameA.exe  360448B  sha256=db1131b5060bcfad80fc21d7bd333d9a7de3eee5190c5586d0a3a096fd563b87
- F2-renamed/GameA/bin64/OptiScaler.asi  26667008B  sha256=0eab8e59446d126fb25e35f83c87ffdf0fe6a3abb1084e6b480ad18234741c60
- F2-renamed/GameA/bin64/ReShade.asi  1024B  sha256=602642dbab0fbb1225ac19d0551dfc62f064c67757c66ef5f7c835ea600b8b85
- F2-renamed/GameA/bin64/ReShade.ini  43B  sha256=a1917414307630abee5ea7c688de46fbfe1d005f5411159fb36b053b3b0a082f

## F3-spoofed
- F3-spoofed/GameA/bin64/dxgi.dll  1024B  sha256=cdbe99fd35f236b04a577654571c01cf790e79a9d2b9cf6f18a3e030c563ffb8
- F3-spoofed/GameA/bin64/GameA.exe  360448B  sha256=db1131b5060bcfad80fc21d7bd333d9a7de3eee5190c5586d0a3a096fd563b87
- F3-spoofed/GameA/bin64/OptiScaler.asi  26667008B  sha256=0eab8e59446d126fb25e35f83c87ffdf0fe6a3abb1084e6b480ad18234741c60
- F3-spoofed/GameA/bin64/ReShade.asi  1024B  sha256=b621ed2ba5c43dbb9829a50624be63faf0a7414780773e5d4137298df9ab342c
- F3-spoofed/GameA/bin64/ReShade.ini  43B  sha256=a1917414307630abee5ea7c688de46fbfe1d005f5411159fb36b053b3b0a082f
- F3-spoofed/GameA/bin64/winmm.dll  3615928B  sha256=fa266e3513d02c08a1b808f28c10538a489eaffaa4b0707f7cc1066e71b5afd7
- F3-spoofed/GameA/bin64/winmm.ini  59B  sha256=ff35d4c4657d2e08f2524f497d66ddb1ec4cf9e8de4dcdd2e78864d1cdf25a89

## F4-override
- F4-override/GameA/bin64/GameA.exe  360448B  sha256=db1131b5060bcfad80fc21d7bd333d9a7de3eee5190c5586d0a3a096fd563b87
- F4-override/GameA/bin64/OptiScaler.asi  26667008B  sha256=0eab8e59446d126fb25e35f83c87ffdf0fe6a3abb1084e6b480ad18234741c60
- F4-override/GameA/bin64/plugins/global.ini  47B  sha256=9d5ce46faeb76dc9de257ea3f115f9718629e7e5df30cf80f49483850db96f32
- F4-override/GameA/bin64/ReShade.asi  1024B  sha256=602642dbab0fbb1225ac19d0551dfc62f064c67757c66ef5f7c835ea600b8b85
- F4-override/GameA/bin64/ReShade.ini  43B  sha256=a1917414307630abee5ea7c688de46fbfe1d005f5411159fb36b053b3b0a082f
- F4-override/GameA/bin64/winmm.dll  3615928B  sha256=fa266e3513d02c08a1b808f28c10538a489eaffaa4b0707f7cc1066e71b5afd7
- F4-override/GameA/bin64/winmm.ini  59B  sha256=ff35d4c4657d2e08f2524f497d66ddb1ec4cf9e8de4dcdd2e78864d1cdf25a89

## F5-disabled
- F5-disabled/GameA/bin64/GameA.exe  360448B  sha256=db1131b5060bcfad80fc21d7bd333d9a7de3eee5190c5586d0a3a096fd563b87
- F5-disabled/GameA/bin64/OptiScaler.asi  26667008B  sha256=0eab8e59446d126fb25e35f83c87ffdf0fe6a3abb1084e6b480ad18234741c60
- F5-disabled/GameA/bin64/ReShade.asi  1024B  sha256=602642dbab0fbb1225ac19d0551dfc62f064c67757c66ef5f7c835ea600b8b85
- F5-disabled/GameA/bin64/ReShade.ini  43B  sha256=a1917414307630abee5ea7c688de46fbfe1d005f5411159fb36b053b3b0a082f
- F5-disabled/GameA/bin64/winmm.dll  3615928B  sha256=fa266e3513d02c08a1b808f28c10538a489eaffaa4b0707f7cc1066e71b5afd7
- F5-disabled/GameA/bin64/winmm.ini  59B  sha256=67dfe9f6bd4c11d566ea339ea7ad61ca445c1c070b94ad680effcdcd007f643e
