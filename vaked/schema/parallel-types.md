# Parallel Types

## New domain types

```text
Index<T>
Catalog<T>
Stream<T>
Fiber<I, O>
Surface
Mesh<Node, Edge>
Device
MediaPipeline
ParallelGroup
```

## Fiber

A fiber is a policy-bound execution lane.

```text
Fiber<I, O> {
  engine: Engine
  input: I
  output: O
  policy: Policy
  budget: Budget
  observe: Bool
}
```

## Index

An index is a reproducible content source.

```text
Index<T> {
  source: Source
  schema: Schema<T>
  trust: TrustPolicy
  normalize: Normalizer
  emit: List<ArtifactTarget>
}
```

## Surface

A surface is an operator-facing visualization or control interface.

```text
Surface {
  mode: SurfaceMode
  input: List<Stream | Graph | Catalog>
  views: List<View>
  budget: Budget
}
```
