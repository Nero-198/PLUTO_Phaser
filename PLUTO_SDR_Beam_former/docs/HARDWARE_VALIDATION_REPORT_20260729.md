# 2チャネルRFフロントエンド基板 機能検証レポート

## 1. 結論

検証期間: 2026-07-16 ～ 2026-07-29

総合判定: **機能検証 PASS**

RP2040-ZeroからのUSB CDC制御、2チャネルのPE4302、MAPS位相器、
BGB741 LNA、TPS7A2033およびLM2776による正負電源について、
実信号を使用した動作を確認した。最終状態では、今回対象とした
すべての基板機能が意図どおり動作しており、基板チャネル固有の
ATT不良も認められなかった。

この判定は、今回の接続、室温、電源条件および測定器設定における
機能合格を意味する。未校正のPluto SDRを用いた値は絶対利得、
絶対挿入損失、帯域平坦度の製品仕様保証には使用しない。

## 2. 検証構成

- 制御: RP2040-Zero、USB CDC（COM4）
- RF信号源／受信: ADALM-PLUTO
- 電源・デジタル波形観測: RIGOL MHO98
- RF分配: Wilkinson divider
- 外付け固定ATT: 測定に応じて20 dBまたは30 dB
- 基板RF電源: IC5 TPS7A2033による+3.3 V、IC1 LM2776による-3.3 V
- 最終チャネル接続: 基板CH1 → Pluto Rx1、基板CH2 → Pluto Rx2

主要な最終RF試験条件:

- RF周波数: 3.0 GHz
- Pluto TX gain: -40 dB
- DDS scale: 0.1
- Pluto RX gain: 45 dB
- LNA: 両チャネルON
- ATT: 0、10、20、31.5 dB
- 位相: 0、90、180、270°
- 取得数: 80 IQキャプチャ
- クリッピング: 0サンプル

## 3. 機能別結果

| 対象 | 判定 | 確認内容 |
| --- | --- | --- |
| USB CDC | PASS | 列挙、コマンド、分割受信、範囲エラー、安全状態を確認 |
| 電源制御 | PASS | +3.3 V/-3.3 V生成、LNA負荷中の保持、安全停止を確認 |
| LNA CH1 | PASS | CH1コマンドでRx1信号レベルが上昇 |
| LNA CH2 | PASS | CH2コマンドでRx2信号レベルが上昇 |
| PE4302 CH1 | PASS | デジタル転送、ラッチ、RF減衰変化を確認 |
| PE4302 CH2 | PASS | デジタル転送、ラッチ、RF減衰変化を確認 |
| MAPS CH1 | PASS | シリアル制御とRF相対位相変化を確認 |
| MAPS CH2 | PASS | シリアル制御とRF相対位相変化を確認 |
| 安全停止 | PASS | LNA OFF、ATT 31.5 dB、位相0°、RF電源OFFへ復帰 |

## 4. 正負電源とLNA負荷

テスターによる確認:

- IC5 pin 5（TPS7A2033 OUT）: 約+3.3 V
- IC1 pin 3（LM2776 VIN）: 約+3.3 V
- IC1 pin 1（LM2776 VOUT）: 約-3.3 V

両LNAをONにした10秒間のMHO98 VAVG測定:

| レール | LNA OFF | LNA ON平均 | 変化 |
| --- | ---: | ---: | ---: |
| +3.3 V | 3.2744 V | 3.27326 V | -1.14 mV |
| -3.3 V | -3.1152 V | -3.11375 V | 絶対値で-1.45 mV |

ATTおよび位相を実信号下で切り替えた区間でも、MHO98では次の値を
維持した。

| レール | 平均 | 最小 | 最大 |
| --- | ---: | ---: | ---: |
| +3.3 V | 3.273129 V | 3.2715 V | 3.2748 V |
| -3.3 V | -3.121929 V | -3.1313 V | -3.1041 V |

MHO98の負電源絶対値にはプローブおよびVAVG設定の影響が含まれる。
電圧絶対値はテスター結果、動的な安定性はMHO98結果を採用する。

根拠:

- [LNA負荷時の電源測定](../captures/internal_power_lna_load_20260729/rail_measurements.csv)
- [RF動作中の電源集計](../captures/internal_rf_phase_att_matrix_20260729/power_rail_summary.csv)

## 5. LNA個別制御

Rx入れ替え後の事前確認では、制御チャネルとRF経路の対応が期待どおりに
なった。

| 条件 | Rx1 | Rx2 | 主な変化 |
| --- | ---: | ---: | --- |
| 両LNA OFF | -69.16 dBFS | -66.80 dBFS | 基準 |
| LNA CH1 ON | -33.03 dBFS | -62.45 dBFS | Rx1 +36.13 dB |
| LNA CH2 ON | -67.62 dBFS | -34.86 dBFS | Rx2 +31.95 dB |
| 両LNA ON | -33.15 dBFS | -34.99 dBFS | 両経路で信号確認 |

この差はLNAの校正済み絶対利得ではなく、LNA OFF時の受信ノイズを
基準とした信号レベル差である。個別ON/OFF機能とチャネル対応の
確認値として使用する。

根拠:

- [LNAチャネル確認](../captures/internal_rf_phase_att_matrix_rx_swapped_20260729/preflight_att0/lna_channel_mapping_summary.csv)

## 6. PE4302 ATT

Rx入れ替え後の3.0 GHz測定:

| ATT設定 | Rx1測定変化 | 誤差 | Rx2測定変化 | 誤差 |
| ---: | ---: | ---: | ---: | ---: |
| 0 dB | 0.000 dB | 0.000 dB | 0.000 dB | 0.000 dB |
| 10 dB | 9.746 dB | -0.254 dB | 9.790 dB | -0.210 dB |
| 20 dB | 19.315 dB | -0.685 dB | 19.836 dB | -0.164 dB |
| 31.5 dB | 28.668 dB | -2.831 dB | 31.941 dB | +0.441 dB |

31.5 dB設定におけるRx1の差は、基板CH1/CH2をRx1/Rx2間で
入れ替えてもRx1側に残った。

| ATT設定 | Rx1 入替前 | Rx1 入替後 | 差 |
| ---: | ---: | ---: | ---: |
| 10 dB | 9.736 dB | 9.746 dB | +0.010 dB |
| 20 dB | 19.230 dB | 19.315 dB | +0.085 dB |
| 31.5 dB | 28.632 dB | 28.668 dB | +0.036 dB |

異なる基板チャネルを接続してもRx1の測定値が再現したため、
31.5 dB時の差は特定のPE4302には追従しない。Pluto Rx1の
測定経路、受信ノイズまたは低SNR時の振幅推定に由来すると判断した。
したがって、基板上の両PE4302は機能合格とする。

根拠:

- [最終ATT集計](../captures/internal_rf_phase_att_matrix_rx_swapped_20260729/attenuation_summary.csv)
- [Rx入れ替え比較](../captures/internal_rf_phase_att_matrix_rx_swapped_20260729/RX_SWAP_COMPARISON.md)
- [Rx入れ替え比較CSV](../captures/internal_rf_phase_att_matrix_rx_swapped_20260729/rx_swap_attenuation_comparison.csv)

## 7. MAPS位相器

### 7.1 3.0 GHz、ATT 0/10 dB

Rx入れ替え後の最終測定では、0/90/180/270°の非ゼロ位相状態について
次の結果を得た。

- 平均絶対位相誤差: 2.69°
- 最大絶対位相誤差: 5.94°
- クリッピング: なし

ATT 20 dB、特に31.5 dBでは受信信号がノイズフロアへ近づき、
位相推定誤差が増加した。この値はMAPS単体の位相誤差とはみなさない。

### 7.2 180°基準、周波数別16状態

2.3～3.8 GHzの指定8周波数で、片側を180°に保持し、反対側を
22.5°刻みの全16状態で測定した。

| 周波数 | CH1平均絶対誤差 | CH1最大誤差 | CH2平均絶対誤差 | CH2最大誤差 |
| ---: | ---: | ---: | ---: | ---: |
| 2.3 GHz | 3.25° | 7.33° | 4.01° | 10.03° |
| 2.4 GHz | 1.89° | 4.46° | 1.39° | 3.16° |
| 2.5 GHz | 2.03° | 5.30° | 2.16° | 5.88° |
| 2.7 GHz | 2.50° | 5.44° | 3.76° | 9.00° |
| 3.0 GHz | 3.75° | 7.64° | 3.96° | 7.79° |
| 3.3 GHz | 2.20° | 4.98° | 3.26° | 4.60° |
| 3.5 GHz | 3.42° | 6.70° | 2.10° | 4.91° |
| 3.8 GHz | 2.40° | 7.06° | 3.21° | 7.57° |

全256状態の平均絶対誤差は2.83°、最大絶対誤差は10.03°だった。
同一状態の繰返し標準偏差は最大0.06°で、測定中の相対位相は安定していた。

根拠:

- [最終3.0 GHz位相・ATT集計](../captures/internal_rf_phase_att_matrix_rx_swapped_20260729/combined_phase_att_summary.csv)
- [180°基準周波数試験](../captures/pluto_phase_reference180_20260728/)

## 8. 1.5～4.5 GHz通過確認

Pluto LOを50 MHz刻みで変化させ、1.5～4.5 GHzの61点で両経路の
信号通過を確認した。

- CH1観測範囲: -10.77 ～ -32.133 dBFS
- CH2観測範囲: -10.965 ～ -34.630 dBFS
- 最大チャネル差: 3.701 dB
- 全61点で両チャネルの信号を取得

この測定はthrough校正を行っていない。周波数応答にはPluto TX/RX、
外付けATT、Wilkinson divider、ケーブル、コネクタおよび基板の
全特性が含まれる。したがって、基板単体の挿入損失や平坦度ではなく、
広帯域で信号が通過することの機能確認として扱う。

根拠:

- [通過特性グラフ](../captures/pluto_dual_passband_1500_4500_50mhz_20260727/dual_channel_passband.png)
- [通過特性CSV](../captures/pluto_dual_passband_1500_4500_50mhz_20260727/dual_channel_passband.csv)
- [測定条件](../captures/pluto_dual_passband_1500_4500_50mhz_20260727/measurement_setup.json)

## 9. デジタル制御波形

MHO98およびテスターで、SN74HC595チェーンへのシリアル入力、
SRCLK、RCLK、SRCLR、出力ピンおよびMAPS CLK/LEを確認した。
R21のはんだ不良を修正後、RCLKラッチとPE4302出力の変化が正常に
観測され、SATSAGENおよびPlutoによるRF測定でも段階的な減衰変化を
確認した。

代表記録:

- [R21修正後のRCLK](../captures/mho98_rclk_after_r21_repair_20260727/)
- [R21修正後のATT出力](../captures/mho98_qc_static_after_r21_repair_20260727/)
- [MAPS制御波形](../captures/mho98_phase_validation_20260727_signalcheck/)

## 10. 通信・安全動作

確認済み項目:

- 起動時はRF電源OFF、LNA OFF、ATT 31.5 dB、位相0°
- RF電源OFF中のATT、PHASE、LNA ON要求を拒否
- 不正刻み、行長超過を拒否し、安全状態を維持
- USB CDCの分割受信
- 内部電源ON後もLNAは明示コマンドまでOFF
- 各測定の終了時または例外時に`SAFE`を実行

最終確認状態:

```text
STATE=OFF
POWER=OFF
SOURCE=NONE
FAULT=NONE
CH1_ATT=31.5
CH1_PHASE=0.0
CH1_LNA=OFF
CH2_ATT=31.5
CH2_PHASE=0.0
CH2_LNA=OFF
```

## 11. 総合判定と残る性能評価

今回の機能検証では、次を合格とする。

1. 正負電源の生成とLNA負荷中の保持
2. LNAの2チャネル個別ON/OFF
3. PE4302の2チャネル段階減衰
4. MAPSの2チャネル位相変化
5. 1.5～4.5 GHzにおける両経路の信号通過
6. USB CDC制御と安全停止

今後、製品仕様値として保証する場合に追加する試験:

- VNAまたは校正済みthrough測定による基板単体Sパラメータ
- LNA利得、雑音指数、P1dB、IP3の絶対測定
- PE4302全64状態の校正済み減衰誤差
- MAPS全16状態の絶対位相誤差と挿入損失
- GPIO26立上り／立下りから正負電源整定までの時間測定
- 電源電圧、温度、個体差を含むコーナー試験

以上から、現基板はRP2040-Zero制御の2チャネルRFフロントエンドとして
正常に機能していると結論する。
