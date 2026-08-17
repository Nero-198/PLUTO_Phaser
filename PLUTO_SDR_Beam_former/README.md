# RP2040-Zero 2-channel RF frontend controller

RP2040-Zeroから2チャネルのPE4302アッテネータ、MAPS-010144位相器、
BGB741 LNA、TPS7A2033/LM2776電源をUSB CDCで安全に制御するC11ファームウェアです。

安全仕様、GPIO割り当て、通信コマンドは
[`docs/hardware_interface.md`](docs/hardware_interface.md)、検証済みツールチェーンは
[`docs/BUILD_ENVIRONMENT.md`](docs/BUILD_ENVIRONMENT.md)を参照してください。

## 構成

- `firmware/include`: GPIO、共通型、I/O抽象化、時間定数
- `firmware/drivers`: SN74HC595、PE4302、MAPS-010144、BGB741、TPS7A2033
- `firmware/app`: RF電源状態機械と通信安全監視
- `firmware/protocol`: ASCII行コマンドの解析と応答
- `firmware/transport`: USB CDCの非ブロッキング入出力
- `tests`: ハードウェア非依存のコード列、波形、状態遷移、通信異常試験

GPIO0/1のUART0は現在使用せず、入力・プルなしの将来予約です。

## ホスト単体試験

```powershell
cmake -S . -B build/host -DBUILD_TESTING=ON -DRF_BUILD_PICO=OFF
cmake --build build/host --config Release
ctest --test-dir build/host -C Release --output-on-failure
```

## RP2040ファームウェアのビルド

Raspberry Pi Pico SDK、ARM GNU Toolchain、Ninja、picotoolを用意します。
標準SDKでpicotoolが有効な場合:

```powershell
$env:PICO_SDK_PATH = "C:\path\to\pico-sdk"
cmake -S . -B build/pico -G Ninja -DRF_BUILD_PICO=ON -DPICO_BOARD=pico
cmake --build build/pico
```

SDK側を`PICO_NO_PICOTOOL=1`にした場合は、UF2を必ず現在のELFから作るため、
picotoolを明示します。

```powershell
cmake -S . -B build/pico -G Ninja `
  -DRF_BUILD_PICO=ON -DPICO_BOARD=pico -DPICO_NO_PICOTOOL=1 `
  -DRF_PICOTOOL_EXECUTABLE="C:\path\to\picotool.exe"
cmake --build build/pico
```

生成物は`build/pico/rf_frontend_firmware.uf2`です。BOOTSELモードの`RPI-RP2`
ドライブへコピーすると再起動し、USB CDCとして列挙します。

検出、コピー、CDC再列挙は次のスクリプトでも確認できます。

```powershell
.\tools\flash_uf2.ps1
```

## 最小動作確認

CDCポートを開いたまま、RF電源ON中は2秒以内に`KEEPALIVE`または別の有効コマンドを
送り続けてください。最初はRF入力を外し、LNA OFF、電流制限付き電源で確認します。

```text
PING
STATUS
POWER ON
ATT ALL 31.5
PHASE ALL 0
LNA ALL OFF
KEEPALIVE
STATUS
POWER OFF
```

USB切断または2秒無通信では安全停止後にFAULTがラッチされます。再開は
`FAULT CLEAR`、`POWER ON`の順です。`POWER ON`後もLNAは自動ONになりません。
実機検証コマンドと測定記録表は
[`docs/HARDWARE_VALIDATION.md`](docs/HARDWARE_VALIDATION.md)を参照してください。
