# API Reference

This page groups every public binding exported by POSY2. For a narrative guide
to the constructors, see [Component Builders](components.md). Nosy types and
lower-level modelling operations are documented in the
[Nosy API reference](https://oecd-nea.github.io/Nosy.jl/dev/api/).

## Package

```@docs
POSY2
```

## Configuration And Input Data

```@docs
POSY2Options
posy_options
discountrate
co2_price
tech_mode
timeseries_mode
readtechdata
gettechparam
readtimeseries
gettimeseries
```

## Demand And Flexibility

```@docs
makedemand
makeflathydrogendemand
makeflexhydrogendemand
makeEV
makedemandresponse
```

## Generation

```@docs
makeflathydrogenpurchase
makedispatchable
makenuclear
makesmr
makeintermittentsource
makehydroror
```

## Storage And Conversion

```@docs
makehydroreservoir
makebatteries
makehydrogenstorage
makeelectrolyser
makeHTelectrolyser
```

## Interconnections

```@docs
makepriceinterco
makenodeinterco
```

## Economics And Optimisation

```@docs
eac
applydcopf!
```

## Post-processing And Export

```@docs
selfcost
printsnapshot
```
