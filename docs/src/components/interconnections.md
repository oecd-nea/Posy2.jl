# Interconnections

POSY2 offers two representations of cross-zone exchange. A node
interconnection connects two explicit model nodes. A price interconnection
represents an external market through import and export capacities and an
exogenous price series.

See [Component Builders](../components.md) for shared capacity, port, and
tagging conventions. See [Input Workbooks](../concepts/input-data.md) for the
transfer-capacity and price sheets.

## Direction And Transfer Multipliers

Directional capacities are base capacities. When a direction is finite, POSY2
reads an hourly multiplier from sheet `transfer_capacities`. Its column is
named for the direction, written as `From>To` with no spaces. Effective
capacity is the base capacity multiplied by that series. The values are
therefore fractions or other multipliers, not absolute MW capacities.

Setting a node-interconnection direction to `Inf` omits its capacity behaviour
and its workbook lookup. A price interconnection always has fixed capacities in
both directions and therefore requires both multiplier columns.

For a price interconnection, `dir=true` adds an SOS1 constraint at every
timestep so that imports and exports cannot be used simultaneously. This may
require solver support beyond a plain continuous LP.

!!! warning "Node-interconnection direction constraint"
    The current node-interconnection implementation applies its `dir=true`
    SOS1 relation to aggregate component input and output. Because either
    physical direction uses one input and one output, the relation can suppress
    all transfer. Leave `dir=false` for [`makenodeinterco`](@ref) until the
    constraint is corrected.

## Node Interconnections

[`makenodeinterco`](@ref) names the component
`"$(cname)_$(a.name)_$(b.name)"`. Its first direction is `a -> b`:

- `input` withdraws from node `a` and carries capacity `atob`;
- `output` delivers to node `b` after `lossfactor`.

The reverse direction is `b -> a`:

- `input2` withdraws from node `b` and carries capacity `btoa`;
- `output2` delivers to node `a` after `lossfactor`.

Only one `AC` node interconnection is allowed between a given unordered pair of
nodes; a second `AC` call for the same pair raises an error. Parallel `DC`
links and mixed `AC`+`DC` on the same pair are allowed.

For a finite direction, `transactioncost` is applied to its sending flow. The
current implementation omits this cost when the corresponding capacity is
`Inf`. The unconnected `grid losses ic` output records proportional losses for
reporting. Both node names are stored as `:zone` values.

The component carries `interconnection`, `nodeinterconnection`, and either
`AC` or `DC` function tags. `foreign=true` adds `foreign`; use it when one
endpoint represents the external system. The nodes themselves still need the
appropriate `:electricity` and `:foreign` tags for self-versus-foreign reports.

### DC Power-flow Metadata

Here `dc` classifies the interconnector for Kirchhoff voltage-law constraints;
it does not make the link unidirectional. `dc=false` creates an AC-classified
link, while `dc=true` excludes it from the cycle constraints added by
[`applydcopf!`](@ref).

When DC power flow is enabled in [`POSY2Options`](@ref), every AC node
interconnection must supply a negative `susceptance`. The builder stores it in
the snapshot's internal registry. Call [`applydcopf!`](@ref) after adding all
links and before optimisation. See
[Optimising A Snapshot](../concepts/optimizing.md) for the complete workflow.

## Price Interconnections

[`makepriceinterco`](@ref) creates `"IC_$(zone)_$(elec.name)"` without creating
an explicit node for the neighbouring market. Imports use component `output`,
fixed base capacity `mcap`, multiplier column `zone>local`, and the neighbour's
`spot_price` series. Exports use component `input`, base capacity `xcap`, and
multiplier column `local>zone`. Export energy earns the same exogenous spot
price; `transactioncost` is added in both directions.

The builder adds `interconnection` and `priceinterconnection` function tags,
stores `zone` as the `:neighbor` value, and stores the local node as `:zone`.
`foreign` defaults to true because the common use case is a market outside the
modelled system. Set it to false when the price series represents another
internal zone.

Price interconnections do not participate in DC power-flow cycle constraints:
they have no second explicit electrical node or susceptance.

## Losses And Reporting

Node-interconnection losses are recorded once on the component. Annual node
reports allocate half to each connected node to avoid double counting.
Directed flow reports use labels of the form `from > to`; price-interconnection
labels combine the `:neighbor` tag and connected local node, while node links
derive their endpoints from port carriers.

Give each explicit electricity node a distinct carrier name. Endpoint discovery
uses those carrier names rather than parsing underscores or other punctuation
from the component name.

## API Entries

See the [API Reference](../api.md) for [`makenodeinterco`](@ref) and
[`makepriceinterco`](@ref).
