# Hydrogen

Hydrogen purchase is a separate exogenous supply of hydrogen energy. Related
hydrogen demand, storage, and electrolyser builders are documented with the
demand and storage pages.

See [Component Builders](../components.md) for shared naming, workbook,
capacity, port, and tagging conventions.

## Purchased Hydrogen

[`makeflathydrogenpurchase`](@ref) represents an exogenous hydrogen supply. It
creates fixed `output` capacity `val / 8760` with a constant profile, so `val`
is the total annual hydrogen-energy purchase. It reads no workbook and adds no
cost. Add an explicit Nosy cost behaviour when purchases should affect the
objective.

The generated name is `"$cname $(n.name)"`; the function tags are `hydrogen`
and `purchase`.

## API Entries

See the [API Reference](../api.md) for [`makeflathydrogenpurchase`](@ref).
Related builders: [`makeflathydrogendemand`](@ref),
[`makeflexhydrogendemand`](@ref), [`makehydrogenstorage`](@ref), and
[`makeelectrolyser`](@ref).
