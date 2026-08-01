import Testing
@testable import Domain
import Foundation

/// Task 1: 識別子と共通値型（architecture.md 6.5 / 6.3）。
///
/// `Identifiers.swift`（ID 型群）と `CommonValues.swift`（`YearMonth` / ハッシュ型群）を
/// まとめて検証する。両ファイルとも専用のテストファイルが計画に無いため、この 1 ファイルへ
/// 集約する（ManagedFileRef 系のみ振る舞い＝failable init が複雑なため
/// `ManagedFileRefTests.swift` を分離している）。

// MARK: - ID 型（rawValue: UUID の Sendable & Hashable struct）

/// `T` が `Sendable` かつ `Hashable` に適合していることをコンパイル時に強制するヘルパー。
/// ジェネリック制約に通せない型は、そもそもこの関数呼び出し自体がコンパイルエラーになる。
private func assertSendableHashable<T: Sendable & Hashable>(_ value: T) -> T { value }

@Test("ProjectIDがSendable/Hashableでraw値を保持する")
func projectIDHoldsRawValue() {
    let id = UUID()
    let subject = assertSendableHashable(ProjectID(rawValue: id))
    #expect(subject.rawValue == id)
}

@Test("BatchIDがSendable/Hashableでraw値を保持する")
func batchIDHoldsRawValue() {
    let id = UUID()
    let subject = assertSendableHashable(BatchID(rawValue: id))
    #expect(subject.rawValue == id)
}

@Test("ExportIDがSendable/Hashableでraw値を保持する")
func exportIDHoldsRawValue() {
    let id = UUID()
    let subject = assertSendableHashable(ExportID(rawValue: id))
    #expect(subject.rawValue == id)
}

@Test("RegionIDがSendable/Hashableでraw値を保持する")
func regionIDHoldsRawValue() {
    let id = UUID()
    let subject = assertSendableHashable(RegionID(rawValue: id))
    #expect(subject.rawValue == id)
}

@Test("FaceTrackIDがSendable/Hashableでraw値を保持する")
func faceTrackIDHoldsRawValue() {
    let id = UUID()
    let subject = assertSendableHashable(FaceTrackID(rawValue: id))
    #expect(subject.rawValue == id)
}

@Test("CustomStampIDがSendable/Hashableでraw値を保持する")
func customStampIDHoldsRawValue() {
    let id = UUID()
    let subject = assertSendableHashable(CustomStampID(rawValue: id))
    #expect(subject.rawValue == id)
}

@Test("ExportQueueItemIDがSendable/Hashableでraw値を保持する")
func exportQueueItemIDHoldsRawValue() {
    let id = UUID()
    let subject = assertSendableHashable(ExportQueueItemID(rawValue: id))
    #expect(subject.rawValue == id)
}

@Test("異なるUUIDから作ったID同士はHashableとして区別される")
func distinctRawValuesProduceDistinctIdentifiers() {
    let a = ProjectID(rawValue: UUID())
    let b = ProjectID(rawValue: UUID())
    #expect(a != b)
    #expect(Set([a, b]).count == 2)
}

// MARK: - YearMonth（architecture.md 6.3。バリデーションは正本に存在しないため実装しない）

@Test("YearMonthのyear/monthの実型がInt32であり値をそのまま保持する")
func yearMonthHoldsInt32Fields() {
    let subject = YearMonth(year: 2026, month: 8)
    let year: Int32 = subject.year
    let month: Int32 = subject.month
    #expect(year == 2026)
    #expect(month == 8)
}

@Test("YearMonthは月の範囲外バリデーションを持たない（正本に存在しないため）")
func yearMonthAcceptsOutOfRangeMonthWithoutValidation() {
    // 正本（architecture.md 6.3）に month のバリデーションは無い。
    // ここでは「範囲外でもコンパイル・生成でき、値がそのまま保持される」ことを確認し、
    // 実装側で誤ってバリデーションを追加していないことを固定する。
    let subject = YearMonth(year: 2026, month: 13)
    #expect(subject.month == 13)
}

@Test("YearMonthはyearを第一キー、monthを第二キーとしてComparableである")
func yearMonthOrdersByYearThenMonth() {
    let earlierYear = YearMonth(year: 2025, month: 12)
    let laterYear = YearMonth(year: 2026, month: 1)
    let sameYearEarlierMonth = YearMonth(year: 2026, month: 1)
    let sameYearLaterMonth = YearMonth(year: 2026, month: 8)

    #expect(earlierYear < laterYear)
    #expect(sameYearEarlierMonth < sameYearLaterMonth)
    #expect(!(sameYearLaterMonth < sameYearEarlierMonth))
}

@Test("YearMonthは年月が完全一致する場合のみ等しい")
func yearMonthEqualityRequiresBothFields() {
    #expect(YearMonth(year: 2026, month: 8) == YearMonth(year: 2026, month: 8))
    #expect(YearMonth(year: 2026, month: 8) != YearMonth(year: 2025, month: 8))
    #expect(YearMonth(year: 2026, month: 8) != YearMonth(year: 2026, month: 7))
}

// MARK: - ハッシュ型（architecture.md 6.5。32バイト検証は正本に無いため実装しない）

@Test("StampAssetHashがSendable/Hashableでbytesを保持する")
func stampAssetHashHoldsBytes() {
    let bytes = Data(repeating: 0xAB, count: 32)
    let subject = assertSendableHashable(StampAssetHash(bytes: bytes))
    #expect(subject.bytes == bytes)
}

@Test("ProjectSettingsHashがSendable/Hashableでbytesを保持する")
func projectSettingsHashHoldsBytes() {
    let bytes = Data(repeating: 0xCD, count: 32)
    let subject = assertSendableHashable(ProjectSettingsHash(bytes: bytes))
    #expect(subject.bytes == bytes)
}

@Test("PreviewRenderHashがSendable/Hashableでbytesを保持する")
func previewRenderHashHoldsBytes() {
    let bytes = Data(repeating: 0xEF, count: 32)
    let subject = assertSendableHashable(PreviewRenderHash(bytes: bytes))
    #expect(subject.bytes == bytes)
}

@Test("ハッシュ型は32バイト長のバリデーションを持たない（正本に throwing init が無いため）")
func hashTypesAcceptArbitraryLengthWithoutValidation() {
    // architecture.md 6.5 / canonical-schema.md 5.3 のいずれにも throwing initializer は
    // 定義されていない。32バイト制約の実行時強制は将来タスク（正準エンコーダ）の管轄。
    let shortBytes = Data(repeating: 0x01, count: 1)
    let subject = StampAssetHash(bytes: shortBytes)
    #expect(subject.bytes.count == 1)
}
