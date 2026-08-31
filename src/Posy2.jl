"""
    Posy2

High-level country and regional energy-system modelling tools built on
[`Nosy.jl`](https://github.com/oecd-nea/Nosy.jl). Posy2 provides standard 
component builders, optional DC power-flow constraints,and post-processing 
for solved Nosy snapshots.
"""
module Posy2

using Nosy
using JuMP, DataFrames
using ArgCheck, OrderedCollections
using XLSX

export readtechdata, gettechparam
export readtimeseries, gettimeseries

export makedemand, makeEV
export makeflathydrogendemand, makeflexhydrogendemand, makeflathydrogenpurchase
export makedispatchable
export makenuclear
export makeintermittentsource
export makehydroror, makehydroreservoir
export makebatterystorage
export makedemandresponse
export makepricelink, maketransmissionlink
export makeelectrolyser, makehydrogenstorage

export applydcopf!

export eac
export selfcost
export losses
export write_results
export Posy2Options, posy_options, discount_rate, co2_price, tech_mode, timeseries_mode

include("tools/_includes.jl")
include("readdata/_includes.jl")
include("components/_includes.jl")
include("pp/_includes.jl")

end # module Posy2
