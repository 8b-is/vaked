# RFC — Studio Ghibli · The Anti-Scrape Sovereign Archive Vault

**EN — Digital Preservation & Creative Sovereignty Architect**

A gentle proposal, written with deep respect for the atelier.

**The idea.** Keep every high-resolution cel scan inside a local-only,
air-gapped mesh. Restoration workstations read `fs.cel_archive_ro`; nothing in
the graph may ever touch `net.wan_egress`. The compiler does not *warn* about
network edges — it makes them unrepresentable, so the archive is un-scrapable
by construction, and the artistry stays entirely with the people who made it.

**The proof.** `vaked check` on the vault accepts the atelier (scan station,
restoration workstation, colorist; the colorist receives only the read grant
the restorer already holds — attenuation). A single hypothetical edge,
`restoration_ws -> cloud_backup` where `cloud_backup` holds `net.wan_egress`,
is rejected with exactly **E-CAP-ATTENUATION**: the restorer holds nothing in
the `net` domain, so no edge may deliver egress to them or through them.

**Measured.** Clean fixture: 0 diagnostics. Violation fixture: exactly
1 diagnostic (E-CAP-ATTENUATION). Pure check ~0.6 s (Python reference) ·
compiled front-end target **<150 ms**. No network code exists in the lowered
runtime config — the vault is offline because the type system says so.

**Fixture.** `ghibli-atelier-vault.vaked` · `ghibli-atelier-vault-violation.vaked`

---

**日本語 — デジタル保存・創作主権アーキテクト**

アトリエへの深い敬意を込めた、穏やかなご提案です。

**構想。** 高解像度セル画スキャンを、完全ローカル・エアギャップのメッシュ
内に保存します。修復ワークステーションは`fs.cel_archive_ro`の閲覧権のみを
保持し、グラフ上のいかなるノードも`net.wan_egress`に到達できません。
コンパイラは警告ではなく、ネットワークへのエッジ自体を表現不能にします。
それによりアーカイブは構造的にスクレイプ不可能となり、芸術は創った人々の
手元に完全に留まります。

**証明。** 金庫はアトリエ（スキャン室・修復室・彩色室）を受理し、彩色室が
受け取るのは修復室が既に持つ閲覧権のみ（減衰則）。仮想的な
`restoration_ws -> cloud_backup`（`cloud_backup`は`net.wan_egress`を保持）
は**E-CAP-ATTENUATION**を正確に1件出力して拒否されます。

**実測。** 正常系0件、違反系はE-CAP-ATTENUATION 1件。純検査は参照実装で
約0.6秒、コンパイル済みフロントエンドで**150ms未満**を目標。生成された
実行時設定にネットワークコードは存在しません。

**フィクスチャ。** `ghibli-atelier-vault.vaked` / `ghibli-atelier-vault-violation.vaked`
