# iOS 単独リリースと Swift + SwiftUI の採用

## Status

Accepted

## Context

上位仕様書 4.2 は iOS / Android のフルネイティブ二本立て（Swift + SwiftUI / Kotlin + Jetpack Compose）を指定していた。v1.x の設計は Kotlin Multiplatform + Compose Multiplatform を採り、「同一のドメインロジックを二度実装しない」ことが技術選定を支配していた。

その後、v1 のリリース対象を iOS のみとする経営判断が下された。実装者は Claude Code 単独である。

支配的な制約が次へ変わった。

- 共有すべき相手が存在しないため、抽象化のコストだけが残る
- プラットフォームの機能（Vision、Core Image、PhotoKit）を抽象化層なしに使える方が有利
- ビルド構成・テスト実行・デバッグ経路を Xcode に閉じられる

対応 OS の下限も未定だった。仕様書 4.1 は明示していない。

## Decision

**技術スタックを Swift 6（strict concurrency）+ SwiftUI の単一ネイティブ構成とする。対応 OS は iOS 26 以降。**

| 構成 | 判断 |
| --- | --- |
| **Swift + SwiftUI** | **採用** |
| KMP + CMP | 不採用。共有相手がいないのに Kotlin ツールチェーンと Swift 相互運用の複雑さを負う |
| Flutter | 不採用。加えて Vision / Core Image / PhotoKit をすべてブリッジ経由にする必要がある |
| UIKit | 不採用。主画面は `Canvas` による自前描画が主体で実装量が変わらず、設定・履歴・Paywall は宣言的な方が短い |

`UIViewRepresentable` / `UIViewControllerRepresentable` を使うのは **広告バナーと共有シートだけ**とする。Google Mobile Ads の `BannerView` に SwiftUI 版が無く、`ShareLink` が共有結果を返せないため。

**iOS 26 は技術的な必須条件ではない。** Swift 専用の Vision API（`DetectFaceRectanglesRequest`）は iOS 18 から、`Observation` は iOS 17 から利用できる。26 を下限とするのは、**古い OS への対応コストを負わず、最新の UI と API だけを対象にするという商品・開発上の判断**である。分岐と回避策を書かない分、実装量とテスト対象が減る。

## Consequences

**受け入れるリスク**

| リスク | 緩和策 |
| --- | --- |
| Android 展開時にドメイン層の再実装が必要 | ドメインの判断をアーキテクチャ設計書へ文章として残す。コードのみが仕様になる状態を避ける |
| 市場の半分を取り逃す | v1 の検証を優先する経営判断として受け入れる |
| iOS 26 未満の端末を切る | 2026 年時点で普及率は十分に高い。古い OS のための回避策コストを負わない |

**解消した制約**

| v1.x の制約 | v2.0 での扱い |
| --- | --- |
| 検出信頼度を使えない（ML Kit に API が無い） | `FaceObservation.confidence` を使える。`lowConfidence` をトリアージ理由へ戻せる |
| ぼかしを OpenGL ES 2.0 のシェーダで自作 | Core Image の `CIGaussianBlur` を使う |
| 両 OS の座標系・角度の差を吸収する契約テスト | 不要。Vision の座標系のみを扱う |
| 広告 SDK の自前ラップ | 不要。iOS SDK を直接使う |
| プレビューと書き出しで描画経路が二系統 | 1 本になり、両者の乖離という問題自体が消える |

**エフェクトの数学を `Domain` に閉じる分離は維持する。** 理由は OS 間の差を吸収するためではなく、**エフェクトの計算をシミュレータなしでテストできる状態に保つため**である。

## References

- 上位仕様書 4.1 / 4.2 / 32.1 からの逸脱（アーキテクチャ設計書 12 章）
