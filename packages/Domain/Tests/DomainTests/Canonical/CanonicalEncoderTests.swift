import Testing
@testable import Domain
import Foundation

// Task 5: CanonicalEncoder のプリミティブ単体テスト（canonical-schema.md 2 章
// 「基本型の符号化」が正本）。
//
// ここでは各プリミティブの符号化規則だけを検証する。SettingsHash.swift 側の
// フィールド合成順序の検証は SettingsHashGoldenTests.swift に委ねる（circular にしない）。

// MARK: - 整数（ビッグエンディアンの固定長）

@Test("bigEndianUInt32は4バイトのビッグエンディアンを返す")
func bigEndianUInt32EncodesFourBytesBigEndian() {
    let encoded = CanonicalEncoder.bigEndianUInt32(0x0102_0304)
    #expect(encoded == Data([0x01, 0x02, 0x03, 0x04]))
}

@Test("bigEndianUInt64は8バイトのビッグエンディアンを返す")
func bigEndianUInt64EncodesEightBytesBigEndian() {
    let encoded = CanonicalEncoder.bigEndianUInt64(0x0102_0304_0506_0708)
    #expect(encoded == Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]))
}

// MARK: - Bool（UInt8 の 0 / 1）

@Test("boolはtrueを1、falseを0の1バイトへ符号化する")
func boolEncodesAsSingleByte() {
    #expect(CanonicalEncoder.bool(true) == Data([0x01]))
    #expect(CanonicalEncoder.bool(false) == Data([0x00]))
}

// MARK: - Double（IEEE 754 bitPattern。-0.0 は +0.0 へ正規化）

@Test("doubleは-0.0を+0.0へ正規化してからbitPatternを符号化する")
func doubleNormalizesNegativeZero() {
    let negativeZero = CanonicalEncoder.double(-0.0)
    let positiveZero = CanonicalEncoder.double(0.0)
    #expect(negativeZero == positiveZero)
    #expect(negativeZero == CanonicalEncoder.bigEndianUInt64(0))
}

@Test("doubleは通常値のbitPatternをビッグエンディアンで符号化する")
func doubleEncodesRegularValueBitPattern() {
    let value = 1.5
    #expect(CanonicalEncoder.double(value) == CanonicalEncoder.bigEndianUInt64(value.bitPattern))
}

@Test("doubleはFloatへ丸めると区別できなくなる2値を異なるバイト列へ符号化する")
func doubleDistinguishesValuesThatCollapseUnderFloatRounding() {
    let precise = 0.15
    let roundTripped = Double(Float(0.15))
    #expect(precise != roundTripped)   // 前提: Float往復で値が変わることを確認する
    #expect(CanonicalEncoder.double(precise) != CanonicalEncoder.double(roundTripped))
}

// MARK: - 可変長データ（UInt32 の長さ前置き）

@Test("lengthPrefixedは4バイトの長さの後にペイロードを続ける")
func lengthPrefixedPrependsFourByteLength() {
    let payload = Data([0xAA, 0xBB, 0xCC])
    let encoded = CanonicalEncoder.lengthPrefixed(payload)
    #expect(encoded == Data([0x00, 0x00, 0x00, 0x03, 0xAA, 0xBB, 0xCC]))
}

@Test("lengthPrefixedは空データで長さ0のみを返す")
func lengthPrefixedHandlesEmptyPayload() {
    let encoded = CanonicalEncoder.lengthPrefixed(Data())
    #expect(encoded == Data([0x00, 0x00, 0x00, 0x00]))
}

// MARK: - String（UTF-8 バイト列、長さ前置き）

@Test("stringはUTF-8バイト列を長さ前置きで符号化する")
func stringEncodesUtf8WithLengthPrefix() {
    let encoded = CanonicalEncoder.string("AB")
    #expect(encoded == Data([0x00, 0x00, 0x00, 0x02, 0x41, 0x42]))
}

@Test("stringは空文字列で長さ0のみを返す")
func stringEncodesEmptyStringAsZeroLength() {
    let encoded = CanonicalEncoder.string("")
    #expect(encoded == Data([0x00, 0x00, 0x00, 0x00]))
}

// MARK: - Optional（0/1 のタグ ＋ 値）

@Test("optionalFieldはnilでタグのみを返す")
func optionalFieldEncodesNilAsTagOnly() {
    let encoded = CanonicalEncoder.optionalField(Int?.none) { CanonicalEncoder.bigEndianUInt32(UInt32($0)) }
    #expect(encoded == Data([0x00]))
}

@Test("optionalFieldは値ありでタグと符号化済み値を連結する")
func optionalFieldEncodesSomeAsTagPlusValue() {
    let encoded = CanonicalEncoder.optionalField(Int?.some(1)) { CanonicalEncoder.bigEndianUInt32(UInt32($0)) }
    #expect(encoded == Data([0x01, 0x00, 0x00, 0x00, 0x01]))
}

// MARK: - ordered array（元の順序を保持する）

@Test("orderedCollectionは要素数の後に元の順序のまま長さ前置き要素を連結する")
func orderedCollectionPreservesOriginalOrder() {
    let elements = ["b", "a"]
    let encoded = CanonicalEncoder.orderedCollection(elements) { Data($0.utf8) }
    let expected = CanonicalEncoder.bigEndianUInt32(2)
        + CanonicalEncoder.lengthPrefixed(Data("b".utf8))
        + CanonicalEncoder.lengthPrefixed(Data("a".utf8))
    #expect(encoded == expected)
}

@Test("orderedCollectionは空配列で要素数0のみを返す")
func orderedCollectionHandlesEmptyArray() {
    let encoded = CanonicalEncoder.orderedCollection([String]()) { Data($0.utf8) }
    #expect(encoded == CanonicalEncoder.bigEndianUInt32(0))
}

// MARK: - unordered collection（符号化済みバイト列の辞書順ソート）

@Test("unorderedCollectionは符号化済みバイト列の辞書順にソートしてから連結する")
func unorderedCollectionSortsEncodedBytesLexicographically() {
    // "b" のバイト列は "a" より大きいが、入力順は逆（b, a）。
    // 出力は辞書順で a, b になるはず。
    let elements = ["b", "a"]
    let encoded = CanonicalEncoder.unorderedCollection(elements) { Data($0.utf8) }
    let expected = CanonicalEncoder.bigEndianUInt32(2)
        + CanonicalEncoder.lengthPrefixed(Data("a".utf8))
        + CanonicalEncoder.lengthPrefixed(Data("b".utf8))
    #expect(encoded == expected)
}

@Test("unorderedCollectionは入力順を変えても同じバイト列になる")
func unorderedCollectionIsOrderIndependent() {
    let ascending = CanonicalEncoder.unorderedCollection(["a", "b", "c"]) { Data($0.utf8) }
    let descending = CanonicalEncoder.unorderedCollection(["c", "b", "a"]) { Data($0.utf8) }
    #expect(ascending == descending)
}
