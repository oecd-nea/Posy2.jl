# Exporting Results

Posy2 provides a standard workbook report for solved studies. Nosy can also
serialize extracted snapshots or write the underlying optimisation model.

## Workbook Post-Processing

[`printsnapshot`](@ref) accepts an extracted `Snapshot{Float64}`:

```julia
result = extract(snapshot)
printsnapshot(result, "scenario.xlsx")
```

The workbook is written to `results/scenario.xlsx` relative to the current
working directory. The output contains five sheets:

- `Annual values (all)`: annual capacities, flows, prices, costs, and related
  indicators for the complete snapshot;
- `Annual values (self)`: the corresponding view for the non-foreign system
  boundary;
- `Losses`: annual losses per node, broken down by category and by technology,
  and the detailed per-source table (see [Losses](#losses));
- `Time series`: hourly demand, production, storage, interconnection, loss,
  curtailment, and price series;
- `Price duration curves`: endogenous and exogenous electricity prices sorted
  from highest to lowest.

Interconnection-specific tables and column conventions are described in
[Interconnections](../components/interconnections.md#losses-and-reporting).

If the destination already exists, Posy2 moves it to
`results/old/scenario.xlsx` before writing the new workbook. An older file with
that backup name is replaced. Use distinct filenames or copy important results
elsewhere when retaining several revisions.

`printsnapshot` accepts only an extracted `Snapshot{Float64}`.
The current standard report assumes a complete 8760-hour result and the
Posy2 node and component tags described in
[Tags And Post-Processing](tags.md).

Marginal-price and self-system interconnection tables require dual prices.
These are available only for continuous solutions and for nodes created with
`evalprice=true`.

## Losses

[`losses`](@ref) collects every loss of the electricity system into one flat
table, with one row per (loss source, node) pair:

```julia
julia> losses(result)
5×5 DataFrame
 Row │ node    source                   tech               category         losses
─────┼──────────────────────────────────────────────────────────────────────────────
   1 │ ZONE1   ZONE1                    network            node             18771.4
   2 │ ZONE1   Battery ZONE1            Battery            storage           1460.0
   3 │ ZONE1   IC_ZONE1_ZONE2           AC                 interconnection  24699.2
   4 │ ZONE2   IC_ZONE1_ZONE2           AC                 interconnection  24699.2
   5 │ ZONE1   Other consumption ZONE1  Other consumption  component        43800.0
```

Values are in MWhe, or hourly MWhe series with `collapse=false`. Each row is
attributed to a single node, and a component spanning several electricity nodes
(a node interconnection) splits its loss equally between them: the system total
therefore counts each loss once, while grouping by `source` still recovers the
whole corridor.

`by` aggregates the table over any combination of `:node`, `:source`, `:tech`
and `:category`:

```julia
losses(result; by=:node)                                    # losses of each node
losses(result; by=(:tech, :category))                       # losses of each technology, split by cause
losses(result; by=:source, categories=(:interconnection,))  # losses of each interconnection
```

`categories` restricts the table to a subset of the five loss categories:
`node` (nodal losses of `Node(losses=...)`, a ratio of the node inflow),
`component` (a single component's proportional `grid losses` flow),
`interconnection` (node interconnection transfer losses), `storage` (charging
conversion losses) and `selfdischarge`. Only the first
three, available as `Posy2.NETWORKLOSSES`, are flows of the nodal balance;
`storage` and `selfdischarge` are internal to their component and already
included in its charging flow. Carrier conversion losses (electrolysis, fuel to
power) are not losses of the electricity system and are not reported here.
Lossless sources are omitted, so an empty table means a lossless system.

The `Losses` sheet labels the three network categories `grid (node)`,
`grid (component)` and `grid (interconnection)`, because together they are the
`Grid losses` column of the annual tables. The categories themselves keep plain
symbol names, so `categories` filters and `category` comparisons stay writable.

## Serializing A Snapshot

Nosy's `exportsnapshot` saves an extracted result without its JuMP model:

```julia
exportsnapshot("results/scenario.snapshot", result)
restored = importsnapshot("results/scenario.snapshot")
```

The restored snapshot retains numeric components, nodes, costs, capacities,
flows, tags, and options, but it is not associated with a live JuMP model. It
is intended for later querying and reporting rather than re-optimisation.

Snapshot export uses Julia serialization. Only import snapshots that you
created yourself and only use compatible Julia, Nosy, and Posy2 versions.
Julia serialization is not a safe interchange format for untrusted files.

## Exporting The Optimisation Problem

To inspect or solve the mathematical problem outside Julia, finalise the
snapshot, set its objective, and use JuMP's file writer:

```julia
import JuMP

finalize!(snapshot)
JuMP.set_objective(
    model(sim(snapshot)),
    JuMP.MIN_SENSE,
    cost(snapshot),
)
JuMP.write_to_file(model(sim(snapshot)), "results/scenario.mps")
```

`Nosy.optimize!` finalises a snapshot automatically. If the model has already
been optimised, it can be passed directly to `JuMP.write_to_file`.

The selected file format may not represent every JuMP constraint type. Check
the writer and external solver when a model contains integer unit commitment,
SOS1 interconnection constraints, or other specialised sets.
