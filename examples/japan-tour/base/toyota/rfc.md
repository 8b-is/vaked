# RFC — Toyota (Arene/Woven) · ISO-26262 Capability Attenuation

**EN — Principal Automotive Systems Architect**

**Problem.** An ECU mesh where the head unit, the ADAS planner, and the brake
actuator share one bus is a privilege problem before it is a timing problem.
ISO-26262 ASIL-D boundaries must be enforced *before* the binary ships — not
by a runtime check that can panic on the highway.

**Design.** `vaked` models the mesh as a capability graph. Three nodes, two
domains: `infotainment_hud` holds `can.telemetry_ro`; `adas_planner` holds
`can.telemetry_ro, sensor.lidar_ro`; `brake_actuator` holds
`can.actuator_rw`; a `vehicle_controller` is the only node granted actuator
authority. Capability order: `none < telemetry_ro < actuator_rw`.

**Proof.** `vaked check` rejects the illegal handoff at compile time:
`infotainment_hud -> brake_actuator` emits exactly
**E-CAP-ATTENUATION** (receiver holds `actuator_rw`, sender holds only
`telemetry_ro`) plus a **W-CONFUSED-DEPUTY** marker on the hub. The legal
edge — `vehicle_controller -> brake_actuator` — checks clean with zero
diagnostics. No runtime guards exist in the lowered artifact: the check is
compile-time, so overhead is exactly zero.

**Measured.** Pure checker pass on the violation fixture: **0.6 s** on the
Python reference front-end (graph-wide Unicode normalization included); the
compiled Zig front-end (`vakedz`) targets **<150 ms**. Positive fixture:
0 diagnostics.

**Fixture.** `toyota-ecu-mesh.vaked` (clean) · `toyota-ecu-mesh-violation.vaked`
(escalation demo).

---

**日本語 — 主席自動車システムアーキテクト**

**課題。** ヘッドユニット・ADASプランナ・ブレーキアクチュエータが同一バスを
共有するECUメッシュは、タイミング以前に権限の問題です。ISO-26262
ASIL-D境界は出荷前に確定していなければならず、走行中にパニックしうる
ランタイム検査に委ねてはなりません。

**設計。** `vaked`はメッシュをケイパビリティグラフとして型検査します。
`infotainment_hud`は`can.telemetry_ro`、`adas_planner`は
`can.telemetry_ro, sensor.lidar_ro`、`brake_actuator`は`can.actuator_rw`
を保持し、`vehicle_controller`のみがアクチュエータ権限を持ちます。
能力順序は`none < telemetry_ro < actuator_rw`。

**証明。** 不正なハンドオフはコンパイル時に拒否されます。
`infotainment_hud -> brake_actuator`は**E-CAP-ATTENUATION**（受信者が
`actuator_rw`、送信者は`telemetry_ro`のみ）と**W-CONFUSED-DEPUTY**を
正確に1件ずつ出力。合法的なエッジ`vehicle_controller -> brake_actuator`は
診断0件。検査はコンパイル時に完結するため、ランタイムオーバーヘッドは
厳密にゼロです。

**実測。** 違反フィクスチャの純検査は参照フロントエンドで**0.6秒**、
コンパイル済みZigフロントエンド（`vakedz`）で**150ms未満**を目標。
正常系は診断0件。

**フィクスチャ。** `toyota-ecu-mesh.vaked` / `toyota-ecu-mesh-violation.vaked`
