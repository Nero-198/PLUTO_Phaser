# Tx1/Tx2を用いた仮想到来方向試験

## 目的

Pluto Tx1/Tx2の相対DDS位相を2アンテナの到来位相差として使用し、
アンテナなしで位相シフタ走査と到来角推定を検証する。

PlutoのDDS対応は、Tx1が`altvoltage0/2`のI/Q、Tx2が
`altvoltage4/6`のI/Qである。仮想到来方向試験では両組を有効にし、
Tx2のI/Q位相を同量だけ回転する。

この試験で確認できるのは、Tx/Rx、RFフロントエンド、位相シフタ、
仮想合成および角度変換である。アンテナの放射特性、相互結合、
マルチパスは試験対象に含まれない。

## 配線

```text
Pluto Tx1 -- fixed ATT >= 20 dB -- board CH1 -- Pluto Rx1
Pluto Tx2 ---------------------- board CH2 -- Pluto Rx2
```

- 1個の固定ATTは既定でTx1経路に入れる。Tx2経路へ入れる場合は
  実行オプションのATT値も入れ替える。
- スクリプトは固定ATT込みの実効利得が両経路で-70 dBになるよう、
  Tx1/Tx2のハードウェア利得を個別に設定する。
- DDS scale 0.1により、さらに振幅を抑える。
- 未使用ポートは50 ohmで終端する。
- 基板ATTは10 dB、Pluto Rx gainは30 dBで開始する。
- Pluto Rxにクリッピングがあれば直ちに停止し、外付けATTまたは基板ATTを増やす。
- 正常終了、例外終了のどちらでも、両Txは-89 dB、全DDS OFFの状態に残す。

## 位相と角度

仮想アンテナ間隔を波長比 `d/lambda` で指定する。入力位相差は

```text
delta_phi_deg = 360 * (d/lambda) * sin(target_angle)
```

である。既定値 `d/lambda=0.5` では、角度範囲を一意に扱える。

## 実行

配線とATTを確認した後、明示的に `-RfConnectionsVerified` を付ける。

```powershell
.\tools\measure_pluto_synthetic_doa.ps1 -DryRun

.\tools\measure_pluto_synthetic_doa.ps1 `
  -InternalPower `
  -RfConnectionsVerified `
  -Tx1ExternalAttenuationDb 20 `
  -Tx2ExternalAttenuationDb 0 `
  -EffectiveTxGainDb -70
```

30 dB ATTをTx1へ入れる場合は
`-Tx1ExternalAttenuationDb 30`とする。Tx2へ入れる場合は、
Tx1を0、Tx2をATT値にする。

既定では0度を最初に測定し、その後、絶対角度の小さい順で
CH2位相シフタを全16状態走査する。各角度の取得終了時には既存の
安全処理によって基板とPluto設定を復帰する。

解析:

```powershell
python .\tools\analyze_synthetic_doa.py `
  .\captures\pluto_synthetic_doa_YYYYMMDD-HHMMSS
```

Pluto Rx1/Rx2の直接校正値が得られた後は、次のように指定する。

```powershell
python .\tools\analyze_synthetic_doa.py `
  .\captures\pluto_synthetic_doa_YYYYMMDD-HHMMSS `
  --rx-phase-correction-deg 12.34
```

## 出力

- `synthetic_doa_manifest.json`: 全体条件と仮想角度
- 各角度ディレクトリ: 生IQ、位相測定CSV、測定条件
- `synthetic_doa_summary.csv`: 位相状態、推定角度、誤差
- `synthetic_doa_analysis.json`: 全体誤差とクリッピング数

解析では16位相状態の仮想合成電力を一次調波へ適合し、連続値の
最大電力位相を求める。0度測定の最大位相を中心校正として使用する。
