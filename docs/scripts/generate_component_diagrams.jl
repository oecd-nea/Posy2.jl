# Run from the repository root with:
# julia --project=docs docs/scripts/generate_component_diagrams.jl
#
# Draws one port diagram per component builder. Inputs are on the left, outputs
# on the right, and the storage level inside the component box. Colour encodes
# the kind of flow, line style repeats it, and a dashed endpoint box marks a
# port that is not connected to a node.

const COLORS = Dict(
    :free => "#2a9d8f",    # flow the optimizer chooses
    :fixed => "#264653",   # flow imposed by an exogenous series
    :linked => "#e76f51",  # flow derived from another flow
    :level => "#c44536",   # stored energy
)
const DASHES = Dict(:free => "none", :linked => "3 3", :fixed => "7 4")

# node boxes are tinted by carrier
const CARRIERS = Dict(
    :electricity => ("#fdf6cd", "#c9a227"),
    :heat => ("#fbe6e2", "#c4553c"),
    :hydrogen => ("#e6effa", "#4a7fb5"),
    :other => ("#eceff1", "#78909c"),
)

const WIDTH = 1000
const SIDE_X, SIDE_W = 20, 150
const COMP_X, COMP_W = 350, 300
const PITCH = 78
const ROW_H = 46

xmlescape(s) = replace(string(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;")

# vertical centre of each of `n` rows inside a component box spanning y0..y1
rowcenters(n, y0, y1) = [(y0 + y1) / 2 + (i - (n + 1) / 2) * PITCH for i in 1:n]

function svg_document(draw, path, height)
    open(path, "w") do io
        println(io, """<svg xmlns="http://www.w3.org/2000/svg" width="$WIDTH" height="$height" viewBox="0 0 $WIDTH $height" role="img">""")
        println(io, """<rect width="100%" height="100%" fill="#ffffff"/>""")
        println(io, "<defs>")
        for (kind, color) in COLORS
            println(io, """<marker id="head-$kind" viewBox="0 0 10 8" refX="9" refY="4" markerWidth="8" markerHeight="7" orient="auto"><path d="M0,0 L10,4 L0,8 z" fill="$color"/></marker>""")
        end
        println(io, "</defs>")
        println(io, """<style>
            text { font-family: system-ui, sans-serif; fill: #263238; }
            .port { font-size: 12px; font-weight: 600; text-anchor: middle; }
            .note { font-size: 10px; fill: #546e7a; text-anchor: middle; }
            .noteleft { font-size: 10px; fill: #546e7a; }
            .box { font-size: 11.5px; text-anchor: middle; }
            .boxsub { font-size: 9.5px; fill: #546e7a; text-anchor: middle; }
            .chip { font-size: 9px; fill: #78909c; font-style: italic; text-anchor: middle; }
            .name { font-size: 12.5px; font-weight: 600; text-anchor: middle; }
            .legend { font-size: 10.5px; fill: #546e7a; }
        </style>""")
        draw(io)
        println(io, "</svg>")
    end
    println("wrote $path")
end

"""Endpoint box at the far end of one or more flows, spanning `ytop..ybot`."""
function drawendpoint(io, e, x, ytop, ybot)
    connected = e.kind === :node
    fill, stroke = connected ? CARRIERS[get(e, :carrier, :other)] : ("#ffffff", "#78909c")
    dash = connected ? "none" : "5 3"
    h = ybot - ytop
    println(io, """<rect x="$x" y="$ytop" width="$SIDE_W" height="$h" rx="6" fill="$fill" stroke="$stroke" stroke-width="1" stroke-dasharray="$dash"/>""")
    xm = x + SIDE_W / 2
    y = ytop + h / 2 - 6 * (length(e.label) - 1)
    println(io, """<text class="box" x="$xm" y="$(y + 4)">$(xmlescape(e.label[1]))</text>""")
    for (i, line) in enumerate(e.label[2:end])
        println(io, """<text class="boxsub" x="$xm" y="$(y + 4 + 13 * i)">$(xmlescape(line))</text>""")
    end
    haskey(e, :chip) && println(io, """<text class="chip" x="$xm" y="$(ybot + 12)">$(xmlescape(e.chip))</text>""")
end

"""
Arrow, name and annotation for one flow. Arrows always point rightwards. A flow
with `port=false` is a bound rather than a port, so it gets no port marker.
"""
function drawflow(io, f, y, side)
    color = COLORS[f.kind]
    x0, x1 = side === :left ? (SIDE_X + SIDE_W, COMP_X) : (COMP_X + COMP_W, WIDTH - SIDE_X - SIDE_W)
    println(io, """<line x1="$x0" y1="$y" x2="$(x1 - 8)" y2="$y" stroke="$color" stroke-width="2" stroke-dasharray="$(DASHES[f.kind])" marker-end="url(#head-$(f.kind))"/>""")
    if get(f, :port, true)
        println(io, """<circle cx="$(side === :left ? x1 : x0)" cy="$y" r="4.5" fill="$color"/>""")
    end
    xm = (x0 + x1) / 2
    println(io, """<text class="port" x="$xm" y="$(y - 10)" fill="$color">$(xmlescape(f.name))</text>""")
    for (i, line) in enumerate(f.note)
        println(io, """<text class="note" x="$xm" y="$(y + 14 + 12 * (i - 1))">$(xmlescape(line))</text>""")
    end
end

"""Group consecutive flows that share an endpoint so they get one box."""
function endpointgroups(flows)
    groups = Tuple{Any,Vector{Int}}[]
    for (i, f) in enumerate(flows)
        if !isempty(groups) && last(groups)[1].label == f.endpoint.label
            push!(last(groups)[2], i)
        else
            push!(groups, (f.endpoint, [i]))
        end
    end
    return groups
end

function drawside(io, flows, ys, side)
    x = side === :left ? SIDE_X : WIDTH - SIDE_X - SIDE_W
    for (i, f) in enumerate(flows)
        drawflow(io, f, ys[i], side)
    end
    for (e, idx) in endpointgroups(flows)
        drawendpoint(io, e, x, minimum(ys[idx]) - ROW_H / 2, maximum(ys[idx]) + ROW_H / 2)
    end
end

"""Storage level gauge drawn inside the component box."""
function drawlevel(io, level, y0, y1)
    gx, gw = COMP_X + 22, 88
    gy1, gh = y1 - 34, min(y1 - y0 - 112, 130)
    gy0 = gy1 - gh
    color = COLORS[:level]
    println(io, """<rect x="$gx" y="$gy0" width="$gw" height="$gh" rx="4" fill="#ffffff" stroke="$color" stroke-width="1.5"/>""")
    println(io, """<rect x="$gx" y="$(gy0 + 0.42 * gh)" width="$gw" height="$(0.58 * gh)" rx="4" fill="$color" fill-opacity="0.28"/>""")
    println(io, """<line x1="$gx" y1="$(gy0 + 0.42 * gh)" x2="$(gx + gw)" y2="$(gy0 + 0.42 * gh)" stroke="$color" stroke-width="1.5"/>""")
    # the level itself is a decision: measure it from zero with a free-flow arrow
    println(io, """<line x1="$(gx + gw / 2)" y1="$(gy1 - 4)" x2="$(gx + gw / 2)" y2="$(gy0 + 0.42 * gh + 7)" stroke="$(COLORS[:free])" stroke-width="2" marker-end="url(#head-free)"/>""")
    println(io, """<text class="note" x="$(gx + gw / 2)" y="$(gy1 + 13)">0</text>""")
    println(io, """<text class="port" x="$(gx + gw / 2)" y="$(gy0 - 9)" fill="$color">$(xmlescape(level.name))</text>""")
    tx = gx + gw + 18
    for (i, line) in enumerate(level.note)
        println(io, """<text class="noteleft" x="$tx" y="$(gy0 + gh / 2 - 6 * length(level.note) + 12 * i)">$(xmlescape(line))</text>""")
    end
end

const LEGEND = [
    :free => "optimized flow",
    :fixed => "exogenous fixed flow",
    :linked => "linked flow",
    :level => "stored energy",
    :unconnected => "not connected",
]

function drawlegend(io, y, kinds)
    x = SIDE_X
    for (kind, label) in LEGEND
        kind in kinds || continue
        if kind === :unconnected
            println(io, """<rect x="$x" y="$(y - 7)" width="24" height="14" rx="3" fill="#ffffff" stroke="#78909c" stroke-dasharray="5 3"/>""")
        else
            println(io, """<line x1="$x" y1="$y" x2="$(x + 24)" y2="$y" stroke="$(COLORS[kind])" stroke-width="2.5" stroke-dasharray="$(get(DASHES, kind, "none"))"/>""")
        end
        println(io, """<text class="legend" x="$(x + 31)" y="$(y + 4)">$(xmlescape(label))</text>""")
        x += 31 + 7 * length(label) + 26
    end
end

function drawdiagram(spec)
    flows = vcat(spec.inputs, spec.outputs)
    kinds = Set(f.kind for f in flows)
    isnothing(spec.level) || push!(kinds, :level, :free)
    any(f -> f.endpoint.kind !== :node, flows) && push!(kinds, :unconnected)
    chips = any(f -> haskey(f.endpoint, :chip), flows)

    y0 = 26
    minheight = isnothing(spec.level) ? 150 : 210
    y1 = y0 + max(minheight, PITCH * max(length(spec.inputs), length(spec.outputs)) + 34)
    svg_document(joinpath(@__DIR__, "..", "src", "assets", spec.file), y1 + (chips ? 74 : 62)) do io
        println(io, """<rect x="$COMP_X" y="$y0" width="$COMP_W" height="$(y1 - y0)" rx="10" fill="#f8f9fa" stroke="#37474f" stroke-width="1.5"/>""")
        println(io, """<text class="name" x="$(COMP_X + COMP_W / 2)" y="$(y0 + 26)">$(xmlescape(spec.component))</text>""")
        for (i, line) in enumerate(get(spec, :inside, String[]))
            println(io, """<text class="boxsub" x="$(COMP_X + COMP_W / 2)" y="$(y0 + 30 + 14 * i)">$(xmlescape(line))</text>""")
        end
        drawside(io, spec.inputs, rowcenters(length(spec.inputs), y0, y1), :left)
        drawside(io, spec.outputs, rowcenters(length(spec.outputs), y0, y1), :right)
        isnothing(spec.level) || drawlevel(io, spec.level, y0, y1)
        drawlegend(io, y1 + (chips ? 52 : 40), kinds)
    end
end

# endpoints shared by several builders
const ELEC = (label=["electricity node", "elec"], kind=:node, carrier=:electricity)
const ELEC_BOTH = (label=["electricity node", "elec"], kind=:node, carrier=:electricity, chip="(same node)")
const H2 = (label=["hydrogen node", "h2"], kind=:node, carrier=:hydrogen)
const H2_BOTH = (label=["hydrogen node", "h2"], kind=:node, carrier=:hydrogen, chip="(same node)")
const CO2 = (label=["CO2 node", "co2"], kind=:node, carrier=:other)
const DRIVING = (label=["not connected", "own carrier"], kind=:unconnected)

const SPECS = [
    # --- demand and flexibility -------------------------------------------
    (
        file="component-demand.svg",
        component="Electricity Demand",
        inputs=[
            (name="input", kind=:fixed, note=["profile_multiplier x profile", "+ annual_flat_demand / 8760"],
                endpoint=(label=["demand node", "n"], kind=:node, carrier=:electricity)),
            (name="grid losses", kind=:linked, note=["only if grid_losses > 0", "grid_losses x input"],
                endpoint=(label=["demand node", "n"], kind=:node, carrier=:electricity)),
        ],
        outputs=[],
        level=nothing,
    ),
    (
        file="component-flat-hydrogen-demand.svg",
        component="Flat Hydrogen Demand",
        inputs=[(name="input", kind=:fixed, note=["annual_demand / 8760 every hour", "no capacity, no cost"], endpoint=H2)],
        outputs=[],
        level=nothing,
    ),
    (
        file="component-flex-hydrogen-demand.svg",
        component="Flexible Hydrogen Demand",
        inputs=[(name="input", kind=:free, note=["hourly shape is free", "yearly sum = annual_demand (equality)"], endpoint=H2)],
        outputs=[],
        level=nothing,
    ),
    (
        file="component-demand-response.svg",
        component="Demand Response",
        inputs=[
            (name="input", kind=:fixed, note=["fixed at 0", "anchors the component"], endpoint=ELEC),
            (name="negative consumption", kind=:linked, note=["-(1 - node losses) x output", "enters the balance as demand"], endpoint=ELEC),
        ],
        outputs=[
            (name="output", kind=:free, note=["cap, or Inf for unlimited", "activation cost, reporting"],
                endpoint=(label=["not connected", "accounting flow only"], kind=:unconnected)),
        ],
        level=nothing,
    ),

    # --- generation --------------------------------------------------------
    (
        file="component-dispatchable.svg",
        component="Dispatchable Generation",
        inputs=[
            (name="fuel", kind=:linked, note=["only with a fuel node", "output / efficiency"],
                endpoint=(label=["fuel node", "fuel_node"], kind=:node, carrier=:other)),
        ],
        outputs=[
            (name="output", kind=:free, note=["cap, unit_size, uc, ramping", "investment, fom, vom, fuel cost"], endpoint=ELEC),
            (name="co2", kind=:linked, note=["only if co2_emission > 0", "output x co2_emission / 1000"], endpoint=CO2),
        ],
        level=nothing,
    ),
    (
        file="component-nuclear.svg",
        component="Nuclear Generation",
        inputs=[
            (name="fuel", kind=:linked, note=["only with a fuel node", "output / efficiency"],
                endpoint=(label=["fuel node", "fuel_node"], kind=:node, carrier=:other)),
        ],
        outputs=[
            (name="output", kind=:free, note=["cap, unit_size, uc, refuel", "investment, fom, vom, waste"], endpoint=ELEC),
            (name="co2", kind=:linked, note=["only if co2_emission > 0", "output x co2_emission / 1000"], endpoint=CO2),
        ],
        level=nothing,
    ),
    (
        file="component-intermittent.svg",
        component="Intermittent Generation",
        inputs=[
            (name="profile", kind=:fixed, port=false, note=["sets output, not a port", "values in [0, 1]"],
                endpoint=(label=["profile series", "profiles_<weather_year>", "column: <tech_column>_<node>"], kind=:series)),
        ],
        outputs=[
            (name="output", kind=:fixed, note=["cap x profile each hour", "curtailed at the node"], endpoint=ELEC),
            (name="co2", kind=:linked, note=["only if co2_emission > 0", "output x co2_emission / 1000"], endpoint=CO2),
        ],
        level=nothing,
    ),
    (
        file="component-hydro-ror.svg",
        component="Run-of-river Hydro",
        inputs=[
            (name="intake envelope", kind=:fixed, port=false, note=["output <= hourly intake", "upper bound, not a port"],
                endpoint=(label=["intake series", "hydro_ror_<weather_year>", "column: zone"], kind=:series)),
        ],
        outputs=[
            (name="output", kind=:free, note=["cap, investment, fom, vom", "dispatchable under the envelope"], endpoint=ELEC),
        ],
        level=nothing,
    ),

    # --- storage -----------------------------------------------------------
    (
        file="component-hydro-reservoir.svg",
        component="Hydro Reservoir",
        inputs=[
            (name="natural", kind=:fixed, note=["intake profile x intake", "not connected; omitted if intake = 0"],
                endpoint=(label=["intake series", "reservoir_inflow_<weather_year>", "column: zone"], kind=:series)),
            (name="input", kind=:free, note=["grid charging, charge_cap", "eff = roundtrip_eff"], endpoint=ELEC_BOTH),
            (name="grid losses", kind=:linked, note=["grid_losses x input", "eff 0, energy discarded"], endpoint=ELEC_BOTH),
        ],
        outputs=[
            (name="output", kind=:free, note=["generation, discharge_cap", "eff 1, all costs attach here"], endpoint=ELEC_BOTH),
            (name="spill", kind=:free, note=["only if spillage = true", "unlimited and uncosted"],
                endpoint=(label=["not connected", "released outside the system"], kind=:unconnected)),
        ],
        level=(name="level", note=["energy_cap", "Inf (default): unlimited", "periodic: wraps last hour", "into first hour"]),
    ),
    (
        file="component-battery.svg",
        component="Battery Storage",
        inputs=[
            (name="input", kind=:free, note=["charging, cap", "eff_i, all costs attach here"], endpoint=ELEC_BOTH),
            (name="grid losses", kind=:linked, note=["only if grid_losses > 0", "grid_losses x input"], endpoint=ELEC_BOTH),
        ],
        outputs=[
            (name="output", kind=:free, note=["discharging, no own capacity", "bounded by cap through Duration"], endpoint=ELEC_BOTH),
        ],
        level=(name="level", note=["duration x cap", "Duration ties the level", "to charging power"]),
    ),

    # --- hydrogen ----------------------------------------------------------
    (
        file="component-flat-hydrogen-purchase.svg",
        component="Flat Hydrogen Purchase",
        inputs=[],
        outputs=[(name="output", kind=:fixed, note=["annual_supply / 8760 every hour", "flat profile source"], endpoint=H2)],
        level=nothing,
    ),
    (
        file="component-electrolyser.svg",
        component="Electrolyser",
        inputs=[
            (name="input", kind=:free, note=["electricity, cap", "all costs attach here"], endpoint=ELEC),
            (name="grid losses", kind=:linked, note=["only if grid_losses > 0", "grid_losses x input"], endpoint=ELEC),
        ],
        outputs=[(name="output", kind=:linked, note=["efficiency x input", "hydrogen production"], endpoint=H2)],
        level=nothing,
    ),
    (
        file="component-hydrogen-storage.svg",
        component="Hydrogen Storage",
        inputs=[(name="input", kind=:free, note=["charging, eff_i", "no power capacity"], endpoint=H2_BOTH)],
        outputs=[(name="output", kind=:free, note=["discharging", "no power capacity"], endpoint=H2_BOTH)],
        level=(name="level", note=["cap, investment, fom", "always simplified"]),
    ),

    # --- interconnections --------------------------------------------------
    (
        file="component-node-interco.svg",
        component="Node Interconnection",
        inputs=[
            (name="input", kind=:free, note=["a to b, shared cap", "x a_to_b_availability"],
                endpoint=(label=["node a", "a"], kind=:node, carrier=:electricity)),
            (name="input2", kind=:free, note=["b to a, shared cap", "x b_to_a_availability"],
                endpoint=(label=["node b", "b"], kind=:node, carrier=:electricity)),
        ],
        outputs=[
            (name="output", kind=:linked, note=["(1 - loss_factor) x input"],
                endpoint=(label=["node b", "b"], kind=:node, carrier=:electricity)),
            (name="output2", kind=:linked, note=["(1 - loss_factor) x input2"],
                endpoint=(label=["node a", "a"], kind=:node, carrier=:electricity)),
            (name="grid losses ic", kind=:linked, note=["loss_factor x (input + input2)", "reporting only"],
                endpoint=(label=["not connected", "avoids double counting"], kind=:unconnected)),
        ],
        level=nothing,
    ),
    (
        file="component-price-interco.svg",
        component="Price Interconnection",
        inside=["the counterparty is a price series, not a node:", "spot_price and transfer capacities for neighbor_column"],
        inputs=[
            (name="input", kind=:free, note=["exports, export_cap", "x export_availability", "revenue -spot_price"], endpoint=ELEC_BOTH),
        ],
        outputs=[
            (name="output", kind=:free, note=["imports, import_cap", "x import_availability", "cost +spot_price"], endpoint=ELEC_BOTH),
        ],
        level=nothing,
    ),

    # --- electric vehicles -------------------------------------------------
    (
        file="component-ev-fixed.svg",
        component="EV, Fixed Profile",
        inputs=[
            (name="input", kind=:fixed, note=["off-hour charging schedule", "sums to annual_consumption"], endpoint=ELEC),
            (name="grid losses", kind=:linked, note=["only if grid_losses > 0", "grid_losses x input"], endpoint=ELEC),
        ],
        outputs=[(name="driving", kind=:fixed, note=["equals the charging series", "reporting only"], endpoint=DRIVING)],
        level=nothing,
    ),
    (
        file="component-ev-flexible.svg",
        component="EV, Smart Charging And V2G",
        inputs=[
            (name="input", kind=:free, note=["fleet charging power", "x charging availability"], endpoint=ELEC_BOTH),
            (name="arrival", kind=:fixed, note=["returning battery energy", "count x SOC x battery_capacity"], endpoint=DRIVING),
        ],
        outputs=[
            (name="output", kind=:free, note=["only if vehicle_to_grid", "fleet dispatch power x avail.", "compensation cost"], endpoint=ELEC_BOTH),
            (name="departure", kind=:fixed, note=["leaving battery energy", "count x SOC x battery_capacity"], endpoint=DRIVING),
            (name="driving", kind=:fixed, note=["net driving", "departure - arrival", "reporting only"], endpoint=DRIVING),
        ],
        level=(name="level", note=["fleet battery capacity", "x charging availability"]),
    ),
]

foreach(drawdiagram, SPECS)
