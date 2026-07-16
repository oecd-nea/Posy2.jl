module POSY2

using Nosy
using JuMP, DataFrames
using ArgCheck, OrderedCollections
using XLSX

using Infiltrator

export readtechdata, gettechparam
export readtimeseries, gettimeseries

export makedemand, makeEV
export makeflathydrogendemand, makeflexhydrogendemand, makeflathydrogenpurchase
export makedispatchable
export makenuclear, makesmr
export makeintermittentsource
export makehydroror, makehydroreservoir
export makebatteries
export makedemandresponse
export makepriceinterco, makenodeinterco
export makeelectrolyser, makeHTelectrolyser, makehydrogenstorage

export applydcopf!

export eac
export selfcost
export printsnapshot
export POSY2Options, posy_options, discountrate, co2_price

include("tools/_includes.jl")
include("readdata/_includes.jl")
include("components/_includes.jl")
include("pp/_includes.jl")

end # module POSY2
