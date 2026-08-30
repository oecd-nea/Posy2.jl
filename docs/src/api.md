# API Reference

This page groups every public binding exported by Posy2. For a narrative guide
to the constructors, see [Component Builders](components.md). Nosy types and
lower-level modelling operations are documented in the
[Nosy API reference](https://oecd-nea.github.io/Nosy.jl/dev/api/).

## Package

```@docs
Posy2
```

## Configuration And Input Data

```@docs
Posy2Options
posy_options
discount_rate
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
makedemandresponse
```

## Electric Vehicles

```@docs
makeEV
```

## Generation

```@docs
makedispatchable
makenuclear
makeintermittentsource
makehydroror
```

## Hydrogen

```@docs
makeflathydrogenpurchase
```

## Storage And Conversion

```@docs
makehydroreservoir
makebatterystorage
makehydrogenstorage
makeelectrolyser
```

## Interconnections

```@docs
makepricelink
maketransmissionlink
```

## Economics And Optimisation

```@docs
eac
applydcopf!
```

## Post-processing And Export

```@docs
selfcost
losses
printsnapshot
```
