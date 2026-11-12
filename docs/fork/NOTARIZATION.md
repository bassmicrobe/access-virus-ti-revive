# Developer ID署名・Apple公証

## 今回の結果（2026-11-12）

[実公証のCI](https://github.com/bassmicrobe/access-virus-ti-revive/actions/runs/43165385989)が成功しました。[検証記録とSHA-256](measurements/installed-polar.json)を保存しています。

- 対象ソース: `79916a17d73c9a8d8e469fb9e8d3197c9883e709`、版0.8.41のfork開発ビルド。
- Appleの結果: **Accepted、警告0・エラー0**。
- AU内のVST3を含む8個のMach-Oと6個のbundleをDeveloper ID Applicationで署名。main executableにはHardened Runtime、署名にはsecure timestampを付与。
- 最終 `.pkg` はDeveloper ID Installerで署名。公証チケットのstaple／validate、Gatekeeperのインストール判定に成功。
- arm64／x86_64を維持し、pkgのroot/wheel所有権、元のDistribution・インストールスクリプト・bundle IDを保持。
- CIの一時キーチェーンと秘密ファイルの終了処理も成功。ローカルmacOS 27.2でもpkg署名・staple・Gatekeeperと8バイナリを再検証。

公証はAppleによるコード署名・悪意ある内容の検査です。原作者やAccess Musicの公式製品・公式承認を示すものではありません。MITと第三者ライセンスの表示を保持し、Accessのバイナリ、スキン、XML、ファームウェア、音色バンクは配布に含めません。

公証済みZIP内のREADMEも、署名済み版専用の導入・検証案内へ更新します。上流の未署名版向けの説明をそのまま残しません。

公証対象は**コードと最終pkg**です。ZIP内の単独 `.command` ファイルを個別に公証・stapleしたという意味ではありません。素材セットアップには、pkg導入後の `/Library/Application Support/TI Revive/Set up Access Virus TI files.command` も使えます。

## GitHub Actionsから実行する

専用workflowは `.github/workflows/mac-notarize.yml`。**mainからの手動実行のみ**で、公開Releaseは作らず、署名済みZIPと検証記録を14日間のActions artifactへ保存します。このforkでは、上流のタグ用自動公開ジョブからad-hoc署名のMac ZIPを公開しない設定です。

1. `build.yml` のビルドとテストを成功させ、そのソースをforkのmainへ統合します。
2. workflowへ成功したrun IDと完全40桁のソースSHAを指定します。
3. `TI-Revive-mac-signed` と `TI-Revive-mac-notarization-records` を取得し、公証記録のstatus／hashを確認します。

今回と同じ成果物を指定する例です。

```sh
gh workflow run mac-notarize.yml \
  --repo bassmicrobe/access-virus-ti-revive --ref main \
  -f build_run_id=43164735413 \
  -f source_sha=79916a17d73c9a8d8e469fb9e8d3197c9883e709
```

署名鍵を読み込む前に、同じforkの成功済み `build.yml`、mainの祖先であるソースSHA、artifactの出所、GitHubのSHA-256を検証します。PR由来のビルドは署名しません。署名ツール自体は実行時のmainコミットから取得します。

### 署名環境

GitHub Environment **`mac-signing`** はmainブランチ限定です。次の5つのEnvironment Secretsを使用します。

| 名前 | 用途 |
|---|---|
| `MACOS_SIGNING_CERT_P12_BASE64` | Application／Installerの両方の秘密鍵付きidentityを含む暗号化p12のBase64 |
| `MACOS_SIGNING_CERT_PASSWORD` | そのp12の書き出しパスワード |
| `ASC_PRIVATE_KEY_P8` | 公証用App Store Connect API秘密鍵 |
| `ASC_KEY_ID` | 対応するAPI key ID |
| `ASC_ISSUER_ID` | 対応するissuer ID |

今回この環境へ設定し、実CIで認証・署名・公証を検証済みです。資格情報はソースやログに記載しません。パスワードはSecurity.frameworkへメモリ内で渡し、コマンド引数に入れません。P8ファイルは0600、一時ディレクトリは0700で作成し、成功・失敗の両方で終了処理を行います。既存のキーチェーンや証明書を失効・削除する処理はありません。

`main`へのpush／PRでは、資格情報を使わない署名ツールの回帰テストも実行します。実際のDeveloper ID操作は上記の手動workflowだけです。

## ローカルで既存ZIPを公証する

このMacでは、公証用プロファイル `ti-revive-notary` をキーチェーンへ設定済みです。利用可能なDeveloper ID Application／Installer identityを指定して実行します。下記のidentity名は例です。

```sh
export DEVELOPER_ID_APPLICATION='Developer ID Application: Your Organization (TEAMID)'
export DEVELOPER_ID_INSTALLER='Developer ID Installer: Your Organization (TEAMID)'
export NOTARY_KEYCHAIN_PROFILE=ti-revive-notary

bash scripts/mac-notarize-release.sh \
  TI-Revive-0.8.41-mac.zip TI-Revive-0.8.41-mac-signed.zip
```

入力ZIPは変更せず、既存の出力を上書きしません。完全なソースSHAを記録する場合は `TIREVIVE_SOURCE_SHA` に指定します。指定キーチェーンにプロファイルがある場合は `NOTARY_KEYCHAIN` も利用できます。キーチェーン方式の代わりに `ASC_KEY_ID`／`ASC_ISSUER_ID`／`ASC_PRIVATE_KEY_PATH` を使えますが、両方式の併用はエラーになります。

新しくビルドしてから公証まで行う場合は、同じ署名・認証設定で次を実行します。

```sh
TIREVIVE_NOTARIZE=1 bash scripts/mac-build-release.sh \
  "$PWD" 0.8.41 "$PWD/package-build"
```

公証を要求した実行で認証・署名が不足すると停止し、ad-hoc版へ自動で切り替えません。未指定の通常ビルドは従来の開発用ad-hocパッケージです。

## 記録と確認

- `*.zip.notarization.json`: 入出力SHA-256、ソースSHA、署名・所有権・公証・staple・Gatekeeperの結果。
- `*.zip.notary-issues.json`: 資格情報・個人パスを除いたAppleの指摘。
- `build-provenance.json`: 元ビルド、artifact、署名ツールのコミット。

AcceptedでもAppleのログを取得します。警告が残れば `accepted_with_warnings`／`clean: false` で記録し、警告0と区別します。エラー、未承認、staple失敗、Gatekeeper拒否では署名済み配布ZIPを成功成果物として公開しません。

Mac上でpkgだけを再確認する例です。インストールやUSB接続は行いません。

```sh
pkgutil --check-signature 'TI Revive.pkg'
xcrun stapler validate 'TI Revive.pkg'
spctl --assess --type install --verbose=4 'TI Revive.pkg'
```

公証済みZIPは、認証前の開発用ZIPとは別ファイルです。プラグインの同名コピーを複数の検索フォルダへ配置せず、[READMEの導入・復元手順](../../README.md#安定版へ戻す)に従います。公証とインストールは別工程です。続く実機確認で、このMacには公証済みfork版0.8.41を導入し、AU／VST3のUSB音声、エディタ、AU状態保存・再読込、保存済み512音色の整合性を確認しました。[導入記録](measurements/installed-polar.json)を参照してください。

## Apple公式資料

- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
