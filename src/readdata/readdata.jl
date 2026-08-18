"""
Read data to generate the dataset.
"""

using XLSX, DataFrames
using Memoize

# read the xlsx file
# if it is already open, make a temp copy, read the copy, and delete the copy
# the function is memoized with memoization dispatch on last file modification time
@memoize function saferead(path::String, fname::String, mtime) # memoize with dispatch on mtime
    fpath = joinpath(path, fname)
    try
        return XLSX.readxlsx(fpath)
    catch
        _fpath = tempname(path)
        cp(fpath, _fpath)
        xl = XLSX.readxlsx(_fpath)
        rm(_fpath) 
        return xl
    end
end

function readexcel(path, fname)
    mtime = stat(joinpath(path, fname)).mtime # modification time of file
    return saferead(path, fname, mtime)
end

"""
    readtechdata(filename="tech_data.xlsx"; data_dir=joinpath(pwd(), "data"))

Open and return the Posy2 technology-parameter workbook at
`joinpath(data_dir, filename)`.

The workbook is cached by path, filename, and modification time. If another
application has locked the file, Posy2 reads a temporary copy when possible.
"""
readtechdata(filename="tech_data.xlsx"; data_dir=joinpath(pwd(), "data")) = readexcel(data_dir, filename)
@memoize function gettechdatasheet(xl, sheetname::String) # this function is memoized because gettable is time-consuming
    sns = XLSX.sheetnames(xl)
    if !(sheetname in sns)
        throw(ArgumentError("technology workbook: sheet '$(sheetname)' not found. Available sheets: $(join(string.(sns), ", "))"))
    end
    return DataFrame(XLSX.gettable(xl[sheetname], infer_eltypes=true))
end

"""
    gettechparam(xl, techkey::String, param::String, sheetname::String, digits::Int)
    gettechparam(s::Snapshot, techkey::String, param::String, sheetname::String;
        digits=6)

Read one technology parameter from `sheetname`. Technology sheets use a
`tech` column for parameter names and one column per technology; `techkey`
selects the technology column and `param` selects the row.

The snapshot method resolves the workbook through [`Posy2Options`](@ref) when
`tech_mode=:excel`; `:arguments` rejects direct snapshot lookups.
Numeric values are rounded to `digits`. Cells of a `*_profile` row hold the
yearly cost shares as a semicolon-separated string and are returned as a
`Vector{Float64}`; other strings are returned unchanged. Missing sheets,
columns, rows, or values raise `ArgumentError` with workbook context.
"""
function gettechparam(xl, techkey::String, param::String, sheetname::String, digits::Int)
    df = gettechdatasheet(xl, sheetname)
    tw = "technology workbook, sheet '$(sheetname)'"
    if !("tech" in names(df))
        throw(ArgumentError("$(tw): expected a parameter name column 'tech' (each row names one parameter). Found columns: $(join(string.(names(df)), ", "))"))
    end
    if !(techkey in names(df))
        throw(ArgumentError("$(tw): no technology column '$(techkey)'. Columns: $(join(string.(names(df)), ", "))"))
    end
    sub = df[df[!, "tech"] .== param, [techkey]]
    if nrow(sub) == 0
        throw(ArgumentError("$(tw): no row with tech=='$(param)' for technology column '$(techkey)'"))
    end
    val = first(sub[!, techkey])
    if ismissing(val) || (val isa AbstractFloat && isnan(val)) ||(val isa AbstractString && isempty(strip(val)))
        throw(ArgumentError("$(tw): empty or missing value for parameter row tech=='$(param)', technology column '$(techkey)'"))
    end
    if val isa Real
        return round(val, digits=digits)
    elseif val isa AbstractString && endswith(param, "_profile")
        # Workbooks store yearly cost shares as "0.3;0.4;0.3"; the model works with vectors.
        shares = tryparse.(Float64, split(val, ';'))
        if any(isnothing, shares)
            throw(ArgumentError("$(tw): parameter row tech=='$(param)', technology column '$(techkey)': expected yearly shares separated by ';', got '$(val)'"))
        end
        return Vector{Float64}(shares)
    else
        return val
    end
end
function gettechparam(s::Snapshot, techkey::String, param::String, sheetname::String; digits=6)
    opts = posy_options(s)
    opts.tech_mode === :excel || throw(ArgumentError(
        "technology parameter '$param' for $sheetname/$techkey must be supplied explicitly " *
        "when tech_mode=:arguments"))
    xl = readtechdata(opts.techdata_file; data_dir=opts.data_dir)
    return gettechparam(xl, techkey, param, sheetname, digits)
end

"""
    readtimeseries(filename="time_series.xlsx";
        data_dir=joinpath(pwd(), "data"))

Open and return the Posy2 hourly time-series workbook at
`joinpath(data_dir, filename)`.

The workbook is cached by path, filename, and modification time. If another
application has locked the file, Posy2 reads a temporary copy when possible.
"""
readtimeseries(filename="time_series.xlsx"; data_dir=joinpath(pwd(), "data")) = readexcel(data_dir, filename)
@memoize function gettimeseriesdatasheet(xl, sheetname::String) # this function is memoized because gettable is time-consuming
    sns = XLSX.sheetnames(xl)
    if !(sheetname in sns)
        throw(ArgumentError("time series workbook: sheet '$(sheetname)' not found. Available sheets: $(join(string.(sns), ", "))"))
    end
    return DataFrame(XLSX.gettable(xl[sheetname], infer_eltypes=true))
end

"""
    gettimeseries(xl, title::String, sheetname::String, digits::Int)
    gettimeseries(s::Snapshot, title::String, sheetname::String; digits=6)

Read and return the complete column `title` from `sheetname` in a Posy2
time-series workbook.

The snapshot method resolves the workbook through [`Posy2Options`](@ref) when
`timeseries_mode=:excel`; `:arguments` rejects direct snapshot lookups.
Values are rounded to `digits`. Missing sheets or columns, and columns
containing missing, non-numeric, or non-finite values raise `ArgumentError`
with workbook context.
"""
function gettimeseries(xl, title::String, sheetname::String, digits::Int)
    df = gettimeseriesdatasheet(xl, sheetname)
    tw = "time series workbook, sheet '$(sheetname)'"
    if !(title in names(df))
        hint = sheetname == "transfer_capacities" ?
            " For sheet 'transfer_capacities', expected column names follow 'From>To' between zone/node names (e.g. country3>country1)." : ""
        throw(ArgumentError("$(tw): no column '$(title)'.$(hint) Columns: $(join(string.(names(df)), ", "))"))
    end
    return _validate_timeseries(
        df[!, title]; keyword="column '$title'", context=tw, digits=digits,
    )
end
function gettimeseries(s::Snapshot, title::String, sheetname::String; digits=6)
    opts = posy_options(s)
    opts.timeseries_mode === :excel || throw(ArgumentError(
        "time series '$title' from sheet '$sheetname' must be supplied explicitly " *
        "when timeseries_mode=:arguments"))
    xl = readtimeseries(opts.timeseries_file; data_dir=opts.data_dir)
    return gettimeseries(xl, title, sheetname, digits)
end

"""
    _validate_timeseries(value; expected_length=nothing, allow_scalar=false,
        keyword="profile", context=nothing, digits=6, lower=nothing, upper=nothing)

Validate and normalize a scalar or vector time series. Scalars are accepted
only when `allow_scalar=true` and are expanded to `expected_length`. When an
expected length is supplied, vectors must match it exactly. `lower` and `upper`
restrict the physical domain of the rounded series: pass `lower=0` for a
quantity that cannot be negative, and `lower=0, upper=1` for an availability or
capacity multiplier.
"""
function _validate_timeseries(value;
                              expected_length::Union{Nothing,Integer}=nothing,
                              allow_scalar::Bool=false,
                              keyword::String="profile",
                              context::Union{Nothing,String}=nothing,
                              digits::Int=6,
                              lower::Union{Nothing,Real}=nothing,
                              upper::Union{Nothing,Real}=nothing)
    label = isnothing(context) ? "`$keyword`" : "$context, $keyword"
    values = if value isa Real && !(value isa Bool)
        allow_scalar || throw(ArgumentError("$label must be an hourly vector"))
        isnothing(expected_length) && throw(ArgumentError(
            "an expected length is required to expand scalar $label",
        ))
        converted = Float64(value)
        isfinite(converted) || throw(ArgumentError("$label must be finite"))
        fill(converted, expected_length)
    elseif value isa AbstractVector
        if !isnothing(expected_length) && length(value) != expected_length
            throw(ArgumentError(
                "$label must contain $expected_length hourly values, got $(length(value))",
            ))
        end
        result = Vector{Float64}(undef, length(value))
        for (i, x) in enumerate(value)
            (ismissing(x) || !(x isa Real) || x isa Bool) && throw(ArgumentError(
                "$label contains a non-numeric value at index $i"))
            converted = Float64(x)
            isfinite(converted) || throw(ArgumentError(
                "$label contains a non-finite value at index $i"))
            result[i] = converted
        end
        result
    else
        allowed = allow_scalar ? "a real number or an hourly vector" : "an hourly vector"
        throw(ArgumentError("$label must be $allowed"))
    end
    rounded = round.(values; digits=digits)
    if !isnothing(lower) || !isnothing(upper)
        domain = "[$(isnothing(lower) ? "-Inf" : lower), $(isnothing(upper) ? "Inf" : upper)]"
        for (i, x) in enumerate(rounded)
            ((!isnothing(lower) && x < lower) || (!isnothing(upper) && x > upper)) &&
                throw(ArgumentError(
                    "$label must stay within $domain, got $x at index $i"))
        end
    end
    return rounded
end

"""
    _resolve_timeseries(s, value, title, sheetname; keyword="profile", digits=6,
        lower=nothing, upper=nothing)

Select an explicit value or a workbook column, then validate the result against
the simulation horizon and, when given, against the `lower`/`upper` physical
domain. `sheetname` is needed only for workbook lookup.
"""
function _resolve_timeseries(s::Snapshot,
                             value,
                             title::String,
                             sheetname::Union{Nothing,String};
                             keyword::String="profile",
                             digits::Int=6,
                             lower::Union{Nothing,Real}=nothing,
                             upper::Union{Nothing,Real}=nothing)
    context = nothing
    if isnothing(value)
        timeseries_mode(s) === :excel || throw(ArgumentError(
            "`$keyword` must be supplied explicitly when timeseries_mode=:arguments",
        ))
        isnothing(sheetname) && throw(ArgumentError(
            "a workbook sheet must be specified to resolve `$keyword`",
        ))
        value = gettimeseries(s, title, sheetname; digits=digits)
        filename = posy_options(s).timeseries_file
        context = "time series workbook '$filename', sheet '$sheetname', column '$title'"
    end
    return _validate_timeseries(
        value;
        expected_length=Nosy.nhours(sim(s)), allow_scalar=true,
        keyword=keyword, context=context, digits=digits, lower=lower, upper=upper,
    )
end
