# Build environment record

確認日: 2026-07-16

## Verified host build

- CMake 3.24.2
- Microsoft Visual C/C++ 19.44 (Visual Studio 2022 generator)
- C language level: C11
- CTest: 5 tests, all passed in Release configuration

## Verified RP2040 build

- Board definition: `PICO_BOARD=pico` (RP2040, 2 MB flash)
- Pico SDK: 2.1.2-develop
- SDK distribution: Arduino-Pico package 4.6.1
- ARM compiler: `arm-none-eabi-gcc` 14.3.0
- picotool: 2.0.0
- Build type: Release
- Program range: `0x10000000` to `0x1000a42c`
- ELF size report: text 42024 bytes, data 0 bytes, BSS 4032 bytes
- UF2 size: 84480 bytes
- Verified UF2 SHA-256: `66CEC1CD404A2E3DB5AA0AD25552A7EB1862E422E3F91692CAB66776289DB9E9`

The Arduino board package does not contain the Pico SDK `.git` metadata, so an
SDK commit ID cannot be recovered from this installed copy. Reproducibility is
therefore pinned to Arduino-Pico 4.6.1 plus the reported SDK version. A future
standalone SDK checkout should record its exact commit ID here before replacing
this toolchain.

No `malloc`, `calloc`, `realloc`, or `free` references exist in project firmware
or test sources. Pico SDK libraries may contain their own allocator support, but
the application does not call it.
