# TI Revive — bassmicrobe fork

[English](README.en.md) · [上流プロジェクト](https://github.com/derpsn/access-virus-ti-revive) · [変更点](docs/fork/CHANGES.md) · [性能測定](docs/fork/PERFORMANCE.md) · [Issue対応状況](docs/fork/ISSUES.md) · [署名・公証](docs/fork/NOTARIZATION.md)

**Access Virus TIを、Apple SiliconのMacからAU / VST3とUSB音声で使うためのTI Revive派生版です。**

このforkは、AUの状態整合性、音声処理中のオートメーション送信コスト、導入時の診断を改善します。音源処理はVirus本体のDSPが行います。Mac側のコードを軽くしても、本体の同時発音数やDSP性能が増えるわけではありません。

> 開発版です。上流の `round-0.8.41` を基点にしています。上流の低遅延モードや既存の修正は、このfork独自の成果に含めません。公開済みの安定版、forkのソース、検証用ビルドは区別して扱ってください。

TI Reviveはderpsnとコントリビュータによる独立プロジェクトです。このforkもAccess Music / Kemperとは無関係であり、公式製品・公式サポートではありません。商標は各権利者に帰属します。

## このforkで扱う改善

| 項目 | 目的 | 検証の見方 |
|---|---|---|
| AU初期値・プリセット復元の同期 | AUが返す値と、音色の実際の初期値を一致させる | 合成回帰テストと実AUで確認 |
| オートメーション送信の事前計算 | 音声処理内で繰り返す文字列・定義探索を減らす | 同一バイト列を保つテストと単独ベンチマーク |
| Windowsの旧ドライバ検出 | 旧Accessドライバが使用中なら、ドライバ変更前に停止する | mockテスト。Windows実機のBSOD根治を意味しない |
| Macの再現・診断手順 | 素材不足・接続・音声の問題を切り分ける | 認証画面を出す全プラグイン走査を必要としない |

各変更の実装状況・測定結果・残る制約は[変更点](docs/fork/CHANGES.md)、[性能測定](docs/fork/PERFORMANCE.md)、[Issue台帳](docs/fork/ISSUES.md)に記録します。

## 必要なもの

- 実機のAccess Virus TI / TI2 / Polar / Keyboard / Snow。機種ごとの検証範囲は[検証記録](docs/fork/PERFORMANCE.md)を参照してください。
- macOS **14.4以降（macOS 27対応）**。**macOS 27.2 / Apple Siliconで動作確認済み**です。[macOS対応範囲・確認手順](docs/fork/MACOS.md)を参照してください。Intelの上流ユーザー報告はありますが、このforkでのIntel実機確認とは区別します。
- 自分で所有するAccess **Virus TI Software Suite**インストーラ。Macは `.pkg`、Windows / Linuxは64bit `.msi`。上流の[配布案内](https://www.virus.info/downloads)を利用します。
- AUまたはVST3を扱えるDAW。プラグイン名は **TI Revive Virus Control**、Snow用は **TI Revive Virus Control (Snow)** です。

Accessのバイナリ、XML、スキン画像、ROMバンク、ファームウェアはこのリポジトリに含めません。TI Reviveは所有者のインストーラから必要なデータを読み取ります。音源をソフトウェアだけで動かすエミュレータではありません。

## Macで使う

Developer ID署名・Apple公証（Accepted、警告0）・staple・Gatekeeper検証を完了した[検証ビルド](https://github.com/bassmicrobe/access-virus-ti-revive/actions/runs/43165385989)があります。arm64／IntelのUniversalパッケージです。[公証対象・再実行・CI設定](docs/fork/NOTARIZATION.md)を参照してください。

1. ビルド元と版を確認します。上流安定版は[上流Releases](https://github.com/derpsn/access-virus-ti-revive/releases)、このforkの公開バイナリは[このforkのReleases](https://github.com/bassmicrobe/access-virus-ti-revive/releases)にあるものだけです。リリースがなければ下記の手順でソースからビルドします。
2. パッケージを使う場合はTI Reviveをインストールし、同梱の **Set up Access Virus TI files.command** に所有するAccess `.pkg`を指定します。Accessインストーラ自体を起動する必要はありません。最後に `Remove original Access plugins? [Y/n]` と聞かれたら、旧プラグインを残す場合は `N` を選びます。この操作は退避ではなく削除です。
3. 旧Access / AURAドライバがVirusを使用中なら競合します。削除前に退避先を記録し、元へ戻せる形で移動します。音色ライブラリや保存バンクを削除する必要はありません。
4. VirusをUSB接続し、DAWのMIDIトラックにTI Reviveを挿します。macOSの「マイク」権限はVirusのUSB音声入力にも必要です。必要なDAWにだけ許可します。
5. 初回はRAMバンクの同期を待ちます。キャッシュ作成後は本体の変更分を確認します。同じ本体を複数のエディタや複数のインスタンスで同時に操作しません。

音声経路は **Virus本体 → USB → TI Revive → DAW → 通常のオーディオ出力** です。USB 1 / 2、設定に応じてUSB 3を扱います。通常の本体レートは44.1 / 48kHzで、別のプロジェクトレートは変換処理を伴います。

### 低遅延を試す

上流0.8.41の **Lower latency (experimental)** はControl CenterのOptionsで選び、次にプラグインを開いた時から反映されます。通常はオフです。このforkのPOLAR / Macテストでは44.1kHz・512サンプル時に録音上の発音位置が約92.9msから約55.1msになりましたが、短い専用ホスト試験であり、DAWの負荷や長時間運用まで保証しません。遅れや音切れが増える場合はオフに戻してプラグインを開き直します。[測定条件と限界](docs/fork/PERFORMANCE.md)を先に確認してください。

プラグインを開くと本体の現在の編集バッファが変わります。未保存の編集は先に保存し、検証は使い捨てのプロジェクトで行ってください。ファーム更新・OS更新・Flash書き込みはこのforkでも対象外です。

### ソースからビルドする

Xcode / Command Line Tools、CMake、Gitが必要です。依存SDKは固定されたsubmodule / バージョンを使います。

下記のCMake手順はプラグイン・Control Center・テストを生成します。USB通信用のbrokerとAccess素材は別途必要です。既に上流安定版のパッケージを導入し、素材のセットアップを済ませたMacなら、その環境でビルド版だけを指定して検証できます。CMakeビルドは既存brokerや安定版を上書きしません。

```sh
git clone --recurse-submodules https://github.com/bassmicrobe/access-virus-ti-revive.git
cd access-virus-ti-revive
cmake -S native -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.4
cmake --build build --parallel 4
ctest --test-dir build --output-on-failure
```

生成先は `build/VST3/Release/`、`build/AU/`、`build/ccapp/` です。ビルドしただけではインストール済みプラグインは置き換わりません。まずそのパスのTI Reviveだけを指定する[専用テスト](docs/fork/PERFORMANCE.md)で確認してください。

未導入のMac向けにbrokerを含むUniversalパッケージを作る場合は、Xcodeを選択した環境で次を実行し、生成したパッケージと同梱の素材セットアップ手順を使います。生成だけではインストールされません。

```sh
bash scripts/mac-build-release.sh "$PWD" 0.8.41 "$PWD/package-build"
```

配布パッケージの作成・Windows / Linuxのビルドは[上流の手順](README.upstream.md#building)にあります。Universal / Intel / Windows / Linux向けに生成できることと、その機種での動作確認済みは別です。

### 安定版へ戻す

DAWとControl Centerを終了し、同じプラグインの退避済み安定版または上流の安定版パッケージへ戻します。AU / VST3のIDは引き継ぐため、同名の安定版とfork版を複数の検索フォルダへ二重に配置しないでください。キャッシュと音色バックアップは保持します。旧Accessソフトへ戻すためのドライバ復元は、TI Reviveの版を戻す操作とは別です。

## Windowsの旧Accessドライバから移行する場合

接続中の旧`vtimidi.sys`がアンロードされるとWindowsが停止したという[上流Issue #31](https://github.com/derpsn/access-virus-ti-revive/issues/31)があります。このforkのインストーラは、使用中の旧ドライバを検出したら変更前に停止する方針です。

Windowsをシャットダウンし、Virusの電源を切ってケーブルを外してからWindowsを再起動し、インストールをやり直します。初回利用前にVirus本体も電源を入れ直します。旧ドライバ使用中のライブ取り外しにも同じ報告があるため、それを対処手順として勧めません。この手順とガードは旧ドライバ自体の修正や、あらゆる環境での無障害保証ではありません。

## 検証と不具合報告

[性能・実機検証記録](docs/fork/PERFORMANCE.md)には環境、測定方法、結果、未確認の項目を記載します。短いテストで音が出たことだけを、すべてのDAWでの長時間安定動作とは扱いません。

このforkへの報告は[このforkのIssues](https://github.com/bassmicrobe/access-virus-ti-revive/issues)、上流の報告は[上流Issues](https://github.com/derpsn/access-virus-ti-revive/issues)へ。ログにユーザー名、ホームパス、シリアル、認証情報が含まれていないか確認してください。[全Issueの対応台帳](docs/fork/ISSUES.md)で、同じ問題の修正状況と再現に必要な情報を確認できます。

## 上流・ライセンス・貢献

- 元プロジェクト: [derpsn/access-virus-ti-revive](https://github.com/derpsn/access-virus-ti-revive)。元の説明は[README.upstream.md](README.upstream.md)に保持しています。
- 基点: 上流 `round-0.8.41` と、その時点の `main` のドキュメント更新。
- ライセンス: [MIT](LICENSE)。著作権表示・第三者ライセンスを保持します。上流の[ライセンス変更議論 #32](https://github.com/derpsn/access-virus-ti-revive/issues/32)を、このforkでの変更決定として扱いません。
- [CONTRIBUTING.md](CONTRIBUTING.md)と[AGENTS.md](AGENTS.md)に従い、Access素材・ファーム・非公開情報をコミットしません。AI支援を使った変更は、その旨と人間／実機による検証範囲を記録します。

このforkの変更にはAI支援を使用しています。実行した検証と未確認事項は[検証記録](docs/fork/PERFORMANCE.md)に記載します。
