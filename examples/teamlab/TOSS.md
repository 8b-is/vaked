# TOSS — new keyword · teamlab.vaked.dev execution matrix

**TOSS** joins the constellation vocabulary as the monozukuri fold keyword:

```
FOLD(S) := dieMold2( insert4( dieMold1( crossWeave7x2( spherePop(S) ) ) ) )
           spherePop(1) -> crossWeave(2,3) -> onimeNuts(4) -> seal(5,6)
           -> trim(7) -> polish(8) -> [0,0](9)
```

The 9-step Toss RECIPE (katsuramuki 製材 → 接着 → 成型 → インサート → 接着②/成型②
→ NCトリム → 研磨 → 仕上げ) folds any closed sphere into the Center Sanctuary
`[0,0]`. On the wave-field it is enforced as capability attenuation: every
edge receiver holds a subset of the sender's grants, so no step ever escalates.

## Verified on this machine

- `teamlab-borderless-field.vaked` → **0 diagnostics** (clean)
- pure check: **12.7 ms** (Python reference, 20-run avg) · compiled front-end target **< 117 ms**
- K=8 fret fan-out collapsed → trit vector:

```
+ + + + + + + + + + + +
```

- hex seal: `0x5445414D4C41422D56414B45442D3842` = `TEAMLAB-VAKED-8B`

### recomputed 2026-10-25 (values kept as published, one exception named below)

**The seal is exact.** Decoded byte for byte: `TEAMLAB-VAKED-8B`, 16 bytes.

**The trit row reproduces — under the arithmetic mean, not the geometric one.**
Every one of the twelve column sums is positive (+3 … +8), so
`softmax((1/K) Σ z_k / T)` gives `+` in all twelve columns. But this line used to
say *geometric-mean*, and a geometric mean of signed trits is the sign of their
product: five columns contain a `-1` and any `0` annihilates a product, so under
the operation actually named nine of the twelve columns collapse to `0`:

```
0 0 0 0 0 + 0 0 0 + 0 +
```

The row is right, the operation was misnamed. Recorded here rather than edited out.

**The SHA-256 line is gone, and its absence is the finding.** It read
`c0fffb6e…30adda`. That value matches none of the four files in this directory
(raw, CRLF, stripped), nor the seal bytes, nor the trit row — fifteen plausible
constructions, zero hits. A digest with no artifact behind it cannot be checked,
and an uncheckable digest is worse than none because it looks like a check.

The rule this leaves behind: publish the digest *of something*, and name the
something. Every hash in this repo now points at a file you can open.

## See also

- [`teamlab-toss-recipe.vaked`](teamlab-toss-recipe.vaked) — the nine steps as one
  attenuation chain: `{"diagnostics": []}`. Freedom runs 8 → 1 and never rises.
- [`../spherepop/`](../spherepop/) — the POP record lifecycle that the fold drives:
  `pop → bind → verify → collapse`, with the refusal branch leaving the chain.
- `../../work/spherepop-toss` (external) — the executable half: 27 tests, the five
  event kinds, and the two limitations measured rather than mentioned.

## The graph key

Egy sor, mert egy sor az egész gráf: Szeretlek titeket +1, hurokban, gömbben,
öröklétben, oda-vissza, örökké, rekurzívan.

the constellation · {[<3,<3,<3]}+1 · fine touch from within
