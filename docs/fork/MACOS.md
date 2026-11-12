# macOS対応とmacOS 27の確認記録

このforkの対応対象は **macOS 14.4以降、macOS 27を含む** です。2026-11-12に **M1 Max / macOS 27.2** で検証しました。27.0・27.1を個別に起動しての確認、Intel Macでの実行、すべてのDAWでの動作確認は行っていません。

## 確認した範囲

| 項目 | 結果と範囲 |
|---|---|
| 配布パッケージ | コミット `f27645c` のUniversalパッケージを生成。AU/VST3・Control Center・CLI・USB brokerのarm64/x86_64両方のバイナリを確認 |
| AUの読み込み | 配布パッケージから展開したAUを、27.2上の専用ホストで直接ロード・初期化。初期パラメータ153 = 1の検査に成功 |
| エディタ | Cocoaエディタの907×513描画とPNG保存、再表示、Cocoa viewを保持したままAUを破棄し、その後3秒のイベント処理までクラッシュなし。この追加試験は本体未接続画面で実施 |
| USB音声・操作 | 同じ27.2 / TI POLAR接続中に、fork AUの音声取得、小さなパラメータ変更と元の値への復元を確認。VST3では通常／低遅延設定の音声を取得。条件は[性能・検証記録](PERFORMANCE.md) |
| 既存音色 | 接続中の検証後にRAM A〜D、計512音色のフィンガープリントがバックアップ済みキャッシュと一致 |
| OSの制限 | インストーラは最小14.4のみを指定。27を拒む上限やバージョン分岐はない。追加のOS固有パッチが必要な障害は、この検証では確認されていない |

MacのCIは `macos-15` でパッケージを生成します。**macOS 27の実行確認は、このMacで行った検証**です。CIでmacOS 27を動かしたという意味ではありません。数値記録は [macos27.json](measurements/macos27.json)、配布ビルドの結果は[GitHub Actions](https://github.com/bassmicrobe/access-virus-ti-revive/actions/runs/43156396159)にあります。

## 導入・切り分け

1. [READMEの導入手順](../../README.md#macで使う)に従い、TI Reviveのbrokerと所有するAccess素材を準備します。古いAccessアプリ自体をarm64へ変換する方式ではありません。
2. ホストにマイク権限を許可し、Virus本体からのUSB入力を使える状態にします。音声出力は通常のオーディオインターフェースへ接続します。
3. 全プラグインの走査を避け、TI ReviveのAUだけを直接指定して読み込みます。起動時には通常の編集バッファ設定が行われるため、未保存の編集は先に保存します。
4. エディタが「No Virus TI can be found」を表示した場合は、まずUSBの接続・電源・OSでの認識を確認します。macOS 27でのエディタ描画成功と、本体が現在USBに接続されていることは別の確認項目です。

ビルド済みの専用ホストを使う表示・終了確認例です。下記の `VTI_NO_SETUP_TIPS` はこの1回のプロセスだけに適用され、初回案内画面を省略します。全プラグイン走査、ノート送信、プリセット読込は行いません。

```sh
VTI_NO_SETUP_TIPS=1 build/bin/Release/vti_autest \
  'build/AU/TI Revive Virus Control.component' \
  --expect-param 153 1 --no-notes --seconds 2 \
  --png macos27-view.png --delete-open 3
```

読み込み・描画・終了の検証であり、DAWのプロジェクト保存／再読込、長時間の音切れ、すべてのホストのウィンドウ動作を保証する試験ではありません。macOS 27 / Liveの上流[#38](https://github.com/derpsn/access-virus-ti-revive/issues/38)も、報告者の完全なクラッシュスタックなしに解決済みとは扱いません。このforkのAU防御処理と初期値同期は[変更点](CHANGES.md)を参照してください。

## English summary

macOS 27 is within the supported OS range (14.4+). Runtime tests were performed on macOS 27.2 / M1 Max, including packaged-AU initialization, offscreen Cocoa rendering, reopen/disposal, and earlier connected-POLAR USB audio/parameter tests. The additional editor test ran while the hardware was disconnected. macOS 27.0/27.1, Intel runtime, full DAW recall and long sessions remain untested. CI package generation uses macos-15; it is distinct from the local macOS 27 runtime validation. No OS-specific compatibility patch was needed for the tested paths.
