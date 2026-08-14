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
working directory. The output contains four sheets:

- `Annual values (all)`: annual capacities, flows, prices, costs, and related
  indicators for the complete snapshot;
- `Annual values (self)`: the corresponding view for the non-foreign system
  boundary;
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
