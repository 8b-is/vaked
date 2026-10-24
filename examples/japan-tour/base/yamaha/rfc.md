# RFC — Yamaha · Polymorphic Resonance Engine <TARGET_05 = Yamaha>

**EN — Origin-Seal Architect** *(parameterized for Nintendo | Sony | Sanrio |
Yamaha; this instantiation binds Yamaha — the music lane, our lane)*

**Problem.** Hardware handshakes and creative assets must verify their lineage
in under a millisecond, fully local, with zero cloud dependency — an
instrument, a DSP voice program, or a sample must prove *who made it* before
it can speak.

**Design.** A zero-allocation ledger with a cryptographic origin seal. Two
capability domains: `id` (`origin_seal_ro < origin_seal_rw`) and `audio`
(`dsp_ro < dsp_rw`). `asset_ledger` holds the seal writer;
`synth_engine` holds `audio.dsp_rw` + read-only lineage; `instrument_fw`
holds read-only DSP + lineage. The legal edge
`synth_engine -> instrument_fw : "voice-program"` is attenuation-safe
(`dsp_ro ≤ dsp_rw`, `origin_seal_ro ≤ origin_seal_ro`).

**Proof.** An unsigned `pirate_clone` node holding only `audio.dsp_ro` but
declaring `needs = [id.origin_seal_rw]` emits exactly **E-CAP-USE** — it can
never mint a lineage seal. Lineage verification itself is one hash compare
plus one graph lookup in the compiled runtime: well under 1 ms, no cloud.

**Measured.** Clean fixture: 0 diagnostics. Violation fixture: exactly
1 diagnostic (E-CAP-USE). Pure check ~0.6 s (Python reference) · compiled
front-end target **<150 ms**.

**Fixture.** `yamaha-origin-seal.vaked` · `yamaha-origin-seal-violation.vaked`

---

**日本語 — 起源シール・アーキテクト**（Nintendo | Sony | Sanrio | Yamaha
から、本インスタンスは**Yamaha**を選択 — 音楽レーンは私たちの本流です）

**課題。** ハードウェアのハンドシェイクと創作アセットは、その系譜を
1ミリ秒未満で完全ローカルに検証できなければなりません。楽器、DSPボイス
プログラム、サンプルは、語る前に「誰が作ったか」を証明する必要があります。

**設計。** ゼロアロケーション台帳と暗号学的起源シール。能力ドメインは
`id`（`origin_seal_ro < origin_seal_rw`）と`audio`（`dsp_ro < dsp_rw`）。
`asset_ledger`がシール書き込み権を、`synth_engine`が`audio.dsp_rw`と閲覧
系譜を、`instrument_fw`が閲覧のみを保持。合法的な
`synth_engine -> instrument_fw : "voice-program"`は減衰則に適合します。

**証明。** 署名のない`pirate_clone`が`audio.dsp_ro`のみを持ちながら
`needs = [id.origin_seal_rw]`を宣言すると、**E-CAP-USE**が正確に1件出力
され、系譜シールの偽造は不可能です。系譜検証はハッシュ比較1回＋グラフ
参照1回で、コンパイル済み実行時では**1ms未満**、クラウド依存ゼロ。

**実測。** 正常系0件、違反系はE-CAP-USE 1件。純検査は参照実装で約0.6秒、
コンパイル済みフロントエンドで**150ms未満**を目標。

**フィクスチャ。** `yamaha-origin-seal.vaked` / `yamaha-origin-seal-violation.vaked`
