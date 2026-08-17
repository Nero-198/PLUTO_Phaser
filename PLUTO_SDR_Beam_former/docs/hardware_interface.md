# RP2040-Zero RFフロントエンド ハードウェアインターフェース

## 対象と根拠資料

この文書は `kicad/MAPS-010143.kicad_sch` と `docs/schematic.pdf` の接続を、
`docs/SOURCES.md` に列挙した各メーカーのデータシートと照合した結果である。
基板名は MAPS-010143 だが、搭載される位相器の型番は
**MAPS-010144-TR0500** である。

## GPIO割り当て

| RP2040 GPIO | 回路ネット | 方向 | 機能 | 安全時 |
| ---: | --- | --- | --- | ---: |
| 0 | `UART_TX` | 入力 | 将来UART0予約、J15 pin 2 | Hi-Z |
| 1 | `UART_RX` | 入力 | 将来UART0予約、J15 pin 3 | Hi-Z |
| 2 | `ATT_SER` | 出力 | ch1 SN74HC595 SER | 0 |
| 3 | `ch1SRCLK` | 出力 | 両SN74HC595 SRCLK | 0 |
| 4 | `ch1_RCLK` | 出力 | 両SN74HC595 RCLK | 0 |
| 5 | `ch1_ATT_LE` | 出力 | 両PE4302 LE | 0 |
| 8 | `ch1_SRCLR` | 出力 | 両SN74HC595 SRCLR（Lowでクリア） | 0 |
| 9 | `LE_CH1` | 出力 | 両MAPS LE | 0 |
| 10 | `CLK_CH1` | 出力 | 両MAPS CLK | 0 |
| 11 | `SER_IN_CH1` | 出力 | ch1 MAPS SERIN | 0 |
| 14 | `ch1_LNA_ON` | 出力 | ch1 BGB741 ON/OFF | 0 |
| 15 | `ch2_LNA_ON` | 出力 | ch2 BGB741 ON/OFF | 0 |
| 26 | `LDO_ENABLE` | 出力 | TPS7A2033 EN | 0 |

GPIO 6、7、12、13、27〜29は本ファームウェアでは使用しない。

J15は pin 1 = +5 V、pin 2 = UART_TX、pin 3 = UART_RX、pin 4 = GNDだが、
現ファームウェアの制御通信はRP2040-ZeroのUSB CDCを使用する。GPIO0/1は入力、
プルなしに保ち、UART0は有効化しない。J15 pin 1から給電する場合は、
RP2040-ZeroのUSB給電との競合を避ける。

## PE4302アッテネータ

- 基板では `P/S = 0` でパラレルモード固定。
- ch1/ch2のSN74HC595は直列接続され、クロック、ラッチ、クリアを共有する。
- SN74HC595の QA/QB は未使用、QC〜QH が順に C0.5、C1、C2、C4、C8、C16を駆動する。
- したがってSN74HC595へ送る1チャネルの8ビット値は
  `attenuation_steps << 2`。`attenuation_steps` は0〜63で、1 step = 0.5 dB。
- ch1の QH' がch2の SERへ接続されるため、**ch2の8ビット、ch1の8ビット**の順で
  MSB first送信する。16ビット送信後にRCLKを立ち上げ、最後にPE4302のLEを
  High→Lowパルスする。これにより2チャネルは同時に反映される。
- PUP1/PUP2は両方Highで、ハードウェア単体のパワーアップ値は31 dB。
  ファームウェアは通電直後に31.5 dBを明示設定する。
- PE4302の最大スイッチングレート25 kHzを守るため、書込み後に最低40 us間隔を置く。

## MAPS-010144位相器

- `P/S = 1` でシリアルモード固定。
- 1デバイスのワードは6ビット、MSB first。D6〜D3が180°、90°、45°、22.5°、
  D2/D1はダミーなので0を送る。したがってワードは `phase_code << 2`、
  `phase_code` は0〜15で、1 code = 22.5°。
- ch1のSEROUTがch2のSERINへ接続されるため、**ch2の6ビット、ch1の6ビット**の順で
  送信する。12ビット送信中はLEをLowに保ち、最後にLEの立上りで同時反映する。
- ファームウェアの1 usハーフサイクルは、最小クロック周期100 ns、制御setup/hold
  20 ns、LEパルス10 ns、LE間隔630 nsを十分に満たす。

## BGB741 LNA

BGB741のON/OFF端子はGPIO14/15で直接制御する。データシート上は
`VCtrl >= 1.2 V` でON、`VCtrl <= 0.3 V` でOFFなので、RP2040の3.3 V CMOSで制御可能。
初期化、電源OFF、SAFE、ウォッチドッグリセットでは必ずLowにする。

## TPS7A2033電源

GPIO26はTPS7A2033のActive-High ENを制御する。データシート上の保証値は
`VEN(HI) >= 0.9 V`、`VEN(LOW) <= 0.3 V`。ENは内蔵プルダウンを持つため、RP2040の
リセット中もLDOは無効側になる。

TPS7A2033が生成する+3.3 VはLNA、PE4302、SN74HC595、MAPSの正電源に供給される。
MAPS用-3.3 VはLM2776で+3.3 Vを反転して生成するため、GPIO26から間接的に起動・停止
する。LM2776 ENには+3.3 Vから100 kΩ、GNDへ100 nFが接続され、時定数は10 ms。
ENの通常動作しきい値1.2 Vへの理想到達時間は約4.52 msであり、従来の5 ms待機では
負電源の整定余裕がない。このため初期実装ではGPIO26立上りから20 ms待機する。

LM2776はshutdown時に出力を約1.85 mAでGND方向へ放電する。C23=10 µFに対する単純
計算は約18 msだが、実装では25 msを初期放電待ちとする。起動20 msと停止25 msは
データシート保証値ではなく、正負電源の実測後に公差・温度マージンを含めて更新する。

### TPS7A2033/LM2776未実装時の外部電源モード

電源ICを実装せず、RF系の+3.3 Vと-3.3 Vを外部電源から与える測定では
`POWER EXTERNAL ON`を使用する。このモードではGPIO26を常にLowに保ち、ファームウェアは
電源を投入も遮断もしない。コマンドは「両電源が既に安定し、GNDがRP2040と共通である」
という操作者の確認として扱う。確認後さらに20 ms待ってから、31.5 dBと0°を初期化する。

外部電源は、未実装の電源ICの出力先であるRF系+3.3 Vネットと-3.3 Vネットへ、極性を
確認して電流制限付きで接続する。RP2040の3.3 Vピン、USB 5 V、GPIO26へ注入してはならない。
初回はRF入力を外し、制御線がLowであることを確認してから両電源を印加する。

停止は必ず次の順で行う。

1. `POWER OFF`または`SAFE`を送り、`EXTERNAL_SAFE`を確認する。
2. 外部+3.3 Vと-3.3 Vを物理的に遮断する。
3. `POWER EXTERNAL OFF`を送り、取り外し済みであることをファームウェアへ通知する。
4. FAULT中だった場合だけ`FAULT CLEAR`を送る。

`POWER EXTERNAL OFF`は外部電源を遮断するコマンドではなく、取り外し済みの確認である。
USB切断や通信タイムアウト時もLNA、ATT、PHASE、制御バスは安全化されるが、外部電源は
残る。外部電源の取り外し確認までは`SOURCE=EXTERNAL`を保持し、FAULT解除を拒否する。

## 安全状態とシーケンス

安全状態は次の通り。

- TPS7A2033 OFF
- ch1/ch2 LNA OFF
- アッテネータの論理状態 31.5 dB
- 位相の論理状態 0°
- シリアルデータ、クロック、ラッチ、SN74HC595 SRCLRをLow

起動時は全GPIOの出力ラッチをLowにしてから出力化する。USB CDCから `POWER ON` を
受けると、LNA OFFとバスLowを再確認し、LDOをON、20 ms待機、SRCLR解除、
アッテネータ31.5 dB、位相0°の順に設定する。LNAは明示的な `LNA ... ON` まで
OFFのままとする。

`POWER OFF` または `SAFE` では、LNA OFF、31.5 dB、0°の順に設定してLDOをOFF、
全バスをLowへ戻し、25 ms後にOFF遷移を完了する。電源OFF中のATT、PHASE、LNA ONは
逆給電防止のため拒否する。2秒のRP2040ウォッチドッグが作動した場合も再起動後は
安全状態へ戻る。

RF電源ON中は2秒の通信リースを監視する。有効コマンドまたは`KEEPALIVE`で更新し、
USB切断または2秒無通信でLNA OFF、31.5 dB、0°、電源OFFへ安全停止してFAULTを
ラッチする。外部電源モードでは制御だけを安全化して`EXTERNAL_SAFE`または`FAULT`へ
移行し、電源そのものは操作者が遮断する。`FAULT CLEAR`は内部電源停止後、または外部電源の
取り外し確認後だけ許可する。

## USB CDCプロトコル

- RP2040 USB CDC。USBホスト接続待ちではブロックしない
- ASCII、1行1コマンド、終端はLFまたはCRLF
- 大文字小文字は区別しない
- 成功は `OK`、失敗は `ERR <理由>`
- 起動通知は `READY RF_FRONTEND 1.0 SAFE`

| コマンド | 説明 |
| --- | --- |
| `PING` | 疎通確認。`OK PONG` |
| `KEEPALIVE` | 通信リース更新。`OK KEEPALIVE` |
| `HELP` | コマンド名一覧 |
| `STATUS` | 状態、電源源（NONE/INTERNAL/EXTERNAL）、FAULT、残りリース、両チャネルの現在状態 |
| `POWER ON` / `POWER OFF` | RF正電源の安全な投入／遮断 |
| `POWER EXTERNAL ON` | 安定済みの外部±3.3 Vを使用してRF制御を初期化（GPIO26はLow） |
| `POWER EXTERNAL OFF` | 外部±3.3 Vを物理的に取り外した後の確認通知 |
| `SAFE` | 最大減衰、0°、LNA OFFにして電源遮断 |
| `FAULT CLEAR` | 電源OFFかつ安全停止完了後にFAULTを解除 |
| `ATT <1\|2\|ALL> <0..31.5>` | 0.5 dB刻みで減衰量を設定 |
| `PHASE <1\|2\|ALL> <0..337.5>` | 22.5°刻みで位相を設定 |
| `LNA <1\|2\|ALL> <ON\|OFF>` | LNAを制御 |

例:

```text
> POWER ON
< OK POWER=ON SOURCE=INTERNAL
> ATT ALL 31.5
< OK
> PHASE 1 90
< OK
> LNA 1 ON
< OK
> STATUS
< OK STATE=READY POWER=ON SOURCE=INTERNAL FAULT=NONE ...
> SAFE
< OK SAFE
```

外部電源測定の最小例:

```text
# 先に電流制限付き外部+3.3 V/-3.3 Vを安定させる
> POWER EXTERNAL ON
< OK POWER=ON SOURCE=EXTERNAL
> ATT 1 0.5
< OK
> POWER OFF
< OK POWER=EXTERNAL_SAFE REMOVE_RAILS
# ここで外部+3.3 V/-3.3 Vを物理的に切る
> POWER EXTERNAL OFF
< OK POWER=OFF SOURCE=NONE
```

範囲外、刻み外、書式不正は状態を変更しない。最大行長は95文字。

## 初回実機確認

1. RF入力を切り離し、安定化電源の電流制限を低めに設定する。
2. 起動直後にGPIO26 Low、+3.3 V OFF、GPIO14/15 Lowを確認する。
3. `POWER ON` 後に+3.3 Vと-3.3 V、およびPE4302の初期減衰を確認する。
4. ロジックアナライザでATT 16クロック、MAPS 12クロック、送信順とLEを確認する。
5. LNA制御はRF無入力で開始し、消費電流を確認してからRF信号を接続する。
6. `SAFE`、USB切断、通信タイムアウト、ウォッチドッグリセット時に安全状態へ戻ることを確認する。
7. GPIO26、+3.3 V、LM2776 EN、-3.3 Vを同時観測し、20 ms起動待ちと25 ms放電待ちを再評価する。

電源IC未実装での測定では、手順2のGPIO26 Lowを確認後に外部±3.3 Vを印加し、
`POWER EXTERNAL ON`を使う。終了時は`POWER OFF`、外部電源の物理遮断、
`POWER EXTERNAL OFF`の順を厳守する。
