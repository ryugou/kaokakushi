import Foundation

// CallOrderRecorder — 複数の Fake にまたがる呼び出し順序を検証するための共有ヘルパー
// （Issue #8 サブプロジェクト5 A2 reviewer Warning S2）。
//
// SourceImportCoordinator+Reselect.swift の performReselect は正本（image-pipeline.md 5章）
// どおり pickedPhotoLoader.load → workingSourceStore.loadWorkingSource の順で呼ぶが、
// Task 3→4間でこの順序が一時的に入れ替わった実績があるにもかかわらず、順序そのものを
// 固定するテストが無かった。各 Fake は自身の呼び出し配列（loadCalls / loadWorkingSourceCalls
// 等）を個別に持つが、それらは Fake ごとに独立しており「どちらが先に呼ばれたか」という
// Fake を跨いだ順序を判定する手段が無い。
//
// 裸の Date() はタイムスタンプの分解能・比較に伴う不確実性を持ち込むため（Global Constraints
// 「裸の Date() 禁止」）使わず、代わりに呼び出しのたびにラベルを配列へ積む連番方式で順序を
// 記録する。テストが明示的に Fake へ注入しなければ何もしない（FakeWorkingSourceStore.gate と
// 同じ「オプトイン」方針）ため、既存テストの挙動には影響しない。
actor CallOrderRecorder {
    private(set) var entries: [String] = []

    init() {}

    func record(_ label: String) {
        entries.append(label)
    }
}
