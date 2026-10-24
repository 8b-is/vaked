# RFC — Canon · Optical Provenance & Lithography Telemetry Ledger

**EN — Embedded Imaging & Fab Security Architect**

**Problem.** Raw CMOS frames and fab alignment metrics must be notarized at
capture time — every packet hash-chained, every injection rejected before it
reaches the Zig/Rust runtime config.

**Design.** Zero-allocation, `#![no_std]` capture path: each frame seal is
`H(frame_id ‖ exposure_us ‖ align_um ‖ seal_prev)`; the seal chain is checked
in the sensor firmware, not in the datacenter. The `.vaked` closed-schema
stream pins the contract:

```vaked
schema cmosFrame {
  field frame_id    : Int { required in 0 .. 4294967295 }
  field exposure_us : Int { required in 10 .. 4000000 }
  field align_um    : Int { required in -1000 .. 1000 }
  field hash_prev   : String { required nonempty }
  field seal        : String { required nonempty }
}
stream cmosTelemetry { source = pipe.cmosFrontend type = cmosFrame fps = 60 }
```

**Proof.** Malformed or injected telemetry is rejected by the closed schema
before lowering: `fps = 0` emits **E-CONSTRAINT-RANGE** (violates `> 0`);
an undeclared `injected = true` field emits **E-CONFORM-UNKNOWN-FIELD**.
The clean fixture checks with 0 diagnostics.

**Measured.** Injection fixture: exactly those 2 diagnostics. Pure check
~0.6 s (Python reference) · compiled front-end target **<150 ms**.

**Fixture.** `canon-cmos-stream.vaked` · `canon-cmos-stream-injection.vaked`

---

**日本語 — 組込イメージング・ファブセキュリティアーキテクト**

**課題。** 生CMOSフレームとファブ位置合わせメトリクスは、撮像時点で公証
され、全パケットがハッシュチェーン結合され、注入データはZig/Rust実行時
設定に降下する前に拒否されなければなりません。

**設計。** ゼロアロケーション・`#![no_std]`撮像経路：フレームシールは
`H(frame_id ‖ exposure_us ‖ align_um ‖ seal_prev)`で、検証はデータセンター
ではなくセンサファームウェア内で行います。クローズドスキーマのストリーム
が契約を固定します（上記の`cmosFrame`参照）。

**証明。** 不正・注入テレメトリは降下前に拒否：`fps = 0`は
**E-CONSTRAINT-RANGE**、未宣言フィールド`injected`は
**E-CONFORM-UNKNOWN-FIELD**を出力。正常系は診断0件。

**実測。** 注入フィクスチャは正確に上記2件。純検査は参照実装で約0.6秒、
コンパイル済みフロントエンドで**150ms未満**を目標。

**フィクスチャ。** `canon-cmos-stream.vaked` / `canon-cmos-stream-injection.vaked`
