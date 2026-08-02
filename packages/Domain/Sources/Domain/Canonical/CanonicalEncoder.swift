import Foundation

// 正準符号化の汎用プリミティブ（canonical-schema.md 2 章「基本型の符号化」）。
//
// ハッシュ入力バイト表現の唯一の正本は canonical-schema.md であり、この文書は散文の
// 符号化規則表のみを持つ（コードブロックを含まない）。このファイルはその表を
// Swift の関数として実装したものである。
//
// SHA-256 の実体計算はここに置かない。Domain は Foundation のみに依存し CryptoKit を
// import できないため、ハッシュ計算そのものは SettingsHash.swift の Sha256Digest
// プロトコル経由でアダプタへ委譲する。
//
// Date・UUID の符号化プリミティブは、Task 5 が扱う2つの設定ハッシュ
// （ProjectSettingsHash / PreviewRenderHash）のどちらからも使われないため、
// 不要な先回り実装として今回は追加しない。

/// canonical-schema.md 2 章の符号化プリミティブ群。将来の他ハッシュ種別
/// （StampAssetHash 等）が同じ表を再利用する前提の名前空間のため、
/// 現時点で本体ロジックから呼ばれないプリミティブ（optionalField / unorderedCollection）
/// も表の完全性を保つために実装し、単体テストで固定する。
public enum CanonicalEncoder {
    /// 整数（UInt32 版）: ビッグエンディアンの固定長 4 バイト。
    public static func bigEndianUInt32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    /// 整数（UInt64 版）: ビッグエンディアンの固定長 8 バイト。Double の bitPattern 用。
    public static func bigEndianUInt64(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    /// Bool: UInt8（0 / 1）。
    public static func bool(_ value: Bool) -> Data {
        Data([value ? 1 : 0])
    }

    /// Double: IEEE 754 の bitPattern。-0.0 は +0.0 へ正規化してから符号化する
    /// （`-0.0 == 0.0` が true になる Double の性質を使い、bitPattern の差異を消す）。
    public static func double(_ value: Double) -> Data {
        let normalized = value == 0 ? 0.0 : value
        return bigEndianUInt64(normalized.bitPattern)
    }

    /// 可変長データ: UInt32 の長さ前置き。
    public static func lengthPrefixed(_ payload: Data) -> Data {
        bigEndianUInt32(UInt32(payload.count)) + payload
    }

    /// String: UTF-8 バイト列（長さ前置き）。
    public static func string(_ value: String) -> Data {
        lengthPrefixed(Data(value.utf8))
    }

    /// Optional: 0/1 のタグ ＋ 値（nil はタグのみ）。
    public static func optionalField<Wrapped>(_ value: Wrapped?, encode: (Wrapped) -> Data) -> Data {
        guard let value else { return bool(false) }
        return bool(true) + encode(value)
    }

    /// ordered array: 先頭に UInt32 の要素数、各要素は長さ前置きで元の順序のまま連結する
    /// （ソートしない）。
    public static func orderedCollection<Element>(_ elements: [Element], encode: (Element) -> Data) -> Data {
        var result = bigEndianUInt32(UInt32(elements.count))
        for element in elements {
            result += lengthPrefixed(encode(element))
        }
        return result
    }

    /// unordered collection: 各要素を符号化し、バイト列の辞書順（lexicographic byte order）に
    /// ソートしてから、先頭に UInt32 の要素数を置いて連結する。
    /// ソートキーは「長さ前置き後」のバイト列。要素長が異なっても比較結果が
    /// 要素間で一意に決まるよう、長さ前置き込みの完全なエンコード結果で
    /// 比較する。
    /// （canonical-schema.md 2 章「長さ前置きを含むバイト列を辞書順にソート」が正本）。
    public static func unorderedCollection<Element>(_ elements: [Element], encode: (Element) -> Data) -> Data {
        let encodedElements = elements
            .map { lengthPrefixed(encode($0)) }
            .sorted { $0.lexicographicallyPrecedes($1) }

        var result = bigEndianUInt32(UInt32(elements.count))
        for piece in encodedElements {
            result += piece
        }
        return result
    }
}
