# Run from the repository root with:
# julia --project=docs docs/scripts/generate_example_figures.jl

using Posy2
using Nosy
using HiGHS
using Printf
import JuMP: set_silent

repo_dir = normpath(joinpath(@__DIR__, "..", ".."))
data_dir = joinpath(repo_dir, "data")
assets_dir = joinpath(repo_dir, "docs", "src", "assets")

function svg_points(values, left, top, width, height, ymin, ymax)
    n = length(values)
    join((@sprintf("%.2f,%.2f",
        left + (i - 1) * width / (n - 1),
        top + height * (1 - (clamp(value, ymin, ymax) - ymin) / (ymax - ymin)),
    ) for (i, value) in enumerate(values)), " ")
end

function nice_upper(value)
    value <= 0 && return 1.0
    scale = 10.0^floor(log10(value))
    ratio = value / scale
    multiplier = first(x for x in (1.0, 2.0, 2.5, 5.0, 10.0) if x >= ratio)
    multiplier * scale
end

function tick_label(value)
    a = abs(value)
    if a >= 10 || iszero(value)
        @sprintf("%.0f", value)
    else
        @sprintf("%.1f", value)
    end
end

function draw_panel(io, series; top, height, title, ylabel, hours, ymin=0.0, ymax=nothing, show_hours=false)
    left = 70.0
    width = 902.0
    ymax = isnothing(ymax) ? nice_upper(maximum(maximum(item.values) for item in series)) : ymax

    println(io, "<text class=\"title\" x=\"70\" y=\"$(top - 12)\">$title</text>")
    println(io, "<text class=\"axis-label\" transform=\"translate(18 $(top + height / 2)) rotate(-90)\">$ylabel</text>")

    for i in 0:4
        value = ymin + (ymax - ymin) * i / 4
        y = top + height * (1 - i / 4)
        println(io, @sprintf("<line class=\"grid\" x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\"/>", left, y, left + width, y))
        println(io, @sprintf("<text class=\"tick\" x=\"62\" y=\"%.1f\">%s</text>", y + 4, tick_label(value)))
    end

    for hour in range(0, hours; length=5)
        x = left + width * hour / hours
        println(io, @sprintf("<line class=\"grid vertical\" x1=\"%.1f\" y1=\"%.1f\" x2=\"%.1f\" y2=\"%.1f\"/>", x, top, x, top + height))
        if show_hours
            println(io, @sprintf("<text class=\"tick x\" x=\"%.1f\" y=\"%.1f\">%.0f</text>", x, top + height + 18, hour))
        end
    end

    println(io, @sprintf("<rect class=\"frame\" x=\"%.1f\" y=\"%.1f\" width=\"%.1f\" height=\"%.1f\"/>", left, top, width, height))
    for item in series
        dash = item.dashed ? " stroke-dasharray=\"7 5\"" : ""
        points = svg_points(item.values, left, top, width, height, ymin, ymax)
        println(io, "<polyline fill=\"none\" stroke=\"$(item.color)\" stroke-width=\"2.4\"$dash points=\"$points\"/>")
    end

    if show_hours
        println(io, @sprintf("<text class=\"axis-label\" x=\"%.1f\" y=\"%.1f\">Hour</text>", left + width / 2, top + height + 38))
    end
end

function draw_legend(io, series; x, y)
    cursor = x
    for item in series
        dash = item.dashed ? " stroke-dasharray=\"7 5\"" : ""
        println(io, "<line x1=\"$cursor\" y1=\"$y\" x2=\"$(cursor + 24)\" y2=\"$y\" stroke=\"$(item.color)\" stroke-width=\"2.4\"$dash/>")
        println(io, "<text class=\"legend\" x=\"$(cursor + 30)\" y=\"$(y + 4)\">$(item.label)</text>")
        cursor += 30 + 7.2 * length(item.label) + 24
    end
end

function svg_document(draw, path, width, height)
    open(path, "w") do io
        println(io, """<svg xmlns="http://www.w3.org/2000/svg" width="$width" height="$height" viewBox="0 0 $width $height" role="img">""")
        println(io, """<style>
            text { font-family: system-ui, sans-serif; fill: #263238; }
            .title { font-size: 14px; font-weight: 600; }
            .legend { font-size: 12px; }
            .axis-label { font-size: 12px; text-anchor: middle; }
            .tick { font-size: 11px; text-anchor: end; fill: #546e7a; }
            .tick.x { text-anchor: middle; }
            .grid { stroke: #dfe5e8; stroke-width: 1; }
            .grid.vertical { stroke-dasharray: 2 4; }
            .frame { fill: none; stroke: #78909c; stroke-width: 1; }
        </style>""")
        println(io, "<rect width=\"100%\" height=\"100%\" fill=\"white\"/>")
        draw(io)
        println(io, "</svg>")
    end
    @info "Wrote figure" path
end

function solve_hydrogen()
    sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())
    set_silent(model(sim))
    snapshot = Snapshot(sim, Dict(:posy => Posy2Options(
        data_dir=data_dir,
        techdata_file="tech_data.xlsx",
        timeseries_file="time_series.xlsx",
        tech_mode=:excel,
        timeseries_mode=:excel,
    )))

    electricity = Node("country1", EnergyCarrier("electricity country1", sim), rule=:curtailed, tags=[:electricity])
    hydrogen = Node("H2 country1", EnergyCarrier("hydrogen country1", sim), rule=:default, tags=[:hydrogen])
    co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

    makedemand("Hydrogen demand", "country1", hydrogen, snapshot; coeff=0.038)
    makeintermittentsource("Solar", "PV", electricity, co2, snapshot; maxcap=1000.0, weatheryear=2019)
    makeelectrolyser("Electrolyser", "PEM", electricity, hydrogen, snapshot; maxcap=300.0)
    makehydrogenstorage(
        "H2 storage", "Hydrogen storage", hydrogen, snapshot;
        cap=28.0 * 168,
    )

    optimize!(snapshot, cost(snapshot))
    extract(snapshot)
end

function solve_ev(vehicle_to_grid)
    sim = Sim(Model(HiGHS.Optimizer); mesh=TimeMesh())
    set_silent(model(sim))
    snapshot = Snapshot(sim, Dict(:posy => Posy2Options(
        data_dir=data_dir,
        techdata_file="tech_data.xlsx",
        timeseries_file="time_series.xlsx",
        tech_mode=:arguments,
        timeseries_mode=:excel,
    )))

    electricity = Node("country1", EnergyCarrier("electricity country1", sim), rule=:curtailed, evalprice=true, tags=[:electricity])
    co2 = Node("CO2", CO2Carrier("CO2", sim), rule=:curtailed, tags=[:co2])

    makedemand("Demand", "country1", electricity, snapshot)
    daily_extra_demand = Float64[
        30, 15, 0, 0, 15, 45, 90, 140, 80, 30, 0, 40,
        110, 50, 10, 20, 70, 150, 100, 30, 90, 60, 30, 20,
    ]
    makedemand(
        "Variable demand", "country1", electricity, snapshot;
        profile=repeat(daily_extra_demand, 365),
    )
    makeintermittentsource(
        "Solar", "PV", electricity, co2, snapshot;
        cap=1500.0,
        weatheryear=2019,
    )
    makeEV(
        "EV", electricity, snapshot;
        number_ev=10_000.0,
        initial_connected_share=1.0,
        fixed_profile=false,
        smart_charging=!vehicle_to_grid,
        vehicle_to_grid=vehicle_to_grid,
        zone="country1",
        charging_eff=0.9,
        max_charging_power_per_ev=0.01,
        max_dispatch_power_per_ev=vehicle_to_grid ? 0.01 : nothing,
        battery_capacity_per_ev=0.06,
        compensation=vehicle_to_grid ? 20.0 : 0.0,
    )
    makedispatchable(
        "OCGT", "OCGT", electricity, co2, snapshot;
        cap=1200.0,
        fuel_cost=68.24,
        unit_size=100.0,
        uc=true,
        startup_cost=6_270.0,
        min_power=0.3,
        min_uptime=2.0,
        min_downtime=2.0,
        startup_duration=1.0,
        shutdown_duration=1.0,
    )

    optimize!(snapshot, cost(snapshot))
    extract(snapshot)
end

values(series) = Float64.(collect(series))

function write_hydrogen_figure(result)
    hours = 336
    demand = values(balance(result, "Hydrogen demand H2 country1", :input, energy; collapse=false, aggregate=true))[1:hours]
    electrolysis = values(balance(result, "Electrolyser country1", :output, energy; collapse=false, aggregate=true))[1:hours]
    storage = values(balance(result, "H2 storage H2 country1", :output, energy; collapse=false, aggregate=true))[1:hours]
    level = values(balance(result, "H2 storage H2 country1", :level, energy; collapse=false, aggregate=true))[1:hours]

    power = [
        (label="Demand", values=demand, color="#264653", dashed=true),
        (label="Electrolyser", values=electrolysis, color="#2a9d8f", dashed=false),
        (label="From storage", values=storage, color="#7b68a6", dashed=false),
    ]
    stored = [(label="Storage level", values=level, color="#c44536", dashed=false)]

    svg_document(joinpath(assets_dir, "hydrogen-production-week.svg"), 1000, 430) do io
        draw_panel(io, power; top=38.0, height=150.0, title="Hydrogen flows", ylabel="Hydrogen (MW)", hours=hours)
        draw_legend(io, power; x=555, y=22)
        draw_panel(io, stored; top=235.0, height=145.0, title="Hydrogen storage", ylabel="Stored hydrogen (MWh)", hours=hours, ymax=5000.0, show_hours=true)
        draw_legend(io, stored; x=820, y=219)
    end
end

function write_ev_figure(result, vehicle_to_grid, first_hour)
    hours = 48
    window = first_hour:first_hour + hours - 1
    inputs = balance(result, "EV country1", :input, energy; collapse=false, aggregate=false)
    outputs = balance(result, "EV country1", :output, energy; collapse=false, aggregate=false)
    charge = values(inputs["input"])[window]
    driving = values(outputs["driving"])[window]
    level = values(balance(result, "EV country1", :level, energy; collapse=false, aggregate=true))[window]
    price = values(dualprice(result.nodes["country1"]))[window]

    flows = [(label="Grid charging", values=charge, color="#2a9d8f", dashed=false)]
    if vehicle_to_grid
        push!(flows, (label="V2G discharge", values=values(outputs["output"])[window], color="#c44536", dashed=false))
    end
    stored = [(label="Battery level", values=level, color="#e76f51", dashed=false)]
    prices = [(label="Dual price", values=price, color="#264653", dashed=false)]
    driving_series = [(label="Net driving", values=driving, color="#7b68a6", dashed=false)]
    filename = vehicle_to_grid ? "electric-vehicles-v2g.svg" : "electric-vehicles-smart.svg"
    level_span = maximum(level) - minimum(level)
    level_scale = 10.0^floor(log10(max(level_span, 1.0)))
    level_min = floor(minimum(level) / level_scale) * level_scale
    level_max = ceil(maximum(level) / level_scale) * level_scale
    level_max == level_min && (level_max += level_scale)
    driving_lim = nice_upper(maximum(abs, driving))

    svg_document(joinpath(assets_dir, filename), 1000, 720) do io
        draw_panel(io, flows; top=38.0, height=110.0, title="EV grid exchange", ylabel="Power (MW)", hours=hours)
        draw_legend(io, flows; x=vehicle_to_grid ? 660 : 805, y=22)
        draw_panel(io, stored; top=195.0, height=110.0, title="EV battery level", ylabel="Stored energy (MWh)", hours=hours, ymin=level_min, ymax=level_max)
        draw_legend(io, stored; x=835, y=179)
        draw_panel(io, prices; top=352.0, height=110.0, title="Electricity price", ylabel="Dual price", hours=hours)
        draw_legend(io, prices; x=845, y=336)
        draw_panel(io, driving_series; top=509.0, height=110.0, title="Net driving (departure − arrival)", ylabel="Power (MW)", hours=hours, ymin=-driving_lim, ymax=driving_lim, show_hours=true)
        draw_legend(io, driving_series; x=830, y=493)
    end
end

mkpath(assets_dir)
write_hydrogen_figure(solve_hydrogen())
smart_ev = solve_ev(false)
v2g_ev = solve_ev(true)
first_ev_hour = 4201 # 25–26 June: active EV operation and several price levels
write_ev_figure(smart_ev, false, first_ev_hour)
write_ev_figure(v2g_ev, true, first_ev_hour)
