# RFC — Panasonic · Cell Provenance & the Technics Audio Lane

**EN — Energy & Audio Systems Architect**

**Problem.** A battery cell and a Technics voice program share one property:
their value is their lineage. Cell-level telemetry (voltage, temperature, SOC)
must be sealed at formation time and read without trust downstream; a service
tool must diagnose without ever gaining cell authority.

**Design.** Closed `cellTelemetry` schema pins the physics
(`cell_voltage_mv ∈ 2000..4200`, `temp_c ∈ -40..85`, `soc_pct ∈ 0..100`, plus
a per-cell `seal`). Two capability domains: `fab`
(`cell_ro < cell_rw`) and `svc` (`diagnostic_ro`). `formation_line` holds
`fab.cell_rw`; `vehicle_bms` holds `fab.cell_ro`; `service_tool` holds only
`svc.diagnostic_ro`. The legal edge `formation_line -> vehicle_bms` is
attenuation-safe.

**Proof.** The violation fixture carries two independent rejections:
`service_tool -> vehicle_bms` emits **E-CAP-ATTENUATION** (the service tool
holds nothing in `fab`), and `fps = 0` on the telemetry stream emits
**E-CONSTRAINT-RANGE**. The clean fixture checks with 0 diagnostics.

**Measured.** Positive: 0 diagnostics. Violation: E-CONSTRAINT-RANGE +
E-CAP-ATTENUATION (+ a W-CONFUSED-DEPUTY marker). Pure check ~0.6 s (Python
reference) · compiled front-end target **<150 ms** · zero runtime overhead.

**Fixture.** `panasonic-cell-provenance.vaked` ·
`panasonic-cell-provenance-violation.vaked`

---

**日本語 — エネルギー・オーディオシステムアーキテクト**

**課題。** 電池セルとTechnicsのボイスプログラムが共有する唯一の性質は、
その価値が系譜にあることです。セル単位のテレメトリ（電圧・温度・SOC）は
形成時点で封印され、下流は無信頼のまま読み取るだけ。サービスツールは
診断はできても、セル権限は決して持ちません。

**設計。** クローズドな`cellTelemetry`スキーマが物理量を固定
（`cell_voltage_mv` 2000〜4200、`temp_c` -40〜85、`soc_pct` 0〜100、セル
毎の`seal`）。能力ドメインは`fab`（`cell_ro < cell_rw`）と`svc`
（`diagnostic_ro`）。`formation_line`が`fab.cell_rw`を、`vehicle_bms`が
`fab.cell_ro`を、`service_tool`は`svc.diagnostic_ro`のみを保持。合法的な
`formation_line -> vehicle_bms`は減衰則に適合します。

**証明。** 違反フィクスチャは独立した2件の拒否を出力：
`service_tool -> vehicle_bms`は**E-CAP-ATTENUATION**、ストリームの
`fps = 0`は**E-CONSTRAINT-RANGE**。正常系は診断0件。

**実測。** 正常系0件、違反系はE-CONSTRAINT-RANGE + E-CAP-ATTENUATION
（+W-CONFUSED-DEPUTY）。純検査は参照実装で約0.6秒、コンパイル済み
フロントエンドで**150ms未満**を目標、ランタイムオーバーヘッドはゼロ。

**フィクスチャ。** `panasonic-cell-provenance.vaked` /
`panasonic-cell-provenance-violation.vaked`
