# RFC — Bandai Namco · Deterministic Netcode & NPC Sandbox Mesh

**EN — Lead Online Engine Architect**

**Problem.** 60 Hz fighting/arcade netcode needs deterministic frame-state
verification; third-party mods need an AI director sandbox that can never
touch player account tokens or memory outside its slice.

**Design.** The closed `tickState` schema pins the tick budget at the schema
level (`tick_hz == 60`, `memory_budget_kb <= 512`, hash-chained frame state),
and the mesh separates four principals: `matchmaker` (tokens_ro, memory_ro),
`arena_host` (memory_rw), `observer` (tokens_ro), and `ai_director`
(mods.sandbox_a). Edges obey attenuation — `matchmaker -> observer` is legal
because `tokens_ro ≤ tokens_ro`; nothing else crosses a boundary.

**Proof.** A `mod_plugin` node that holds only `mods.sandbox_a` but declares
`needs = [player.tokens_ro]` emits exactly **E-CAP-USE**: a held grant must
dominate every exercised capability. The clean field checks with
0 diagnostics; the compiler never emits runtime guards, so the 60 Hz loop
carries zero verification overhead.

**Measured.** Violation fixture: exactly 1 diagnostic (E-CAP-USE). Pure check
~0.6 s (Python reference) · compiled front-end target **<150 ms**.

**Fixture.** `namco-netcode-field.vaked` · `namco-netcode-field-violation.vaked`

---

**日本語 — 主任オンラインエンジンアーキテクト**

**課題。** 60Hz対戦・アーケードネットコードには決定的なフレーム状態検証が
必要です。またサードパーティMODのAIディレクタは、プレイヤーのアカウント
トークンや割当外メモリに一切触れないサンドボックスでなければなりません。

**設計。** クローズドな`tickState`スキーマがティック予算を固定
（`tick_hz == 60`・`memory_budget_kb <= 512`・ハッシュチェーン化フレーム
状態）。`matchmaker`・`arena_host`・`observer`・`ai_director`
（`mods.sandbox_a`）の4主体を分離し、エッジは減衰則に従います。

**証明。** `mods.sandbox_a`しか持たない`mod_plugin`が
`needs = [player.tokens_ro]`を宣言すると、**E-CAP-USE**が正確に1件出力。
正常系は診断0件で、60Hzループに検証オーバーヘッドは一切残りません。

**実測。** 違反フィクスチャはE-CAP-USE 1件のみ。純検査は参照実装で約
0.6秒、コンパイル済みフロントエンドで**150ms未満**を目標。

**フィクスチャ。** `namco-netcode-field.vaked` / `namco-netcode-field-violation.vaked`
