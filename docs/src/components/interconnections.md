# Interconnections

Posy2 offers two representations of cross-zone exchange. A node
interconnection connects two explicit model nodes. A price interconnection
represents an external market through import and export capacities and an
exogenous price series.

See [Component Builders](../components.md) for shared capacity, port, and
tagging conventions. See [Input Workbooks](../concepts/input-data.md) for the
transfer-capacity and price sheets.

## Direction And Transfer Multipliers

Directional capacities are base capacities and may be numeric or externally
defined by a JuMP variable or affine expression. For a numeric nonzero finite
direction or any symbolic direction, Posy2 uses an hourly multiplier. In
`timeseries_mode=:excel`, an omitted
multiplier is read from sheet `transfer_capacities`; in `:arguments` mode it
defaults to one. Its column is
named for the direction, written as `From>To` with no spaces. Effective
capacity is the base capacity multiplied by that series. The values are
therefore fractions or other multipliers, not absolute MW capacities.

Setting a node-interconnection direction to zero skips its multiplier lookup;
setting it to `Inf` omits both its capacity behaviour and multiplier lookup. A
price interconnection likewise resolves availability for numeric nonzero and
all symbolic directions. Its spot-price series remains required when either
direction is active, because a zero price would permit free imports rather than
disable the feature.

A symbolic direction is always treated as active and finite while the component
is built, even if its solved value may be zero. Numeric `Inf` remains the only
unlimited-capacity sentinel for node interconnections.

For a price interconnection, `dir=true` adds an SOS1 constraint at every
timestep so that imports and exports cannot be used simultaneously. For a
node interconnection, `dir=true` likewise constrains the two sending ports
(`input` and `input2`) so that only one direction can be positive in a given
hour. This may require solver support beyond a plain continuous LP.

## Node Interconnections

[`makenodeinterco`](@ref) names the component
`"$(cname)_$(a.name)_$(b.name)"`. Its first direction is `a -> b`:

- `input` withdraws from node `a` and carries capacity `atob`;
- `output` delivers to node `b` after `lossfactor`.

The reverse direction is `b -> a`:

- `input2` withdraws from node `b` and carries capacity `btoa`;
- `output2` delivers to node `a` after `lossfactor`.

`lossfactor` must be finite and lie in `[0, 1)`. Each delivered flow is its
sending flow multiplied by `1 - lossfactor`; invalid factors are rejected
before model construction.

The endpoints must be distinct. Self-connections and generated-name
collisions are rejected before the builder creates component variables or
directional SOS constraints.

Exactly one `AC` and one `DC` may share the same unordered node pair
(either, both, or neither is fine). A second `AC` or a second `DC` on
that pair raises an error. Aggregate equivalent parallel circuits
before calling the builder.

`transactioncost` is applied to each direction's sending flow, including when
that direction's capacity is `Inf`. The unconnected `grid losses ic` output 
records proportional losses for reporting. Both node names are stored as 
`:zone` values.

The component carries `interconnection`, `nodeinterconnection`, and either
`AC` or `DC` function tags. There is no component-level foreign flag: a node
interconnection counts as foreign in reports exactly when at least one of its
endpoints is a node tagged `:foreign`. Give nodes the appropriate
`:electricity` and `:foreign` tags for self-versus-foreign reports.

### DC Power-flow Metadata

Here `dc` classifies the interconnector for Kirchhoff voltage-law constraints;
it does not make the link unidirectional. `dc=false` creates an AC-classified
link, while `dc=true` excludes it from the cycle constraints added by
[`applydcopf!`](@ref).

When DC power flow is enabled in [`Posy2Options`](@ref), every AC node
interconnection must supply a negative series `susceptance`
(``B\approx-1/X`` for inductive lines). The builder stores it in the
snapshot's internal registry. Call [`applydcopf!`](@ref) after adding all
links and before optimisation. See
[Optimising A Snapshot](../concepts/optimizing.md) for the complete workflow.

## Price Interconnections

[`makepriceinterco`](@ref) creates `"IC_$(zone)_$(elec.name)"` without creating
an explicit node for the neighbouring market. Imports use component `output`,
base capacity `mcap`, multiplier column `zone>local`, and the neighbour's
`spot_price` series. Exports use component `input`, base capacity `xcap`, and
multiplier column `local>zone`. Export energy earns the same exogenous spot
price; `transactioncost` is added in both directions.

The builder adds `interconnection` and `priceinterconnection` function tags,
stores `zone` as the `:neighbor` value, and stores the local node as `:zone`.
`foreign` defaults to true because the common use case is a market outside the
modelled system. Set it to false when the price series represents another
internal zone.

Price interconnections do not participate in DC power flow cycle constraints:
they have no second explicit electrical node or susceptance.

## Losses And Reporting

Node-interconnection losses are recorded once on the component. Annual node
reports allocate half to each connected node to avoid double counting.
Directed flow reports use labels of the form `from > to`; price-interconnection
labels combine the `:neighbor` tag and connected local node, while node links
derive their endpoints from port carriers. Annual workbook tables include
interconnection capacity and volume for all links, then AC-only and DC-only
node-interconnection views (price interconnections appear only in the total
tables). Hours at NTC (Net Transfer Capacity, the directional transfer limit)
are reported as `(AC or DC)` (hour counts if either link
is binding), then `(AC)` and `(DC)` separately. In the hourly time-series sheet,
the same directed `from > to` label is used; when AC and DC share a corridor
their flows are summed into one column (there are no separate AC/DC time-series
columns). The hourly sheet also reports available transfer capacities
(`ATC from > to`) for foreign links, using the same endpoint conventions: price
interconnections built with `foreign=true`, and node interconnections with at
least one `:foreign`-tagged endpoint (foreign-foreign transit corridors
included). A direction without a capacity limit is omitted, and ATCs of AC and
DC links sharing a corridor are summed into one column.

Give each explicit electricity node a distinct carrier name. Endpoint discovery
uses those carrier names rather than parsing underscores or other punctuation
from the component name.

## API Entries

See the [API Reference](../api.md) for [`makenodeinterco`](@ref) and
[`makepriceinterco`](@ref).
